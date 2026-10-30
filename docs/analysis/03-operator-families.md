# 03 · Operator families and their invariants

Operators fall into families by the *shape* of their specification: which
variables they need, which actions they add, and what kind of property
captures them. The families below go from the ones where TLA+ adds little
to the ones where model checking finds bugs that tests miss. Each has a
checked specification in `specs/` or a sketch marked as such.

| Family | Operators | Extra state | Extra actions | Characteristic property | Spec |
|---|---|---|---|---|---|
| Pointwise | `map`, `filter`, `scan`, `distinctUntilChanged`, `tap`, `startWith`, `pairwise` | none, or an accumulator | none | `out = F(in)` | `Pointwise.tla` |
| Truncating | `take`, `first`, `takeWhile`, `takeUntil`, `skip`, `takeLast`, `last` | a count | none, but ends the stream | prefix relations, `~subscribed` when done | `Take.tla` |
| Timing | `debounceTime`, `throttleTime`, `delay`, `timeout`, `auditTime`, custom `cancelAfter` | `now`, deadlines, a pending value | `Tick`, `Fire` | quiet windows, deadlines as invariants | `DebounceTime.tla`, `CancelAfter.tla` |
| Flattening | `switchMap`, `mergeMap`, `concatMap`, `exhaustMap` | one record per inner | `InnerNext`, `InnerComplete`, `InnerError` | interleaving, cancellation, ordering | `Flatten.tla` |
| Combining | `combineLatest`, `zip`, `withLatestFrom`, `merge`, `concat`, `forkJoin`, `race` | a second source | the second source's actions | synchronisation, liveness | `CombineLatest.tla` |
| Multicasting | `share`, `shareReplay`, `connect` | one stream per subscription, a shared subject, a replay buffer | subscribe, unsubscribe per subscription | refCount, multicast, replay | `Share.tla` |
| Error handling | `retry`, `catchError`, `retryWhen`, `finalize` | an attempt counter, a resubscribable source, a fallback stream | resubscribe, switch to the fallback | values concatenated, bounded attempts, which errors reach the subscriber | `Retry.tla`, `CatchError.tla` |

## Pointwise operators: the invariant is the operator

For `map`, `filter`, `scan` and `distinctUntilChanged`, the output is a
function of the input trace and nothing else. The whole specification of
each is one equation:

```tla
MapSpec(s)    == [i \in DOMAIN s |-> F(s[i])]      \* map(F)
FilterSpec(s) == SelectSeq(s, P)                   \* filter(P)

RECURSIVE ScanSpec(_)                              \* scan(Acc, Seed)
ScanSpec(s) ==
  IF s = <<>> THEN <<>>
  ELSE LET prev == ScanSpec(SubSeq(s, 1, Len(s) - 1))
           acc  == IF prev = <<>> THEN Seed ELSE Last(prev)
       IN  Append(prev, Acc(acc, Last(s)))

MapCorrect == mapOut = MapSpec(in)
```

`Pointwise.tla` drives all four from one source and checks, in every
reachable state, that the incremental computation in the action equals the
declarative definition over the whole trace. The termination half is pure
propagation: `outDone = inDone`.

What the checker adds here is modest. The equations are so direct that a
property-based test against real RxJS would do nearly as well, and part 06
recommends exactly that as the conformance check. Two things are still
worth having:

- **The termination contract comes for free.** `ObservableContract` holds
  for all four outputs, and `TerminalPassesThrough` says no pointwise
  operator ever completes early or late.
- **The state space is the source's.** 363 distinct states for three values
  and length four, regardless of how many pointwise operators are chained.
  This is the reason pipelines of synchronous operators stay cheap to check
  (part 05).

Other members: `tap` is `map` with `F = identity` plus a side effect that
the model ignores; `startWith(x)` is `out = <<x>> \o in`; `pairwise` is
`out[i] = <<in[i], in[i+1]>>`; `withLatestFrom(b$)` is pointwise on `in`
with a read of `Last(b)`, which makes it a combining operator in disguise.

## Truncating operators: the operator ends the stream

`take(N)` adds a count and nothing else, but it introduces the one thing
pointwise operators never do: it terminates the output itself and must
therefore stop listening. The characteristic invariants are prefix
relations plus a statement about the upstream link:

```tla
AtMostN              == Len(out) <= N
OutIsPrefixOfIn      == IsPrefix(out, in)
CompletesAtN         == Len(out) = N => outDone = "complete"
UnsubscribedWhenDone == Terminal(outDone) => ~subscribed
NoDeliveryAfterUnsubscribe == [][~subscribed => UNCHANGED in]_vars
```

The last one is an action property: it says the source delivers nothing
once `take` has let go. Part 01 shows what TLC reports when the guard that
enforces it is missing.

Variants, as changes to `Take.tla`:

| Operator | Change |
|---|---|
| `first()` | `N = 1`, and `SourceEnd("complete")` with `out = <<>>` becomes an error (`EmptyError`) |
| `takeWhile(P)` | `SourceNext(v)` completes when `~P(v)` instead of counting, and does not forward `v` (unless `inclusive`) |
| `takeUntil(n$)` | a second source whose first `Next` completes `out`; `CancelAfter.tla` is this with `n$ = timer(D)` |
| `skip(N)` | forwards only when `Len(in) > N`; `out = SubSeq(in, N + 1, Len(in))` is the invariant |
| `takeLast(N)` | forwards nothing until `inDone = "complete"`, then `out = SubSeq(in, Len(in) - N + 1, Len(in))` |
| `last()` | `takeLast(1)` plus the empty-source error |

## Timing operators: time becomes a variable

TLA+ has no clock. `debounceTime` and `cancelAfter` add `now` and an action
`Tick` that advances it by one frame, with deadlines stored in ordinary
variables. Part 04 is about this family; the summary is that timing
requirements turn into invariants over `now`:

```tla
\* debounceTime: an output at frame t carries the last input, which arrived at t - D
Debounced(e) == /\ e.n \in DOMAIN in
                /\ in[e.n].v = e.v
                /\ in[e.n].t = e.t - D

\* cancelAfter: nothing after frame D, and time cannot pass D while active
NoEmitAfterDeadline  == \A k \in DOMAIN out : out[k].t <= D
TerminatedByDeadline == now > D => Terminal(outDone)
```

Sketches for the rest of the family, as deltas on `DebounceTime.tla`:

| Operator | Timer rule | Characteristic invariant |
|---|---|---|
| `throttleTime(D)` (leading) | emit immediately, then ignore inputs until `now >= lastEmit + D` | consecutive outputs are at least `D` frames apart |
| `auditTime(D)` | first input starts a timer; on `Fire` emit the *latest* input | each output's value is the last input in its window |
| `delay(D)` | each input gets its own deadline `t + D`; `Fire` emits the earliest due | `out[k].t = in[k].t + D` and `out` is `in` shifted |
| `timeout(D)` | a deadline that each input pushes to `now + D`; if `Tick` reaches it, error | `outDone = "error"` iff some gap in `in` exceeded `D` |
| `sampleTime(D)` | `Tick` fires every `D` frames and emits the latest unseen input | at most one output per window |

The cost of this family is the state space: every frame multiplies it.
`CancelAfter` with `D = 5` and seven frames reaches 33 863 distinct states,
the largest in this repository, from a machine with five actions.

## Flattening operators: where TLA+ pays for itself

`switchMap`, `mergeMap`, `concatMap` and `exhaustMap` share everything
except one decision: what to do with a new inner Observable while an older
one is still live. `Flatten.tla` makes that decision a constant and puts it
in a single `CASE`:

```tla
OuterNext ==
  /\ subscribed /\ outerDone = "active" /\ Len(inner) < MaxOuter
  /\ inner' =
       CASE Strategy = "switch"  -> Append(SetState(inner, Active, "cancelled"), Rec("active", 0))
         [] Strategy = "merge"   -> Append(inner, Rec("active", 0))
         [] Strategy = "concat"  -> Append(inner, Rec(IF Live = {} THEN "active" ELSE "pending", 0))
         [] Strategy = "exhaust" -> Append(inner, Rec(IF Active = {} THEN "active" ELSE "dropped", 0))
  /\ UNCHANGED <<outerDone, out, outDone, subscribed>>
```

Each inner is a record `[state, sent]` whose state moves through
`pending → active → done`, or ends in `cancelled`, `dropped` or `errored`.
Inner values are delivered by a separate action `InnerNext(k)`, so TLC
interleaves outer values, inner values and inner completions in every
order. That is what a marble test cannot do: it fixes one interleaving.

Seven invariants separate the strategies. The matrix below was produced by
running every strategy against every invariant with TLC; the four strategy
configs in `specs/` check exactly the cells marked as holding.

| Invariant | Says | switch | merge | concat | exhaust |
|---|---|---|---|---|---|
| `AtMostOneActive` | at most one inner is subscribed at a time | holds | fails | holds | holds |
| `NoInterleaving` | outputs are grouped by inner, in outer order | holds | fails | holds | holds |
| `NewestOnly` | only the most recent inner can be running | holds | fails | fails | fails |
| `InOrder` | finished before the active one, queued after it | fails | fails | holds | fails |
| `NoCancellation` | no inner is cancelled unless the stream errors | fails | holds | holds | holds |
| `NoDrop` | no inner is ignored | holds | holds | holds | fails |
| `NothingLost` | on completion every started inner delivered everything | fails | holds | holds | fails |

Read down a column and you have the operator's documentation as a set of
checked facts: `switchMap` keeps only the newest inner and therefore loses
values; `mergeMap` loses nothing and interleaves everything; `concatMap`
loses nothing and preserves order by queueing; `exhaustMap` preserves order
by dropping.

Five more hold for all four and describe the shared machinery:
`PerInnerOrder` (each inner's values arrive in order, without gaps),
`NotCompleteWhileLive`, `ErrorTearsDown`, `DroppedNeverDeliver`, and the
action property `OnlyActiveInnersDeliver`.

Two configurations show the checker finding real bugs:

**`Flatten_bug_mergeForSwitch.cfg`** runs the `merge` strategy against
`switchMap`'s `NoInterleaving`. This is the classic live-search bug: a
developer wrote `mergeMap` where `switchMap` was needed, and a slow earlier
request overwrites the result of a newer one. TLC's counterexample:

```
State 2: OuterNext        inner = <<active>>
State 3: OuterNext        inner = <<active, active>>
State 4: OuterComplete
State 5: InnerNext(2)     out = <<<<2,1>>>>
State 6: InnerNext(1)     out = <<<<2,1>>, <<1,1>>>>     <- Invariant NoInterleaving is violated
```

In marble form, with `-` as any step:

```
outer     1-2|
inner 1   ----x---        (x = <<1,1>>, stale)
inner 2   ---y----        (y = <<2,1>>)
expected  ---y|           switchMap
actual    ---yx|          mergeMap
```

**`Flatten_stall_concat.cfg`** checks `concatMap` under a weaker fairness
assumption, `SpecInnerMayHang`, which lets an inner deliver all its values
and then never complete. The liveness property "every queued inner
eventually runs" fails, and the counterexample ends in a stutter:

```
State 2: OuterNext        inner 1 active
State 3: InnerNext(1)     out = <<<<1,1>>>>
State 4: OuterNext        inner 2 pending
State 5: OuterComplete
State 6: Stuttering       <- inner 2 waits forever
```

This is `concatMap(() => http.get(...))` where the inner Observable never
completes. The same spec with `Strategy = "merge"` passes, because
`mergeMap` has no queue.

Modelling choices worth knowing:

- Every inner delivers exactly `MaxInner` values. That makes `NothingLost`
  a sharp claim and keeps the state space small. A model where inners may
  complete early is a one-line change to `InnerComplete`.
- `mergeMap(project, concurrent)` is `merge` with a `pending` state entered
  when `Cardinality(Active) = concurrent`; the `concat` branch is the case
  `concurrent = 1`.
- Synchronous inners such as `of(x)` are covered: an `InnerNext` step may
  follow an `OuterNext` step immediately, which is the same trace.

## Combining operators: two sources and the liveness question

`combineLatest([a$, b$])` has two input streams, so its `Next` is the
disjunction of both sources' actions and TLC explores every interleaving of
their notifications. The safety invariants are straightforward:

```tla
EmitsOnlyWhenBothSeen == out /= <<>> => (a /= <<>> /\ b /= <<>>)
LatestPair == (a /= <<>> /\ b /= <<>>) => (out /= <<>> /\ Last(out) = <<Last(a), Last(b)>>)
CompletesOnlyWhenBothComplete == outDone = "complete" => (aDone = "complete" /\ bDone = "complete")
ErrorIfEither == (aDone = "error" \/ bDone = "error") => outDone = "error"
```

The family's real content is liveness. `CombineLatest.tla` has two
specifications that differ only in fairness:

```tla
SpecFair  == Init /\ [][Next]_vars /\ WF_vars(AStep) /\ WF_vars(BStep)   \* both sources progress
SpecFairA == Init /\ [][Next]_vars /\ WF_vars(AStep)                     \* only A does
```

| Config | Spec | Property | Result | Counterexample |
|---|---|---|---|---|
| `CombineLatest.cfg` | `SpecFair` | `<>Terminal(outDone)` | holds | |
| `CombineLatest_SilentB.cfg` | `SpecFairA` | `<>Terminal(outDone)` | fails | A emits twice and completes; B emits twice; then nothing, forever |
| `CombineLatest_EmptySource.cfg` | `SpecFair` | `<>(out /= <<>>)` | fails | B emits, then errors before A ever delivered |

The second row is "the pipeline hangs": nothing is wrong with the operator;
the property depends on an assumption about a source the operator cannot
enforce. The third row says that even fair sources do not guarantee an
emission, because a source may end before the pair forms. Both are facts a
developer discovers in production, and here they are three-line configs.

Sketches for the rest of the family:

| Operator | Emits when | Completes when | Liveness hazard |
|---|---|---|---|
| `zip` | both have an unpaired value; outputs `<<a[k], b[k]>>` | either completes and its buffer cannot be paired again | a fast source's buffer grows without bound: `Len(a) - Len(b)` is unbounded, a model-bound violation |
| `withLatestFrom(b$)` | `a` delivers and `b /= <<>>` | `a` completes | silent until `b` has delivered |
| `forkJoin` | never, until all complete; then `<<Last(a), Last(b)>>` once | all complete | hangs on any source that never completes; emits nothing if any source completed empty |
| `merge` | either delivers | both complete | none |
| `concat` | `a` delivers, or `b` delivers after `aDone = "complete"` | `b` completes | `b` never starts if `a` never completes |
| `race` | the first source to deliver wins; the other is unsubscribed | the winner completes | none |

## Multicasting: many subscriptions, one source

`share()` is the one operator whose state machine cannot be captured by one
`in`/`out` pair, because it has one input and several outputs that start and
stop independently of each other and of the source. RxJS 7 implements
`share()`, `shareReplay(n)` and `shareReplay({refCount: true})` as a single
operator, `share(config)`, and `Share.tla` does the same: the constants are
the configuration.

| RxJS | `BufferSize` | `ResetOnComplete` | `ResetOnError` | `ResetOnRefCountZero` |
|---|---|---|---|---|
| `share()` | 0 | TRUE | TRUE | TRUE |
| `shareReplay(1)` | 1 | FALSE | TRUE | FALSE |
| `shareReplay({bufferSize: 1, refCount: true})` | 1 | FALSE | TRUE | TRUE |

The variables follow the implementation's own state. One stream per
subscription replaces the single `out`:

```tla
VARIABLES sub,          \* [Subs -> {"idle", "on", "complete", "error", "off"}]
          received,     \* [Subs -> Seq(Values)]: each subscription's stream
          conn,         \* [Subs -> Nat]: which connection it joined
          subject,      \* "none" | "live" | "complete" | "error": the shared Subject
          buffer,       \* the ReplaySubject's buffer; always empty for share()
          srcSent,      \* what the current connection has delivered
          connections   \* how many times the source has been subscribed

RefCount == Cardinality({s \in Subs : sub[s] = "on"})
```

Four actions: `Subscribe(s)` creates the subject and connects the source if
there is none, then replays the buffer to the newcomer; `Unsubscribe(s)`
resets and disconnects if the newcomer was the last and the configuration
says so; `SourceNext(v)` appends to the buffer and to every `"on"`
subscription in the same step; `SourceEnd(how)` terminates every `"on"`
subscription and either resets the subject or leaves it in its terminal
state. A reset is `subject' = "none"`, after which the next subscription
starts a new connection. The model is safety-only: the interesting content
of this family is which interleavings are allowed, not progress.

The invariants that hold for all three configurations are the multicast
guarantees:

| Invariant | Says |
|---|---|
| `OnMeansLive` | a subscription receives only while the shared source is live |
| `NoGaps` | each subscription's stream is a contiguous window of its connection's values |
| `InSyncAtTail` | every current subscription has seen everything up to the latest value |
| `BufferIsRecent` | the buffer is the last `BufferSize` values of the connection |
| `ReplayCoversBuffer` | a subscription receives at least the last `BufferSize` values, however late it joined |
| `MulticastStep` (action) | a source value reaches every current subscription in the same step |
| `NoDeliveryAfterEnd` (action) | nothing reaches a subscription that has ended or left |
| `PerSubscriberContract` (action) | every subscription's stream respects the Observable contract |

Two properties separate the configurations, and both correspond to
behaviour that RxJS users regularly get wrong:

| Property | Says | `share()` | `shareReplay(1)` | `shareReplay({refCount: true})` |
|---|---|---|---|---|
| `SourceStopsWhenUnused` | the source never runs with nobody subscribed | holds | fails | holds |
| `CompletedStays` | once completed, the source is never subscribed again | trivial (a completed subject is reset) | holds | holds |
| `SingleExecution` | the source is subscribed at most once | fails | fails | fails |

**`Share_leak_demo.cfg`** checks `shareReplay(1)` against
`SourceStopsWhenUnused`. The counterexample is two steps long:

```
State 2: Subscribe(s1)     subject = "live"   RefCount = 1   connections = 1
State 3: Unsubscribe(s1)   subject = "live"   RefCount = 0        <- SourceStopsWhenUnused violated
```

This is the documented `shareReplay` hazard: with the default
`refCount: false`, the source keeps running after the last subscriber
leaves, and the model lets `SourceNext` keep filling the buffer with
nobody listening. The same configuration with `ResetOnRefCountZero = TRUE`
passes.

**`Share_restart_demo.cfg`** checks `share()` against `SingleExecution`,
and the counterexample is the re-execution people are surprised by:

```
State 2: Subscribe(s1)     connections = 1
State 3: Unsubscribe(s1)   subject = "none"       (reset on refCount zero)
State 4: Subscribe(s2)     connections = 2        <- SingleExecution violated
```

A subscription that arrives after everyone has left, or after the source
has completed, gets a fresh execution of the source. `shareReplay` fails
the same invariant through its `ResetOnError` path, which is the retry
behaviour it has by design; with errors removed from the model it holds.

What was checked: three subscriptions, two values, three values per
connection and up to two connections. These are the largest models in the
repository (`shareReplay(1)` reaches 439 177 distinct states), because each
subscription's window into the stream is independent state. Both checkers
report identical counts.

Modelling choices worth knowing:

- Each subscription id subscribes once. A subscriber that resubscribes is
  a second id, which keeps the state space finite and the traces readable.
- Resets are immediate. RxJS also accepts a notifier Observable for a
  delayed reset (`resetOnRefCountZero: () => timer(…)`); modelling that
  needs the `Tick` machinery from part 04 and is the natural extension.
- `ReplaySubject`'s `windowTime` is not modelled; the buffer is bounded by
  count only.
- A source that completes synchronously on connection is covered: it is
  the trace where `SourceEnd` follows `Subscribe` immediately.

## Error handling: resubscription and recovery

`retry` and `catchError` both react to the source's error by subscribing
to something else: `retry` to the same source again, `catchError` to
whatever its selector returns. The modelling step they share is a source
that can be subscribed more than once, so a single `in`/`inDone` pair is
not enough: `Retry.tla` keeps the current attempt's values in `in` and the
values of all attempts in `all`; `CatchError.tla` keeps the source and the
fallback as two streams and a `phase` that says which one is subscribed.

**`Retry.tla`** covers `retry(n)`, `retry({count, resetOnSuccess})` and
`retry({count, delay})` through three constants. Its counter follows the
RxJS 7 implementation, which increments on every error and retries while
the old value was below `Count`, so `retry(n)` subscribes at most `n + 1`
times. The `delay` form reuses the `Tick` machinery of part 04: an error
puts the operator into a `"waiting"` state with a `resumeAt` frame, and a
`Resubscribe` action fires when the frame arrives.

| Invariant | Says |
|---|---|
| `ValuesConcatenated` (`out = all`) | the subscriber gets every value of every attempt, in order; nothing is hidden or replayed |
| `ErrorOnlyWhenExhausted` | the error is delivered only once `Count` retries have been used |
| `CounterTracksAttempts` | without `resetOnSuccess`, the counter is exactly the number of failed attempts |
| `SuccessResetsCounter` | with `resetOnSuccess`, any value in the current attempt clears it |
| `AttemptsBounded` | attempts never exceed `Count + 1` plus the number of values that could have reset the counter |
| `WaitingIsBounded`, `ImmediateWithoutDelay` | the gap between attempts is at most `Delay` frames, and absent when `Delay = 0` |
| `NoDeliveryWhileWaiting` (action) | between attempts the subscriber hears nothing |
| `WaitingEndsInResubscription` (liveness) | a delayed retry always happens, given fairness on `Tick` and `Resubscribe` only |

The demonstration `Retry_partial_demo.cfg` checks `retry(2)` against
"nothing was delivered when the final error arrives" and fails in four
steps:

```
State 2: SourceNext(a)   out = <<a>>   attempt = 1
State 3: SourceError     attempt = 2   soFar = 1      (retried, subscriber told nothing)
State 4: SourceError     attempt = 3   soFar = 2
State 5: SourceError     outDone = "error"            <- NoPartialResults violated: out = <<a>>
```

That is the fact newcomers find surprising: `retry` does not roll back. A
UI that renders values as they arrive shows the partial result of a failed
attempt, then the error. `ValuesConcatenated` states the same thing
positively.

**`CatchError.tla`** models the selector's result as a second source that
the environment controls, so one model covers `EMPTY`, `of(d)`,
`throwError(...)` and a selector that throws. The one selector it does not
cover is `catchError((e, caught) => caught)`, which resubscribes the source
and is therefore `retry(Infinity)`, bounded in `Retry.tla` by `MaxTotal`.

| Invariant | Says |
|---|---|
| `OutIsSourceThenFallback` (`out = in \o fb`) | the subscriber sees the source's values, then the fallback's |
| `NoSourceErrorDelivered` | an error can only come from the fallback |
| `FallbackOnlyAfterError`, `FallbackSilentBeforeError` | the fallback runs after the source has errored, never alongside it |
| `CompleteFromRunningStream` | completion comes from whichever stream was subscribed |
| `ErrorIsSwallowed` (action) | the step in which the source errors delivers nothing downstream |
| `NoReturnToSource` (action) | the selector runs at most once |

The demonstration `CatchError_fallbackError_demo.cfg` checks "the result
never errors" and fails in two steps: the source errors, then the fallback
errors. `catchError` is not a `try`/`catch` around the pipeline; it
replaces one stream with another, and the replacement can fail too. The
usual fix, `catchError(() => of(fallback))`, is the trace where the fallback
delivers and completes, which the passing configuration also covers.

Both operators cost little to check (a few hundred states; the delayed
retry 2 245). Their state spaces are small for the same reason as the
pointwise family: the only independent event is the source's next
notification. Where they earn a specification is in composition, which is
the next thing to write for this family:

- `retry` on a shared source: `share()` resets on error, so a retry
  resubscribes the shared connection and every other subscriber sees the
  new attempt. `Share.tla` with `ResetOnError = TRUE` already shows the
  reconnection; a combined model would show who receives what.
- `catchError` inside `switchMap` against outside it: inside, an inner
  error is replaced and the outer keeps running; outside, the first inner
  error ends the whole pipeline. The invariant that separates them is
  whether `outerDone` can still be `"active"` after an inner error.
- `retry(n), catchError(() => of(fallback))`: `n + 1` attempts, then a
  value and a completion, never an error. `NoSourceErrorDelivered` becomes
  an end-to-end property of the pair.

`retryWhen` is `retry` with the resubscription decided by a notifier
Observable rather than a count; `finalize(f)` is a side effect on any
terminal or unsubscribe step and has no observable property beyond "runs
exactly once", an action property on a counter.

## Choosing what to specify

A rule of thumb from these families: specify an operator in TLA+ when its
behaviour depends on the *order of independent events*. Timers, inner
Observables, second sources and other subscribers all create independent
events. Pointwise operators do not, and for them a property test against
the real implementation is the better tool. The specs in this repository
follow that rule: `Pointwise.tla` exists to show the pattern, `Flatten.tla`
and `CombineLatest.tla` exist to find bugs.
