"""结构样本为合成数据；签名成功仅由 mock 覆盖，不代表真实签名验收。"""
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
import warnings
import zipfile

from ipa_test_support import APP_NAME, EXT_NAME, ROOT, archive, bundle, run


class VerifyIPA(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="verify ipa ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = self.root / "Payload"
        self.app = bundle(self.payload)
        self.ext = self.app / "PlugIns" / EXT_NAME
        self.ipa = self.root / 'input space \' " $dollar `literal`.ipa'
        self.env = dict(os.environ)
        self.owned_tmp = self.root / "temp"
        self.owned_tmp.mkdir()
        self.env["TMPDIR"] = str(self.owned_tmp)

    def verify(self, mode="--unsigned", code=0, category=None, macho=False):
        before = hashlib.sha256(self.ipa.read_bytes()).digest() if self.ipa.exists() else None
        flags = [mode, "--macho"] if macho else [mode]
        result = run([ROOT / "Scripts/verify-ipa.sh", *flags, self.ipa], env=self.env)
        self.assertEqual(result.returncode, code, result.stdout)
        if category:
            self.assertIn(category, result.stdout)
        if before:
            self.assertEqual(hashlib.sha256(self.ipa.read_bytes()).digest(), before)
        self.assertEqual(list(self.owned_tmp.iterdir()), [])
        return result

    def test_valid_unsigned_and_signed_rejection(self):
        archive(self.payload, self.ipa)
        self.verify()
        self.verify("--signed", 10, "SIGNATURE_MISSING")

    def test_deployment_versions_are_required_and_match_product_contract(self):
        for path, wrong in ((self.app, "16.2"), (self.ext, "15.0")):
            original = (path / "Info.plist").read_bytes()
            for value in (wrong, None, "", "16.x", "16.2.0.0", 16.2, True):
                with self.subTest(bundle=path.name, value=value):
                    info = plistlib.loads(original)
                    info["DTSDKName"] = "iphoneos26.5"
                    if value is None:
                        info.pop("MinimumOSVersion")
                    else:
                        info["MinimumOSVersion"] = value
                    (path / "Info.plist").write_bytes(plistlib.dumps(info))
                    archive(self.payload, self.ipa)
                    result = self.verify(code=14, category="DEPLOYMENT")
                    self.assertIn(path.name, result.stdout)
                    self.assertIn("MinimumOSVersion", result.stdout)
            (path / "Info.plist").write_bytes(original)

    def test_deployment_versions_compare_numeric_components(self):
        for path, version in ((self.app, "15.0.0"), (self.ext, "16.2.0")):
            info = plistlib.loads((path / "Info.plist").read_bytes())
            info.update(MinimumOSVersion=version, DTSDKName="iphoneos26.5")
            (path / "Info.plist").write_bytes(plistlib.dumps(info))
        archive(self.payload, self.ipa)
        self.verify()

    def macho_fixture(self):
        tools = self.root / "macho-tools"
        tools.mkdir()
        tool = tools / "xcrun"
        tool.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if os.environ.get("TOOL_FAIL") == args[0]:
    print("fixture read failed", file=sys.stderr)
    sys.exit(23)
if args[0] == "lipo":
    print(os.environ.get("ARCHS", "arm64"))
elif args[0] == "vtool":
    version = "16.2.0" if args[-1].endswith("/RouteLiveActivity") else "15.0.0"
    if args[-1].endswith("/RouteLiveActivity") and "EXT_OUTPUT" in os.environ:
        print(os.environ["EXT_OUTPUT"])
    else:
        print("cmd LC_BUILD_VERSION\\n platform IOS\\n minos " + version
              + "\\n sdk 26.5\\n ntools 1\\n tool LD\\n version 1267.0")
else:
    sys.exit(24)
''')
        tool.chmod(0o755)
        self.env["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]
        archive(self.payload, self.ipa)
        return tool

    def test_macho_minimum_uses_deployment_field_not_sdk_or_linker_version(self):
        self.macho_fixture()
        result = self.verify(macho=True)
        self.assertIn("LC_BUILD_VERSION.minos=16.2.0", result.stdout)
        self.env["EXT_OUTPUT"] = "cmd LC_VERSION_MIN_IPHONEOS\n version 16.2\n sdk 26.5"
        self.verify(macho=True)
        self.env["EXT_OUTPUT"] = "cmd LC_BUILD_VERSION\n platform IOS\n minos 26.5\n sdk 16.2"
        self.verify(code=14, category="DEPLOYMENT", macho=True)

    def test_macho_mismatch_missing_malformed_platform_and_duplicate_commands(self):
        self.macho_fixture()
        for output in ("", "not Mach-O", "cmd LC_BUILD_VERSION\n platform IOS\n sdk 16.2",
                       "cmd LC_BUILD_VERSION\n platform IOS\n minos 15.0\n sdk 16.2",
                       "cmd LC_BUILD_VERSION\n platform IOS\n minos bad\n sdk 26.5",
                       "cmd LC_BUILD_VERSION\n platform IOSSIMULATOR\n minos 16.2\n sdk 26.5",
                       "cmd LC_VERSION_MIN_MACOSX\n version 16.2\n sdk 26.5",
                       "cmd LC_BUILD_VERSION\n minos 16.2\n sdk 26.5",
                       "cmd LC_BUILD_VERSION\n platform IOS\n version 16.2\n sdk 26.5",
                       "cmd LC_BUILD_VERSION\n platform IOS\n minos 16.2\n minos 16.2",
                       "cmd LC_BUILD_VERSION\n platform IOS\n minos 16.2\n minos",
                       "cmd LC_BUILD_VERSION\n platform IOS\n minos 16.2\n minos bad extra",
                       "cmd LC_BUILD_VERSION\n cmd LC_VERSION_MIN_IPHONEOS\n version 16.2"):
            with self.subTest(output=output):
                self.env["EXT_OUTPUT"] = output
                result = self.verify(code=14, category="DEPLOYMENT", macho=True)
                self.assertIn(EXT_NAME, result.stdout)
                self.assertIn("Mach-O", result.stdout)

    def test_macho_tools_fail_closed_and_structure_mode_remains_portable(self):
        tool = self.macho_fixture()
        for name in ("lipo", "vtool"):
            self.env["TOOL_FAIL"] = name
            result = self.verify(code=12, category="TOOL", macho=True)
            self.assertIn("fixture read failed", result.stdout)
            self.verify()  # 跨平台结构入口不得调用 Xcode 工具。
        self.env.pop("TOOL_FAIL")
        for archs in ("", "arm64 arm64", "unexpected: output"):
            self.env["ARCHS"] = archs
            self.verify(code=14, category="DEPLOYMENT", macho=True)
        tool.write_text("not an executable format")
        self.verify(code=12, category="TOOL", macho=True)

    def test_every_macho_slice_is_checked(self):
        self.macho_fixture()
        self.env["ARCHS"] = "arm64 arm64e"
        result = self.verify(macho=True)
        self.assertEqual(result.stdout.count("LC_BUILD_VERSION.minos="), 4)

    def test_structure_errors(self):
        cases = (
            (self.app, "missing_app", 6, "BUNDLE"),
            (self.ext, "missing_extension", 6, "BUNDLE"),
            (self.app / "PaopaoLocationSpoofer", "missing_executable", 8, "EXECUTABLE"),
            (self.ext / "RouteLiveActivity", "missing_extension_executable", 8, "EXECUTABLE"),
            (self.app / "Info.plist", "missing_plist", 7, "PLIST"),
        )
        for path, name, code, category in cases:
            with self.subTest(name=name):
                saved = self.root / "saved"
                path.rename(saved)
                archive(self.payload, self.ipa)
                self.verify(code=code, category=category)
                saved.rename(path)

    def test_invalid_plist_and_contract(self):
        original = (self.ext / "Info.plist").read_bytes()
        for value, code, category in ((b"invalid", 7, "PLIST"), (plistlib.dumps([]), 7, "PLIST"),
                                      (b'<?xml version="1.0"?><plist><dict></plist>', 7, "PLIST")):
            (self.ext / "Info.plist").write_bytes(value)
            archive(self.payload, self.ipa)
            self.verify(code=code, category=category)
        for field, value in (("CFBundleIdentifier", "wrong.id"), ("CFBundleVersion", "12"),
                             ("CFBundleShortVersionString", "2.0"), ("NSExtension", []),
                             ("CFBundleExecutable", "../../outside")):
            info = plistlib.loads(original)
            info[field] = value
            (self.ext / "Info.plist").write_bytes(plistlib.dumps(info))
            archive(self.payload, self.ipa)
            self.verify(code=8 if field == "CFBundleExecutable" else 9,
                        category="EXECUTABLE" if field == "CFBundleExecutable" else "CONTRACT")

    def test_non_executable_file(self):
        (self.app / "PaopaoLocationSpoofer").chmod(0o644)
        archive(self.payload, self.ipa)
        self.verify(code=8, category="EXECUTABLE")

    def test_bad_zip_and_crc(self):
        self.ipa.write_bytes(b"not a ZIP")
        self.verify(code=4, category="ZIP")
        with zipfile.ZipFile(self.ipa, "w", zipfile.ZIP_STORED) as z:
            z.writestr("Payload/data", b"unique-crc-sample")
        data = self.ipa.read_bytes().replace(b"unique-crc-sample", b"broken-crc-sample")
        self.ipa.write_bytes(data)
        self.verify(code=4, category="ZIP")

    def test_argument_and_input_errors(self):
        self.verify(code=3, category="INPUT")
        for args in ([], ["--unknown", self.ipa], ["--unsigned"],
                     ["--signed", "--unsigned", self.ipa]):
            result = run([ROOT / "Scripts/verify-ipa.sh", *args], env=self.env)
            self.assertEqual(result.returncode, 2, result.stdout)

    def test_invalid_zip_filename_encoding_has_stable_error(self):
        with zipfile.ZipFile(self.ipa, "w") as z:
            z.writestr("entry/data", b"data")
        data = bytearray(self.ipa.read_bytes())
        for signature, flag_offset, name_offset in ((b"PK\x03\x04", 6, 30), (b"PK\x01\x02", 8, 46)):
            offset = data.index(signature)
            flags = struct.unpack_from("<H", data, offset + flag_offset)[0]
            struct.pack_into("<H", data, offset + flag_offset, flags | 0x800)
            data[offset + name_offset] = 0xff
        self.ipa.write_bytes(data)
        result = self.verify(code=4, category="ZIP")
        self.assertNotIn("Traceback", result.stdout)

    def test_unsafe_archive_paths_and_links(self):
        outside = self.root / "outside"
        for name in ("../outside", str(outside), "Payload/../../outside", "C:/outside",
                     "Payload\\outside", "Payload/./outside", "Payload//outside"):
            with self.subTest(name=name):
                archive(self.payload, self.ipa)
                with zipfile.ZipFile(self.ipa, "a") as z:
                    z.writestr(name, "escape")
                self.verify(code=5, category="UNSAFE_PATH")
                self.assertFalse(outside.exists())
        archive(self.payload, self.ipa)
        with zipfile.ZipFile(self.ipa, "a") as z:
            link = zipfile.ZipInfo("Payload/link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(link, str(self.root))
            z.writestr("Payload/link/outside", "escape")
        self.verify(code=5, category="UNSAFE_PATH")
        self.assertFalse(outside.exists())

    def test_duplicate_and_file_parent_rejected(self):
        for names in (("Payload/file", "Payload/file"), ("Payload/file", "Payload/file/child"),
                      ("Payload/AssetsUpper/one", "Payload/assetsupper/two")):
            with self.subTest(names=names):
                with warnings.catch_warnings(), zipfile.ZipFile(self.ipa, "w") as z:
                    warnings.simplefilter("ignore", UserWarning)
                    for name in names:
                        z.writestr(name, b"data")
                self.verify(code=5, category="UNSAFE_PATH")

    def test_contract_uses_exact_zip_paths_on_case_insensitive_filesystems(self):
        for old, new, code, category in (("Payload/", "payload/", 6, "BUNDLE"),
                                        ("Info.plist", "info.plist", 7, "PLIST"),
                                        ("/PaopaoLocationSpoofer", "/paopaolocationspoofer", 8, "EXECUTABLE")):
            with self.subTest(path=old):
                archive(self.payload, self.ipa)
                with zipfile.ZipFile(self.ipa) as z:
                    members = [(item, z.read(item)) for item in z.infolist()]
                with zipfile.ZipFile(self.ipa, "w") as z:
                    for item, data in members:
                        if code == 8:
                            if item.filename.endswith(old):
                                item.filename = item.filename[:-len(old)] + new
                        else:
                            item.filename = item.filename.replace(old, new)
                        z.writestr(item, data)
                self.verify(code=code, category=category)

    def signature_fixture(self, command):
        for path in (self.app, self.ext):
            (path / "_CodeSignature").mkdir(exist_ok=True)
            (path / "_CodeSignature/CodeResources").write_text("mock signature marker")
        archive(self.payload, self.ipa)
        tools = self.root / "tools"
        tools.mkdir(exist_ok=True)
        tool = tools / "codesign"
        tool.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$SIGN_CALLS"\n' + command + "\n")
        tool.chmod(0o755)
        self.env["SIGN_CALLS"] = str(self.root / "signature-calls")
        self.env["PATH"] = str(tools) + os.pathsep + os.environ["PATH"]

    def test_mock_signature_success_and_failures(self):
        self.signature_fixture("exit 0")
        self.verify("--signed")
        calls = (self.root / "signature-calls").read_text()
        self.assertIn("--verify --deep --strict", calls)
        self.assertIn(EXT_NAME, calls)
        self.signature_fixture("exit 1")
        self.verify("--signed", 11, "SIGNATURE_INVALID")
        self.signature_fixture("exit 127")
        self.verify("--signed", 12, "TOOL")
        self.signature_fixture("kill -TERM $$")
        self.verify("--signed", 12, "TOOL")
        (self.root / "tools/codesign").write_text("not an executable format")
        self.verify("--signed", 12, "TOOL")

    def test_signed_mode_requires_exact_signature_resource_path(self):
        self.signature_fixture("exit 0")
        with zipfile.ZipFile(self.ipa) as z:
            members = [(item, z.read(item)) for item in z.infolist()]
        with zipfile.ZipFile(self.ipa, "w") as z:
            for item, data in members:
                item.filename = item.filename.replace("CodeResources", "coderesources")
                z.writestr(item, data)
        self.verify("--signed", 10, "SIGNATURE_MISSING")

    def test_make_entry_and_safe_quoting(self):
        archive(self.payload, self.ipa)
        result = run(["make", "verify-ipa", "IPA_MODE=unsigned", "IPA=" + str(self.ipa)], env=self.env)
        self.assertEqual(result.returncode, 0, result.stdout)
        result = run(["make", "verify-ipa", "IPA=" + str(self.ipa)], env=self.env)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("SIGNATURE_MISSING", result.stdout)
        result = run(["make", "verify-ipa", "IPA="], env=self.env)
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
