// construct_auto_classifier.qnt: the generic guard instantiated with the
// parameters of godspede/construct-auto-classifier at commit 9062b34.
//
// Mapping (see README.md for the table):
//   intent      = the normalised command key of state-manager.ts:107-125,
//                 which drops `sudo`, leading env assignments, quotes and
//                 output shapers. `rm -rf build` and `sudo rm -rf build`
//                 therefore share one intent.
//   ctx         = the working directory of the tool call (agy `Cwd`), which
//                 is neither in the key nor in the state sent to the model.
//   TTL         = slidingWindowMs (300 000 ms) scaled to 5 ticks.
//   MAX_RETRY   = 0: the Jev path issues one request.
//   FAIL_OPEN   = false: a transport failure is a deny (jev-client.ts:257-260).
//   CHECK_REQ_ID= true: one process per hook call, one awaited promise.
//   CACHE_BY_INTENT = true, CACHE_IRREVERSIBLE = true: recentAllow is consulted
//                 before the model with no danger check (index.ts:164-172).
//
// The replay test in replay/construct-auto-classifier drives the real hook
// with the values of `contextLeakTest` and `sudoLeakTest`.
module construct_auto_classifier {
  import guard(
    TTL = 5,
    MAX_RETRY = 0,
    FAIL_OPEN = false,
    CACHE_BY_INTENT = true,
    CACHE_IRREVERSIBLE = true,
    CHECK_REQ_ID = true,
    ACTIONS = Set(
      { id: "rm_build",      intent: "rm -rf build" },
      { id: "sudo_rm_build", intent: "rm -rf build" },
      { id: "ls",            intent: "ls" }
    ),
    CTXS = Set("dev-sandbox", "prod"),
    IRREVERSIBLE = Set(
      ("rm_build", "prod"),
      ("sudo_rm_build", "dev-sandbox"),
      ("sudo_rm_build", "prod")
    ),
    INITIAL_CTX = "dev-sandbox"
  ).* from "./guard"

  pure val rmBuild: Action = { id: "rm_build", intent: "rm -rf build" }
  pure val sudoRmBuild: Action = { id: "sudo_rm_build", intent: "rm -rf build" }

  /// The model allows `rm -rf build` in the sandbox. The agent moves to the
  /// production checkout and proposes the same text. The cache answers.
  run contextLeakTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev-sandbox" }, Allow))
      .then(resolve)
      .then(switchCtx("prod"))
      .then(propose(rmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(executed.length() == 2)
      .expect(executed[1].basis == Cache)
      .expect(not(noUnapprovedIrreversible))

  /// The model allows `rm -rf build`. The agent proposes `sudo rm -rf build`.
  /// The key normalisation drops `sudo`, so the cache answers.
  run sudoLeakTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev-sandbox" }, Allow))
      .then(resolve)
      .then(propose(sudoRmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(executed.length() == 2)
      .expect(executed[1].basis == Cache)
      .expect(not(cacheSoundness))
      .expect(not(noUnapprovedIrreversible))

  /// After the window has passed, the same call is judged again.
  run windowExpiresTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev-sandbox" }, Allow))
      .then(resolve)
      .then(advanceTime).then(advanceTime).then(advanceTime).then(advanceTime).then(advanceTime)
      .then(switchCtx("prod"))
      .then(propose(rmBuild))
      .expect(not(cache.get(cacheKey(rmBuild, "prod")).at + TTL > now))

  /// Fail-closed holds: a timeout never executes anything.
  run timeoutDeniesTest =
    init
      .then(propose(sudoRmBuild))
      .then(askOracle)
      .then(oracleTimeout)
      .expect(curDecision.verdict == Ask)
      .expect(curDecision.basis == FailOpen)
      .expect(failClosedOnTimeout)
}

/// The cheapest fix: key the cache by (exact command, cwd) and do not drop
/// `sudo`. In the model that is CACHE_BY_INTENT = false; `sudo_rm_build`
/// already has its own id.
///
/// This closes both replayed paths and satisfies `provenance`: every cached
/// verdict is about the same call in the same cwd. It does NOT satisfy
/// `safety`: `rm -rf build` in prod, once allowed, is re-run from cache
/// inside the window without a fresh judgment. See `irreversibleRepeatTest`.
module construct_auto_classifier_fix1 {
  import guard(
    TTL = 5,
    MAX_RETRY = 0,
    FAIL_OPEN = false,
    CACHE_BY_INTENT = false,
    CACHE_IRREVERSIBLE = true,
    CHECK_REQ_ID = true,
    ACTIONS = Set(
      { id: "rm_build",      intent: "rm -rf build" },
      { id: "sudo_rm_build", intent: "rm -rf build" },
      { id: "ls",            intent: "ls" }
    ),
    CTXS = Set("dev-sandbox", "prod"),
    IRREVERSIBLE = Set(
      ("rm_build", "prod"),
      ("sudo_rm_build", "dev-sandbox"),
      ("sudo_rm_build", "prod")
    ),
    INITIAL_CTX = "dev-sandbox"
  ).* from "./guard"

  pure val rmBuild: Action = { id: "rm_build", intent: "rm -rf build" }

  /// A repeat in the same cwd is still served from cache: the fix keeps the
  /// saving the cache was built for.
  run sameCwdStillHitsTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev-sandbox" }, Allow))
      .then(resolve)
      .then(propose(rmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(executed[1].basis == Cache)
      .expect(provenance)
      .expect(safety)

  /// The remaining gap: the same irreversible call, same cwd, inside the
  /// window. `provenance` holds (the verdict was about this call here);
  /// `safety` does not (an irreversible call was not judged this time).
  run irreversibleRepeatTest =
    init
      .then(switchCtx("prod"))
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "prod" }, Allow))
      .then(resolve)
      .then(propose(rmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(executed[1].basis == Cache)
      .expect(provenance)
      .expect(not(safety))
}

/// Fix 1 plus fix 2: never serve a call that is irreversible here from the
/// cache. For this implementation that means caching only allows whose risk
/// answers are well below the threshold, or not caching at all for anything
/// the fast rules did not clear. This satisfies `safety`.
module construct_auto_classifier_fixed {
  import guard(
    TTL = 5,
    MAX_RETRY = 0,
    FAIL_OPEN = false,
    CACHE_BY_INTENT = false,
    CACHE_IRREVERSIBLE = false,
    CHECK_REQ_ID = true,
    ACTIONS = Set(
      { id: "rm_build",      intent: "rm -rf build" },
      { id: "sudo_rm_build", intent: "rm -rf build" },
      { id: "ls",            intent: "ls" }
    ),
    CTXS = Set("dev-sandbox", "prod"),
    IRREVERSIBLE = Set(
      ("rm_build", "prod"),
      ("sudo_rm_build", "dev-sandbox"),
      ("sudo_rm_build", "prod")
    ),
    INITIAL_CTX = "dev-sandbox"
  ).* from "./guard"

  pure val rmBuild: Action = { id: "rm_build", intent: "rm -rf build" }

  /// A reversible repeat in the same cwd is still served from cache.
  run reversibleRepeatStillHitsTest =
    init
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "dev-sandbox" }, Allow))
      .then(resolve)
      .then(propose(rmBuild))
      .then(cacheHit)
      .then(resolve)
      .expect(executed[1].basis == Cache)
      .expect(safety)

  /// The cost: an irreversible repeat is judged again. `cacheHit` is not
  /// enabled even though the entry is present and fresh.
  run irreversibleRepeatIsJudgedTest =
    init
      .then(switchCtx("prod"))
      .then(propose(rmBuild))
      .then(askOracle)
      .then(answer({ reqId: 0, actionId: "rm_build", ctx: "prod" }, Allow))
      .then(resolve)
      .then(propose(rmBuild))
      .expect(cache.keys().contains(cacheKey(rmBuild, "prod")))
      .then(askOracle)
      .then(answer({ reqId: 1, actionId: "rm_build", ctx: "prod" }, Allow))
      .then(resolve)
      .expect(executed[1].basis == Oracle)
      .expect(safety)
}
