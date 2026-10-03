"""有效设置解析及工具失败回归；真实 XcodeGen 生成由正式构建入口执行。"""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Scripts"))
import deployment_targets as deployment


def settings(target="RouteLiveActivity", minimum="16.2", config="Debug", sdk="iphoneos"):
    return [dict(target=target, buildSettings=dict(CONFIGURATION=config,
                 PLATFORM_NAME=sdk, IPHONEOS_DEPLOYMENT_TARGET=minimum, SDK_VERSION="26.5"))]


class DeploymentTargets(unittest.TestCase):
    def check(self, data, target="RouteLiveActivity", config="Debug", sdk="iphoneos"):
        with contextlib.redirect_stdout(io.StringIO()):
            deployment.check_build_settings(data, target, config, sdk)

    def test_fixed_product_contract_and_equivalent_versions(self):
        self.assertEqual(deployment.EXPECTED_TARGETS,
                         {"PaopaoLocationSpoofer": "15.0", "RouteLiveActivity": "16.2"})
        for target, minimum in (("PaopaoLocationSpoofer", "15.0.0"), ("RouteLiveActivity", "16.2.0")):
            self.check(settings(target, minimum), target)

    def test_inheritance_app_raise_and_invalid_versions(self):
        for target, wrong in (("RouteLiveActivity", "15.0"), ("PaopaoLocationSpoofer", "16.2")):
            for value in (wrong, None, "", "$(inherited)", "16.x", "16.2.0.0", True, 16.2):
                with self.subTest(target=target, value=value):
                    with self.assertRaisesRegex(deployment.DeploymentError, "IPHONEOS_DEPLOYMENT_TARGET"):
                        self.check(settings(target, value), target)
        data = settings()
        del data[0]["buildSettings"]["IPHONEOS_DEPLOYMENT_TARGET"]
        with self.assertRaises(deployment.DeploymentError):
            self.check(data)

    def test_missing_duplicate_or_wrong_target_configuration_platform(self):
        for data in (None, {}, [], [None], settings() * 2,
                     [dict(target="RouteLiveActivity")], settings("PaopaoLocationSpoofer"),
                     settings(config="Release"), settings(sdk="iphonesimulator")):
            with self.subTest(data=data), self.assertRaises(deployment.DeploymentError):
                self.check(data)

    def test_project_reports_tool_failure_invalid_json_and_does_not_skip_target(self):
        with patch.object(deployment, "tool_output", return_value="not JSON"):
            with self.assertRaises(deployment.DeploymentError) as caught:
                deployment.check_project("fixture.xcodeproj")
            self.assertEqual(caught.exception.code, 12)
        with patch.object(deployment, "tool_output", return_value=json.dumps(settings())):
            with self.assertRaisesRegex(deployment.DeploymentError, "PaopaoLocationSpoofer"):
                deployment.check_project("fixture.xcodeproj")

    def test_tool_errors_never_become_success(self):
        for error in (OSError("missing"), subprocess.TimeoutExpired("xcodebuild", 120),
                      UnicodeError("invalid output")):
            with patch.object(deployment.subprocess, "run", side_effect=error):
                with self.assertRaises(deployment.DeploymentError) as caught:
                    deployment.tool_output(["xcodebuild"], "RouteLiveActivity")
                self.assertEqual(caught.exception.code, 12)
        result = subprocess.CompletedProcess([], 23, stdout="{}", stderr="cannot read")
        with patch.object(deployment.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(deployment.DeploymentError, "退出 23"):
                deployment.tool_output(["xcodebuild"], "RouteLiveActivity")


if __name__ == "__main__":
    unittest.main()
