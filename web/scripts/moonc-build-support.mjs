// The subset of moon.pkg used by Readit and its pinned standard-library closure.
// This is not a replacement for Moon's dependency resolver or package installer.
const knownConditions = new Set(['wasm', 'wasm-gc', 'js', 'native', 'llvm', 'debug', 'release']);

export function rememberInput(inputs, file, key, digest) {
  const previous = inputs.get(file);
  if (previous && previous.sha256 !== digest) {
    throw new Error(`Input changed between build reads: ${key}`);
  }
  inputs.set(file, { path: key, sha256: digest });
}

export function tokenize(text) {
  const tokens = [];
  let offset = 0;
  while (offset < text.length) {
    const rest = text.slice(offset);
    const ignored = rest.match(/^(?:\s+|\/\/[^\n]*|\/\*[\s\S]*?\*\/)/);
    if (ignored) {
      offset += ignored[0].length;
      continue;
    }
    const string = rest.match(/^"(?:[^"\\]|\\.)*"/);
    if (string) {
      tokens.push({ kind: 'string', value: JSON.parse(string[0]) });
      offset += string[0].length;
      continue;
    }
    const word = rest.match(/^[A-Za-z_][\w/-]*/);
    if (word) {
      tokens.push({ kind: 'word', value: word[0] });
      offset += word[0].length;
      continue;
    }
    tokens.push({ kind: 'punctuation', value: rest[0] });
    offset += 1;
  }
  return tokens;
}

function list(tokens, start) {
  if (tokens[start]?.value !== '[') throw new Error('Expected a condition list');
  const values = [];
  let index = start + 1;
  while (tokens[index]?.value !== ']') {
    if (!tokens[index]) throw new Error('Unclosed condition list');
    if (tokens[index].value === ',') {
      index += 1;
    } else if (tokens[index].value === '[') {
      const nested = list(tokens, index);
      values.push(nested.value);
      index = nested.end;
    } else if (tokens[index].kind === 'string') {
      values.push(tokens[index].value);
      index += 1;
    } else {
      throw new Error('Unsupported condition expression');
    }
  }
  return { value: values, end: index + 1 };
}

export function matchesCondition(condition, target, mode) {
  if (typeof condition === 'string') {
    if (!knownConditions.has(condition)) throw new Error(`Unknown build condition: ${condition}`);
    return condition === target || condition === mode;
  }
  if (!Array.isArray(condition) || !condition.length) {
    throw new Error('Empty or unsupported build condition');
  }
  const [operator, ...rest] = condition;
  if (['not', 'and', 'or'].includes(operator)) {
    if (!rest.length) throw new Error(`Empty ${operator} condition`);
    const matches = rest.map(value => matchesCondition(value, target, mode));
    if (operator === 'not') return !matches.some(Boolean);
    return operator === 'and' ? matches.every(Boolean) : matches.some(Boolean);
  }
  return condition.map(value => matchesCondition(value, target, mode)).some(Boolean);
}

export function parseManifest(text) {
  const tokens = tokenize(text);
  const imports = [];
  const rules = new Map();
  let supported = null;
  let executable = false;
  for (let index = 0; index < tokens.length; index += 1) {
    if (tokens[index].value === 'import' && tokens[index + 1]?.value === '{') {
      const group = [];
      index += 2;
      while (tokens[index]?.value !== '}') {
        const token = tokens[index];
        if (!token) throw new Error('Unclosed import group');
        if (token.value === ',') {
          index += 1;
          continue;
        }
        if (token.kind !== 'string' || !/^[\w-]+(?:\/[\w-]+)+$/.test(token.value)) {
          throw new Error('Unsupported package import');
        }
        const pkg = token.value;
        let alias = pkg.split('/').at(-1);
        index += 1;
        if (tokens[index]?.value === '@') {
          alias = tokens[index + 1]?.value;
          if (!alias || !/^[A-Za-z_][\w/]*$/.test(alias)) {
            throw new Error('Unsupported import alias');
          }
          index += 2;
        }
        group.push({ pkg, alias });
      }
      if (tokens[index + 1]?.value === 'for') {
        const kind = tokens[index + 2];
        if (kind?.kind !== 'string' || !['test', 'wbtest'].includes(kind.value)) {
          throw new Error('Unsupported import group condition');
        }
        index += 2;
      } else {
        imports.push(...group);
      }
    } else if (tokens[index].value === 'supported_targets') {
      if (tokens[index + 1]?.value !== '=') throw new Error('Invalid supported_targets');
      if (tokens[index + 2]?.kind === 'string') {
        supported = [tokens[index + 2].value];
      } else {
        supported = list(tokens, index + 2).value;
      }
    } else if (tokens[index].value === 'targets' && tokens[index + 1]?.value === ':') {
      if (tokens[index + 2]?.value !== '{') throw new Error('Unsupported targets object');
      index += 3;
      while (tokens[index]?.value !== '}') {
        if (tokens[index]?.value === ',') {
          index += 1;
          continue;
        }
        const file = tokens[index];
        if (file?.kind !== 'string' || !file.value.endsWith('.mbt') ||
            tokens[index + 1]?.value !== ':') {
          throw new Error('Unsupported target file rule');
        }
        const condition = list(tokens, index + 2);
        if (rules.has(file.value)) throw new Error('Duplicate target file rule');
        rules.set(file.value, condition.value);
        index = condition.end;
      }
    } else if (tokens[index].value === 'pkgtype') {
      const values = tokens.slice(index + 1, index + 6).map(token => token.value);
      if (values.join('|') !== '(|kind|:|executable|)') {
        throw new Error('Only executable pkgtype is supported');
      }
      executable = true;
    }
  }
  if (new Set(imports.map(dep => dep.alias)).size !== imports.length) {
    throw new Error('Duplicate import alias');
  }
  return { imports, rules, supported, executable };
}

// The worker API does not expose Moon's automatic prelude/skip-tests flags.
// Generate explicit imports in a virtual file; never rewrite project or SDK files.
export function preludeSource(api, sources, alias) {
  const symbols = new Map();
  for (const match of api.matchAll(
    /^(?:pub(?:\([^)]*\))? )?(type|struct|enum|suberror|trait) ([A-Za-z_]\w*)/gm
  )) {
    symbols.set(match[2], `${match[1] === 'trait' ? 'trait' : 'type'} ${match[2]}`);
  }
  for (const match of api.matchAll(
    /^pub (?:fn(?:\[[^\n\]]*\])?|let|const) ([A-Za-z_]\w*)(?=\(|\s*:(?!:)|\s*=)/gm
  )) {
    symbols.set(match[1], match[1]);
  }
  const source = sources.join('\n');
  const declared = new Set();
  for (const match of source.matchAll(
    /^(?:pub(?:\([^)]*\))? )?(?:fn(?:\[[^\n\]]*\])?|type|struct|enum|suberror|trait|let|const)\s+([A-Za-z_]\w*)(?!\w|::)/gm
  )) {
    declared.add(match[1]);
  }
  for (const match of source.matchAll(/#alias\(\s*"?([A-Za-z_]\w*)(?=\s*[,)]|"\s*[,)]|\s+as)/g)) {
    declared.add(match[1]);
  }
  for (const match of source.matchAll(/(?:pub )?using\s+@[^\s{]+\s*\{([^}]+)\}/g)) {
    for (const item of match[1].matchAll(/(?:type |trait )?([A-Za-z_]\w*)/g)) {
      declared.add(item[1]);
    }
  }
  const selected = [...symbols].filter(([name]) => {
    return !declared.has(name) && new RegExp(`\\b${name}\\b`).test(source);
  });
  return selected.length ? `using @${alias} {${selected.map(([, value]) => value).join(', ')}}\n` : '';
}

export function productionSource(source, parser) {
  if (!/^test\b/m.test(source)) return source;
  const tree = parser.parse(source);
  try {
    const tests = tree.rootNode.namedChildren.filter(node => node.type === 'test_definition');
    const starts = [...source.matchAll(/^test\b/gm)].map(match => match.index);
    if (tests.length !== starts.length || tests.some((node, index) => {
      return node.hasError || node.startIndex > starts[index] || node.endIndex <= starts[index];
    })) {
      throw new Error('Cannot safely exclude inline tests: incomplete test parse');
    }
    let result = source;
    for (const node of tests.reverse()) {
      result = result.slice(0, node.startIndex) + node.text.replace(/[^\r\n]/g, ' ') +
        result.slice(node.endIndex);
    }
    return result;
  } finally {
    tree.delete();
  }
}
