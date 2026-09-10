#!/usr/bin/env python3
"""Poll a student pending-checkin API and push new items to Bark."""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Callable

ENV_PATTERN = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
MIN_POLL_INTERVAL = 5
DEFAULT_AUTH_COOLDOWN = 1800
DEFAULT_TIMEOUT = 15
TRUTHY = {True, 1, "1", "true", "True", "yes", "YES"}

FetchFn = Callable[[dict[str, Any]], tuple[int, Any]]
NotifyFn = Callable[[str, str, dict[str, Any]], None]


def expand_string(value: str) -> str:
    return ENV_PATTERN.sub(lambda match: os.environ.get(match.group(1), ""), value)


def expand_tree(value: Any) -> Any:
    if isinstance(value, str):
        return expand_string(value)
    if isinstance(value, list):
        return [expand_tree(item) for item in value]
    if isinstance(value, dict):
        return {key: expand_tree(item) for key, item in value.items()}
    return value


def get_path(obj: Any, path: str) -> Any:
    if path == "":
        return obj
    current = obj
    for key in path.split("."):
        if isinstance(current, dict):
            current = current.get(key)
            continue
        if isinstance(current, list) and key.isdigit():
            index = int(key)
            if index < 0 or index >= len(current):
                return None
            current = current[index]
            continue
        return None
    return current


def as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return list(value.values())
    raise ValueError(f"pending list must be an array or object, got {type(value).__name__}")


def is_signed(value: Any) -> bool:
    return value in TRUTHY


def load_json_file(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_config(path: Path) -> dict[str, Any]:
    raw = load_json_file(path)
    if not isinstance(raw, dict):
        raise ValueError("config root must be an object")
    config = expand_tree(raw)
    validate_config(config)
    return config


def validate_config(config: dict[str, Any]) -> None:
    request = config.get("request")
    fields = config.get("fields")
    bark = config.get("bark")
    if not isinstance(request, dict) or not str(request.get("url") or "").strip():
        raise ValueError("request.url is required")
    if not isinstance(fields, dict) or "listPath" not in fields or not fields.get("idPath"):
        raise ValueError("fields.listPath and fields.idPath are required")
    if not isinstance(bark, dict) or not str(bark.get("deviceKey") or "").strip():
        raise ValueError("bark.deviceKey is required")
    interval = int(config.get("pollIntervalSeconds") or MIN_POLL_INTERVAL)
    if interval < MIN_POLL_INTERVAL:
        raise ValueError(f"pollIntervalSeconds must be >= {MIN_POLL_INTERVAL}")


def default_state() -> dict[str, Any]:
    return {"alertedIds": [], "authAlertedAt": 0}


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return default_state()
    raw = load_json_file(path)
    if not isinstance(raw, dict):
        return default_state()
    ids = raw.get("alertedIds") or []
    if not isinstance(ids, list):
        ids = []
    return {
        "alertedIds": [str(item) for item in ids],
        "authAlertedAt": int(raw.get("authAlertedAt") or 0),
    }


def save_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def state_path_for(config: dict[str, Any], config_path: Path) -> Path:
    configured = str(config.get("statePath") or "").strip()
    path = Path(configured) if configured else config_path.with_name("state.json")
    if not path.is_absolute():
        path = (config_path.parent / path).resolve()
    return path


def http_request(method: str, url: str, headers: dict[str, str], body: Any, timeout: float) -> tuple[int, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request_headers = dict(headers)
    if data is not None:
        request_headers.setdefault("Content-Type", "application/json; charset=utf-8")
    request = urllib.request.Request(url, data=data, headers=request_headers, method=method.upper())
    context = ssl.create_default_context()
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            return response.status, parse_http_body(response.read())
    except urllib.error.HTTPError as error:
        return error.code, parse_http_body(error.read())


def parse_http_body(raw: bytes) -> Any:
    if not raw:
        return None
    text = raw.decode("utf-8", errors="replace")
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return text


def fetch_pending(config: dict[str, Any], http_fn: FetchFn | None = None) -> tuple[int, Any]:
    request = config["request"]
    headers = request.get("headers") or {}
    if not isinstance(headers, dict):
        raise ValueError("request.headers must be an object")
    str_headers = {str(key): str(value) for key, value in headers.items()}
    timeout = float(config.get("requestTimeoutSeconds") or DEFAULT_TIMEOUT)
    fn = http_fn or (
        lambda _: http_request(
            str(request.get("method") or "GET"),
            str(request["url"]),
            str_headers,
            request.get("body"),
            timeout,
        )
    )
    return fn(config)


def is_auth_failure(status: int, payload: Any, config: dict[str, Any]) -> bool:
    failure = config.get("authFailure") or {}
    statuses = failure.get("httpStatus") or [401, 403]
    if status in statuses:
        return True
    code_path = str(failure.get("jsonCodePath") or "code")
    values = failure.get("jsonCodeValues") or [401, 403, "UNAUTHORIZED", "unauthorized"]
    code = get_path(payload, code_path) if isinstance(payload, (dict, list)) else None
    return code in values


def extract_pending_items(payload: Any, fields: dict[str, Any]) -> list[dict[str, str]]:
    items = []
    signed_path = str(fields.get("signedPath") or "")
    for raw in as_list(get_path(payload, str(fields.get("listPath") or ""))):
        if not isinstance(raw, dict):
            continue
        if signed_path and is_signed(get_path(raw, signed_path)):
            continue
        item_id = get_path(raw, str(fields["idPath"]))
        if item_id is None or str(item_id).strip() == "":
            continue
        items.append(
            {
                "id": str(item_id),
                "title": stringify(get_path(raw, str(fields.get("titlePath") or ""))),
                "deadline": stringify(get_path(raw, str(fields.get("deadlinePath") or ""))),
            }
        )
    return items


def stringify(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def format_checkin_body(item: dict[str, str]) -> str:
    lines = [f"id: {item['id']}"]
    if item["deadline"]:
        lines.append(f"截止: {item['deadline']}")
    return "\n".join(lines)


def diff_checkins(alerted_ids: set[str], items: list[dict[str, str]]) -> tuple[list[dict[str, str]], set[str]]:
    pending_ids = {item["id"] for item in items}
    new_items = [item for item in items if item["id"] not in alerted_ids]
    return new_items, alerted_ids & pending_ids


def send_bark(config: dict[str, Any], title: str, body: str, extra: dict[str, Any] | None = None) -> None:
    bark = config["bark"]
    server = str(bark.get("server") or "https://api.day.app").rstrip("/")
    payload = {
        "device_key": str(bark["deviceKey"]),
        "title": title,
        "body": body,
        "group": str(bark.get("group") or "checkin-monitor"),
        "level": str(bark.get("level") or "timeSensitive"),
        "isArchive": "1",
    }
    if extra:
        payload.update(extra)
    status, response = http_request("POST", f"{server}/push", {}, payload, DEFAULT_TIMEOUT)
    if status >= 300:
        raise RuntimeError(f"Bark push failed: HTTP {status} {response}")


def run_cycle(
    config: dict[str, Any],
    state: dict[str, Any],
    now: int,
    fetch: FetchFn | None = None,
    notify: NotifyFn | None = None,
) -> dict[str, Any]:
    notify_fn = notify or (lambda title, body, extra: send_bark(config, title, body, extra))
    try:
        status, payload = fetch_pending(config, fetch)
    except Exception as error:
        print(f"poll failed: {error}", file=sys.stderr)
        return state
    if is_auth_failure(status, payload, config):
        return alert_auth_failure(config, state, now, notify_fn, status)
    try:
        items = extract_pending_items(payload, config["fields"])
    except ValueError as error:
        print(f"payload mapping failed: {error}", file=sys.stderr)
        return state
    return alert_new_checkins(state, items, notify_fn)


def alert_auth_failure(
    config: dict[str, Any],
    state: dict[str, Any],
    now: int,
    notify: NotifyFn,
    status: int,
) -> dict[str, Any]:
    cooldown = int(config.get("authAlertCooldownSeconds") or DEFAULT_AUTH_COOLDOWN)
    last = int(state.get("authAlertedAt") or 0)
    if last and now - last < cooldown:
        print(f"auth failure HTTP {status}; alert suppressed by cooldown", file=sys.stderr)
        return state
    try:
        notify("签到监控鉴权失败", f"HTTP {status}，学生 token 可能已过期。", {"level": "active"})
    except Exception as error:
        print(f"auth Bark failed: {error}", file=sys.stderr)
        return state
    updated = dict(state)
    updated["authAlertedAt"] = now
    return updated


def alert_new_checkins(state: dict[str, Any], items: list[dict[str, str]], notify: NotifyFn) -> dict[str, Any]:
    new_items, retained = diff_checkins(set(state.get("alertedIds") or []), items)
    for item in new_items:
        title = item["title"] or "待签到"
        try:
            notify(title, format_checkin_body(item), {"id": f"checkin-{item['id']}"})
        except Exception as error:
            print(f"checkin Bark failed for {item['id']}: {error}", file=sys.stderr)
            continue
        retained.add(item["id"])
        print(f"alerted checkin {item['id']}")
    updated = dict(state)
    updated["alertedIds"] = sorted(retained)
    return updated


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Poll student pending check-ins and notify via Bark")
    parser.add_argument("--config", required=True, help="path to config.json")
    parser.add_argument("--once", action="store_true", help="run a single poll cycle and exit")
    parser.add_argument("--dump", action="store_true", help="print the raw pending-list JSON and exit")
    return parser.parse_args(argv)


def dump_payload(config: dict[str, Any]) -> int:
    status, payload = fetch_pending(config)
    print(f"HTTP {status}")
    if isinstance(payload, (dict, list)):
        print(json.dumps(payload, ensure_ascii=False, indent=2))
    else:
        print(payload)
    return 0 if status < 400 else 1


def loop(config: dict[str, Any], config_path: Path, once: bool) -> int:
    path = state_path_for(config, config_path)
    state = load_state(path)
    interval = int(config.get("pollIntervalSeconds") or MIN_POLL_INTERVAL)
    while True:
        state = run_cycle(config, state, int(time.time()))
        save_state(path, state)
        if once:
            return 0
        time.sleep(interval)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    config_path = Path(args.config).expanduser().resolve()
    config = load_config(config_path)
    if args.dump:
        return dump_payload(config)
    return loop(config, config_path, args.once)


if __name__ == "__main__":
    sys.exit(main())
