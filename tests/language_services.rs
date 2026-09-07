//! Run with: cargo test --test language_services -- --ignored --nocapture
//! Requires scripts/setup_lsp.py and rust-analyzer. Never executes fixture source.
use readit::language_service::{Query, Service, Snapshot, position_at};
use std::{fs, path::PathBuf};
struct Fixture(PathBuf);
impl Fixture {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "readit-lsp-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        Self(root.canonicalize().unwrap())
    }
    fn write(&self, p: &str, text: &str) {
        let path = self.0.join(p);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
    fn snapshot(&self, path: &str, text: &str, needle: &str, extra: Vec<(&str, &str)>) -> Snapshot {
        let mut documents = vec![(self.0.join(path), text.into())];
        documents.extend(extra.into_iter().map(|(p, t)| (self.0.join(p), t.into())));
        Snapshot {
            root: self.0.clone(),
            path: self.0.join(path),
            position: position_at(text, text.rfind(needle).unwrap() + 1),
            documents,
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
#[test]
#[ignore = "requires local Python language server"]
fn python_definitions_references_symbols_hover_and_unsaved_edits() {
    let f = Fixture::new("python");
    let module = "def original(value: int) -> int:\n    \"\"\"Double a value.\"\"\"\n    return value * 2\n\ndef revised(value: int) -> int:\n    return value * 3\n";
    let code = "from helpers import original as chosen\n# 🦀 Unicode before a reference\nresult = chosen(3)\n\ndef unrelated():\n    chosen = 42\n    return chosen\n";
    f.write("helpers.py", module);
    f.write("main.py", code);
    let mut service = Service::default();
    let mut snapshot = f.snapshot("main.py", code, "chosen(3)", vec![("helpers.py", module)]);
    let answer = service.query(Query::Definition, snapshot.clone()).unwrap();
    println!("Python definition: {answer:?}");
    assert!(
        answer
            .targets
            .iter()
            .any(|t| t.path.ends_with("helpers.py") && t.start.line == 0)
    );
    let hover = service.query(Query::Hover, snapshot.clone()).unwrap();
    assert!(hover.information.contains("value"));
    let symbols = service.query(Query::Symbols, snapshot.clone()).unwrap();
    assert!(symbols.targets.iter().any(|t| t.name.contains("unrelated")));
    // Pyright treats an explicit import alias as a distinct symbol. References
    // at the alias must resolve its calls without including a shadowed local.
    let refs = service.query(Query::References, snapshot.clone()).unwrap();
    println!("Python alias references: {refs:?}");
    assert!(
        refs.targets
            .iter()
            .any(|t| t.path.ends_with("main.py") && t.start.line == 2)
    );
    assert!(
        !refs
            .targets
            .iter()
            .any(|t| t.path.ends_with("main.py") && t.start.line >= 5)
    );
    snapshot.path = f.0.join("helpers.py");
    snapshot.position = position_at(module, module.find("original").unwrap() + 1);
    let imports = service.query(Query::References, snapshot).unwrap();
    assert!(
        imports
            .targets
            .iter()
            .any(|t| t.path.ends_with("main.py") && t.start.line == 0)
    );
    let edited = code.replacen("original as chosen", "revised as chosen", 1);
    let answer = service
        .query(
            Query::Definition,
            f.snapshot(
                "main.py",
                &edited,
                "chosen(3)",
                vec![("helpers.py", module)],
            ),
        )
        .unwrap();
    assert!(
        answer
            .targets
            .iter()
            .any(|t| t.path.ends_with("helpers.py") && t.start.line == 4)
    );
    assert_eq!(fs::read_to_string(f.0.join("main.py")).unwrap(), code);
}
#[test]
#[ignore = "requires local TypeScript language server"]
fn typescript_aliases_types_implementations_and_references() {
    let f = Fixture::new("typescript");
    let module = "export interface Named { name: string }\nexport class Person implements Named { name = 'Alice'; }\nexport function greet(value: Named) { return value.name; }\n";
    let code = "import { greet as hello, Named, Person } from './model';\nconst value: Named = new Person();\nconst result = hello(value);\nfunction other() { const hello = 3; return hello; }\n";
    f.write(
        "tsconfig.json",
        "{\"compilerOptions\":{\"strict\":true,\"target\":\"ES2022\"},\"include\":[\"*.ts\"]}",
    );
    f.write("model.ts", module);
    f.write("main.ts", code);
    let mut service = Service::default();
    let snapshot = f.snapshot("main.ts", code, "hello(value)", vec![("model.ts", module)]);
    let answer = service.query(Query::Definition, snapshot.clone()).unwrap();
    println!("TS definition: {answer:?}");
    assert!(
        answer
            .targets
            .iter()
            .any(|t| t.path.ends_with("model.ts") && t.start.line == 2)
    );
    let answer = service.query(Query::References, snapshot.clone()).unwrap();
    assert!(
        !answer
            .targets
            .iter()
            .any(|t| t.path.ends_with("main.ts") && t.start.line == 3)
    );
    let snapshot = f.snapshot("main.ts", code, "value);", vec![("model.ts", module)]);
    assert!(
        service
            .query(Query::TypeDefinition, snapshot)
            .unwrap()
            .targets
            .iter()
            .any(|t| t.path.ends_with("model.ts") && t.start.line == 0)
    );
    let mut snapshot = f.snapshot("model.ts", module, "Named", vec![("main.ts", code)]);
    snapshot.position = position_at(module, module.find("Named").unwrap() + 1);
    let answer = service.query(Query::Implementation, snapshot).unwrap();
    println!("TS implementation: {answer:?}");
    assert!(
        answer
            .targets
            .iter()
            .any(|t| t.path.ends_with("model.ts") && t.start.line == 1)
    );
}
#[test]
#[ignore = "requires rust-analyzer"]
fn rust_definition_and_references() {
    let f = Fixture::new("rust");
    f.write(
        "Cargo.toml",
        "[package]\nname = \"readit_nav_fixture\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
    );
    let code =
        "pub fn double(value: i32) -> i32 { value * 2 }\npub fn example() -> i32 { double(21) }\n";
    f.write("src/lib.rs", code);
    let mut service = Service::default();
    let snapshot = f.snapshot("src/lib.rs", code, "double(21)", vec![]);
    let mut found = false;
    for _ in 0..10 {
        match service.query(Query::Definition, snapshot.clone()) {
            Ok(answer) if !answer.targets.is_empty() => {
                assert_eq!(answer.targets[0].start.line, 0);
                found = true;
                break;
            }
            Ok(_) => std::thread::sleep(std::time::Duration::from_millis(500)),
            Err(e) => panic!("{e}"),
        }
    }
    assert!(found, "rust-analyzer did not resolve fixture");
    let mut snapshot = snapshot;
    snapshot.position = position_at(code, code.find("double").unwrap() + 1);
    assert!(
        service
            .query(Query::References, snapshot)
            .unwrap()
            .targets
            .iter()
            .any(|t| t.start.line == 1)
    );
}
