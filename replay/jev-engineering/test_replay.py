"""Replays specs/jev_engineering.qnt against the unmodified jev-engineering hook.

Nothing inside the target is patched. The test uses only the hook's public
contract (Claude Code PreToolUse JSON on stdin, exit code out) and documented
environment variables: JEV_ENDPOINT, JEV_GATE_MODE, JEV_GATE_TIMEOUT,
JEV_GATE_LOG, JEV_GATE_HOME, OPENROUTER_API_KEY.

The model's `oracleTimeout` is realised by an endpoint that never answers.
In `guard` mode the trace says the destructive call executes on a fail-open
fallback (exit 0). In `enforce` mode the same input must not exit 0.
"""
from __future__ import annotations

import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from itf import load_trace, tool_calls  # noqa: E402

HERE = Path(__file__).parent
TARGET = HERE / "target"
TRACES = HERE.parent.parent / "traces"

# ---- abstraction mapping (mirrors docs/abstraction.md) ----
COMMAND = {"rm_data": "rm -rf ./data", "ls": "ls"}


class FakeSystemOne(http.server.BaseHTTPRequestHandler):
    mode = "hang"  # hang | allow
    calls = 0

    def do_POST(self):  # noqa: N802
        FakeSystemOne.calls += 1
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if FakeSystemOne.mode == "hang":
            time.sleep(5)  # longer than JEV_GATE_TIMEOUT; the client gives up
            return
        answers = {}
        for qid, q in body.get("questions", {}).items():
            if q.get("type") == "noul":
                answers[qid] = {"type": "noul", "noul": 0.05}
            elif q.get("type") == "choice":
                answers[qid] = {"type": "choice", "choice": "allow", "confidence": 0.9}
        payload = json.dumps({"answers": answers, "usage": {"cost": 0}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # silence
        pass


class ReplayTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (TARGET / "jev_gate.py").exists():
            raise unittest.SkipTest("target not found; run replay/setup.sh first")
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeSystemOne)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.tmp = Path(tempfile.mkdtemp(prefix="guard-spec-jeveng-"))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_hook(self, mode: str, command: str) -> subprocess.CompletedProcess:
        env = {
            **os.environ,
            "JEV_ENDPOINT": f"http://127.0.0.1:{self.port}/v1/systemone",
            "OPENROUTER_API_KEY": "replay-test",
            "JEV_GATE_MODE": mode,
            "JEV_GATE_TIMEOUT": "1",
            "JEV_GATE_LOG": str(self.tmp / "decisions.jsonl"),
            "JEV_GATE_HOME": str(self.tmp / "home"),
        }
        event = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": "/srv/repo"}
        return subprocess.run(
            [sys.executable, str(TARGET / "jev_gate.py")],
            input=json.dumps(event),
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def test_guard_mode_replays_timeoutRunsTest(self):
        calls = tool_calls(load_trace(TRACES / "jev_engineering_guard_timeoutRunsTest.itf.json"))
        self.assertEqual(len(calls), 1)
        call = calls[0]
        self.assertEqual((call.verdict, call.basis), ("Allow", "FailOpen"))
        FakeSystemOne.mode = "hang"
        before = FakeSystemOne.calls
        r = self.run_hook("guard", COMMAND[call.action_id])
        self.assertEqual(FakeSystemOne.calls - before, 1, "the hook asked the model once")
        # The model says the action executes on fail-open. Exit 0 is the hook
        # not blocking, which is exactly that.
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_enforce_mode_does_not_fail_open(self):
        FakeSystemOne.mode = "hang"
        r = self.run_hook("enforce", COMMAND["rm_data"])
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("wants a human", r.stderr)

    def test_sanity_model_allow_exits_zero_in_both_modes(self):
        FakeSystemOne.mode = "allow"
        for mode in ("guard", "enforce"):
            r = self.run_hook(mode, COMMAND["ls"])
            self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == "__main__":
    unittest.main()
