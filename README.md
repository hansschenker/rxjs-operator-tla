# RxJS operator behaviour in TLA+

How the syntax of TLA+ can describe what an RxJS operator does, and how the
TLA+ model checkers can then verify that description for every input stream
up to a chosen size. This repository holds the written analysis and a set of
runnable specifications that back it up.

The short version: an Observable is a state machine with a small protocol
(`next* (complete | error)?` plus unsubscription), an operator is a machine
that reacts to that protocol, and TLA+ is a language for writing such
machines as logic. Once an operator is written that way, TLC explores every
interleaving of source values, timers and inner Observables and reports the
first one that breaks a property, as a trace that reads like a marble diagram.

## Layout

| Path | Contents |
|---|---|
| [`docs/analysis/`](docs/analysis/) | The analysis, six parts. Start with part 01. |
| [`specs/`](specs/) | Runnable TLA+ modules, one per operator family, with TLC configs and a manifest of expected outcomes |
| [`scripts/check.mjs`](scripts/check.mjs) | Runs every manifest entry through tla-ts or TLC and compares with the expected result |
| `docs/Claude-RxJS and TLA+ verification-*.md` | The exported conversation this project grew out of |

## The analysis

1. [The Observable as a state machine](docs/analysis/01-observable-as-state-machine.md): the contract, the modelling pattern every spec uses, and a line-by-line reading of `take(N)`.
2. [TLA+ syntax, mapped to RxJS](docs/analysis/02-syntax-mapping.md): every construct the specs use, what it means, and its nearest TypeScript or RxJS analogue.
3. [Operator families and their invariants](docs/analysis/03-operator-families.md): pointwise, truncating, timing, flattening, combining, multicasting and error-handling operators, with the invariants that characterise each family, a checked matrix for the four flattening strategies, and a configuration matrix for `share` and `shareReplay`.
4. [Time and marble diagrams](docs/analysis/04-time-and-marbles.md): logical time as a `Tick` action, how it lines up with `TestScheduler` frames, and where the two differ.
5. [Composing operators into pipelines](docs/analysis/05-composition.md): why synchronous stages fuse into one action and asynchronous ones multiply interleavings, with `filter → take` as the worked example.
6. [Tooling, limits and workflow](docs/analysis/06-tooling-and-workflow.md): running TLC and tla-ts, reading the three kinds of counterexample, what was verified here, and what model checking cannot tell you about the real operator.

## Running the specs

```
npm install
npm run check          # tla-ts: pure Node, no Java needed
npm run check:tlc      # the official TLC: needs Java 11+ and tla2tools.jar
npm run check:trace    # tla-ts, and print the counterexample traces
```

`check:tlc` looks for `tla2tools.jar` in the VS Code TLA+ extension folder.
Set `TLA2TOOLS_JAR` to point elsewhere, and `JAVA` if `java` is not on the
PATH. Both commands exit non-zero when any outcome differs from
`specs/manifest.json`.

## What is checked

Thirty-one configurations. Nineteen are expected to pass; twelve are
deliberate demonstrations of bugs, hangs or documented hazards and are
expected to fail in a specific way. On 2026-10-30 both checkers agreed on
all thirty-one, with identical state counts on every passing run.

| Config | Operator | Expected | States (generated / distinct) |
|---|---|---|---|
| `Take.cfg` | `take(2)` | pass | 23 / 13 |
| `Pointwise.cfg` | `map`, `filter`, `scan`, `distinctUntilChanged` | pass | 605 / 363 |
| `Flatten_switch.cfg` | `switchMap` | pass | 677 / 381 |
| `Flatten_merge.cfg` | `mergeMap` | pass | 18 173 / 8 672 |
| `Flatten_concat.cfg` | `concatMap` | pass | 191 / 102 |
| `Flatten_exhaust.cfg` | `exhaustMap` | pass | 235 / 129 |
| `Flatten_bug_mergeForSwitch.cfg` | `mergeMap` checked as `switchMap` | invariant violation | stops at first violation |
| `Flatten_stall_concat.cfg` | `concatMap`, inner never completes | liveness violation | 71 / 39 |
| `DebounceTime.cfg` | `debounceTime(2)` | pass | 18 557 / 9 281 |
| `CancelAfter.cfg` | custom `cancelAfter(5)` | pass | 47 048 / 33 863 |
| `Pipeline.cfg` | `filter(P), take(2)` | pass | 1 997 / 1 159 |
| `CombineLatest.cfg` | `combineLatest([a$, b$])` | pass | 1 598 / 840 |
| `CombineLatest_SilentB.cfg` | one source never progresses | liveness violation | 1 598 / 840 |
| `CombineLatest_EmptySource.cfg` | a source ends before the pair forms | liveness violation | 1 598 / 840 |
| `Share.cfg` | `share()` | pass | 581 739 / 324 355 |
| `Share_replay.cfg` | `shareReplay(1)` | pass | 750 155 / 439 177 |
| `Share_replayRefCount.cfg` | `shareReplay({bufferSize: 1, refCount: true})` | pass | 288 884 / 161 967 |
| `Share_leak_demo.cfg` | `shareReplay(1)` keeps the source running with no subscribers | invariant violation | stops at first violation |
| `Share_restart_demo.cfg` | `share()` re-executes the source after a reset | invariant violation | stops at first violation |
| `Retry.cfg` | `retry(2)` | pass | 535 / 275 |
| `Retry_resetOnSuccess.cfg` | `retry({count: 1, resetOnSuccess: true})` | pass | 581 / 301 |
| `Retry_delay.cfg` | `retry({count: 2, delay: 2})` | pass | 4 625 / 2 245 |
| `Retry_partial_demo.cfg` | `retry(2)` delivers values of failed attempts | invariant violation | stops at first violation |
| `CatchError.cfg` | `catchError(selector)`, any fallback | pass | 345 / 210 |
| `CatchError_fallbackError_demo.cfg` | `catchError` does not catch the fallback's error | invariant violation | stops at first violation |
| `Zip.cfg` | `zip(a$, b$)` | pass | 2 921 / 1 405 |
| `Zip_buffer_demo.cfg` | `zip` buffers without bound | invariant violation | stops at first violation |
| `Zip_notLatest_demo.cfg` | `zip` pairs by position, not recency | invariant violation | stops at first violation |
| `ForkJoin.cfg` | `forkJoin(a$, b$)` | pass | 3 677 / 1 769 |
| `ForkJoin_silentB_demo.cfg` | a source never completes | liveness violation | 3 677 / 1 769 |
| `ForkJoin_emptySource_demo.cfg` | a source completes without a value | liveness violation | 3 677 / 1 769 |

## Status and caveats

- Every spec in `specs/` was model-checked with both TLC (version 2026.10.28) and tla-ts 0.0.3. Nothing in the analysis is a hand-checked claim about those specs.
- The specs describe the operators as documented and as implemented in RxJS 7. They are models: the gap between a model and the real operator is discussed in part 06, together with the property-test approach that closes it.
- Model bounds are small on purpose (two or three values, streams of length four or five, a few frames of time). Part 06 explains why that is enough for design bugs and where it is not.
