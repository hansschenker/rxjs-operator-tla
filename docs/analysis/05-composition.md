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
