// guard_fixed.qnt: the same guard with the four fixes applied.
//
//   1. cache key is (action id, context), not the intent class
//   2. an action that is irreversible in the current context is never
//      served from cache
//   3. a final timeout asks a human instead of allowing
//   4. an oracle answer is applied only to the request it was issued for
//
//   quint run    --main guard_fixed --invariant safety specs/guard_fixed.qnt
//   quint verify --main guard_fixed --invariant safety --max-steps 12 specs/guard_fixed.qnt
//   quint run    --main guard_fixed --invariant noReversibleExecuted specs/guard_fixed.qnt  # expect a violation
//
// guard_fix1 .. guard_fix4 apply one fix each, to show that no single fix
// closes every path.
module guard_fixed {
  import guard(
    TTL = 2,
    MAX_RETRY = 1,
    FAIL_OPEN = false,
    CACHE_BY_INTENT = false,
    CACHE_IRREVERSIBLE = false,
    CHECK_REQ_ID = true,
    ACTIONS = Set(
      { id: "rm_build", intent: "delete_dir" },
      { id: "rm_root",  intent: "delete_dir" },
      { id: "ls",       intent: "read" }
    ),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"

  pure val ls: Action = { id: "ls", intent: "read" }
  pure val rmRoot: Action = { id: "rm_root", intent: "delete_dir" }

  /// The fixed guard still lets a reversible action run.
  run reversibleRunsTest =
    init
      .then(propose(ls))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "ls", ctx: "dev" }, Allow))
      .then(resolve)
      .expect(not(noReversibleExecuted))
      .expect(safety)

  /// The cost of fix 3: every final timeout is now a human question.
  run timeoutAsksHumanTest =
    init
      .then(propose(rmRoot))
      .then(askOracle)
      .then(oracleTimeout)
      .then(oracleTimeout)
      .expect(curDecision.verdict == Ask)
      .then(humanApprove)
      .then(resolve)
      .expect(executedViaHuman)
      .expect(safety)
}

/// Fix 1 only: key by (id, ctx).
module guard_fix1 {
  import guard(
    TTL = 2, MAX_RETRY = 1, FAIL_OPEN = true,
    CACHE_BY_INTENT = false, CACHE_IRREVERSIBLE = true, CHECK_REQ_ID = false,
    ACTIONS = Set({ id: "rm_build", intent: "delete_dir" }, { id: "rm_root", intent: "delete_dir" }, { id: "ls", intent: "read" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}

/// Fix 2 only: never serve an irreversible action from cache.
module guard_fix2 {
  import guard(
    TTL = 2, MAX_RETRY = 1, FAIL_OPEN = true,
    CACHE_BY_INTENT = true, CACHE_IRREVERSIBLE = false, CHECK_REQ_ID = false,
    ACTIONS = Set({ id: "rm_build", intent: "delete_dir" }, { id: "rm_root", intent: "delete_dir" }, { id: "ls", intent: "read" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}

/// Fix 3 only: fail closed on timeout.
module guard_fix3 {
  import guard(
    TTL = 2, MAX_RETRY = 1, FAIL_OPEN = false,
    CACHE_BY_INTENT = true, CACHE_IRREVERSIBLE = true, CHECK_REQ_ID = false,
    ACTIONS = Set({ id: "rm_build", intent: "delete_dir" }, { id: "rm_root", intent: "delete_dir" }, { id: "ls", intent: "read" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}

/// Fix 4 only: drop answers to other requests.
module guard_fix4 {
  import guard(
    TTL = 2, MAX_RETRY = 1, FAIL_OPEN = true,
    CACHE_BY_INTENT = true, CACHE_IRREVERSIBLE = true, CHECK_REQ_ID = true,
    ACTIONS = Set({ id: "rm_build", intent: "delete_dir" }, { id: "rm_root", intent: "delete_dir" }, { id: "ls", intent: "read" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}

/// Fixes 1 and 2 (the cache fixes) without touching timeouts or correlation.
module guard_fix12 {
  import guard(
    TTL = 2, MAX_RETRY = 1, FAIL_OPEN = true,
    CACHE_BY_INTENT = false, CACHE_IRREVERSIBLE = false, CHECK_REQ_ID = false,
    ACTIONS = Set({ id: "rm_build", intent: "delete_dir" }, { id: "rm_root", intent: "delete_dir" }, { id: "ls", intent: "read" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}

/// Fixes 1, 2 and 3: everything except request correlation.
module guard_fix123 {
  import guard(
    TTL = 2, MAX_RETRY = 1, FAIL_OPEN = false,
    CACHE_BY_INTENT = false, CACHE_IRREVERSIBLE = false, CHECK_REQ_ID = false,
    ACTIONS = Set({ id: "rm_build", intent: "delete_dir" }, { id: "rm_root", intent: "delete_dir" }, { id: "ls", intent: "read" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}
