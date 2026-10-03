"""部署版本契约与检查；有效设置/Mach-O 检查需要 macOS Xcode 工具。"""
import json
import re
import subprocess
import sys

# 产品支持约定的唯一检查预期来源，独立于待检查的 project.yml 和构建产物。
# project.yml 是生成工程的输入；调整支持范围时必须一起审阅此契约与独立测试样本。
EXPECTED_TARGETS = {"PaopaoLocationSpoofer": "15.0", "RouteLiveActivity": "16.2"}


class DeploymentError(Exception):
    def __init__(self, message, code=14):
        super().__init__(f"ERROR[{'TOOL' if code == 12 else 'DEPLOYMENT'}]: {message}")
        self.code = code


def version_components(value, context):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise DeploymentError(f"{context}: 最低系统版本缺失或非法: {value!r}")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def check_version(value, expected, context):
    if version_components(value, context) != version_components(expected, context):
        raise DeploymentError(f"{context}: 预期 {expected}，实际 {value}")


def tool_output(args, context):
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False, timeout=120)
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        raise DeploymentError(f"{context}: 无法读取工具输出 ({args[0]}): {error}", 12) from error
    if result.returncode:
        raise DeploymentError(
            f"{context}: {args[0]} 退出 {result.returncode}: {result.stderr.strip()[:500]}", 12)
    return result.stdout


def check_build_settings(data, target, config, sdk):
    context = f"{target} [{config}/{sdk}] IPHONEOS_DEPLOYMENT_TARGET"
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise DeploymentError(f"{context}: build settings 不是 target 列表")
    matches = [item for item in data if item.get("target") == target]
    if len(matches) != 1 or not isinstance(matches[0].get("buildSettings"), dict):
        raise DeploymentError(f"{context}: 未得到唯一 target 的有效设置")
    settings = matches[0]["buildSettings"]
    for field, expected in (("CONFIGURATION", config), ("PLATFORM_NAME", sdk)):
        if settings.get(field) != expected:
            raise DeploymentError(f"{context}: {field} 预期 {expected}，实际 {settings.get(field)!r}")
    value = settings.get("IPHONEOS_DEPLOYMENT_TARGET")
    check_version(value, EXPECTED_TARGETS[target], context)
    print(f"PASS: {context}={value}")


def check_project(project):
    for target in EXPECTED_TARGETS:
        for config in ("Debug", "Release"):
            for sdk, destination in (("iphoneos", "generic/platform=iOS"),
                                     ("iphonesimulator", "generic/platform=iOS Simulator")):
                context = f"{target} [{config}/{sdk}] build settings"
                # scheme 输出未必包含依赖扩展，逐 target 查询以免漏检继承值。
                output = tool_output([
                    "xcodebuild", "-project", str(project), "-target", target,
                    "-configuration", config, "-sdk", sdk, "-destination", destination,
                    "-showBuildSettings", "-json", "CODE_SIGNING_ALLOWED=NO",
                    "CODE_SIGNING_REQUIRED=NO",
                ], context)
                try:
                    data = json.loads(output)
                except ValueError as error:
                    raise DeploymentError(f"{context}: 无法解析 Xcode JSON", 12) from error
                check_build_settings(data, target, config, sdk)


def single_field(output, field, context):
    lines = [line.split() for line in output.splitlines()]
    matches = [parts for parts in lines if parts and parts[0] == field]
    if len(matches) != 1 or len(matches[0]) != 2:
        raise DeploymentError(f"{context}: {field} 缺失、非法或不唯一")
    return matches[0][1]


def macho_minimum(output, context):
    # 只解释 vtool 的部署 load command；sdk 和链接器 tool version 都不是部署目标。
    command = single_field(output, "cmd", context)
    if command == "LC_BUILD_VERSION":
        platform = single_field(output, "platform", context)
        if platform not in ("IOS", "2"):
            raise DeploymentError(f"{context}: platform 应为 IOS，实际 {platform}")
        field = "minos"
    elif command == "LC_VERSION_MIN_IPHONEOS":
        field = "version"
    else:
        raise DeploymentError(f"{context}: 不支持或缺少 iOS 最低版本 load command: {command}")
    value = single_field(output, field, context)
    version_components(value, f"{context} {command}.{field}")
    return value, f"{command}.{field}"


def check_macho(binary, expected):
    context = f"{binary.parent.name}/{binary.name} Mach-O"
    archs = tool_output(["xcrun", "lipo", "-archs", str(binary)], context).split()
    if (not archs or len(archs) != len(set(archs))
            or any(not re.fullmatch(r"[A-Za-z0-9_]+", arch) for arch in archs)):
        raise DeploymentError(f"{context}: 无法读取有效架构列表")
    for arch in archs:
        output = tool_output(["xcrun", "vtool", "-arch", arch, "-show-build", str(binary)], context)
        value, field = macho_minimum(output, f"{context} [{arch}]")
        check_version(value, expected, f"{context} [{arch}] {field}")
        print(f"PASS: {context} [{arch}] {field}={value}")


def main(args):
    if len(args) != 2 or args[0] != "--project":
        print("Usage: python3 Scripts/deployment_targets.py --project /path/to/app.xcodeproj",
              file=sys.stderr)
        return 2
    try:
        check_project(args[1])
    except DeploymentError as error:
        print(error, file=sys.stderr)
        return error.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
