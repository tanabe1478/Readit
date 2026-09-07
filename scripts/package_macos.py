"""Package the local debug executable with an ad-hoc signature, not for distribution."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import os

root = Path(__file__).resolve().parents[1]
app = root / "artifacts" / "Readit.app" / "Contents"
(app / "MacOS").mkdir(parents=True, exist_ok=True)
temporary_executable = app / "MacOS/.Readit-new"
shutil.copy2(root / "target/debug/readit", temporary_executable)
# Replace the inode instead of overwriting a mapped executable from an older run.
os.replace(temporary_executable, app / "MacOS/Readit")
with (app / "Info.plist").open("wb") as f:
    plistlib.dump({
        "CFBundleExecutable": "Readit",
        "CFBundleIdentifier": "local.readit.prototype",
        "CFBundleName": "Readit",
        "CFBundleDisplayName": "Readit",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "3",
        "CFBundleShortVersionString": "0.3.0",
        "NSHighResolutionCapable": True,
    }, f)
resources = app / "Resources" / "licenses"
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root / "THIRD_PARTY_NOTICES.md", resources)
for license_file in (root / "third-party").iterdir():
    if license_file.is_file():
        shutil.copy2(license_file, resources)
subprocess.run(["codesign", "--force", "--sign", "-", str(app.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app.parent)], check=True)
print(app.parent)
