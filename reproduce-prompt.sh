#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(pwd)"
if [[ "$WORKSPACE" == *"Code6-27-B"* ]]; then
  VARIANT="B"
  STATE_DIR="${HOME}/.cache/code6-27-b"
else
  VARIANT="A"
  STATE_DIR="${HOME}/.cache/code6-27-a"
fi

export WORKSPACE VARIANT STATE_DIR
python3 - <<'PY'
import concurrent.futures
import json
import os
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

workspace = Path(os.environ["WORKSPACE"]).resolve()
variant = os.environ["VARIANT"]
state_dir = Path(os.environ["STATE_DIR"]).resolve()
api_base = os.environ.get("API_BASE_URL", "").rstrip("/")
if not api_base:
    raise SystemExit("API_BASE_URL is required")

api_port = int((state_dir / "api-port").read_text().strip())
base = f"{api_base}/api/v1"
results = []


def call(method, path, body=None, headers=None, root=None):
    url = f"{root or base}{path}"
    payload = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    request_headers = {"Content-Type": "application/json; charset=utf-8"}
    request_headers.update(headers or {})
    request = urllib.request.Request(url, data=payload, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read().decode("utf-8")
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8")
        try:
            data = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            data = {"raw": raw}
        return error.code, data
    except Exception as error:
        return 0, {"error": str(error)}


def record(name, ok, detail):
    results.append({"name": name, "ok": bool(ok), "detail": detail})
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {detail}")


def health_live():
    status, _ = call("GET", "/health/live", root=f"http://127.0.0.1:{api_port}")
    return status == 200


def restart_api():
    pid_file = state_dir / "api.pid"
    try:
        os.kill(int(pid_file.read_text().strip()), signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError, ValueError):
        pass
    deadline = time.time() + 15
    while time.time() < deadline and health_live():
        time.sleep(0.2)

    log_path = state_dir / "api.log"
    log_file = open(log_path, "ab")
    env = os.environ.copy()
    env["DATA_FILE"] = "data.json"
    env["PORT"] = str(api_port)
    server_entry = state_dir / "api-runtime/server.ts" if variant == "B" else workspace / "api/server.ts"
    process = subprocess.Popen(
        [str(workspace / "node_modules/.bin/tsx"), str(server_entry)],
        cwd=str(state_dir),
        env=env,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    pid_file.write_text(str(process.pid))
    deadline = time.time() + 30
    while time.time() < deadline:
        if health_live():
            return
        time.sleep(0.3)
    raise RuntimeError("API did not become ready after restart")


status, created = call("POST", "/tours", {"name": "边界验证剧团", "seed": 42})
record("创建剧团", status == 200 and "tour" in created, f"status={status}")
if status != 200 or "tour" not in created:
    raise SystemExit(1)
tour = created["tour"]
tour_id = tour["id"]

status, investigated = call(
    "POST",
    f"/tours/{tour_id}/investigations",
    {"kind": "market", "baseVersion": tour["version"]},
)
record("进入编排阶段", status == 200 and "tour" in investigated, f"status={status}")
if status != 200 or "tour" not in investigated:
    raise SystemExit(1)
tour = investigated["tour"]
actor_id = tour["actors"][0]["id"]
draft = {
    "playId": "moon",
    "assignments": {},
    "timeline": [{"actionId": "bow", "actorIds": [actor_id], "act": 0, "slot": 0}],
    "endings": [0, 1, 2],
}
draft_version = tour.get("draftVersion") if isinstance(tour.get("draftVersion"), int) else 0

if variant == "A":
    save_body = {**draft, "expectedVersion": draft_version}
else:
    save_body = {"baseVersion": tour["version"], "draft": draft}

status, saved = call("PUT", f"/tours/{tour_id}/production", save_body)
record("保存草稿", status == 200 and "tour" in saved, f"status={status}")
if status != 200 or "tour" not in saved:
    raise SystemExit(1)
saved_tour = saved["tour"]
saved_version = saved.get("draftVersion", saved_tour.get("draftVersion"))

bad_draft = {**draft, "endings": [2, 2, 2]}
if variant == "A":
    unsaved_body = {**bad_draft, "expectedVersion": saved_version}
else:
    unsaved_body = {"baseVersion": saved_tour["version"], "draftVersion": saved_version, "draft": bad_draft}
status, unsaved = call(
    "POST",
    f"/tours/{tour_id}/performances",
    unsaved_body,
    {"Idempotency-Key": "unsaved-draft-key"},
)
record("未保存草稿不能生成快照", status == 409, f"status={status}, code={unsaved.get('code')}")

if variant == "A":
    concurrent_body = {**draft, "expectedVersion": saved_version}
else:
    concurrent_body = {"baseVersion": saved_tour["version"], "draft": draft}

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    futures = [
        pool.submit(call, "PUT", f"/tours/{tour_id}/production", concurrent_body),
        pool.submit(call, "PUT", f"/tours/{tour_id}/production", concurrent_body),
    ]
    concurrent_results = [future.result() for future in futures]
concurrent_statuses = sorted(status for status, _ in concurrent_results)
winner = next(((status, body) for status, body in concurrent_results if status == 200), None)
record(
    "并发保存只有一份提交成功",
    concurrent_statuses == [200, 409] and winner is not None,
    f"statuses={concurrent_statuses}",
)
if winner is None:
    raise SystemExit(1)
winner_tour = winner[1]["tour"]
winner_version = winner[1].get("draftVersion", winner_tour.get("draftVersion"))
perform_base_version = winner_tour["version"]
perform_draft_version = winner_version
if variant == "A":
    perform_body = {"expectedVersion": perform_draft_version}
else:
    perform_body = {
        "baseVersion": perform_base_version,
        "draftVersion": perform_draft_version,
        "draft": draft,
    }
replay_key = "restart-replay-key"
status, performance = call(
    "POST",
    f"/tours/{tour_id}/performances",
    perform_body,
    {"Idempotency-Key": replay_key},
)
record("首次演出使用已保存草稿", status == 200 and "performance" in performance, f"status={status}")
if status != 200 or "performance" not in performance:
    raise SystemExit(1)
performance_id = performance["performance"]["id"]

restart_api()
status, replay = call(
    "POST",
    f"/tours/{tour_id}/performances",
    perform_body,
    {"Idempotency-Key": replay_key},
)
record(
    "重启后合法重放返回原演出",
    status == 200 and replay.get("replayed") is True and replay.get("performance", {}).get("id") == performance_id,
    f"status={status}, replayed={replay.get('replayed')}",
)

if variant == "A":
    stale_replay_body = {"expectedVersion": perform_draft_version + 1}
else:
    stale_replay_body = {
        "baseVersion": perform_base_version + 1,
        "draftVersion": perform_draft_version + 1,
        "draft": bad_draft,
    }
status, stale_replay = call(
    "POST",
    f"/tours/{tour_id}/performances",
    stale_replay_body,
    {"Idempotency-Key": replay_key},
)
record(
    "重启后陈旧重放被拒绝",
    status == 409,
    f"status={status}, code={stale_replay.get('code')}, replayed={stale_replay.get('replayed')}",
)

overall = all(item["ok"] for item in results)
payload = {"variant": variant, "overall": "PASS" if overall else "FAIL", "checks": results}
(state_dir / "repro-result.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"RESULT {variant} {'PASS' if overall else 'FAIL'}")
sys.exit(0 if overall else 1)
PY
