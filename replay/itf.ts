// Minimal reader for the ITF traces under traces/, shared by the replay tests.
// It turns a trace of the guard model into the sequence of tool calls the
// agent made, each with the decision the model reached for it.
//
// A tool call starts when `pending` goes from None to Some(action) and ends at
// the first later state where `decision` is Some. The context is read at the
// end state. A trailing proposal that never reaches a decision is dropped.
import { readFileSync } from "node:fs";

export type Verdict = "Allow" | "Ask" | "Block";
export type Basis = "Oracle" | "Cache" | "Human" | "FailOpen";
export type ToolCall = {
  index: number;
  actionId: string;
  intent: string;
  ctx: string;
  verdict: Verdict;
  basis: Basis;
  /// srcId / srcCtx of the decision: what the reused verdict was about.
  srcId: string;
  srcCtx: string;
};

type Itf = { vars: string[]; states: Record<string, unknown>[] };

function tag(v: unknown): string {
  return (v as { tag: string }).tag;
}
function some(v: unknown): unknown | undefined {
  const o = v as { tag: string; value: unknown };
  return o.tag === "Some" ? o.value : undefined;
}

export function loadTrace(path: string): Itf {
  return JSON.parse(readFileSync(path, "utf8")) as Itf;
}

export function toolCalls(trace: Itf): ToolCall[] {
  const prefix = trace.vars[0].slice(0, trace.vars[0].lastIndexOf("::") + 2);
  const get = (s: Record<string, unknown>, name: string) => s[prefix + name];
  const calls: ToolCall[] = [];
  let open: { actionId: string; intent: string } | undefined;
  for (const s of trace.states) {
    const pending = some(get(s, "pending")) as { id: string; intent: string } | undefined;
    const decision = some(get(s, "decision")) as
      | { verdict: unknown; basis: unknown; srcId: string; srcCtx: string }
      | undefined;
    if (!open && pending) {
      open = { actionId: pending.id, intent: pending.intent };
    }
    if (open && decision) {
      calls.push({
        index: calls.length,
        actionId: open.actionId,
        intent: open.intent,
        ctx: get(s, "ctx") as string,
        verdict: tag(decision.verdict) as Verdict,
        basis: tag(decision.basis) as Basis,
        srcId: decision.srcId,
        srcCtx: decision.srcCtx,
      });
      open = undefined;
    }
    if (!pending) open = undefined;
  }
  return calls;
}
