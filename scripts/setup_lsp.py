"""Install pinned, local reading services; do not change the opened project."""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
services = root / "tools/lsp"
node, npm = shutil.which("node"), shutil.which("npm")
if not node or not npm:
    raise SystemExit("Node.js 24以降とnpmをインストールしてください。")
subprocess.run([npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=services, check=True)
runtime = {"node": node}
rust = shutil.which("rust-analyzer")
if rust:
    try:
        subprocess.run([rust, "--version"], check=True, capture_output=True, text=True, timeout=10)
        rustup = shutil.which("rustup")
        if rustup:
            resolved = subprocess.run([rustup, "which", "rust-analyzer"], capture_output=True, text=True, timeout=10)
            if resolved.returncode == 0:
                rust = resolved.stdout.strip()
        runtime["rustAnalyzer"] = rust
    except (subprocess.SubprocessError, OSError):
        pass
(services / "runtime.json").write_text(json.dumps(runtime, indent=2) + "\n")
print("Python / JavaScript / TypeScriptの解析を設定しました。")
if "rustAnalyzer" not in runtime:
    print("Rustも利用する場合: rustup component add rust-analyzer を実行後、このスクリプトを再実行してください。")
