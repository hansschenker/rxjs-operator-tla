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

What the model leaves out, and what the next version would add: errors
(a failing save, and whether `retry` on the inner keeps the queue intact),
and a `Tick` so that the time between a result and its acknowledgement is
bounded. Both are additions to the actions; the properties stay.
