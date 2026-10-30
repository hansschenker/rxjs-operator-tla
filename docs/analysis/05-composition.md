# 05 · Composing operators into pipelines

The reason TLA+ can check a whole `pipe(...)` and not just one operator is
that operator specifications compose the same way the operators do: the
output stream of one stage is the input stream of the next. This part shows
the composition rule, works through `filter → take`, and explains why
synchronous and asynchronous stages compose differently.

## 1. The rule

An operator spec has an `in` pair and an `out` pair. To chain two, rename
the first stage's `out` to the second stage's `in`:

```
source ──► [ filter ] ──► [ take ] ──► subscriber
   src         mid           out
```

`Pipeline.tla` has three stream pairs, `src`/`srcDone`, `mid`/`midDone`,
`out`/`outDone`, and one `subscribed` flag for the upstream link. Each
stage's invariant is stated over its own pair, and a new, end-to-end
invariant is stated over the ends:

```tla
FilterCorrect == mid = SelectSeq(src, P)                      \* stage 1
TakeCorrect   == IsPrefix(out, mid) /\ Len(out) <= N          \* stage 2
EndToEnd      == IsPrefix(out, SelectSeq(src, P)) /\ Len(out) <= N   \* the pipeline
```

`EndToEnd` is what a user of the pipeline relies on, and it is not merely
the conjunction of the two stage properties: it also needs the fact that
`mid` is what `take` saw, which is only true if the stages are wired
correctly. The checker verifies that wiring.

## 2. Synchronous stages fuse into one action

`filter` and `take` are both synchronous: each reacts inside the `next`
call that delivered the value. So in the composed machine a single source
delivery runs the whole chain in one step:

```tla
SourceNext(v) ==
  /\ subscribed /\ srcDone = "active" /\ Len(src) < MaxLen
  /\ src' = Append(src, v)
  /\ IF P(v)
       THEN /\ mid' = Append(mid, v)                   \* filter lets it through
            /\ out' = Append(out, v)                   \* take forwards it
            /\ IF Len(out') = N                        \* ... and may finish
                 THEN outDone' = "complete" /\ subscribed' = FALSE
                 ELSE UNCHANGED <<outDone, subscribed>>
       ELSE UNCHANGED <<mid, out, outDone, subscribed>> \* filter swallows it
  /\ UNCHANGED <<srcDone, midDone>>
```

Three things are visible in this one action that a per-operator view
hides:

- **Unsubscription travels the whole chain in one step.** When `take`
  completes, `subscribed' = FALSE` stops the source. The intermediate
  `filter` is never told to complete; it is unsubscribed. The invariant
  `MiddleNeverCompletedEarly` states that: when `out` has completed but the
  source has not, `midDone` is still `"active"`.
- **The state space does not grow.** `Pipeline` with four values and
  length five has 1 159 distinct states, about the same as `Take` would
  have with the same bounds. Adding synchronous stages adds variables but
  not interleavings, because there is still exactly one action per source
  event.
- **The composed terminal behaviour is explicit.** `SourceEnd(how)` sets
  all three `Done` variables at once, because a terminal notification
  passes through synchronous stages without delay.

## 3. Asynchronous boundaries multiply interleavings

An operator that reacts later, on a timer or on an inner Observable's
notification, cannot fuse into the source's action. It contributes actions
of its own, and the checker interleaves them with everything else. That is
the difference between `pipe(filter, take)` and `pipe(debounceTime, take)`:

| Pipeline | Actions in the composed machine | Why |
|---|---|---|
| `filter(P), take(N)` | `SourceNext`, `SourceEnd` | both stages react in the source's step |
| `debounceTime(D), take(N)` | `Tick`, `SourceNext`, `Fire`, `SourceEnd` | `take` reacts inside `Fire`, which is a separate step |
| `switchMap(f), concatMap(g)` | outer actions, inner-of-`switchMap` actions, inner-of-`concatMap` actions | two asynchronous boundaries |

So the cost of checking a pipeline is set by the number of asynchronous
boundaries in it, not by the number of operators. A pipeline of eight
pointwise operators and one `switchMap` costs roughly what `switchMap`
costs on its own.

This also says which end-to-end properties are worth checking. In a
synchronous pipeline, `EndToEnd` follows from the stage properties plus the
wiring, and the wiring is simple. Across an asynchronous boundary, new
properties appear that no single stage has:

- `debounceTime(D), take(1)`: the single output is the last of a burst, and
  the source is unsubscribed at the frame it fires, not at the frame of the
  last input.
- `switchMap(search), concatMap(save)`: at most one search in flight, saves
  serialised, and a cancelled search never leads to a save. The last one is
  a property *between* the two stages.
- `timeout(T), retry(n)`: the total time before the final error is at most
  `(n + 1) · T` frames, an invariant over `now` that spans both stages.

## 4. Order matters, and the checker can prove it

`pipe(filter(P), take(N))` and `pipe(take(N), filter(P))` are different
pipelines with different invariants:

```tla
\* filter then take: the first N values that pass
EndToEnd_FT == IsPrefix(out, SelectSeq(src, P)) /\ Len(out) <= N

\* take then filter: those of the first N values that pass
EndToEnd_TF == out = SelectSeq(SubSeq(src, 1, N), P)   \* once Len(src) >= N
```

An instructive exercise is to put both pipelines in one module, driven by
the same source, and ask TLC to check `outFT = outTF`. It is false, and the
counterexample is the shortest source on which the two differ: with
`P = even` and `N = 2`, the source `1, 2` gives `<<2>>` for one and the
pipeline still waiting for the other. That trace is also the regression
test that documents why the order was chosen.

## 5. How this generalises

`Pipeline.tla` is written by hand. For the general case there are two
routes, and TLA+ supports both.

**Shared-variable composition.** Write each operator as a module whose
actions mention its own stream variables, then write the pipeline module
that declares all the streams and conjoins or disjoins the stage actions.
Synchronous stages are *conjoined* in one action (they step together);
asynchronous ones are *disjoined* in `Next` (they step independently).
That is exactly what `Pipeline.tla` does inline, and it is how a
`pipe(...)`-to-TLA+ translator would work: one action per source event,
containing the conjunction of every synchronous stage's reaction, plus
one additional action per timer and per inner event.

**Module instantiation.** TLA+'s `INSTANCE ... WITH` renames a module's
variables, so stage modules can be reused:

```tla
\* sketch, not checked in this repository
VARIABLES src, srcDone, mid, midDone, out, outDone, subscribed
Stage1 == INSTANCE Filter WITH in <- src, inDone <- srcDone, out <- mid, outDone <- midDone
Stage2 == INSTANCE Take   WITH in <- mid, inDone <- midDone, out <- out, outDone <- outDone
```

The difficulty is the joint step: `Stage1!SourceNext(v) /\ Stage2!SourceNext(v)`
only works if each module's action leaves the other's variables free, which
means the per-operator modules must be written without `UNCHANGED` on
variables they do not own. It is doable but changes the style of every
operator module, so the hand-written form is the better starting point.

## 6. What a translator needs from each operator

To turn `source.pipe(op1, op2, ...)` into a composed spec automatically, each
operator module has to export:

| Export | Example from `Take` | Used for |
|---|---|---|
| its private variables and their `Init` | none beyond the streams | declaring the pipeline's variables |
| a synchronous reaction `OnNext(v)`, `OnEnd(how)` as conjuncts over `in'`, `out'`, private state | the body of `SourceNext`, minus the guard | fusing into the upstream event's action |
| zero or more asynchronous actions | `Fire` for timers, `InnerNext(k)` for inners | adding to the pipeline's `Next` |
| which of its steps set `subscribed' = FALSE` | the `Len(out') = N` branch | propagating cancellation upstream |
| its stage invariants, parameterised by stream names | `IsPrefix(out, in)`, `Len(out) <= N` | the per-stage checks |
| fairness requirements on its own actions | `WF_vars(Fire)` | the pipeline's `Spec` |

With these, the per-operator specs in this repository become a library and
the pipeline spec is generated. The operator catalogue in part 03 is the
list of what still has to be written.

## 7. A two-boundary pipeline, checked

`SearchAndSave.tla` is the pipeline from section 3 with two asynchronous
boundaries:

```ts
terms$.pipe(switchMap(term => search(term)), concatMap(result => save(result)))
```

Each term starts a search that delivers `ResultsPerSearch` results and
completes; each result starts a save that delivers one acknowledgement and
completes; the subscriber receives the acknowledgements. Both stages take
their flattening strategy from a constant, so the same module checks the
intended pair and shows what every other choice breaks.

The composition rules of sections 2 and 3 are visible in the actions.
`SearchNext(k)` is one step in which a search delivers a result,
`switchMap` forwards it into `mid`, and `concatMap` starts a save for it:
the synchronous part of the chain fuses. Searches completing
(`SearchComplete`) and saves finishing (`SaveDone`) are separate actions,
and TLC interleaves them with each other and with new terms. The two
strategies live in two functions, `Start(f, strategy, rec)` and
`Finish(f, strategy, i)`, shared by both stages.

The properties come in three groups, and the third is the one no single
operator spec can state:

| Group | Invariants |
|---|---|
| stage 1 (`switchMap`) | at most one search in flight, and it is the newest; results of an older search never follow results of a newer one |
| stage 2 (`concatMap`) | saves run one at a time, in order; none is cancelled or dropped |
| across the boundary | one save per result; acknowledgements are a prefix of the results; `NoStaleSave`, the search ids in the acknowledgements never decrease; `EveryResultSaved`, on completion the acknowledgements equal the results |

Four demonstrations each change one strategy and check one invariant.
The first is the live-search bug from part 03 followed through to its
consequence two stages later:

```
SearchStrategy = "merge"
State 2: TermNext          search 1 active
State 3: TermNext          search 2 active (search 1 is not cancelled)
State 4: SearchNext(2)     mid = <<<<2,1>>>>            save <<2,1>> active
State 5: SearchNext(1)     mid = <<<<2,1>>, <<1,1>>>>   save <<1,1>> pending
State 6: SaveDone(1)       out = <<<<2,1>>>>
State 7: SaveDone(2)       out = <<<<2,1>>, <<1,1>>>>   <- NoStaleSave violated
```

The stale result of the first search is saved after, and therefore over,
the result of the second. The second demonstration is the one that
matters most in practice, `switchMap` used for the writes:

```
SaveStrategy = "switch"
State 4: SearchNext(2)     save <<2,1>> active
State 5: TermsComplete
State 6: SearchNext(2)     save <<2,1>> cancelled, save <<2,2>> active   <- NoLostSave violated
```

A write in flight is cancelled by the next result and never completes. The
remaining two show `mergeMap` letting two writes overlap and `exhaustMap`
dropping a result that arrives during a write.

To see the whole design space, every strategy pair was run against the
five save-side invariants with TLC (eighty runs):

| search \ save | `switch` | `merge` | `concat` | `exhaust` |
|---|---|---|---|---|
| `switch` | lost writes | overlapping, stale | **all hold** | dropped |
| `merge` | lost, stale | overlapping, stale | stale | dropped, stale |
| `concat` | lost writes | overlapping, stale | all hold | dropped |
| `exhaust` | lost writes | overlapping, stale | all hold | dropped |

Reading the columns: the save strategy alone decides whether writes are
lost (`switch`), overlap (`merge`) or are dropped (`exhaust`), and only
`concat` saves everything. Reading the rows: `merge` for the searches is
the only search strategy that produces stale saves, because it is the only
one that lets an older search deliver after a newer one has. `concat` and
`exhaust` for the searches also satisfy every save-side property, but they
are not a live search: part 03's matrix shows that they queue or drop
search terms, which is a stage-1 property this table does not show.

What this model leaves out, errors (a failing save, and whether `retry`
on the inner keeps the queue intact) and time (a bound on the wait from a
result to its acknowledgement), section 12 adds. Both are additions to
the actions; the properties above stay.

## 8. `retry` and `share`: the order decides who recovers

A second kind of composition is two operators whose order changes the
meaning for *other* subscribers. `RetryOnShare.tla` has a source, a
`share()`, several subscriptions, and a `retry(Count)` in one of two
places:

```ts
// Placement = "before": one retry for everybody
const shared$ = source$.pipe(retry(2), share());

// Placement = "after": a retry per subscription
const shared$ = source$.pipe(share());
const s1 = shared$.pipe(retry(2));
const s2 = shared$;
```

The module is `Share.tla` (one received stream per subscription, a shared
subject, a connection count) with `Retry.tla`'s counter added, once
upstream and once per subscription. Its one new idea is `EndStatus`: a
downstream `retry` that has received the error but still has retries left
is `"error"` as far as the shared stream is concerned and `"active"` as
far as its subscriber is concerned, and the Observable contract has to be
checked on the second view.

What holds in both placements is what `share` promises regardless: every
current subscription is in sync at the tail across retries
(`InSyncAtTail`), and every termination of the source causes at most one
re-execution however many subscriptions retry (`OneExecutionPerTermination`),
because the first retry to resubscribe recreates the subject and the
others join it.

What separates the placements:

| Property | `retry` before `share` | `retry` after `share` |
|---|---|---|
| a subscription without its own retry sees an error only after `Count` source errors (`SharedProtection`) | holds | fails |
| nobody sees an error until the retries are used up (`NoErrorBeforeExhaustion`) | holds | not applicable |
| a source error reaches every current subscription (`ErrorReachesEveryone`) | never happens | holds |
| a used-up retry has re-executed the source each time (`RetriesReexecute`) | not applicable | holds with `resetOnError`, fails without |

Two demonstrations:

```
RetryOnShare_after_demo.cfg      (retry after share, resetOnError: true)
State 2: Subscribe(s2)     s2 has no retry
State 3: SourceError       sub[s2] = "error"   srcErrors = 1      <- SharedProtection violated
```

A `retry` placed after `share` protects exactly one subscription. Anyone
else on the shared stream receives the first error, which is usually not
what the author of `shared$.pipe(retry(2))` had in mind.

```
RetryOnShare_noReset_demo.cfg    (retry after share({resetOnError: false}))
State 2: Subscribe(s1)     connections = 1
State 3: Subscribe(s2)
State 4: SourceError       subject = "error"  (not reset)
State 5: Retry(s1)         soFar[s1] = 1   sub[s1] = "error"   connections = 1
State 6: Retry(s1)         soFar[s1] = 2   sub[s1] = "error"   connections = 1   <- RetriesReexecute violated
```

With `resetOnError: false` the subject stays errored, so each
resubscription errors again at once. The two retries are used up in two
steps and the source never ran a second time. This is the configuration
to check whenever a downstream `retry` "does nothing": the fix is upstream,
in the `share` config, not in the `retry`.

The model omits `share`'s replay buffer and manual unsubscription, both
of which `Share.tla` covers on its own; adding them back is a matter of
copying the actions. Each placement is checked with two subscriptions, two
values, two values per execution and `Count = 2`, about 53 000 distinct
states.

## 9. `catchError` inside or outside a `switchMap`

The third placement question is the one every live-search tutorial gets
to eventually. `CatchInSwitchMap.tla` has terms, a `switchMap` that starts
a search per term, searches that may error, and a `catchError` in one of
two places:

```ts
// Placement = "inside": the failed search is replaced, the outer carries on
terms$.pipe(switchMap(t => search(t).pipe(catchError(() => fallback$))))

// Placement = "outside": the first failed search is an error for switchMap
terms$.pipe(switchMap(t => search(t)), catchError(() => fallback$))
```

The module is `Flatten.tla` with the `switch` strategy and inner errors,
plus `CatchError.tla`'s environment-controlled fallback. Inside, an inner
that errors moves to a `"recovering"` state in which its fallback delivers
values attributed to that search; it is still an inner, so a new term
cancels it like any other. Outside, an inner error is `switchMap`'s error:
it unsubscribes from the terms, and the outer `catchError` runs one
fallback whose termination is the output's termination.

What holds for both placements is `switchMap`'s own contract, with a
recovering fallback counted as live: at most one live inner, only the
newest, values grouped by search, and the subscriber's error only ever
coming from a fallback. What separates them:

| Property | inside | outside |
|---|---|---|
| every failed search is caught, and the terms stay subscribed (`OuterSurvivesInnerErrors`) | holds | fails |
| the output does not complete while the terms are active (`NotCompleteWhileTermsActive`) | holds | fails |
| at most one search ever errors (`AtMostOneInnerError`) | not applicable | holds |
| the first failed search unsubscribes from the terms (`FirstErrorEndsSwitchMap`) | never | holds |
| the fallback's termination is the output's (`OutputEndsWithFallback`) | not applicable | holds |

The outside placement is checked as a correct description of what the
code does, and the two demos are the same behaviour seen as the two
symptoms users report:

```
CatchInSwitchMap_bug_outsideStops.cfg
State 2: OuterNext        search 1 active
State 3: InnerError(1)    subscribed = FALSE   fallback = "active"   <- OuterSurvivesInnerErrors violated
```

"The search box stops responding after one failed request": the terms are
no longer subscribed, so later terms are never searched.

```
CatchInSwitchMap_bug_outsideCompletes.cfg
State 2: OuterNext
State 3: InnerError(1)
State 4: OuterFallbackEnd("complete")   outDone = "complete"   outerDone = "active"   <- NotCompleteWhileTermsActive violated
```

"My stream completed and I never completed anything": the fallback
completed, so `catchError`'s output completed, while the terms were still
going.

Two things the inside placement adds that are easy to miss. A new term
cancels a running fallback, because the fallback is part of the inner;
`NewestOnly` says so, and a slow fallback such as a retry-with-backoff
inside a search is therefore cancelled by typing. And an error in the
inside fallback is not caught by anything: `InnerFallbackError` tears the
pipeline down, which is `CatchError.tla`'s fallback-error demo again, one
level deeper.

The inside placement is checked with three terms, two results per search
and one fallback value, 12 014 distinct states; the outside placement,
which ends early, has 926.

## 10. `retry` then `catchError`, and the reverse

The last error-handling pair is the one whose order people get wrong by
accident. `RetryThenCatch.tla` has a resubscribable source, a retry
counter and an environment-controlled fallback, and an `Order` constant:

```ts
// Order = "retryFirst": the usual intent
source$.pipe(retry(2), catchError(() => fallback$))

// Order = "catchFirst": the common mistake
source$.pipe(catchError(() => fallback$), retry(2))
```

In the first order, `retry` sees the source's errors and `catchError`
sees only the one that escapes after the retries are used up. In the
second, `catchError` is upstream of `retry`, so `retry` only ever sees
errors that `catchError` lets through, which are the fallback's own.

| Property | `retry` then `catchError` | `catchError` then `retry` |
|---|---|---|
| the source is retried after each of its first `Count` errors (`SourceIsRetriedAfterError`) | holds | fails |
| the fallback runs at most once (`FallbackRunsAtMostOnce`) | holds | fails |
| the fallback runs only after the retries are used up (`FallbackOnlyAfterExhaustion`) | holds | fails |
| the fallback runs on every source error (`FallbackOnEveryError`) | fails | holds |
| the source is retried only when the fallback errors (`RetryOnlyOnFallbackError`) | fails | holds |
| the output is the source's values, then the fallback's (`OutIsSourceThenFallback`) | holds | fails: they interleave per attempt |
| a source error never reaches the subscriber (`SourceErrorNeverDelivered`) | holds | holds |

The last row is why the mistake goes unnoticed: in both orders the
subscriber never sees the source's error, so a test that only checks for
"no error" passes. The two demonstrations are the differences that tests
miss:

```
RetryThenCatch_bug_reversedNoRetry.cfg
State 2: SourceError        phase = "fallback"   attempts = 1   soFar = 0
State 3: FallbackNext(d)    out = <<d>>
State 4: FallbackComplete   outDone = "complete"                 <- FallbackCompletesOnlyAfterRetries violated
```

With `catchError` first and a fallback that completes, as `of(default)`
does, the first error ends the stream with the default value. The
`retry(2)` never ran, because nothing ever errored downstream of
`catchError`.

```
RetryThenCatch_bug_reversedRepeats.cfg
State 2: SourceError        fbRuns = 1
State 3: FallbackError      attempts = 2   (retry resubscribes source$.pipe(catchError))
State 4: SourceError        fbRuns = 2                            <- FallbackRunsAtMostOnce violated
```

With a fallback that rethrows, `retry` does resubscribe, but it
resubscribes the whole upstream, so the fallback runs again on the next
error. Anything the fallback does besides rethrowing, a toast, a log
line, a default written somewhere, happens once per attempt instead of
once.

Both orders are small models, 180 and 1 972 distinct states, and part 03's
remark about this family applies: the operators are cheap, the
compositions are where the specification earns its keep.

## 11. Curing the `forkJoin` hang, and what each cure costs

`ForkJoin_silentB_demo` in part 03 is a hang that no change to `forkJoin`
can fix, because it is a fact about a source. The fix is a guard on that
source, and there are three common ones. `ForkJoinGuarded.tla` puts the
guard between `b$` and `forkJoin` as a constant:

```ts
forkJoin([a$, b$])                                              // Guard = "none"
forkJoin([a$, b$.pipe(take(1))])                                // Guard = "take1"
forkJoin([a$, b$.pipe(takeUntil(timer(D)))])                    // Guard = "takeUntilTimer"
forkJoin([a$, b$.pipe(takeUntil(timer(D)), defaultIfEmpty(d))]) // Guard = "takeUntilTimerDefault"
```

What is wrong with `b$` is a fairness assumption, so the module has three
specifications that differ only in what `b$` is assumed to do, with the
guard's own machinery (time, the timer) always fair:

| Spec | `b$` is | RxJS example |
|---|---|---|
| `SpecSilentB` | never required to deliver or terminate | a `Subject` nobody calls |
| `SpecChattyB` | required to keep delivering, never to complete | `interval`, a websocket |
| `SpecFair` | well-behaved | an HTTP request |

Checked against `<>Terminal(outDone)` (does `forkJoin` end?) and the
invariant `BranchCompletesWithValue` (does the guard ever hand `forkJoin`
an empty branch, which makes it complete without a value?):

| Guard | silent `b$` | chatty `b$` | branch can end empty | value `forkJoin` gets from `b$` |
|---|---|---|---|---|
| none | hangs | hangs | only if `b$` completes empty itself | its last |
| `take(1)` | hangs | ends | only if `b$` completes empty itself | its first |
| `takeUntil(timer(D))` | ends | ends | yes, when the timer fires first | its last before `D`, or none |
| `takeUntil(timer(D)), defaultIfEmpty(d)` | ends | ends | never | its last before `D`, or `d` |

Each cell is one of the six configurations or follows from it. The two
demonstrations are the two cells people discover in production:

```
ForkJoinGuarded_take1_silent_demo.cfg     (take(1), SpecSilentB)
State 2: ANext(y)
State 3: AComplete
State 4: Stuttering        <- EventuallyTerminal violated: b$ never delivers, take(1) never fires
```

`take(1)` turns "must complete" into "must deliver once", which is a
weaker assumption but still an assumption about a source you do not
control. Against a `Subject` nobody calls, it hangs exactly as before.

```
ForkJoinGuarded_timer_empty_demo.cfg      (takeUntil(timer(2)), SpecSilentB)
State 2: ANext(x)
State 3: Tick
State 4: Tick
State 5: Fire              <- BranchCompletesWithValue violated: the branch completes empty
```

`takeUntil(timer(D))` makes the hang impossible, because its only
assumption is that time passes, but it can complete the branch with
nothing in it, and `forkJoin` then completes without a value. This is a
silent outcome, not an error, so a UI waiting for the joined value shows
nothing and reports nothing. `defaultIfEmpty` after the `takeUntil` is
what turns it back into a value, and the fourth configuration checks that
the branch then never completes empty on the guard's account.

The invariant is worded carefully: a branch that completes empty because
`b$` itself completed empty is not the guard's fault, and no guard can
supply a value for a source that had none. The first version of this
spec blamed `take(1)` for exactly that case, and the checker's trace, two
steps long, was the correction.

Everything here is `ForkJoin.tla` plus a layer for the guard (`bSeen`,
`bBranchDone`, `bSub`) and the `Tick` machinery of part 04. The timer
configurations have about 2 000 distinct states; the others under 400.

## 12. Saves that take time and can fail

Section 7 left two things out of `SearchAndSave`: a save takes no time,
and a save cannot fail. `SearchAndSaveTimed.tla` adds both, with the
strategies fixed at `switchMap` and `concatMap` and the handling of a
failed save as a constant:

```ts
terms$.pipe(switchMap(search), concatMap(r => save(r).pipe(h)))

h = identity                       // SaveFailure = "propagate"
h = retry(Count)                   // SaveFailure = "retryInner"
h = catchError(() => EMPTY)        // SaveFailure = "catchInner"
```

A save attempt takes between `SaveMin` and `SaveMax` frames, chosen by
the environment when the attempt starts, and may fail at any point while
running. Each save record carries the frame its result arrived, how many
saves were queued or running ahead of it at that moment, the frame its
current attempt is due, its attempt count, and the frame it was
acknowledged. Time is the `Tick` machinery of part 04: a due save must
finish or fail before the frame ends.

There is no liveness property in this module. "Every save is eventually
acknowledged" is stated the way part 04 recommends, as a deadline
invariant:

```tla
AckLatencyBounded == \A m \in DOMAIN save :
  save[m].state = "done" => Latency(m) <= (save[m].ahead + 1) * SaveMax * MaxAttempts
```

The wait from a result's arrival to its acknowledgement is at most the
number of saves ahead of it plus one, times the longest attempt, times
the attempts a save may take. That bound is tight, which the third
demonstration shows by dropping the last factor.

What holds for every handling: the invariants of section 7 that still
apply (one search at a time, saves serialised and in order, one save per
result, no stale save), the acknowledgements are exactly the done saves
in result order, a running save is never overdue, and the latency bound.
What separates the handlings:

| Property | `propagate` | `retry(Count)` | `catchError(() => EMPTY)` |
|---|---|---|---|
| a save is cancelled only after more than `Count` failures (`QueueSurvivesRetries`) | fails | holds | holds |
| on completion every result was acknowledged (`EveryResultAcked`) | holds | holds | fails |
| latency bound without the retry factor (`AckLatencyBoundedNoRetry`) | holds | fails | holds |

Three demonstrations, one per column:

```
SearchAndSaveTimed_bug_propagate.cfg
State 2: TermNext
State 3: SearchNext(1)    save <<1,1>> active, due at 1
State 4: SaveError(1)     outDone = "error"   save <<1,1>> cancelled   <- QueueSurvivesRetries violated
```

An unhandled error in a `concatMap` inner is an error of the whole
pipeline. The save in flight is cancelled, and so is everything queued
behind it. One failed write loses all the pending ones.

```
SearchAndSaveTimed_bug_catchSkips.cfg
State 4: SearchNext(1)    save <<1,1>> active
State 5: SearchComplete(1)
State 6: SaveError(1)     save <<1,1>> skipped   outDone = "complete"   out = <<>>   <- EveryResultAcked violated
```

Swallowing the error keeps the queue moving, and the pipeline completes
as if everything had been saved. Nothing downstream can tell that a write
is missing. `retry` is the handling that satisfies both of these
properties, and the one the main configuration checks.

```
SearchAndSaveTimed_bug_latency.cfg      (retry(1))
State 3: SearchNext(1)    save <<1,1>> active, arrived at 0, due at 1
State 4: Tick             now = 1
State 5: SaveError(1)     attempt 2, due at 3
State 6-7: Tick, Tick     now = 3
State 8: SaveDone(1)      acknowledged at 3: latency 3, bound without retries 2   <- violated
```

A retry costs up to another `SaveMax` frames, for the retried save and
for everything queued behind it. The bound that forgets this is false;
the one that multiplies by `Count + 1` holds.

The bounds are two terms, one result per search, attempts of one or two
frames, one retry and a horizon of eight frames, which is exactly the
worst case for the second queued save. Within those, the `retry`
configuration has 51 562 distinct states and the `catchError` one
24 522. The horizon is handled by letting the model stop at `MaxTime`
rather than by guarding the actions, so late saves are simply cut off,
which the latency invariant tolerates because it speaks only of saves
that were acknowledged.
