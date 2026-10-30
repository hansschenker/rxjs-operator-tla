# 04 · Time and marble diagrams

TLA+ has no notion of time. "Eventually" (`<>`) is about the order of states
in a behaviour, not about duration, and nothing in the logic measures
anything. RxJS, on the other hand, has `debounceTime`, `delay`, `timeout`
and a dozen other operators whose whole meaning is a duration. The gap is
closed the same way RxJS's own test scheduler closes it: with discrete
logical time.

## 1. Logical time: `now` and `Tick`

Lamport's recipe ("Real Time is Really Simple", 2005) is to make time a
variable and let a `Tick` action advance it. In the specs:

```tla
VARIABLE now                          \* the current frame

Tick == /\ now < MaxTime              \* model bound
        /\ ~TimerDue                  \* a due timer fires before time moves on
        /\ now' = now + 1
        /\ UNCHANGED <<everything else>>
```

A timer is a deadline stored in an ordinary variable, and firing it is an
action guarded by `now = deadline`:

```tla
TimerDue == pending /= None /\ now = deadline

Fire == /\ TimerDue
        /\ out'     = Append(out, OutEvent(pending))
        /\ pending' = None
        /\ UNCHANGED <<now, in, inDone, outDone, deadline>>
```

The guard `~TimerDue` on `Tick` is the one rule that makes this a model of a
scheduler rather than of a clock that might skip. A due timer always fires
in its frame. Forget the guard and TLC answers at once; for `CancelAfter`:

```
Error: Invariant TerminatedByDeadline is violated.
State 2: Tick   now = 1   outDone = "active"
...
State 7: Tick   now = 6   outDone = "active"      <- time ran past D = 5, the timer never fired
```

## 2. Marbles and actions line up

`TestScheduler` advances a virtual clock one frame at a time and runs the
work scheduled for each frame. That is exactly `Tick` plus the actions
between ticks, so the marble language maps onto the specs almost symbol for
symbol:

| Marble | Meaning | TLA+ |
|---|---|---|
| `-` | one frame passes | one `Tick` step |
| `a` | a value in this frame | `SourceNext(a)` (or `Fire`) in the current frame |
| `\|` | complete | `SourceEnd("complete")` / `SourceComplete` |
| `#` | error | `SourceEnd("error")` / `SourceError` |
| `(ab\|)` | several events in one frame | several actions between two `Tick` steps |
| `^` | subscription point | `Init` (`now = 0`) |
| `!` | unsubscription | `connected' = FALSE` / `subscribed' = FALSE` |
| `5ms` | five frames | five `Tick` steps |

A marble test and a TLA+ behaviour are the same kind of object: a sequence
of frames with events in them. The difference is quantity. The test gives
one such sequence; the spec's `Next` generates every sequence the model
bounds allow, and the checker visits them all.

Values in the time-based specs carry their frame so that invariants can
reason about intervals:

```tla
InEvent(v)  == [t |-> now, v |-> v]
OutEvent(v) == [t |-> now, v |-> v, n |-> Len(in)]
```

## 3. `debounceTime(D)` as a worked example

The operator: deliver a value only when the source has been quiet for `D`
frames after it. On complete, flush a pending value. On error, drop it.
`DebounceTime.tla` has five actions: `Tick`, `SourceNext(v)`, `Fire`,
`SourceComplete`, `SourceError`. The new input restarts the timer:

```tla
SourceNext(v) ==
  /\ inDone = "active" /\ Len(in) < MaxLen /\ now + D <= MaxTime
  /\ in'       = Append(in, InEvent(v))
  /\ pending'  = v
  /\ deadline' = now + D
  /\ UNCHANGED <<now, inDone, out, outDone>>
```

The property that captures "debounced" is per output event:

```tla
Debounced(e) == /\ e.n \in DOMAIN in          \* the input it carries exists
                /\ in[e.n].v = e.v            \* and is the last one received when it fired
                /\ in[e.n].t = e.t - D        \* and arrived exactly D frames earlier
```

That last conjunct is sharper than "no input in the last D frames": because
`e.n` is the last input received when the output fired, and the deadline is
always the last input's frame plus `D`, the equation pins down both the
value and the timing. Together with the flush case:

```tla
EveryOutputIsDebouncedOrFlushed == \A k \in DOMAIN out : Debounced(out[k]) \/ Flushed(out[k])
```

With `D = 2`, six frames and up to three inputs from `{a, b}`, TLC checks
9 281 distinct states and every marble diagram in that space satisfies the
property, including ones like these:

```
in    a-b---|        out   ---b--|      (b restarts the timer; a is never delivered)
in    a---|          out   --a-|        (a fires at frame 2)
in    a|             out   (a|)         (flush on complete)
in    a#             out   -#           (dropped on error)
```

## 4. Where TLC is stricter than `TestScheduler`

Two events in the same frame have no order in a marble diagram, but they do
have an order at runtime. `TestScheduler` fixes it: work scheduled for the
same frame runs in scheduling order. TLC does not fix it: all orders of the
actions between two ticks are explored.

`DebounceTime` shows the consequence. At the frame where a timer is due,
both `Fire` and `SourceNext(w)` are enabled. If the input comes first, the
timer restarts and the pending value is replaced. If `Fire` comes first,
the old value is delivered and `w` starts a new window. The real operator
under `TestScheduler` takes one of these paths, depending on which task was
scheduled first. The spec requires the property to hold on both.

This is why `OutEvent` carries `n`, the number of inputs received when the
output fired. Without it, an invariant written over frames alone cannot
tell "input, then fire" from "fire, then input" within one frame, and the
`Debounced` property would be false for a correct operator. Frame-level
time needs an event-level tie-breaker as soon as an operator can act and
receive in the same frame.

The practical reading: a property that holds in TLC holds under every
tie-break rule a scheduler might use. A marble test that passes shows the
operator is right for one of them.

## 5. Deadlines are safety, not liveness

A requirement such as "respond within D frames" sounds like an "eventually"
claim, but `<>P` cannot express a bound. With `now` it does not have to:

```tla
TerminatedByDeadline == now > D => Terminal(outDone)     \* CancelAfter
```

This is an ordinary invariant: it is checked in every state, it is cheap,
and a violation is a finite trace. It is also closer to what a marble test
asserts, which is "complete at frame 5", not "complete at some point". The
table from part 02 restated for timing:

| | `<>P` | `now > D => P` |
|---|---|---|
| kind | liveness | safety |
| needs fairness | yes | no (but `Tick` must not skip a due timer) |
| counterexample | a loop | a finite trace |
| RxJS analogue | waiting for `complete` | `timeout(D)`, `takeUntil(timer(D))` |

The liveness properties in the timing specs are the ones that cannot be
turned into deadlines, and they need fairness only on the operator's own
machinery, never on the source:

```tla
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Fire)

PendingResolves == (pending /= None) ~> (pending = None)      \* DebounceTime
Terminates      == <>Terminal(outDone)                        \* CancelAfter
```

"Time advances and due timers fire" is an assumption about the scheduler,
which is reasonable. "The source eventually completes" would be an
assumption about the user's data, which is not. `CancelAfter` exists
precisely to make `Terminates` true without the second assumption.

## 6. `cancelAfter(D)`: code, test and spec of one operator

The custom operator from the earlier session is `takeUntil(timer(D))`:

```ts
export const cancelAfter = <T>(ms: number, scheduler = asyncScheduler): MonoTypeOperatorFunction<T> =>
  source => source.pipe(takeUntil(timer(ms, scheduler)));
```

Its marble test:

```
source   a-b-c-d-e|
result   a-b-c|           subscription to source   ^----!
```

`CancelAfter.tla` is the same deadline stated over every run. The spec's
properties, each with the marble fact it generalises:

| Property | Kind | In the marble test |
|---|---|---|
| `NoEmitAfterDeadline` | invariant | nothing after frame 5 |
| `PassThrough` (`out = in`) | invariant | `a-b-c` arrives unchanged |
| `TerminatedByDeadline` | invariant | `\|` at frame 5 |
| `UnsubscribedWhenDone` | invariant | `!` at frame 5 |
| `ObservableContract` | action property | the contract |
| `NoDeliveryAfterUnsubscribe` | action property | `d` and `e` are never received |
| `Terminates` | liveness | the test ends |

Two observations from running it:

- At frame `D` exactly, a source value and the timer are both enabled. TLC
  checks both orders; `NoEmitAfterDeadline` uses `<=` so that a value in
  frame `D` delivered before the timer is allowed, which matches
  `takeUntil`.
- This is the largest model in the repository (33 863 distinct states) from
  a four-action machine, because every frame multiplies the number of
  possible input histories. The timing family is where model bounds need
  the most care.

## 7. Bounds and what they cost

Timing specs are checked with values like `D = 2`, `MaxTime = 6`,
`MaxLen = 3`. That is not a weakness: marble tests work the same way,
because what matters is the *order* of deadlines relative to events, not
their size. A `debounceTime(300)` bug that needs 300 frames to show does
not exist; the same bug shows at `D = 2`.

What the bounds do cost is coverage of long histories. A property that only
fails after four restarts of a timer needs `MaxLen >= 4`, and the state
count grows roughly with `|Values|^MaxLen · MaxTime`. When a model becomes
slow, the first things to shrink are `Values` (two values are almost always
enough; one is often enough for timing) and `MaxTime` (set it to the
smallest value that lets every deadline in the model expire).

## 8. Variable durations

One thing the spec can do that a marble diagram cannot: leave a duration
open. "The HTTP response arrives somewhere between one and three frames
later" is

```tla
deadline' \in now + 1 .. now + 3
```

and TLC checks every timing at once. A marble test has to fix the frame.
For operators whose correctness depends on the relative timing of two
unknown durations (a `switchMap` over requests of varying latency, a
`timeout` racing a slow source), this is the feature that finds the bug.
