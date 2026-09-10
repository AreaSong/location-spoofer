#!/usr/bin/env python3
"""Tests for the student pending-checkin poller."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import poller

SAMPLE_PAYLOAD = {
    "code": 0,
    "data": {
        "list": [
            {
                "id": "chk_1001",
                "title": "高等数学 第3节",
                "deadline": "2026-09-10 12:40:00",
                "signed": False,
            },
            {
                "id": "chk_1002",
                "title": "已签到的课",
                "deadline": "2026-09-10 13:00:00",
                "signed": True,
            },
        ]
    },
}

BASE_CONFIG = {
    "pollIntervalSeconds": 15,
    "authAlertCooldownSeconds": 1800,
    "request": {"url": "https://example.test/pending", "method": "GET", "headers": {}, "body": None},
    "authFailure": {
        "httpStatus": [401, 403],
        "jsonCodePath": "code",
        "jsonCodeValues": [401, 403, "UNAUTHORIZED"],
    },
    "fields": {
        "listPath": "data.list",
        "idPath": "id",
        "titlePath": "title",
        "deadlinePath": "deadline",
        "signedPath": "signed",
    },
    "bark": {"server": "https://api.day.app", "deviceKey": "test-key"},
}


class PathTests(unittest.TestCase):
    def test_nested_list_path(self) -> None:
        self.assertEqual(poller.get_path(SAMPLE_PAYLOAD, "data.list.0.id"), "chk_1001")

    def test_empty_path_returns_root(self) -> None:
        self.assertEqual(poller.get_path(SAMPLE_PAYLOAD, ""), SAMPLE_PAYLOAD)

    def test_missing_path_returns_none(self) -> None:
        self.assertIsNone(poller.get_path(SAMPLE_PAYLOAD, "data.missing"))

    def test_expand_env_in_headers(self) -> None:
        previous = os.environ.get("STUDENT_TOKEN")
        os.environ["STUDENT_TOKEN"] = "secret-token"
        self.addCleanup(
            lambda: (
                os.environ.__setitem__("STUDENT_TOKEN", previous)
                if previous is not None
                else os.environ.pop("STUDENT_TOKEN", None)
            )
        )
        expanded = poller.expand_tree({"Authorization": "Bearer ${STUDENT_TOKEN}"})
        self.assertEqual(expanded["Authorization"], "Bearer secret-token")


class ExtractTests(unittest.TestCase):
    def test_skips_signed_items(self) -> None:
        items = poller.extract_pending_items(SAMPLE_PAYLOAD, BASE_CONFIG["fields"])
        self.assertEqual([item["id"] for item in items], ["chk_1001"])

    def test_dict_list_values(self) -> None:
        payload = {"data": {"list": {"a": {"id": "1", "signed": False}}}}
        items = poller.extract_pending_items(payload, BASE_CONFIG["fields"])
        self.assertEqual(items[0]["id"], "1")

    def test_skips_blank_ids(self) -> None:
        payload = {"data": {"list": [{"id": "", "signed": False}]}}
        self.assertEqual(poller.extract_pending_items(payload, BASE_CONFIG["fields"]), [])


class DiffTests(unittest.TestCase):
    def test_new_item_is_returned(self) -> None:
        items = [{"id": "chk_1001", "title": "A", "deadline": ""}]
        new_items, retained = poller.diff_checkins(set(), items)
        self.assertEqual(new_items[0]["id"], "chk_1001")
        self.assertEqual(retained, set())

    def test_known_item_is_not_new(self) -> None:
        items = [{"id": "chk_1001", "title": "A", "deadline": ""}]
        new_items, retained = poller.diff_checkins({"chk_1001"}, items)
        self.assertEqual(new_items, [])
        self.assertEqual(retained, {"chk_1001"})

    def test_disappeared_id_is_dropped(self) -> None:
        new_items, retained = poller.diff_checkins({"chk_old"}, [])
        self.assertEqual(new_items, [])
        self.assertEqual(retained, set())


class CycleTests(unittest.TestCase):
    def test_notifies_new_checkin_once(self) -> None:
        calls: list[tuple[str, str, dict]] = []
        state = poller.default_state()
        fetch = lambda _: (200, SAMPLE_PAYLOAD)
        notify = lambda title, body, extra: calls.append((title, body, extra))
        state = poller.run_cycle(BASE_CONFIG, state, 1000, fetch, notify)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "高等数学 第3节")
        self.assertIn("chk_1001", calls[0][1])
        state = poller.run_cycle(BASE_CONFIG, state, 1010, fetch, notify)
        self.assertEqual(len(calls), 1)

    def test_realerts_after_item_disappears(self) -> None:
        calls: list[tuple[str, str, dict]] = []
        notify = lambda title, body, extra: calls.append((title, body, extra))
        empty = {"code": 0, "data": {"list": []}}
        state = poller.run_cycle(BASE_CONFIG, poller.default_state(), 1, lambda _: (200, SAMPLE_PAYLOAD), notify)
        state = poller.run_cycle(BASE_CONFIG, state, 2, lambda _: (200, empty), notify)
        state = poller.run_cycle(BASE_CONFIG, state, 3, lambda _: (200, SAMPLE_PAYLOAD), notify)
        self.assertEqual(len(calls), 2)

    def test_http_401_alerts_with_cooldown(self) -> None:
        calls: list[tuple[str, str, dict]] = []
        notify = lambda title, body, extra: calls.append((title, body, extra))
        fetch = lambda _: (401, {"code": 401})
        state = poller.run_cycle(BASE_CONFIG, poller.default_state(), 100, fetch, notify)
        state = poller.run_cycle(BASE_CONFIG, state, 200, fetch, notify)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "签到监控鉴权失败")
        state = poller.run_cycle(BASE_CONFIG, state, 100 + 1800, fetch, notify)
        self.assertEqual(len(calls), 2)

    def test_json_unauthorized_code_is_auth_failure(self) -> None:
        self.assertTrue(poller.is_auth_failure(200, {"code": "UNAUTHORIZED"}, BASE_CONFIG))

    def test_failed_notify_retries_next_cycle(self) -> None:
        attempts = {"n": 0}

        def notify(title: str, body: str, extra: dict) -> None:
            attempts["n"] += 1
            if attempts["n"] == 1:
                raise RuntimeError("bark down")

        state = poller.default_state()
        fetch = lambda _: (200, SAMPLE_PAYLOAD)
        state = poller.run_cycle(BASE_CONFIG, state, 1, fetch, notify)
        self.assertEqual(state["alertedIds"], [])
        state = poller.run_cycle(BASE_CONFIG, state, 2, fetch, notify)
        self.assertEqual(state["alertedIds"], ["chk_1001"])


class ConfigTests(unittest.TestCase):
    def test_missing_device_key_fails(self) -> None:
        config = dict(BASE_CONFIG)
        config["bark"] = {"server": "https://api.day.app", "deviceKey": ""}
        with self.assertRaises(ValueError):
            poller.validate_config(config)

    def test_interval_too_small_fails(self) -> None:
        config = dict(BASE_CONFIG)
        config["pollIntervalSeconds"] = 1
        with self.assertRaises(ValueError):
            poller.validate_config(config)

    def test_example_config_loads_with_env(self) -> None:
        previous_token = os.environ.get("STUDENT_TOKEN")
        previous_key = os.environ.get("BARK_DEVICE_KEY")
        os.environ["STUDENT_TOKEN"] = "token"
        os.environ["BARK_DEVICE_KEY"] = "bark-key"
        self.addCleanup(
            lambda: _restore_env("STUDENT_TOKEN", previous_token)
        )
        self.addCleanup(
            lambda: _restore_env("BARK_DEVICE_KEY", previous_key)
        )
        example = Path(__file__).with_name("config.example.json")
        config = poller.load_config(example)
        self.assertIn("/api/student/pending-checkins", config["request"]["url"])
        self.assertEqual(config["fields"]["idPath"], "id")
        self.assertEqual(config["bark"]["deviceKey"], "bark-key")

    def test_state_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            poller.save_state(path, {"alertedIds": ["a"], "authAlertedAt": 9})
            loaded = poller.load_state(path)
            self.assertEqual(loaded["alertedIds"], ["a"])
            self.assertEqual(loaded["authAlertedAt"], 9)


def _restore_env(name: str, previous: str | None) -> None:
    if previous is None:
        os.environ.pop(name, None)
    else:
        os.environ[name] = previous


class BarkTests(unittest.TestCase):
    def test_send_bark_posts_push_endpoint(self) -> None:
        captured: dict[str, object] = {}

        def fake_http(method: str, url: str, headers: dict, body: object, timeout: float):
            captured.update({"method": method, "url": url, "body": body})
            return 200, {"code": 200}

        with patch.object(poller, "http_request", fake_http):
            poller.send_bark(BASE_CONFIG, "标题", "正文", {"id": "checkin-1"})
        self.assertEqual(captured["method"], "POST")
        self.assertEqual(captured["url"], "https://api.day.app/push")
        body = captured["body"]
        assert isinstance(body, dict)
        self.assertEqual(body["device_key"], "test-key")
        self.assertEqual(body["title"], "标题")
        self.assertEqual(body["id"], "checkin-1")


if __name__ == "__main__":
    unittest.main()
