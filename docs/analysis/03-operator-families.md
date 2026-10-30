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
| Multicasting | `share`, `shareReplay`, `connect` | a subscriber count, a connection | subscribe, unsubscribe per subscriber | refCount, replay | sketch only |
| Error handling | `catchError`, `retry`, `retryWhen`, `finalize` | an attempt count | resubscribe | bounded attempts, teardown | sketch only |

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

## Multicasting: many subscribers (sketch)

`share()` is the one operator whose state machine cannot be captured by one
`in`/`out` pair, because it has one input and several outputs that start and
stop independently. A specification needs:

```tla
CONSTANT Subscribers
VARIABLES in, inDone,                             \* the shared source, once connected
          subs,          \* [Subscribers -> {"off", "on", "complete", "error"}]
          outs,          \* [Subscribers -> Seq(Values)]
          connected,     \* BOOLEAN: is the source subscribed?
          refCount
```

with actions `Subscribe(s)`, `Unsubscribe(s)`, `SourceNext(v)` (delivered to
every `s` with `subs[s] = "on"`) and `SourceEnd(how)`. The properties that
matter are the ones that have had bugs in RxJS's history:

- `connected <=> refCount > 0` (the refCount rule), as an invariant;
- `SourceNext` is delivered to all current subscribers, not a subset;
- after `SourceEnd`, late subscribers get the terminal immediately
  (`resetOnComplete`), or a fresh connection, depending on configuration;
- a subscribe that arrives in the same step as the last unsubscribe does not
  reconnect (`resetOnRefCountZero` races).

`shareReplay(n)` adds a buffer and the invariant that a new subscriber
receives `SubSeq(in, Len(in) - n + 1, Len(in))` first. This family is the
most valuable next spec to write, because its bugs are exactly the
interleavings of subscribe and unsubscribe that TLC enumerates and tests
rarely cover.

## Error handling: resubscription (sketch)

`retry(n)` resubscribes to the source after an error, up to `n` times. The
source must therefore be modelled as something that can be subscribed to
repeatedly:

```tla
VARIABLES attempt,                \* 0..n
          in, inDone,             \* the current attempt's stream
          out, outDone
Resubscribe == /\ inDone = "error" /\ attempt < n
               /\ attempt' = attempt + 1 /\ in' = <<>> /\ inDone' = "active"
               /\ UNCHANGED <<out, outDone>>
```

Invariants: `attempt <= n`; `outDone = "error" => attempt = n`; values from
all attempts are concatenated in `out` (a `retry` does not undo delivered
values, which is the surprising part for newcomers). `catchError(f)` is
`SourceEnd("error")` followed by switching `in` to the fallback Observable,
which is the flattening machinery with one inner. `finalize(f)` is a
side-effect on any terminal or unsubscribe step and has no observable
property beyond "runs exactly once", an action property on a counter.

## Choosing what to specify

A rule of thumb from these families: specify an operator in TLA+ when its
behaviour depends on the *order of independent events*. Timers, inner
Observables, second sources and other subscribers all create independent
events. Pointwise operators do not, and for them a property test against
the real implementation is the better tool. The specs in this repository
follow that rule: `Pointwise.tla` exists to show the pattern, `Flatten.tla`
and `CombineLatest.tla` exist to find bugs.
