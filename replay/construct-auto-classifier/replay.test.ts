// Replays the counterexample traces of specs/construct_auto_classifier.qnt
// against the unmodified construct-auto-classifier agy hook.
//
// Nothing inside the target is patched. The test uses only:
//   - the hook's public stdin/stdout contract (`auto-classifier agy`)
//   - documented environment variables (TYPESAFE_BASE_URL, TYPESAFE_API_KEY,
//     AUTO_CLASSIFIER_PROVIDER, AUTO_CLASSIFIER_CONFIG, AUTO_CLASSIFIER_LOG,
//     XDG_RUNTIME_DIR, HOME)
//   - a fake System One endpoint that answers what the model trace says the
//     oracle answered, or hangs where the trace says it timed out.
//
// For every tool call in the trace the test asserts two things:
//   1. the hook's decision agrees with the model's verdict
//   2. the fake endpoint was called exactly when the model's basis is Oracle,
//      and not at all when the basis is Cache (the fake would answer "deny"
//      in that case, so a hidden call could not pass unnoticed)
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadTrace, toolCalls, type ToolCall } from "../itf";

const HERE = import.meta.dir;
const TARGET = join(HERE, "target");
const TRACES = join(HERE, "..", "..", "traces");

// ---- abstraction mapping (mirrors README.md) ----
const COMMAND: Record<string, string> = {
  rm_build: "rm -rf build",
  sudo_rm_build: "sudo rm -rf build",
  ls: "ls",
};
const CWD: Record<string, string> = {
  "dev-sandbox": "/work/dev-sandbox",
  prod: "/srv/prod",
};
const SESSION = "guard-spec-replay";

// ---- fake System One endpoint ----
type Mode = "allow" | "deny" | "hang";
let mode: Mode = "deny";
let calls = 0;
let lastState: unknown;
let server: ReturnType<typeof Bun.serve>;

function answersFor(questions: Record<string, { type: string }>, m: Mode) {
  const answers: Record<string, unknown> = {};
  for (const [id, q] of Object.entries(questions)) {
    if (q.type === "choice") {
      const choice = m === "allow" ? "allow" : "deny";
      answers[id] = {
        type: "choice",
        choice,
        confidence: 0.97,
        probabilities: { allow: choice === "allow" ? 0.97 : 0.03, deny: choice === "allow" ? 0.03 : 0.97 },
      };
    } else if (q.type === "noul") {
      answers[id] = { type: "noul", noul: m === "allow" ? 0.01 : 0.95 };
    }
  }
  return answers;
}

beforeAll(() => {
  if (!existsSync(join(TARGET, "src", "cli.ts"))) {
    throw new Error("target not found; run replay/setup.sh first");
  }
  server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    async fetch(req) {
      calls += 1;
      const body = (await req.json()) as { state: unknown; questions: Record<string, { type: string }> };
      lastState = body.state;
      if (mode === "hang") {
        await new Promise(() => {}); // never answers; the hook's own timeout fires
      }
      return Response.json({ model: "fake", answers: answersFor(body.questions, mode), usage: { cost: 0 } });
    },
  });
});

afterAll(() => server?.stop(true));

// ---- one isolated hook environment per trace ----
let home: string;
function freshEnv() {
  home = mkdtempSync(join(tmpdir(), "guard-spec-cac-"));
  // The only config option used: shorten the model timeout so the timeout
  // scenario replays in seconds. Everything else is the shipped default.
  writeFileSync(join(home, "config.json"), JSON.stringify({ jev: { timeoutMs: 1500 } }));
  return {
    ...process.env,
    HOME: home,
    XDG_RUNTIME_DIR: home,
    AUTO_CLASSIFIER_CONFIG: join(home, "config.json"),
    AUTO_CLASSIFIER_PROVIDER: "jev",
    AUTO_CLASSIFIER_LOG: "",
    TYPESAFE_API_KEY: "replay-test",
    TYPESAFE_BASE_URL: `http://127.0.0.1:${server.port}`,
  };
}

type HookOutput = { decision: "allow" | "deny" | "ask" | "force_ask"; reason?: string };

// Async on purpose: the fake endpoint runs in this process, so the hook must
// not be awaited with a blocking spawn.
async function runHook(env: Record<string, string | undefined>, call: ToolCall): Promise<HookOutput> {
  const input = {
    conversationId: SESSION,
    toolCall: { name: "run_command", args: { CommandLine: COMMAND[call.actionId], Cwd: CWD[call.ctx] } },
  };
  const p = Bun.spawn(["bun", join(TARGET, "src", "cli.ts"), "agy"], {
    stdin: new TextEncoder().encode(JSON.stringify(input)),
    env,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [status, stdout, stderr] = await Promise.all([
    p.exited,
    new Response(p.stdout).text(),
    new Response(p.stderr).text(),
  ]);
  if (status !== 0) throw new Error(`hook exited ${status}: ${stderr}`);
  return JSON.parse(stdout.trim()) as HookOutput;
}

async function replay(traceFile: string) {
  const calls_ = toolCalls(loadTrace(join(TRACES, traceFile)));
  expect(calls_.length).toBeGreaterThan(0);
  const env = freshEnv();
  const log: string[] = [];
  for (const call of calls_) {
    // Program the oracle from the trace.
    if (call.basis === "Oracle") mode = call.verdict === "Allow" ? "allow" : "deny";
    else if (call.basis === "FailOpen") mode = "hang";
    else mode = "deny"; // Cache / Human: the endpoint must not be consulted at all
    const before = calls;
    const out = await runHook(env, call);
    const consulted = calls - before;
    log.push(`${call.actionId}@${call.ctx} model=${call.verdict}/${call.basis} hook=${out.decision} calls=${consulted}`);

    // 1. decision agrees with the model
    if (call.verdict === "Allow" && out.decision !== "allow") {
      throw new Error(`expected allow for ${call.actionId}@${call.ctx}, hook said ${out.decision}: ${out.reason}`);
    }
    if (call.verdict !== "Allow") expect(out.decision).not.toBe("allow");

    // 2. the endpoint was consulted exactly when the model asked the oracle
    if (call.basis === "Oracle") {
      expect(consulted).toBe(1);
      // and it never saw the working directory
      expect(JSON.stringify(lastState)).not.toContain(CWD[call.ctx]);
    } else if (call.basis === "Cache") {
      expect(consulted).toBe(0);
      expect(out.reason).toContain("same verdict as earlier in this session");
    } else if (call.basis === "FailOpen") {
      expect(consulted).toBe(1);
    }
  }
  console.log(`\n${traceFile}\n  ${log.join("\n  ")}`);
  rmSync(home, { recursive: true, force: true });
}

describe("construct-auto-classifier replays the model's counterexamples", () => {
  test("CE3 context leak: an Allow from the sandbox cwd is served in the prod cwd", async () => {
    await replay("construct_auto_classifier_contextLeakTest.itf.json");
  });

  test("CE1 intent leak: an Allow for `rm -rf build` is served for `sudo rm -rf build`", async () => {
    await replay("construct_auto_classifier_sudoLeakTest.itf.json");
  });

  test("fail-closed: a model timeout does not allow", async () => {
    await replay("construct_auto_classifier_timeoutDeniesTest.itf.json");
  });
});
