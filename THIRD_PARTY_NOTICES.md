# Third-party notices

Readit runs in the browser (`web/`). The components delivered to the browser,
web-tree-sitter and the Tree-sitter grammars, are listed with versions and licenses
in `web/README.md` (第三者の部品). The GPUI desktop version and its Rust dependencies
were removed in October 2026, so their notices are no longer bundled.

## Local language servers

Readit implements its own LSP client. Language servers run as local processes on
demand. npm versions are pinned in `tools/lsp/package-lock.json`:

- Pyright 1.1.413, Microsoft Corporation: MIT. `third-party/PYRIGHT-MIT.txt`.
  https://github.com/microsoft/pyright
  Bundled typeshed: `third-party/PYRIGHT-TYPESHED-LICENSE.txt`.
- TypeScript Language Server 6.0.0, TypeFox and contributors: Apache-2.0.
  `third-party/TYPESCRIPT-LANGUAGE-SERVER-LICENSE.txt`.
  https://github.com/typescript-language-server/typescript-language-server
- TypeScript 5.9.3, Microsoft Corporation: Apache-2.0.
  `third-party/TYPESCRIPT-APACHE-2.0.txt` and `third-party/TYPESCRIPT-THIRD-PARTY-NOTICES.txt`.
  https://github.com/microsoft/TypeScript
- rust-analyzer: MIT OR Apache-2.0, invoked from the locally installed Rust toolchain.
  https://github.com/rust-lang/rust-analyzer
- Eclipse JDT Language Server 1.50.0: EPL-2.0, downloaded by `scripts/setup_lsp.py`.

These direct notices do not replace the complete distribution review of bundled
server dependencies, Node.js and final application assets.

## Distribution status

This is a local development prototype, not a signed commercial release. Review the
exact bundled grammars, server dependencies and runtime before commercial distribution.

The original Readit source has not been assigned an open-source license.
