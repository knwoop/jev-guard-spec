// jev_engineering.qnt: the generic guard instantiated with the parameters of
// eugeniughelbur/jev-engineering at commit 3161dbf, JEV_GATE_MODE=guard.
//
// Mapping (see docs/abstraction.md):
//   cache       = none. TTL = 0 makes `cacheHit` unreachable.
//   MAX_RETRY   = 0: one urllib request (jev_gate.py:108-123).
//   FAIL_OPEN   = true in `guard` mode: an unreachable model is `ask`, and
//                 `ask` is exit 0, which does not block (jev_gate.py:141-142,
//                 263-271). Whether the host then prompts is outside the
//                 guard; in bypass or auto-approve modes the call runs.
//   FAIL_OPEN   = false in `enforce` mode: `ask` is exit 2.
//   CHECK_REQ_ID= true: one process per hook call.
//
// The replay test in replay/jev-engineering drives jev_gate.py with a fake
// endpoint that never answers and checks the exit code in both modes.
module jev_engineering_guard {
  import guard(
    TTL = 0,
    MAX_RETRY = 0,
    FAIL_OPEN = true,
    CACHE_BY_INTENT = false,
    CACHE_IRREVERSIBLE = false,
    CHECK_REQ_ID = true,
    ACTIONS = Set(
      { id: "rm_data", intent: "rm -rf ./data" },
      { id: "ls",      intent: "ls" }
    ),
    CTXS = Set("repo"),
    IRREVERSIBLE = Set(("rm_data", "repo")),
    INITIAL_CTX = "repo"
  ).* from "./guard"

  pure val rmData: Action = { id: "rm_data", intent: "rm -rf ./data" }

  /// The model times out; guard mode exits 0; the destructive call runs.
  run timeoutRunsTest =
    init
      .then(propose(rmData))
      .then(askOracle)
      .then(oracleTimeout)
      .then(resolve)
      .expect(executedViaFailOpen)
      .expect(not(noUnapprovedIrreversible))
}

module jev_engineering_enforce {
  import guard(
    TTL = 0,
    MAX_RETRY = 0,
    FAIL_OPEN = false,
    CACHE_BY_INTENT = false,
    CACHE_IRREVERSIBLE = false,
    CHECK_REQ_ID = true,
    ACTIONS = Set(
      { id: "rm_data", intent: "rm -rf ./data" },
      { id: "ls",      intent: "ls" }
    ),
    CTXS = Set("repo"),
    IRREVERSIBLE = Set(("rm_data", "repo")),
    INITIAL_CTX = "repo"
  ).* from "./guard"

  pure val rmData: Action = { id: "rm_data", intent: "rm -rf ./data" }

  /// The model times out; enforce mode exits 2; a human has to decide.
  run timeoutAsksTest =
    init
      .then(propose(rmData))
      .then(askOracle)
      .then(oracleTimeout)
      .expect(curDecision.verdict == Ask)
      .then(humanDeny)
      .expect(executed.length() == 0)
      .expect(safety)
}
