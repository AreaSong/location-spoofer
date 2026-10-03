"""执行实际构建脚本；编译器由可控工具替身代替，ZIP/复制/验证逻辑真实运行。"""
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from ipa_test_support import APP_NAME, EXT_NAME, bundle, run, workspace

TOOLS = r'''#!/usr/bin/python3
import json, os, pathlib, shutil, signal, sys
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
with (root / "calls").open("a") as f:
    f.write(tool + " " + repr(args) + "\n")
if tool == "go":
    with (root / "go-toolchains").open("a") as f:
        f.write(os.environ.get("GOTOOLCHAIN", "unset") + "\n")
    if os.environ.get("GO_FAIL_AT") == " ".join(args[:2]):
        sys.exit(26)
if tool == "node":
    sys.exit(27 if os.environ.get("NODE_FAIL") else 0)
if tool == "go" and args[0] == "build":
    out = pathlib.Path(args[args.index("-o") + 1])
    out.write_bytes(b"archive")
    out.with_suffix(".h").write_bytes(b"header")
elif tool == "xcrun":
    if args[0] == "lipo":
        if "-create" in args:
            pathlib.Path(args[args.index("-output") + 1]).write_bytes(b"fat archive")
        elif args[-1].endswith(("/PaopaoLocationSpoofer", "/RouteLiveActivity")):
            print("arm64")
        else:
            case = os.environ["LIPO_CASE"]
            print("x86_64" if case == "missing" else "" if case == "empty"
                  else "arm64" if case == "missing_sim_x86" else "arm64 x86_64")
            sys.exit(23 if case == "fail" else 0)
    elif args[0] == "vtool":
        minimum = "16.2" if args[-1].endswith("/RouteLiveActivity") else "15.0"
        if os.environ.get("MACHO_BAD") and args[-1].endswith("/RouteLiveActivity"):
            minimum = "15.0"
        print("Load command 11\n cmd LC_BUILD_VERSION\n platform IOS\n minos "
              + minimum + "\n sdk 26.5\n ntools 1\n tool LD\n version 1267.0")
    elif args[0] == "nm":
        case = os.environ["NM_CASE"]
        if case in ("early", "fail"):
            print("000000 T _wloccore_startproxyv2", flush=True)
        if case != "empty":
            for _ in range(30000):
                print("000000 T _irrelevant_symbol_padding")
        if case == "late":
            print("000000 T _wloccore_startproxyv2")
        if case == "undefined":
            print("         U _wloccore_startproxyv2")
        sys.exit(24 if case == "fail" else 0)
    elif args[0] == "simctl":
        prefix = "com.apple.CoreSimulator.SimRuntime."
        runtimes = [{"identifier": prefix + name, "version": version, "isAvailable": available}
                    for name, version, available in [("iOS-18-5", "18.5", True),
                        ("iOS-26-5", "26.5", True), ("iOS-27-0", "27.0", False),
                        ("tvOS-27-0", "27.0", True)]]
        def device(uid, **kwargs):
            return dict(name="iPhone Same Name", udid=uid, isAvailable=True,
                        deviceTypeIdentifier="com.apple.CoreSimulator.SimDeviceType.iPhone-17", **kwargs)
        old = device("11111111-1111-1111-1111-111111111111")
        chosen = device("22222222-ABCD-2222-2222-222222222222")
        duplicate = device("33333333-3333-3333-3333-333333333333")
        unavailable = dict(old, isAvailable=False)
        devices = {prefix + "iOS-18-5": [old], prefix + "iOS-26-5": [duplicate, chosen, unavailable],
                   prefix + "iOS-27-0": [old], prefix + "tvOS-27-0": [old]}
        case = os.environ.get("SIM_CASE")
        if case == "no_devices": devices = {}
        if case == "no_runtimes": runtimes = []
        if case == "no_iphone":
            devices = {prefix + "iOS-26-5": [dict(old, deviceTypeIdentifier="iPad")]}
        print("broken JSON" if case == "invalid_json" else json.dumps(
            dict(runtimes=runtimes, devices=devices, padding="x" * 200000)))
        sys.exit(25 if os.environ.get("SIM_FAIL") else 0)
    else:
        print("/mock/sdk" if "--show-sdk-path" in args else "/mock/clang")
elif tool == "xcodebuild" and "-showBuildSettings" in args:
    target = args[args.index("-target") + 1]
    config = args[args.index("-configuration") + 1]
    sdk = args[args.index("-sdk") + 1]
    minimum = "16.2" if target == "RouteLiveActivity" else "15.0"
    if os.environ.get("SETTINGS_BAD") == "/".join((target, config, sdk)):
        minimum = "17.0"
    print(json.dumps([dict(target=target, buildSettings=dict(CONFIGURATION=config,
        PLATFORM_NAME=sdk, IPHONEOS_DEPLOYMENT_TARGET=minimum, SDK_VERSION="26.5"))]))
elif tool == "xcodebuild" and "build" in args:
    app = root / "build/DerivedData/Build/Products/Release-iphoneos/PaopaoLocationSpoofer.app"
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / "fixture/PaopaoLocationSpoofer.app", app)
elif tool == "xcodebuild" and "test" in args:
    sys.exit(29 if os.environ.get("TEST_FAIL") else 0)
'''


class BuildBehavior(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="build scripts ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo space ' quote"
        self.env, self.tools = workspace(self.root)
        dispatcher = self.tools / "dispatcher"
        dispatcher.write_text(TOOLS)
        dispatcher.chmod(0o755)
        for name in ("xcrun", "go", "xcodegen", "xcodebuild", "node"):
            (self.tools / name).symlink_to(dispatcher)
        self.app = bundle(self.root / "fixture")
        self.ipa = self.root / "dist/PaopaoLocationSpoofer-unsigned.ipa"

    def command(self, *args):
        return run(args, cwd=self.root, env=self.env)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_core_symbol_and_architecture_failures(self):
        for case, expected in (("early", 0), ("late", 0), ("missing", 1), ("empty", 1),
                               ("undefined", 1), ("fail", 24)):
            with self.subTest(nm=case):
                self.env["NM_CASE"] = case
                result = self.command("./Scripts/build-core.sh")
                self.assertEqual(result.returncode, expected, result.stdout)
        self.env["NM_CASE"] = "late"
        for case, expected in (("empty", 1), ("missing", 1), ("missing_sim_x86", 1), ("fail", 23)):
            with self.subTest(lipo=case):
                self.env["LIPO_CASE"] = case
                result = self.command("./Scripts/build-core.sh")
                self.assertEqual(result.returncode, expected, result.stdout)

    def test_repack_replaces_old_entries_and_preserves_executable_extension(self):
        self.env["NM_CASE"] = "late"
        self.assert_success(self.command("./Scripts/build-unsigned-ipa.sh"))
        with zipfile.ZipFile(self.ipa) as z:
            self.assertIn(f"Payload/{APP_NAME}/B", z.namelist())
        (self.app / "B").unlink()
        (self.app / "A").write_text("current A")
        (self.app / "C").write_text("current C")
        self.assert_success(self.command("./Scripts/build-unsigned-ipa.sh"))
        with zipfile.ZipFile(self.ipa) as z:
            prefix = f"Payload/{APP_NAME}/"
            self.assertNotIn(prefix + "B", z.namelist())
            self.assertEqual(z.read(prefix + "A"), b"current A")
            self.assertEqual(z.read(prefix + "C"), b"current C")
            for binary in ("PaopaoLocationSpoofer", f"PlugIns/{EXT_NAME}/RouteLiveActivity"):
                self.assertEqual((z.getinfo(prefix + binary).external_attr >> 16) & 0o777, 0o755)

    def test_failed_package_or_validation_preserves_previous_output(self):
        self.env["NM_CASE"] = "late"
        for failure in ("zip", "verify"):
            for has_old in (False, True):
                with self.subTest(failure=failure, has_old=has_old):
                    if self.ipa.exists():
                        self.ipa.unlink()
                    if has_old:
                        self.assert_success(self.command("./Scripts/build-unsigned-ipa.sh"))
                    old = self.ipa.read_bytes() if has_old else None
                    if failure == "zip":
                        stub = self.tools / "zip"
                        stub.write_text('#!/bin/bash\nprintf partial > "$2"\nexit 31\n')
                        stub.chmod(0o755)
                    else:
                        (self.app / "PlugIns" / EXT_NAME / "Info.plist").rename(self.app / "saved-plist")
                    result = self.command("./Scripts/build-unsigned-ipa.sh")
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertNotIn("Output:", result.stdout)
                    self.assertEqual(self.ipa.read_bytes() if self.ipa.exists() else None, old)
                    self.assertEqual(list(self.ipa.parent.glob(".unsigned-ipa.*")), [])
                    if failure == "zip":
                        stub.unlink()
                    else:
                        (self.app / "saved-plist").rename(self.app / "PlugIns" / EXT_NAME / "Info.plist")

    def test_make_builds_core_once(self):
        self.env["NM_CASE"] = "late"
        self.assert_success(self.command("make", "ipa-unsigned"))
        self.assertEqual((self.root / "calls").read_text().count("go ['mod', 'download']"), 1)

    def test_official_entry_checks_all_effective_settings_before_compiling(self):
        self.assert_success(self.command("./build.sh"))
        calls = (self.root / "calls").read_text().splitlines()
        settings = [line for line in calls if "'-showBuildSettings'" in line]
        self.assertEqual(len(settings), 8)
        for target in ("PaopaoLocationSpoofer", "RouteLiveActivity"):
            for config in ("Debug", "Release"):
                for sdk in ("iphoneos", "iphonesimulator"):
                    self.assertEqual(sum(all(repr(x) in line for x in (target, config, sdk))
                                         for line in settings), 1)
        self.assertLess(calls.index(settings[-1]), next(i for i, line in enumerate(calls)
                                                       if line.startswith("xcodebuild") and "'build'" in line))
        self.assertEqual(sum("vtool" in line for line in calls), 2)
        self.assertLess(next(i for i, line in enumerate(calls) if line.startswith("xcodegen")),
                        calls.index(settings[0]))

    def test_wrong_effective_settings_fail_before_compile_and_preserve_old_ipa(self):
        self.assert_success(self.command("./Scripts/build-unsigned-ipa.sh"))
        old = self.ipa.read_bytes()
        for target in ("PaopaoLocationSpoofer", "RouteLiveActivity"):
            for config in ("Debug", "Release"):
                for sdk in ("iphoneos", "iphonesimulator"):
                    with self.subTest(target=target, config=config, sdk=sdk):
                        (self.root / "calls").unlink()
                        self.env["SETTINGS_BAD"] = "/".join((target, config, sdk))
                        result = self.command("./Scripts/build-unsigned-ipa.sh")
                        self.assertEqual(result.returncode, 14, result.stdout)
                        self.assertIn(target, result.stdout)
                        self.assertNotIn("'build'", (self.root / "calls").read_text().split("xcodegen")[-1])
                        self.assertEqual(self.ipa.read_bytes(), old)

    def test_candidate_deployment_failure_preserves_previous_package(self):
        self.assert_success(self.command("./Scripts/build-unsigned-ipa.sh"))
        old = self.ipa.read_bytes()
        plist = self.app / "PlugIns" / EXT_NAME / "Info.plist"
        original = plist.read_bytes()
        for case in ("plist", "macho"):
            with self.subTest(case=case):
                if case == "plist":
                    info = plistlib.loads(original)
                    info["MinimumOSVersion"] = "15.0"
                    plist.write_bytes(plistlib.dumps(info))
                else:
                    self.env["MACHO_BAD"] = "1"
                result = self.command("./Scripts/build-unsigned-ipa.sh")
                self.assertEqual(result.returncode, 14, result.stdout)
                self.assertIn(EXT_NAME, result.stdout)
                self.assertEqual(self.ipa.read_bytes(), old)
                self.assertNotIn("Output:", result.stdout)
                self.assertEqual(list(self.ipa.parent.glob(".unsigned-ipa.*")), [])
                plist.write_bytes(original)

    def test_simulator_selection_consumes_output_and_propagates_failure(self):
        self.env["NM_CASE"] = "late"
        self.assert_success(self.command("./build.sh", "--test"))
        calls = (self.root / "calls").read_text()
        self.assertIn("platform=iOS Simulator,id=22222222-ABCD-2222-2222-222222222222", calls)
        self.assertIn("build/SimulatorTests.xcresult", calls)
        self.env["SIM_FAIL"] = "1"
        (self.root / "calls").unlink()
        result = self.command("./build.sh", "--test")
        self.assertEqual(result.returncode, 25, result.stdout)
        self.assertNotIn("'test'", (self.root / "calls").read_text())
        self.env["SIMULATOR_DESTINATION"] = "platform=iOS Simulator,id=explicit"
        self.assert_success(self.command("./build.sh", "--test"))

    def test_simulator_missing_or_malformed_data_never_skips_tests(self):
        for case in ("no_devices", "no_runtimes", "no_iphone", "invalid_json"):
            with self.subTest(case=case):
                self.env["SIM_CASE"] = case
                result = self.command("./build.sh", "--test")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("'test'", (self.root / "calls").read_text())

    def test_swift_failure_fails_build_even_when_ipa_exists(self):
        self.env["TEST_FAIL"] = "1"
        result = self.command("./build.sh", "--test")
        self.assertEqual(result.returncode, 29, result.stdout)
        self.assertTrue(self.ipa.is_file())
        self.assertNotIn("Next: sign", result.stdout)

    def test_make_go_propagates_each_failure_without_changing_toolchain(self):
        for failure in ("mod download", "mod verify", "test -race", "vet ./..."):
            with self.subTest(failure=failure):
                self.env.update(GO_FAIL_AT=failure, GOTOOLCHAIN="auto")
                result = self.command("make", "test-go")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                calls = (self.root / "calls").read_text().splitlines()
                self.assertIn(repr(failure.split()[0]), calls[-1])
                self.assertEqual(set((self.root / "go-toolchains").read_text().splitlines()), {"local"})
                (self.root / "calls").unlink()
        self.env.pop("GO_FAIL_AT")
        self.assert_success(self.command("make", "test-go"))
        self.assertEqual(len((self.root / "calls").read_text().splitlines()), 4)

    def test_make_scripts_propagates_failures_and_runs_each_entry_once(self):
        tests = self.root / "Tests"
        tests.mkdir()
        first = tests / "a_test.sh"
        first.write_text('echo first >> scheduled\nexit 31\n')
        (tests / "b_test.sh").write_text('echo second >> scheduled\n')
        self.assertNotEqual(self.command("make", "test-scripts").returncode, 0)
        self.assertEqual((self.root / "scheduled").read_text(), "first\n")
        self.assertFalse((self.root / "calls").exists())
        first.write_text('echo first >> scheduled\n')
        (self.root / "scheduled").unlink()
        self.assert_success(self.command("make", "test-scripts"))
        self.assertEqual((self.root / "scheduled").read_text(), "first\nsecond\n")
        self.assertEqual((self.root / "calls").read_text().count("node ["), 1)
        self.env["NODE_FAIL"] = "1"
        self.assertNotEqual(self.command("make", "test-scripts").returncode, 0)

    def test_make_scripts_missing_tests_is_failure(self):
        self.assertNotEqual(self.command("make", "test-scripts").returncode, 0)

    def test_refuses_symlinked_output_parent_without_deleting_external_data(self):
        self.env["NM_CASE"] = "late"
        outside = Path(self.temp.name) / "outside"
        (outside / "DerivedData").mkdir(parents=True)
        marker = outside / "DerivedData/marker"
        marker.write_text("keep")
        (self.root / "build").symlink_to(outside)
        result = self.command("./Scripts/build-unsigned-ipa.sh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(marker.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
