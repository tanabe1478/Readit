"""Package an optimized executable by default, with an ad-hoc development signature."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--profile', choices=['release', 'debug'], default='release')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
executable = root / 'target' / args.profile / 'readit'
if not executable.is_file():
    parser.error(f'{executable} is missing; run cargo build' + (' --release' if args.profile == 'release' else ''))
app = root / "artifacts" / "Readit.app" / "Contents"
(app / "MacOS").mkdir(parents=True, exist_ok=True)
temporary_executable = app / "MacOS/.Readit-new"
shutil.copy2(executable, temporary_executable)
# Replace the inode instead of overwriting a mapped executable from an older run.
os.replace(temporary_executable, app / "MacOS/Readit")
with (app / "Info.plist").open("wb") as f:
    plistlib.dump({
        "CFBundleExecutable": "Readit",
        "CFBundleIdentifier": "local.readit.prototype",
        "CFBundleName": "Readit",
        "CFBundleDisplayName": "Readit",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "4",
        "CFBundleShortVersionString": "0.4.0",
        "NSHighResolutionCapable": True,
    }, f)
resources = app / "Resources" / "licenses"
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "THIRD_PARTY_NOTICES.md", resources)
for license_file in (root / "third-party").iterdir():
    if license_file.is_file():
        shutil.copy2(license_file, resources)
mcp_resources = app / "Resources" / "mcp"
mcp_resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "tools/readit_mcp.py", mcp_resources)
shutil.copytree(root / "skills/readit-guide", app / "Resources/skills/readit-guide", dirs_exist_ok=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app.parent)], check=True)
print(app.parent)
