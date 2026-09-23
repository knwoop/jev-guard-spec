"""Minimal reader for the ITF traces under traces/ (Python twin of replay/itf.ts)."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ToolCall:
    index: int
    action_id: str
    intent: str
    ctx: str
    verdict: str  # Allow | Ask | Block
    basis: str  # Oracle | Cache | Human | FailOpen
    src_id: str
    src_ctx: str


def _some(v):
    return v["value"] if v.get("tag") == "Some" else None


def load_trace(path: Path) -> dict:
    return json.loads(path.read_text())


def tool_calls(trace: dict) -> list[ToolCall]:
    first = trace["vars"][0]
    prefix = first[: first.rfind("::") + 2]
    calls: list[ToolCall] = []
    open_call = None
    for s in trace["states"]:
        pending = _some(s[prefix + "pending"])
        decision = _some(s[prefix + "decision"])
        if open_call is None and pending is not None:
            open_call = (pending["id"], pending["intent"])
        if open_call is not None and decision is not None:
            calls.append(
                ToolCall(
                    index=len(calls),
                    action_id=open_call[0],
                    intent=open_call[1],
                    ctx=s[prefix + "ctx"],
                    verdict=decision["verdict"]["tag"],
                    basis=decision["basis"]["tag"],
                    src_id=decision["srcId"],
                    src_ctx=decision["srcCtx"],
                )
            )
            open_call = None
        if pending is None:
            open_call = None
    return calls
