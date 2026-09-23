// guard.qnt: a generic model of a tool-call guard for AI coding agents.
//
// The guard sits between an agent and a judgment model ("the oracle"). It may
// keep a semantic cache of verdicts, retry a timed-out request, fall back
// open or closed on a final timeout, and ask a human. The oracle is a black
// box: any in-flight request may be answered with any verdict at any time.
// We never model whether the oracle is right. We ask whether the guard is
// safe for every answer it could give.
//
// The module is parametric. A configuration instantiates it with
//   import guard(TTL = 2, ...) from "./guard"
// so the vulnerable and fixed variants share one body (see guard_vuln.qnt and
// guard_fixed.qnt) and a real implementation gets its own instance (see
// construct_auto_classifier.qnt and jev_engineering.qnt).
module guard {
  // ---------- parameters ----------
  /// Cache entry lifetime in ticks. 0 disables the cache.
  const TTL: int
  /// Re-asks after a timeout before giving up.
  const MAX_RETRY: int
  /// true: a final timeout allows the action. false: it asks a human.
  const FAIL_OPEN: bool
  /// true: cache key is the intent class. false: key is (action id, context).
  const CACHE_BY_INTENT: bool
  /// false: an action that is irreversible here is never served from cache.
  const CACHE_IRREVERSIBLE: bool
  /// true: an oracle answer whose reqId is not the one awaited is dropped.
  const CHECK_REQ_ID: bool
  /// The universe of actions the agent may propose.
  const ACTIONS: Set[Action]
  /// The contexts (cwd, environment, branch) the agent may be in.
  const CTXS: Set[str]
  /// (action id, context) pairs in which the action cannot be undone.
  const IRREVERSIBLE: Set[(str, str)]
  /// The context the run starts in.
  const INITIAL_CTX: str

  // ---------- types ----------
  type Verdict = Allow | Ask | Block
  /// What an execution rests on.
  type Basis = Oracle | Cache | Human | FailOpen
  /// `id` is the concrete call; `intent` is the class a semantic cache maps it to.
  type Action = { id: str, intent: str }
  type Req = { reqId: int, actionId: str, ctx: str }
  type Key = { k: str, c: str }
  type CacheEntry = { verdict: Verdict, actionId: str, ctx: str, at: int }
  /// srcId / srcCtx: the action and context the verdict was originally about.
  type Decision = { verdict: Verdict, basis: Basis, reqId: int, srcId: str, srcCtx: str }
  type Exec = { act: Action, ctx: str, basis: Basis, reqId: int, srcId: str, srcCtx: str }
  type Option[a] = Some(a) | None

  // ---------- derived ----------
  pure def irreversible(a: Action, c: str): bool = IRREVERSIBLE.contains((a.id, c))

  pure def cacheKey(a: Action, c: str): Key =
    if (CACHE_BY_INTENT) { k: a.intent, c: "" } else { k: a.id, c: c }

  // ---------- state ----------
  var now: int
  var ctx: str
  /// The proposal awaiting a decision, if any.
  var pending: Option[Action]
  /// The decision reached for `pending`, not yet acted on.
  var decision: Option[Decision]
  /// The reqId the guard currently waits for.
  var waitingFor: Option[int]
  var retries: int
  var nextReq: int
  /// Every request ever issued. Only invariants read it.
  var issued: Set[Req]
  /// Requests whose answer may still arrive, including timed-out ones.
  var inflight: Set[Req]
  var cache: Key -> CacheEntry
  var executed: List[Exec]

  // ---------- helpers ----------
  val isPending: bool = pending != None
  val undecided: bool = isPending and decision == None
  val cur: Action = match pending { | Some(a) => a | None => { id: "", intent: "" } }
  val curDecision: Decision = match decision {
    | Some(d) => d
    | None => { verdict: Block, basis: Oracle, reqId: -1, srcId: "", srcCtx: "" }
  }
  val execs: Set[Exec] = executed.foldl(Set(), (acc, e) => acc.union(Set(e)))

  // ---------- actions ----------
  action init = all {
    now' = 0,
    ctx' = INITIAL_CTX,
    pending' = None,
    decision' = None,
    waitingFor' = None,
    retries' = 0,
    nextReq' = 0,
    issued' = Set(),
    inflight' = Set(),
    cache' = Map(),
    executed' = List(),
  }

  /// The agent proposes a tool call.
  action propose(a: Action): bool = all {
    not(isPending),
    pending' = Some(a),
    decision' = None,
    retries' = 0,
    now' = now, ctx' = ctx, waitingFor' = waitingFor, nextReq' = nextReq,
    issued' = issued, inflight' = inflight, cache' = cache, executed' = executed,
  }

  /// Serve the decision from the semantic cache.
  action cacheHit: bool = all {
    undecided,
    waitingFor == None,
    val k = cacheKey(cur, ctx)
    all {
      cache.keys().contains(k),
      cache.get(k).at + TTL > now,
      CACHE_IRREVERSIBLE or not(irreversible(cur, ctx)),
      decision' = Some({
        verdict: cache.get(k).verdict, basis: Cache, reqId: -1,
        srcId: cache.get(k).actionId, srcCtx: cache.get(k).ctx
      }),
    },
    now' = now, ctx' = ctx, pending' = pending, waitingFor' = waitingFor,
    retries' = retries, nextReq' = nextReq, issued' = issued,
    inflight' = inflight, cache' = cache, executed' = executed,
  }

  /// Issue a request to the oracle.
  action askOracle: bool = all {
    undecided,
    waitingFor == None,
    val r = { reqId: nextReq, actionId: cur.id, ctx: ctx }
    all {
      issued' = issued.union(Set(r)),
      inflight' = inflight.union(Set(r)),
      waitingFor' = Some(nextReq),
      nextReq' = nextReq + 1,
    },
    now' = now, ctx' = ctx, pending' = pending, decision' = decision,
    retries' = retries, cache' = cache, executed' = executed,
  }

  /// The oracle answers in-flight request `r` with verdict `v`.
  /// Without CHECK_REQ_ID, a late answer to an earlier request is applied to
  /// whatever proposal is pending now, and is cached under that proposal's key.
  action answer(r: Req, v: Verdict): bool = all {
    inflight.contains(r),
    val matches = waitingFor == Some(r.reqId)
    val applies = undecided and waitingFor != None and (matches or not(CHECK_REQ_ID))
    all {
      inflight' = inflight.exclude(Set(r)),
      decision' = if (applies)
        Some({ verdict: v, basis: Oracle, reqId: r.reqId, srcId: r.actionId, srcCtx: r.ctx })
        else decision,
      cache' = if (applies)
        cache.put(cacheKey(cur, ctx), { verdict: v, actionId: cur.id, ctx: ctx, at: now })
        else cache,
      waitingFor' = if (applies) None else waitingFor,
    },
    now' = now, ctx' = ctx, pending' = pending, retries' = retries,
    nextReq' = nextReq, issued' = issued, executed' = executed,
  }

  /// The oracle is a black box: any in-flight request, any verdict.
  action oracleAnswer: bool = all {
    inflight != Set(),
    nondet r = inflight.oneOf()
    nondet v = Set(Allow, Ask, Block).oneOf()
    answer(r, v),
  }

  /// The awaited request times out. Retry while allowed, then fall back.
  /// The timed-out request stays in flight: its answer may still arrive.
  action oracleTimeout: bool = all {
    undecided,
    waitingFor != None,
    if (retries < MAX_RETRY)
      val r = { reqId: nextReq, actionId: cur.id, ctx: ctx }
      all {
        retries' = retries + 1,
        issued' = issued.union(Set(r)),
        inflight' = inflight.union(Set(r)),
        waitingFor' = Some(nextReq),
        nextReq' = nextReq + 1,
        decision' = decision,
      }
    else all {
      retries' = retries,
      issued' = issued,
      inflight' = inflight,
      nextReq' = nextReq,
      waitingFor' = None,
      decision' = Some({
        verdict: if (FAIL_OPEN) Allow else Ask, basis: FailOpen,
        reqId: -1, srcId: "", srcCtx: ""
      }),
    },
    now' = now, ctx' = ctx, pending' = pending, cache' = cache, executed' = executed,
  }

  action humanApprove: bool = all {
    isPending,
    decision != None,
    curDecision.verdict == Ask,
    decision' = Some({ verdict: Allow, basis: Human, reqId: -1, srcId: cur.id, srcCtx: ctx }),
    now' = now, ctx' = ctx, pending' = pending, waitingFor' = waitingFor,
    retries' = retries, nextReq' = nextReq, issued' = issued,
    inflight' = inflight, cache' = cache, executed' = executed,
  }

  action humanDeny: bool = all {
    isPending,
    decision != None,
    curDecision.verdict == Ask,
    pending' = None,
    decision' = None,
    now' = now, ctx' = ctx, waitingFor' = waitingFor,
    retries' = retries, nextReq' = nextReq, issued' = issued,
    inflight' = inflight, cache' = cache, executed' = executed,
  }

  /// Act on an Allow. A Block just drops the proposal.
  action resolve: bool = all {
    isPending,
    decision != None,
    curDecision.verdict != Ask,
    executed' = if (curDecision.verdict == Allow)
      executed.append({
        act: cur, ctx: ctx, basis: curDecision.basis, reqId: curDecision.reqId,
        srcId: curDecision.srcId, srcCtx: curDecision.srcCtx
      })
      else executed,
    pending' = None,
    decision' = None,
    now' = now, ctx' = ctx, waitingFor' = waitingFor,
    retries' = retries, nextReq' = nextReq, issued' = issued,
    inflight' = inflight, cache' = cache,
  }

  action advanceTime: bool = all {
    now' = now + 1,
    ctx' = ctx, pending' = pending, decision' = decision, waitingFor' = waitingFor,
    retries' = retries, nextReq' = nextReq, issued' = issued,
    inflight' = inflight, cache' = cache, executed' = executed,
  }

  /// The environment changes between calls (cwd, branch, dev to prod).
  /// The cache survives the change.
  action switchCtx(c: str): bool = all {
    not(isPending),
    c != ctx,
    ctx' = c,
    now' = now, pending' = pending, decision' = decision, waitingFor' = waitingFor,
    retries' = retries, nextReq' = nextReq, issued' = issued,
    inflight' = inflight, cache' = cache, executed' = executed,
  }

  action changeCtx: bool = all {
    CTXS.exclude(Set(ctx)) != Set(),
    nondet c = CTXS.exclude(Set(ctx)).oneOf()
    switchCtx(c),
  }

  action step = any {
    nondet a = ACTIONS.oneOf()
    propose(a),
    cacheHit,
    askOracle,
    oracleAnswer,
    oracleTimeout,
    humanApprove,
    humanDeny,
    resolve,
    advanceTime,
    changeCtx,
  }

  // ---------- invariants ----------
  /// The execution rests on a request issued for this very action in this
  /// very context.
  def answeredForThis(e: Exec): bool =
    issued.exists(r => r.reqId == e.reqId and r.actionId == e.act.id and r.ctx == e.ctx)

  /// An irreversible execution rests on the oracle's Allow for that action or
  /// on a human. Never on a cache entry or a fail-open fallback.
  val noUnapprovedIrreversible = execs.forall(e =>
    irreversible(e.act, e.ctx) implies
      (e.basis == Human or (e.basis == Oracle and answeredForThis(e))))

  /// A cache-based execution reuses a verdict about the same id and context.
  val cacheSoundness = execs.forall(e =>
    e.basis == Cache implies (e.srcId == e.act.id and e.srcCtx == e.ctx))

  /// With FAIL_OPEN off, nothing executes on a fallback.
  val failClosedOnTimeout =
    FAIL_OPEN or execs.forall(e => e.basis != FailOpen)

  /// An oracle-based execution used the answer to its own request.
  val answerMatchesRequest = execs.forall(e =>
    e.basis == Oracle implies answeredForThis(e))

  val safety = all {
    noUnapprovedIrreversible,
    cacheSoundness,
    failClosedOnTimeout,
    answerMatchesRequest,
  }

  /// Everything in `safety` except the rule that an irreversible action is
  /// never served from cache. A guard that satisfies `provenance` but not
  /// `safety` reuses verdicts only about the same call in the same context,
  /// and re-runs an irreversible call inside the cache window without a
  /// fresh judgment. Whether that is acceptable is a policy decision; the
  /// two invariants keep it explicit.
  val provenance = all {
    cacheSoundness,
    failClosedOnTimeout,
    answerMatchesRequest,
  }

  // ---------- reachability (guards against over-blocking) ----------
  /// A guard that blocks everything satisfies `safety`. To rule that out we
  /// check that a reversible action can still execute on the oracle's Allow:
  /// `quint run --invariant noReversibleExecuted` must find a violation.
  val noReversibleExecuted = execs.forall(e =>
    not(not(irreversible(e.act, e.ctx)) and e.basis == Oracle))

  // ---------- witnesses for trace shapes ----------
  val executedViaCache = execs.exists(e => e.basis == Cache)
  val executedViaFailOpen = execs.exists(e => e.basis == FailOpen)
  val executedViaHuman = execs.exists(e => e.basis == Human)
}
