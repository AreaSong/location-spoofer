"""仅用于脚本行为测试的合成 bundle 和隔离工作区，不是可安装 App。"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = "PaopaoLocationSpoofer.app"
EXT_NAME = "RouteLiveActivity.appex"
APP_ID = "com.paopaolabs.location-spoofer"


def bundle(root):
    app = root / APP_NAME
    ext = app / "PlugIns" / EXT_NAME
    for path, executable, identifier, kind in (
        (app, "PaopaoLocationSpoofer", APP_ID, "APPL"),
        (ext, "RouteLiveActivity", APP_ID + ".route-activity", "XPC!"),
    ):
        path.mkdir(parents=True, exist_ok=True)
        info = dict(CFBundleExecutable=executable, CFBundleIdentifier=identifier,
                    CFBundlePackageType=kind, CFBundleVersion="11",
                    CFBundleShortVersionString="1.1.0.0",
                    MinimumOSVersion="16.2" if kind == "XPC!" else "15.0")
        if kind == "XPC!":
            info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
        else:
            info["NSSupportsLiveActivities"] = True
        (path / "Info.plist").write_bytes(plistlib.dumps(info))
        (path / executable).write_bytes(b"synthetic executable\n")
        (path / executable).chmod(0o755)
    (app / "A").write_text("old A")
    (app / "B").write_text("old B")
    return app


def archive(payload, output):
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
        for file in sorted(payload.rglob("*")):
            z.write(file, file.relative_to(payload.parent))


def run(args, cwd=ROOT, env=None):
    return subprocess.run([str(a) for a in args], cwd=cwd,
                          env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def workspace(root):
    root.mkdir()
    shutil.copytree(ROOT / "Scripts", root / "Scripts")
    for name in ("build.sh", "Makefile"):
        shutil.copy2(ROOT / name, root / name)
    (root / "Core").mkdir()
    tools = root / "tools"
    tools.mkdir()
    env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
               FIXTURE_ROOT=str(root), NM_CASE="early", LIPO_CASE="ok")
    return env, tools
