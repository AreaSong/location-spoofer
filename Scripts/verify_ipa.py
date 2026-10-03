"""IPA 只读结构/代码签名检查。无需第三方 Python 包，不访问签名凭据。"""
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile
import zlib
from xml.parsers.expat import ExpatError

from deployment_targets import DeploymentError, EXPECTED_TARGETS, check_macho, check_version

APP_NAME = "PaopaoLocationSpoofer.app"
EXT_NAME = "RouteLiveActivity.appex"
APP_ID = "com.paopaolabs.location-spoofer"


class VerificationError(Exception):
    def __init__(self, code, category, message):
        super().__init__(f"ERROR[{category}]: {message}")
        self.code = code


def fail(code, category, message):
    raise VerificationError(code, category, message)


def safe_entries(archive):
    entries = archive.infolist()
    paths = {}
    members = {}
    explicit_paths = set()
    for entry in entries:
        name = entry.filename
        parts = (name[:-1] if entry.is_dir() else name).split("/")
        kind = stat.S_IFMT(entry.external_attr >> 16)
        # 本项目 iOS bundle 是普通文件/目录树；拒绝链接和特殊文件，避免解包逃逸。
        if (entry.orig_filename != name or "\\" in name or ":" in name
                or any(p in ("", ".", "..") for p in parts)
                or any(ord(c) < 32 for c in name)
                or kind not in (0, stat.S_IFREG, stat.S_IFDIR)
                or (kind == stat.S_IFDIR and not entry.is_dir())
                or (kind == stat.S_IFREG and entry.is_dir())):
            fail(5, "UNSAFE_PATH", "ZIP 含非法路径、链接或特殊文件")
        # macOS 常用文件系统不区分大小写且会规范化 Unicode；先拒绝别名覆盖。
        raw_path = "/".join(parts)
        if raw_path in explicit_paths:
            fail(5, "UNSAFE_PATH", "ZIP 含重复或冲突条目")
        explicit_paths.add(raw_path)
        # 隐式父目录同样参与别名/类型检查，不能依赖解包文件系统替我们判断路径。
        for length in range(1, len(parts) + 1):
            raw_path = "/".join(parts[:length])
            is_directory = length < len(parts) or entry.is_dir()
            key = unicodedata.normalize("NFD", raw_path).casefold()
            value = (raw_path, is_directory)
            if key in paths and paths[key] != value:
                fail(5, "UNSAFE_PATH", "ZIP 含路径别名或文件/目录冲突")
            paths[key] = value
            members[raw_path] = is_directory
    return entries, members


def extract(archive, entries, destination):
    # 所有路径已整体检查；不使用可还原链接的外部解包命令。
    for entry in entries:
        target = destination / entry.filename
        if entry.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(entry) as source, target.open("xb") as output:
            shutil.copyfileobj(source, output)
        target.chmod((entry.external_attr >> 16) & 0o777 or 0o644)


def read_bundle(destination, relative, members):
    path = destination / relative
    if members.get(relative) is not True or not path.is_dir():
        fail(6, "BUNDLE", "缺少预期 App 或实时活动扩展")
    if members.get(relative + "/Info.plist") is not False:
        fail(7, "PLIST", "缺少精确命名的 Info.plist")
    try:
        info = plistlib.loads((path / "Info.plist").read_bytes())
    except (OSError, ValueError, TypeError, OverflowError, plistlib.InvalidFileException, ExpatError):
        fail(7, "PLIST", "Info.plist 缺失、不可读或无法解析")
    if not isinstance(info, dict):
        fail(7, "PLIST", "Info.plist 根节点必须是字典")
    executable = info.get("CFBundleExecutable")
    if (not isinstance(executable, str) or not executable or executable in (".", "..")
            or any(c in executable for c in ("/", "\\", "\x00"))):
        fail(8, "EXECUTABLE", "CFBundleExecutable 必须指向 bundle 内的文件名")
    binary = path / executable
    if (members.get(relative + "/" + executable) is not False or not binary.is_file()
            or not binary.stat().st_size or not binary.stat().st_mode & 0o111):
        fail(8, "EXECUTABLE", "可执行文件缺失、为空或没有执行权限")
    return info


def check_structure(destination, members, macho=False):
    payload = destination / "Payload"
    app_relative = "Payload/" + APP_NAME
    ext_relative = app_relative + "/PlugIns/" + EXT_NAME
    app, ext = destination / app_relative, destination / ext_relative
    app_info = read_bundle(destination, app_relative, members)
    ext_info = read_bundle(destination, ext_relative, members)
    if set(payload.glob("*.app")) != {app} or set((app / "PlugIns").glob("*.appex")) != {ext}:
        fail(9, "CONTRACT", "App 或扩展集合不符合项目约定")
    expected = ((app_info, APP_ID, "APPL"), (ext_info, APP_ID + ".route-activity", "XPC!"))
    for info, identifier, kind in expected:
        if info.get("CFBundleIdentifier") != identifier or info.get("CFBundlePackageType") != kind:
            fail(9, "CONTRACT", "bundle 标识或类型不符合项目约定")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        version = app_info.get(key)
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version):
            fail(9, "CONTRACT", "App 版本字段无效")
        if ext_info.get(key) != version:
            fail(9, "CONTRACT", "主 App 与扩展版本不一致")
    extension = ext_info.get("NSExtension")
    if (app_info.get("NSSupportsLiveActivities") is not True or not isinstance(extension, dict)
            or extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension"):
        fail(9, "CONTRACT", "实时活动声明或扩展类型无效")
    for path, info, target in ((app, app_info, "PaopaoLocationSpoofer"),
                               (ext, ext_info, "RouteLiveActivity")):
        expected = EXPECTED_TARGETS[target]
        check_version(info.get("MinimumOSVersion"), expected, f"{path.name} MinimumOSVersion")
        if macho:
            check_macho(path / info["CFBundleExecutable"], expected)
    return app, ext


def check_signatures(destination, app, ext, members):
    for path in (ext, app):
        marker = path / "_CodeSignature/CodeResources"
        relative = marker.relative_to(destination).as_posix()
        if members.get(relative) is not False or not marker.is_file() or not marker.stat().st_size:
            fail(10, "SIGNATURE_MISSING", "App 或扩展缺少代码签名资源")
    codesign = shutil.which("codesign")
    if not codesign:
        fail(12, "TOOL", "缺少 codesign 验证工具")
    for path in (ext, app):
        try:
            result = subprocess.run([codesign, "--verify", "--deep", "--strict", str(path)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        except OSError:
            fail(12, "TOOL", "无法执行 codesign 验证工具")
        if result.returncode == 1:
            fail(11, "SIGNATURE_INVALID", "代码签名校验失败")
        if result.returncode != 0:
            fail(12, "TOOL", "codesign 验证工具异常退出")


def verify(mode, filename, macho=False):
    if not filename.is_file():
        fail(3, "INPUT", "输入 IPA 不存在或不是普通文件")
    try:
        with zipfile.ZipFile(filename) as archive:
            entries, members = safe_entries(archive)
            if archive.testzip() is not None:
                fail(4, "ZIP", "ZIP 条目校验失败")
            with tempfile.TemporaryDirectory(prefix="verify-ipa.") as folder:
                destination = Path(folder)
                extract(archive, entries, destination)
                app, ext = check_structure(destination, members, macho)
                if mode == "--signed":
                    check_signatures(destination, app, ext, members)
    except (zipfile.BadZipFile, NotImplementedError, RuntimeError, EOFError, zlib.error, UnicodeError):
        fail(4, "ZIP", "ZIP 损坏、加密或使用不支持的格式")
    except OSError:
        fail(13, "IO", "读取 IPA 或隔离目录操作失败")


def main(args):
    macho = len(args) == 3 and args[1] == "--macho"
    if macho:
        args = [args[0], args[2]]
    if len(args) != 2 or args[0] not in ("--unsigned", "--signed"):
        print("Usage: verify-ipa.sh --unsigned|--signed [--macho] /path/to/app.ipa", file=sys.stderr)
        return 2
    try:
        verify(args[0], Path(args[1]), macho)
    except (VerificationError, DeploymentError) as error:
        print(error, file=sys.stderr)
        return error.code
    print("PASS: IPA 结构完整（App、实时活动扩展、标识、版本、MinimumOSVersion 和可执行权限）")
    if not macho:
        print("INFO: 未检查 Mach-O 最低系统版本；macOS 正式产物门禁需传 --macho")
    if args[0] == "--signed":
        print("PASS: codesign 代码签名校验；未检查 provisioning/entitlements 一致性或设备可安装性")
    else:
        print("INFO: 未签名产物结构模式，未执行代码签名校验")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
