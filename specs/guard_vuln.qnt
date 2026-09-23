// guard_vuln.qnt: the generic guard with every optimisation switched on.
//
// Three actions, two contexts, TTL 2, one retry. `rm_build` and `rm_root`
// share the intent class "delete_dir". `rm_build` is reversible in dev and
// irreversible in prod; `rm_root` is always irreversible; `ls` is always safe.
//
//   quint run  --main guard_vuln --invariant safety specs/guard_vuln.qnt   # expect a violation
//   quint test --main guard_vuln specs/guard_vuln.qnt                      # pinned counterexamples
module guard_vuln {
  import guard(
    TTL = 2,
    MAX_RETRY = 1,
    FAIL_OPEN = true,
    CACHE_BY_INTENT = true,
    CACHE_IRREVERSIBLE = true,
    CHECK_REQ_ID = false,
    ACTIONS = Set(
      { id: "rm_build", intent: "delete_dir" },
      { id: "rm_root",  intent: "delete_dir" },
      { id: "ls",       intent: "read" }
    ),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("rm_root", "dev"), ("rm_root", "prod"), ("rm_build", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"

  pure val rmBuild: Action = { id: "rm_build", intent: "delete_dir" }
  pure val rmRoot: Action = { id: "rm_root", intent: "delete_dir" }
  pure val ls: Action = { id: "ls", intent: "read" }

  /// CE1: the safe rm_build is allowed, the verdict is cached under the
  /// intent "delete_dir", and the dangerous rm_root is served from it.
  run intentLeakTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev" }, Allow))
      .then(resolve)
      .then(propose(rmRoot))
      .then(cacheHit)
      .then(resolve)
      .expect(not(noUnapprovedIrreversible))
      .expect(not(cacheSoundness))

  /// CE2: two timeouts on rm_root end in fail-open and the action runs.
  run failOpenTest =
    init
      .then(propose(rmRoot))
      .then(askOracle)
      .then(oracleTimeout)
      .then(oracleTimeout)
      .then(resolve)
      .expect(not(noUnapprovedIrreversible))
      .expect(executedViaFailOpen)

  /// CE3: an Allow for rm_build obtained in dev survives a switch to prod,
  /// where the same call is irreversible, and is served from cache.
  run contextLeakTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev" }, Allow))
      .then(resolve)
      .then(switchCtx("prod"))
      .then(propose(rmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(not(noUnapprovedIrreversible))
      .expect(not(cacheSoundness))

  /// CE4: request 0 for ls times out, is retried as request 1, times out
  /// again, and the guard falls back. The agent then proposes rm_root, the
  /// guard issues request 2, and the late Allow for request 0 arrives and is
  /// applied to rm_root.
  run staleAnswerTest =
    init
      .then(propose(ls))
      .then(askOracle)
      .then(oracleTimeout)
      .then(oracleTimeout)
      .then(resolve)
      .then(propose(rmRoot))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "ls", ctx: "dev" }, Allow))
      .then(resolve)
      .expect(not(answerMatchesRequest))
      .expect(not(noUnapprovedIrreversible))

  /// CE5 (not in the original list): the stale answer of CE4 is also written
  /// to the cache under rm_root's key, so a later rm_build in prod is served
  /// from a verdict that was never about deleting anything. Two optimisations
  /// compose into a third path.
  run stalePollutesCacheTest =
    init
      .then(propose(ls))
      .then(askOracle)
      .then(oracleTimeout)
      .then(oracleTimeout)
      .then(resolve)
      .then(propose(rmRoot))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "ls", ctx: "dev" }, Allow))
      .then(resolve)
      .then(switchCtx("prod"))
      .then(propose(rmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(executed.length() == 3)
      .expect(executed[2].basis == Cache)
      .expect(not(noUnapprovedIrreversible))

  /// Sanity: a reversible action does execute on the oracle's Allow.
  run reversibleRunsTest =
    init
      .then(propose(ls))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "ls", ctx: "dev" }, Allow))
      .then(resolve)
      .expect(not(noReversibleExecuted))
      .expect(safety)
}
