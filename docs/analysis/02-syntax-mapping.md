# 02 · TLA+ syntax, mapped to RxJS and TypeScript

Every construct used in `specs/`, what it means, where it appears, and the
nearest thing in TypeScript or RxJS. The analogues are aids to reading, not
translations: TLA+ expressions are mathematical values, not computations,
and several rows say so where it matters.

## Module structure

| TLA+ | Meaning | TypeScript analogue |
|---|---|---|
| `---- MODULE Take ----` … `====` | module boundaries; the file name must match | a module file |
| `EXTENDS RxBase, Integers` | import every definition of those modules | `import * from` |
| `CONSTANTS Values, N, MaxLen` | parameters fixed per model run, given in the `.cfg` | generics plus config |
| `ASSUME N \in Nat /\ N >= 1` | a condition on the constants, checked once | a runtime assertion on config |
| `VARIABLES in, out, subscribed` | the state | fields of a state object |
| `vars == <<in, out, subscribed>>` | the tuple of all variables, used in `[Next]_vars` | none; a convention |
| `\* comment` and `(* comment *)` | comments | `//` and `/* */` |

## Logic

| TLA+ | ASCII | Meaning | TypeScript |
|---|---|---|---|
| ∧ | `/\` | and | `&&` |
| ∨ | `\/` | or | `\|\|` |
| ¬ | `~` | not | `!` |
| ⇒ | `=>` | implies | `!a \|\| b` |
| ≡ | `<=>` | if and only if | `===` on booleans |
| ∀ x ∈ S : P | `\A x \in S : P` | for all | `S.every(x => P)` |
| ∃ x ∈ S : P | `\E x \in S : P` | there exists | `S.some(x => P)` |
| `TRUE`, `FALSE`, `BOOLEAN` | | the booleans and their set | `true`, `false`, `boolean` |

A list of conjuncts written vertically with leading `/\` is the idiomatic
way to write an action. Indentation is significant inside such a list, which
is why every `/\` of one action lines up.

`\E v \in Values : SourceNext(v)` in `Next` is the one place where the
analogy with `some` breaks: it does not search for a `v`, it declares that
the machine may take the step for *any* `v`, and the checker explores all of
them.

## Sets

| TLA+ | Meaning | TypeScript |
|---|---|---|
| `{a, b}` | set literal | `new Set([a, b])` |
| `x \in S` | membership | `S.has(x)` |
| `S \subseteq T` | subset | |
| `S \cup T`, `S \cap T`, `S \ T` | union, intersection, difference | |
| `1..N` | the integers from 1 to N | `range(1, N + 1)` |
| `{x \in S : P(x)}` | filter | `[...S].filter(P)` |
| `{F(x) : x \in S}` | map | `[...S].map(F)` |
| `S \X T` | set of pairs | tuple type `[S, T]` |
| `SUBSET S` | the power set | |
| `Cardinality(S)` | size (needs `FiniteSets`) | `S.size` |
| `CHOOSE x \in S : P(x)` | some fixed element satisfying P | `find`, but deterministic and total |

`Values` is a set of model values in most configs (`Values = {a, b}`),
which means "two distinct things with no other properties". When the
operator needs arithmetic (`map(x => x * 2)`), the config uses numbers
instead (`Values = {0, 1, 2}`).

## Functions and records

TLA+ functions are total maps with an explicit domain. Sequences and records
are both special cases of functions.

| TLA+ | Meaning | TypeScript |
|---|---|---|
| `[x \in S \|-> e]` | the function mapping each `x` to `e` | `Object.fromEntries(S.map(x => [x, e]))` |
| `f[x]` | application | `f[x]` |
| `DOMAIN f` | the domain | `Object.keys(f)` |
| `[f EXCEPT ![k] = e]` | a copy of `f` with one entry changed | `{...f, [k]: e}` |
| `[f EXCEPT ![k].sent = @ + 1]` | nested update; `@` is the old value | `{...f, [k]: {...f[k], sent: f[k].sent + 1}}` |
| `[state \|-> "active", sent \|-> 0]` | a record | an object literal |
| `r.state` | field access | `r.state` |
| `[state : InnerState, sent : 0..MaxInner]` | the *set* of all records with those field types | an interface, read as a set |
| `[S -> T]` | the set of all functions from S to T | |

`Flatten` keeps one record per inner Observable in a sequence, and
`SetState(f, S, st)` builds a new sequence with the state of every member of
`S` changed. There is no mutation anywhere: `inner'` is a new value defined
in terms of `inner`.

## Sequences and tuples

| TLA+ | Meaning | TypeScript |
|---|---|---|
| `<<>>` | the empty sequence | `[]` |
| `<<a, b>>` | a sequence or tuple | `[a, b]` |
| `Seq(S)` | the set of all finite sequences over S | `S[]` as a type |
| `Len(s)` | length | `s.length` |
| `s[i]` | the i-th element, **1-based** | `s[i - 1]` |
| `Head(s)`, `Tail(s)` | first element, the rest | `s[0]`, `s.slice(1)` |
| `Append(s, x)` | add at the end | `[...s, x]` |
| `s \o t` | concatenation | `[...s, ...t]` |
| `SubSeq(s, m, n)` | elements m..n | `s.slice(m - 1, n)` |
| `SelectSeq(s, P)` | keep elements satisfying P | `s.filter(P)` |
| `Last(s)`, `Range(s)`, `IsPrefix(s, t)` | defined in `RxBase` | |

`SelectSeq(in, P)` is the whole specification of `filter`. `[i \in DOMAIN s
|-> F(s[i])]` is the whole specification of `map`. That these are one-liners
is the point of part 03.

A tuple `<<k, j>>` is a sequence of length two, so `out[i][1]` is the first
component of the i-th output. `Flatten` uses that to ask which inner a value
came from.

## Actions and primes

| TLA+ | Meaning | Analogue |
|---|---|---|
| `x'` | the value of `x` in the next state | the return value of a reducer |
| `x' = e` | the next value of `x` is `e` | `return {...state, x: e}` |
| `UNCHANGED x` | `x' = x` | leaving a field out of the spread |
| `UNCHANGED <<x, y>>` | both unchanged | |
| `[A]_v` | `A` or `v` unchanged (a stuttering step) | |
| `<<A>>_v` | `A` and `v` changed | |
| `ENABLED A` | some next state satisfies `A` | "the guard is true" |

An action is any formula containing primed variables. In TLA+ an action
does not *do* anything; it is a predicate on pairs of states that is true
for exactly the transitions it allows. The `scan`-style reading
`(state, event) => newState` is close enough for operators, with one
difference: every variable must be accounted for in every action. Forget
`UNCHANGED inDone` and the checker treats `inDone'` as free to take any
value, which produces baffling counterexamples. TLC reports it as an error
instead when it can.

## Temporal operators

| TLA+ | ASCII | Meaning | RxJS reading |
|---|---|---|---|
| □P | `[]P` | P holds in every state from now on | an invariant |
| ◇P | `<>P` | P holds in some state from now on | "eventually emits / completes" |
| □◇P | `[]<>P` | P holds again and again | "keeps emitting" |
| ◇□P | `<>[]P` | from some point on P always holds | "settles" |
| P ⇝ Q | `P ~> Q` | whenever P holds, Q holds later | `[](P => <>Q)`; "every request gets a response" |
| □[A]_v | `[][A]_v` | every step is an A step or a stutter | an action property, e.g. the Observable contract |
| WF_v(A) | `WF_vars(A)` | weak fairness: if A stays enabled, A eventually happens | "the scheduler will run a due timer" |
| SF_v(A) | `SF_vars(A)` | strong fairness: if A is enabled infinitely often, A eventually happens | |

`<>` is about order in the behaviour, not about duration. "Within 300 ms" is
not `<>`; it is an invariant over a `now` variable (part 04).

A specification is itself a temporal formula:

```tla
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)
```

"Start in `Init`; every step is a `Next` step or a stutter; do not stutter
forever while a `Next` step is possible." The last conjunct is what makes
"eventually" properties provable, and the choice of which actions to make
fair is the main design decision in any liveness argument (part 06).

## Definitions and control

| TLA+ | Meaning | TypeScript |
|---|---|---|
| `Name == expr` | a definition (macro-like, no evaluation order) | `const` or a function |
| `Name(x, y) == expr` | an operator with parameters | a function |
| `LET a == e1  b == e2 IN body` | local definitions | `const` inside a function |
| `IF c THEN a ELSE b` | conditional expression | `c ? a : b` |
| `CASE c1 -> a [] c2 -> b` | multi-way conditional; some case must match | `switch` without fallthrough |
| `RECURSIVE F(_)` then `F(s) == …` | declare before a recursive definition | a recursive function |
| `LAMBDA e : e[1] = k` | an anonymous operator passed as an argument | `e => e[0] === k` |
| `Op(_)` as a parameter | an operator-valued parameter | a function parameter |

`ScanSpec` and `DistinctSpec` in `Pointwise.tla` are recursive definitions
over the input trace. They state what `scan` and `distinctUntilChanged`
*mean*; the actions state how to compute them one value at a time; the
invariants `scanOut = ScanSpec(in)` say the two agree.

## The configuration file

TLC does not read constants or properties from the module. A `.cfg` file
next to it says what to check:

```
SPECIFICATION Spec            \* the temporal formula to check behaviours of
CONSTANTS
  Values = {a, b}             \* a and b become model values
  N      = 2
  Strategy = "switch"         \* a string constant
INVARIANTS                    \* state predicates, checked in every state
  AtMostN
  CompletesAtN
PROPERTIES                    \* temporal and action formulas
  ObservableContract
  Terminates
```

One module can have several configurations. `Flatten.tla` has six: one per
strategy, one that checks `mergeMap` against `switchMap`'s invariants, and
one that drops fairness to show a stall. The module is the machine; the
config is the question asked of it.

## Things with no RxJS analogue, and the other way round

**No analogue in RxJS:** `\A` and `\E` over a whole set of values at once;
the primed variable; fairness. These are what a specification has that a
test does not.

**No analogue in TLA+:** time, callbacks, closures, mutable subscriptions,
the microtask queue. Each of these has to be modelled explicitly. Part 04
covers time; part 06 covers scheduler fidelity.
