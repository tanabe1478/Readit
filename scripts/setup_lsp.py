"""Install pinned, local reading services; do not change the opened project."""
import hashlib
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

# Eclipse JDT Language Server, pinned to a milestone build rather than the rotating snapshot.
JDTLS_URL = "https://download.eclipse.org/jdtls/milestones/1.50.0/jdt-language-server-1.50.0-202509041425.tar.gz"
JDTLS_SHA256 = "3292c5c33888f95ab0ff718e777ee94ff5496b8635a23a8844b876ee090ebdea"


def install_java(services: Path) -> str | None:
    """Unpack the Java server and return its launcher jar, or None when Java is unavailable."""
    java = shutil.which("java")
    if not java:
        print("Javaを読む場合: JDK 21以降を入れてから、このスクリプトを再実行してください。")
        return None
    target = services / "jdtls"
    launcher = next(target.glob("plugins/org.eclipse.equinox.launcher_*.jar"), None)
    if launcher is None:
        archive = services / "jdt-language-server.tar.gz"
        print("Eclipse JDT Language Serverを取得しています…")
        with urllib.request.urlopen(JDTLS_URL, timeout=300) as response:
            archive.write_bytes(response.read())
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if digest != JDTLS_SHA256:
            archive.unlink()
            raise SystemExit(f"ダウンロードの検証に失敗しました: {digest}")
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        with tarfile.open(archive) as tar:
            tar.extractall(target, filter="data")
        archive.unlink()
        launcher = next(target.glob("plugins/org.eclipse.equinox.launcher_*.jar"), None)
    if launcher is None:
        raise SystemExit("JDT Language Serverのlauncherが見つかりません。")
    return str(launcher)

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
java_launcher = install_java(services)
if java_launcher:
    runtime["java"] = shutil.which("java")
    runtime["javaLauncher"] = java_launcher
    suffix = "_arm" if platform.machine() == "arm64" else ""
    runtime["javaConfiguration"] = str(services / f"jdtls/config_mac{suffix}")
(services / "runtime.json").write_text(json.dumps(runtime, indent=2) + "\n")
print("Python / JavaScript / TypeScriptの解析を設定しました。")
if java_launcher:
    print("Javaの解析を設定しました。")
if "rustAnalyzer" not in runtime:
    print("Rustも利用する場合: rustup component add rust-analyzer を実行後、このスクリプトを再実行してください。")
