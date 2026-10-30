# RxJS and TLA+ verification

**Created:** 10/30/2026 5:54:53  
**Updated:** 10/30/2026 6:38:37  
**Exported:** 10/30/2026 6:39:14  
**Link:** [https://claude.ai/chat/2d65c0a1-08f3-4da6-b817-4011018c13ed](https://claude.ai/chat/2d65c0a1-08f3-4da6-b817-4011018c13ed)  

## User:

> 10/30/2026 5:54:53

<Task>Task: Summarize the following content in 5-10 bullet points with timestamp if it's transcript.
Give me the list of Key terms with a short description.
what can we learn from this chat, what are the key takeaways</Task>

<ContentTitle>Title: "A Beginner's Guide to TLA+ Exploring State Machines \u0026 Proving Correctness | Jeff Weiss | Code BEAM V"</ContentTitle>
URL: "https://www.youtube.com/watch?v=H7yBYoY7ILc"
<Transcript>Transcript: "(00:09) hello thank you for joining me today i'm jeff weiss and i'll be talking about tla plus and using it to prove correctness of a sample problem my goal is to walk through the epiphanies that i had while watching a video series by leslie lamport who in addition to taylor tla plus gave us paxos and latex at prior code beams hillel wayne presented why you ought to look at tla plus and how you might use it this is not meant as a replacement for that talk or his text practical tla plus which i also recommend his presentation and the book (00:50) focus more on plus calc a subset of tla plus which has a more imperative syntax and compiles down to raw tla plus instead of looking at plus calc i will focus primarily on raw tla plus and here's why it's simply a state machine and more than any other language or run time that i've worked with state machines are far more prevalent in our ecosystem formerly with gen state or with gen fsm now with gen state m gen state machine and if you squint many gen server implementations look like state machines because state machines are part of our (01:38) vernacular is much is a much smaller transition to represent our problem as a state machine even if it is not implemented as one this brings me to a very important point tla plus does not test the code or the implementation it validates the model that you have created against the properties that you have specified to highlight this i'm going to take a sample well-tested package from hex build a tla model for it prove a handful of properties before i propose this talk i asked chris keithley if i could use his circular (02:17) buffer package for this demonstration and he kindly agreed so we'll move forward with it it's an ideal test case because its interface is relatively small the constraints can quickly be understood even if one has not previously been exposed to the concept of a circular or ring buffer which i will use interchangeably it's easily modeled as a state machine and most importantly chris already did the hard work of figuring out what properties are what the properties are and creating property-based tests for his implementation (02:54) for an introduction to the goal of a circular or ring buffer the intent is to have predictable asymptotic memory usage for a list or buffer where only the most recent item items are important so for instance some loggers will use a ring buffer on the back end assuming that only the most recent log entries are the important ones and that the oldest ones can be overwritten if they haven't been able to have been flushed to disk or to i o and when you add too many items the older ones are overwritten our properties are these (03:35) the number of elements is always less than or equal to the starting size the head element is always the oldest and eventually the buffer fills fortunately for highlighting different aspects of tla plus these properties consist of two classes invariance always less than or equal to the size always the oldest and temporal in that eventually it fills up let's dive in in our specification we declare the initial state function and next state functions because this syntax is likely new for folks i will run through it in more detail (04:17) what we have here our specification has two variables that we will use size to represent how big the buffer is and elements the buffer itself our init function is a combination of boolean expressions by convention we start each line with slash backslash for and interestingly we are not stating here that the size is a random value between one and n but rather all values between one and end this is a bit of a mental hurdle and i recommend starting with a mental model of a value between one and n elements simply begins its life as an empty (04:58) sequence i'll briefly jump to the next function and we'll tackle the constituent parts of add full and add novel afterwards this backslash e nonsense is stating that there exists a value v in our set of model values which we'll get to in a moment such that add not full is true or add full is true and here the backslash slash forming a v means or if neither of them are true the model checker will flag in an error that is equivalent to a no function head matching error okay drilling down what does add not fold do because this is a state function it (05:43) implicitly takes the existing variables of the state diagram size and elements and will turn return new or prime versions of those we will start with the equivalent of a guard clause that is that the size is strictly greater than the number of elements already in our buffer if that's true then we say that the elements prime is our original value with the candidate new item appended to it afterwards we're explicitly stating that the size is unchanged by this function because for each variable we must say what happened to happens to it during a (06:22) state transition function add full is very similar to add not full except our guard clause is that the size is equal to the number of elements in the buffer and rather than simply appending our new item to the elements list or sequence we append to the tail of that list dropping the prior head of the list here's our implementation along with some pseudo elixir code i'll pause for a moment for folks to get the idea and do the mental translation okay now it's time to create our first model and test it against this specification (07:17) the model checker automatically picks up our init and next state functions along with the specification of constants in for the largest possible value size and values the set of placeholders the checker ought to use the model checker is capable of checking an infinite set of values but since my talk is limited to around 20 minutes we don't have to we don't have that time and we have to constrain it to a reasonable set in this case we assign them labels v1 to v15 these are typeless model values not unlike any if you've (07:54) used proper we also declare that the maximum size is 5 because we can extrapolate that if these invariants hold for all sizes up to 5 they will continue to hold for larger sizes than 5 as well we also then add our invariant less than or equal to size running the model checker with these values takes about 10 seconds if we're more patient slash paranoid we could increase both the maximum size and the set of possible values to test when adding to our circular buffer we can also lower these values or sets for near instant feedback (08:35) here we see that the model checker explored 13 million states of which 871 thousand were distinct in 10 seconds the model checker examined 13 million orderings of our values v1 to 15 for buffer sizes up to 5 resulting in 871 000 unique orderings and are invariant held for each one okay our first and variance complete let's move to the second that the element at the head is the oldest previously our specification had no concept of age so we need to add it we could have attempted to make elements a sequence of tuples where (09:15) age is one and the model value is the other that's complexity we don't need in this demo so what we're going to do instead is keep a second sequence of just the ages that we'll operate on in the same way that we do the elements when we go to add a new element to our ring buffer we also add a new age of 0 and increment the age for all of the existing elements increment is a recursive function for a sequence if we have an empty sequence we return an empty sequence if we have at least one item in that sequence we increment the value at the (09:52) head and then recursively increment the remainder of the sequence once the buffer is full we discard discard the age at the beginning of the sequence just like we do for our buffer elements for our invariant any sequence of one length is by definition already ordered for larger sequences we state that all values i in the length of our sequence as we progress through our sequence the ages get progressively smaller when we run this model with our new invariant we see that it also passes though taking a bit more time (10:37) now for our temporal property eventually the buffer is full this is different than an invariant because it is not strictly true at each stage of the state machine but after at least size elements it does become true intuitively we can see that yes the buffer eventually fills but creating a specification for it is a little less straightforward using the two operators always with square brackets and eventually with angle brackets we can combine them in two ways always eventually and eventually always they're slightly different semantics (11:18) always eventually states that we must get to a full buffer but it might not stay full at any point after that eventually always states that it might take some time but once we fill we must stay full this gives us very rich ways to express our behavior as an aside it's possible that some ring buffers would allow you to remove elements and thus we may actually reach the case where the buffer is full at one point and then no longer full in the future however fortunately for me is the one specifying this and you as the audience listen to (11:58) me drone on about this this implementation simply grows to a fixed size making it far simpler for to specify that once it's full it stays full we will in fact add both versions of the temporal property to our specification however when we first attempt to add it our model fails when tla plus is checking the model by default it considers a valid next stage of the state machine to be that it stays where it is permanently staying at a step is called stuttering what this error is highlighting is that if we stay at our initial state (12:40) oh sorry if we stay at our initial state and never add an element our even if our initial buffer size is one that we will never be eventually full tla plus has a way for us to nudge processing and say some stuttering is fine but eventually we need to get some work done this is referred to as weak fairness as opposed to strong fairness which is the default so we add the weak fairness magical incantation to our specification we see our model now passes awesome we have a fully specified and check we have fully specified and (13:21) check the properties for this package i'll now do a brief demonstration of it running so it's not just screenshots and you can see that it does uh note that for brevity and the amount of time that will sit watching the screen i've reduced the set of model values and the maximum size of the buffer so here is our full implementation it's the same as what what you saw prior on a slide along with our model and so that's the results spoiler uh so we do have our two invariants and our temporal property and we have our (14:02) set of model values and our maximal length of four and when i run this model it does take a few seconds even with only up to four elements our number of states and distinct states is much smaller because we have a maximal buffer length of four instead of five uh however we see it does complete uh and this found 871 thousand states of which 58 000 were distinct but that two invariants held and the temporal property did help for hold for all of those as well if you have further interest in tla plus i recommend that you check out these (14:45) resources the first is leslie lamport's video series that i alluded to earlier the second is hillel wayne's book practical tl8 plus there is i believe in october a conference related to tla plus coming up the fourth item here is the google group for tla plus free to join and then the last item is leslie lamport's original paper around tla plus thank you for your time and thanks to chris for letting me use this package as an example if the track host has gathered questions i can attempt to answer them now thank you (15:23) well we have a question here with a tool like a proper or quick check we are testing our actual code assuming i model and verify something in tli blue class how can i check if my actual code follows that model yeah so um i didn't i didn't talk about this in the talk the intent of tla plus is for checking the design and seeing if the design meets what um what what you want and and the specific properties you can if you want take the model that you and specification that you have in tla plus and translate it to an analogous model (16:09) in proper and run your your actual code through there to to test um but but there certainly is no is no cohesion between the two um tla pluses are all around um testing your design rather than than your specific implementation and and i found that it is for me when when i want to do specification in tla plus it's far faster for me to synthesize the specification and the model within tla plus than it is to actually write the code um and then write the write the property based tests great [Music] verification and if yes uh could i (16:55) recommend some uh i have not um sorry so i i have some acquaintances um at uh galwa here in portland that that do many uh various kinds of formal verification and some folks at auxon who are doing related things for autonomous vehicles that's that are looking at tla plus and a couple other things but but i have not used them personally no sorry you"</Transcript>

## Assistant:

> 10/30/2026 5:55:18

> Deciding to keep the summary in chat.
>
> - Deciding to keep the summary in chat.
> - **Done**

# TLA+ for Beginners: State Machines and Proving Correctness (Jeff Weiss, Code BEAM V)

## Summary

- **(00:09) Intro and framing.** Weiss shares what clicked for him from Leslie Lamport's TLA+ video series. Hillel Wayne's earlier talk and book focus on PlusCal, an imperative layer that compiles to TLA+. Weiss works in raw TLA+ instead, because at its core TLA+ is just a state machine.
- **(00:50–01:38) Why state machines suit BEAM developers.** Erlang and Elixir developers already think in state machines (gen_fsm, gen_statem, and many GenServers). That makes modelling a problem as a state machine a small step, even if the real code isn't written as one.
- **(01:38) TLA+ checks the model, not the code.** It verifies that your design satisfies the properties you specify. It says nothing about whether your implementation matches that design.
- **(02:17–03:35) The example: Chris Keathley's circular buffer.** It has a small interface and existing property-based tests. A ring buffer keeps memory use bounded by overwriting the oldest items when it's full, which is useful for things like loggers. Three properties are checked:
  1. The number of elements never exceeds the size.
  2. The head element is always the oldest.
  3. The buffer eventually fills.

  The first two are invariants; the third is a temporal property.
- **(04:17–06:22) Writing the spec.**
  - The variables are `size` and `elements`.
  - `Init` sets `size` to *every* value in 1..N, not one random value, and `elements` to an empty sequence.
  - `Next` says: there exists a value `v` such that either `AddNotFull` or `AddFull` holds.
  - Each action has a guard (size > length, or size = length) and defines the primed next-state variables. Every variable has to be accounted for in each transition, including the ones that don't change.
- **(07:17–08:35) Model checking.** The checker uses typeless model values v1 to v15 and a maximum size of 5. Checking small sizes lets you extrapolate to larger ones. It explored about 13M states, 871K of them distinct, in about 10 seconds, and the size invariant held.
- **(08:35–10:37) Checking the "head is oldest" property.** Weiss adds a parallel `ages` sequence: each new element gets age 0 and all existing ages increment (a recursive helper). The invariant is that ages strictly decrease along the sequence. It passes.
- **(10:37–13:21) The temporal property and fairness.**
  - `[]<>` (always eventually) means the buffer keeps becoming full again, but may not stay full.
  - `<>[]` (eventually always) means once full, it stays full.
  - The first check fails because of *stuttering*: the system may stay in its initial state forever and never add anything. Adding *weak fairness* to the spec makes it pass.
- **(13:21–14:45) Live demo.** With max size 4: 871K states, 58K distinct, all properties hold. Recommended resources: Lamport's video series, *Practical TLA+*, the TLA+ conference, the TLA+ Google group, and Lamport's original paper.
- **(15:23) Q&A: how does this connect to real code?** It doesn't, directly. You can translate the TLA+ model into PropEr or QuickCheck properties and test the implementation that way. Weiss finds writing a TLA+ spec faster than writing code plus property tests, which makes it a cheap way to validate a design first.

## Key terms

| Term | Description |
|---|---|
| **TLA+** | Lamport's Temporal Logic of Actions: a language for specifying systems as state machines and checking properties of them. |
| **PlusCal** | An imperative-style language that compiles down to TLA+. |
| **TLC / model checker** | The tool that exhaustively explores every reachable state of a spec, within the bounds you give it. |
| **Init** | A predicate defining the set of possible initial states. |
| **Next** | A predicate defining which state transitions are allowed. |
| **Action** | One kind of transition (e.g. `AddFull`), usually a guard plus the new primed values. |
| **Primed variable (`x'`)** | The value of a variable in the next state. |
| **UNCHANGED** | An explicit statement that a variable keeps its value during a transition. |
| **`\E` / `\/` / `/\`** | Exists, logical OR, logical AND. |
| **Model values** | Typeless placeholder values (v1…v15) used by the checker, similar to `any()` in PropEr. |
| **Constants** | Parameters such as the maximum size N and the value set, which bound the checking. |
| **Invariant** | A property that must hold in every reachable state. |
| **Temporal property** | A property over whole behaviours (sequences of states), e.g. "eventually full". |
| **`[]` (always) / `<>` (eventually)** | The temporal operators. |
| **`[]<>` vs `<>[]`** | Always eventually (recurring) vs eventually always (stable once reached). |
| **Stuttering** | A step in which nothing changes; TLA+ allows these by default. |
| **Weak fairness (WF)** | A rule that an action which stays continuously enabled must eventually happen. |
| **Strong fairness (SF)** | A rule that an action which is enabled infinitely often must eventually happen. |
| **Distinct states** | Unique states found, as opposed to the total number of states visited. |
| **Circular / ring buffer** | A fixed-capacity buffer that overwrites its oldest entries when full. |
| **Property-based testing** | Testing implementation code against generated inputs (PropEr, QuickCheck). |

## Key takeaways

1. **A spec is just two predicates.** If you can name your variables, your initial states and your allowed transitions, you have a TLA+ specification. The rest is the properties you want to check.
2. **The design and the implementation are checked separately.** TLA+ proves the design is sound. Property-based tests check that the code follows it. Both are worthwhile, at different stages.
3. **Think in sets, not samples.** `Init` and `Next` describe *all* possibilities at once, unlike a test, which picks one example. This is the main mental shift for newcomers.
4. **Invariants and temporal properties are different kinds of claims.** Invariants are about individual states; temporal properties are about entire runs of the system.
5. **Liveness needs fairness.** "Eventually" properties fail until you rule out the system stalling forever. Hitting a stuttering failure is the normal, expected first step.
6. **Small bounds are enough.** Checking sizes up to 5 explored millions of states in seconds, and most design bugs show up at small sizes.
7. **Model only what the property needs.** For "head is oldest", Weiss added a parallel `ages` sequence rather than restructuring the elements into tuples.
8. **Specs are cheaper than code.** Writing the spec first is a fast way to catch design errors before implementing anything.

## Connection to RxJS

The `Init`/`Next` shape is exactly what `scan(next, init)` gives you: an Observable of commands folded into a sequence of states. A `scan`-based reducer is therefore already a state machine you could model in TLA+.

Invariants on that model correspond to checks on every emitted state. Temporal properties such as "eventually always" correspond to claims about the stream as a whole, which marble tests or property tests over generated event streams can check.

## User:

> 10/30/2026 6:10:52

give an explantion on the list of TLA+ Syntax symbols

## Assistant:

> 10/30/2026 6:13:12

> Planning the page's sections and example spec.
>
> - Planning the page's sections and example spec.
> - **Done**

I'll build this as a reference page you can keep, published as an artifact and also given to you as a local .html file.

> Drafting the TLA+ syntax sections with a annotated circular buffer spec.
>
> - Loaded a skill
> - Drafting the TLA+ syntax sections with a annotated circular buffer spec.
> - Created a file
> - **Done**

## User:

> 10/30/2026 6:13:12

It is hard to see that TLA+ is related to State Machines

## Assistant:

> 10/30/2026 6:13:12

## User:

> 10/30/2026 6:13:12

could we formulate Rxjs Operator Behavior with TLA+ invariants

## Assistant:

> 10/30/2026 6:14:57

> Drawing the SVG diagrams for the spec's states.
>
> - Drawing the SVG diagrams for the spec's states.
> - Edited a file
> - Edited a file
> - **Done**

Now renumber sections, update the nav, and add diagram styles.

> - Ran a command
> - Used artifacts
> - Shared files
> - **Done**

The TLA+ Symbol Reference is published, and there's a local `tla-symbols.html` copy you can download. It covers every operator family in ASCII and typeset form, with JS/TS analogues, and has a separate section of labelled edge cases.

**Why the state machine is hard to see.** TLA+ never uses the words "state" or "transition"; it writes the machine as logic. The mapping is:
- **States:** all the variables taken together.
- **Start states:** `Init`.
- **Transitions:** each `\/` branch of `Next`.
- **Guards:** the unprimed conjuncts in a branch.
- **Targets:** the primed (`x'`) conjuncts.
- **Inputs:** the value picked by `\E`.

Section 01 of the page has this table plus a drawing of the ring buffer for `size = 2`. One line like `Append(Tail(elements), v)` stands for thousands of concrete edges, so the spec never lists states the way XState or `gen_statem` would.

**RxJS operator behaviour as invariants.** Yes, this fits well. Section 10 has a complete `take(N)` spec you can run in TLC:
- Its variables are `in`, `out`, the source's state and the subscriber's state.
- It checks `AtMostN`, `IsPrefix` and `CompletesAtN`.
- It checks `TerminalIsFinal`, which says nothing is emitted after complete or error.

It also has a table of invariants for `map`, `filter`, `scan`, `distinctUntilChanged`, `switchMap`, `mergeMap`, `concatMap`, `exhaustMap` and others. A short fast-check example shows how the same invariants become tests against the real operator.

These parts are labelled as edge cases on the page:
- "Nothing after complete" is a property over steps, not over single states, so it has to be written and checked differently.
- Time-based operators need an explicit tick action.
- Algebraic laws such as `map` fusion need two pipelines modelled side by side.
- TLA+ pays off most on interleavings like `switchMap` cancellation and `share` refCount races, not on `map`.

A good next step would be a full `switchMap` spec, because cancellation races are exactly the bugs TLC finds that example-based tests miss.

## User:

> 10/30/2026 6:18:54

wow you gave a very good description on TLA+ syntax and possible use for Rxjs Operator Behavior, that is an excellent document source, congratulations to Opus 5.5

## Assistant:

> 10/30/2026 6:18:56

> - **Done**

Thank you, Hans, I'm glad it's useful.

If you take it further, the `switchMap` spec would be the most interesting test. A cancellation race there needs the interleavings TLC is built to explore, which marble tests tend to cover only by luck. The operator invariants table could also become an extra classification axis in the operator navigator, alongside the type-signature patterns.

## User:

> 10/30/2026 6:20:32

the big advantage of describing Rxjs Operator Behavior with TLA+ is the ability to use the Model Checker from the TLA+ ecosystem to check the validity of an Rxjs pipeline

## Assistant:

> 10/30/2026 6:20:46

> Listing the limits of model checking for pipelines.
>
> - Listing the limits of model checking for pipelines.
> - **Done**

Yes, and the reason it works is that operators compose the same way their specs do.

**Base case: a pipeline is a composition of operator machines.** Each operator spec has an `in` and an `out`. Chaining operators means the `out` of one becomes the `in` of the next. So `source.pipe(filter(p), take(3))` becomes one spec in which:
- The variables are `src`, `mid` and `out`, plus each stage's protocol state.
- `Next` is the disjunction of the source's actions and each operator's reactions.
- TLC checks properties of the whole pipeline, not just of each operator.

These are the properties you couldn't easily get from testing operators one by one:
- **End-to-end invariants**, such as `out` being a prefix of `SelectSeq(src, P)` with length at most 3.
- **The protocol across the chain:** no stage emits after its upstream terminated or after its downstream unsubscribed.
- **Concurrency bounds** in a nested pipeline, such as at most one in-flight request through `switchMap` into `concatMap`.
- **Liveness**, such as "every search term leads to a result or is cancelled by a newer term" (`P ~> Q`), with fairness on the HTTP action.
- **Counterexamples:** when a property fails, TLC gives you the exact interleaving as a trace. That trace translates almost directly into a marble diagram for a regression test.

**Limits (edge cases):**
- **You check a model of the operators.** The guarantee only holds if each operator spec matches RxJS's real behaviour. Running every spec's invariants as fast-check tests against the real operator closes that gap, and each operator only needs it once.
- **State explosion.** Every stage multiplies the state space, so you'd keep value sets and stream lengths small (2–3 values, length 4–5). As in the talk, most bugs appear at small sizes. Apalache, a symbolic checker for TLA+, can push further than TLC on some specs.
- **Time.** Operators like `debounceTime` and `delay` need a `Tick` action and a `now` variable, which grows the state space quickly.
- **Real schedulers.** Microtask and macrotask ordering only matters if you model it. Without that, TLC treats all orderings as possible, which is stricter than reality. That's usually fine, but it can report a race the JavaScript event loop would actually prevent.

The tooling this points to is a library of operator modules, each one conformance-tested against RxJS, plus a translator that turns a `pipe(...)` expression into a composed spec. The operator modules map naturally onto the behaviour patterns in your operator navigator and the pure-functional operator definitions in rxjs-fp.

If you'd like, I can build the composed `filter → take` pipeline spec next, or go straight to `switchMap`, where the model checker would find the cancellation race.

## User:

> 10/30/2026 6:22:38

would the Marble Syntax of the TestScheduler that works on a frame as logical time not clock time now() help to solve the Time edge case

## Assistant:

> 10/30/2026 6:23:02

> Drafting a debounce spec with timers and a Tick action.
>
> - Drafting a debounce spec with timers and a Tick action.
> - **Done**

Yes, mostly. Marble frames are the same idea TLA+ uses for time: discrete logical time instead of a real clock. TLA+ has no built-in time at all, and Lamport's standard approach ("Real Time is Really Simple") is a `now` variable that advances one step at a time. One marble frame is one tick.

**Base case: marbles and TLA+ actions line up**

| Marble | TLA+ |
|---|---|
| `-` | `Tick` (`now' = now + 1`) |
| `a` | `SourceNext("a")` in the current frame |
| `\|` | `SourceEnd("complete")` |
| `#` | `SourceEnd("error")` |
| `(ab)` | several actions between two ticks |
| `^` / `!` | `Subscribe` / `Unsubscribe` actions |
| `5ms` time progression | five `Tick` steps |

A timer is a deadline variable, and `Tick` may not move past a timer that is due. With those two pieces, `debounceTime(D)` looks like this:

```tla
VARIABLES now, in, out, pending, deadline   \* in/out hold <<frame, value>> pairs

Tick == /\ now < MaxTime
        /\ ~(pending /= None /\ deadline = now)   \* a due timer must fire first
        /\ now' = now + 1
        /\ UNCHANGED <<in, out, pending, deadline>>

SourceNext(v) == /\ in'       = Append(in, <<now, v>>)
                 /\ pending'  = v
                 /\ deadline' = now + D            \* restart the timer
                 /\ UNCHANGED <<now, out>>

Fire == /\ pending /= None /\ deadline = now
        /\ out'     = Append(out, <<now, pending>>)
        /\ pending' = None
        /\ UNCHANGED <<now, in, deadline>>

\* Invariant: every emission at frame t had no input in (t-D, t]
QuietWindow ==
  \A k \in 1..Len(out) :
    ~\E j \in 1..Len(in) : out[k][1] - D < in[j][1] /\ in[j][1] <= out[k][1]
```

This is the same mechanism as `TestScheduler`: virtual time that advances only when nothing is due in the current frame. It also gives you a direct path between the two tools. A TLC counterexample trace can be printed as a marble diagram, and existing marble tests can be read as specific behaviours that the spec must allow.

**Edge cases that remain**
- **State space.** Each frame multiplies the states. Keep durations tiny (`D = 2`, `MaxTime ≈ 8`). Marble tests already work this way: what matters is the order of deadlines, not their real size.
- **Order within a frame.** `TestScheduler` runs simultaneous events in one fixed order. TLC tries every order of the actions between two ticks, so it is stricter and can find bugs that depend on that order.
- **Time that never advances.** Without fairness on `Tick`, TLC accepts a behaviour where time stops forever, and liveness checks like "eventually emits" fail. Add `WF_vars(Tick)` and `WF_vars(Fire)`.
- **Variable durations.** Marbles fix every delay in advance. TLA+ can say "the HTTP response arrives somewhere between 1 and 3 frames" (`deadline' \in now+1..now+3`) and check every timing at once. A marble test can't express that.

Do you want me to add this as a "Time and marbles" section to the reference page?

## User:

> 10/30/2026 6:23:31

TLA+ Eventually is a time based operator

## Assistant:

> 10/30/2026 6:23:43

> Adding a deadline variable to bound the response.
>
> - Adding a deadline variable to bound the response.
> - **Done**

Not quite. In TLA+, "eventually" is about *order*, not *duration*. That difference decides how timing requirements get checked.

**Base case: `<>` means "at some later step".** A behaviour is a sequence of states: s0, s1, s2, and so on. `<>P` says that P is true in some state at or after the current one. It says nothing about how many steps that takes, and nothing about clock time. Nothing in the logic itself measures time; the "temporal" in temporal logic refers to the position of a state in that sequence.

So `<>(sub = "complete")` holds even if completion arrives after a billion steps. It is the same promise as an Observable without `timeout`: it will complete, but there is no bound on when.

**Bounded time needs the explicit clock.** "Respond within D frames" cannot be written with `<>` alone. With the `now` variable from the marble discussion, it becomes a deadline:

```tla
\* when a request starts:  deadline' = now + D
WithinD == answered \/ now <= deadline        \* an ordinary invariant
```

The bounded requirement becomes a *safety* property: an invariant TLC checks in every state, and a violation shows up as a finite trace you can draw as a marble diagram. This is what `timeout(D)` does at runtime: it turns "eventually" into "by frame D, or error".

**What the two kinds of property need from TLC:**

| | `<>P` (unbounded) | `now <= deadline` (bounded) |
|---|---|---|
| Kind | liveness | safety (invariant) |
| Needs fairness | yes, e.g. `WF_vars(Next)` | no, but `Tick` must not skip past a due deadline |
| Counterexample | an infinite loop (a cycle in the state graph) | a finite trace |
| RxJS analogue | `last()` / waiting for complete | `timeout(D)` |

**Edge case:** liveness checking is far more expensive for TLC than invariant checking, and its counterexamples are cycles, which are harder to read. Once a property is a deadline over `now`, writing it as an invariant is usually the better choice: it is cheaper to check and closer to what a marble test asserts.

## User:

> 10/30/2026 6:25:21

yes liveness is hard to check, Leslie Lampert in his presentations only shows the first part and leaves out going deeper into liveness

## Assistant:

> 10/30/2026 6:25:35

> Checking Lamport's stance on liveness in his course.
>
> - Checking Lamport's stance on liveness in his course.
> - **Done**

That's largely deliberate on his part. In his talks and in *Specifying Systems*, Lamport puts safety first and treats liveness as a smaller, later topic. *Specifying Systems* does have a full chapter on liveness and fairness, but it comes after the safety material.

There are three practical reasons for that order:

1. **Most bugs are safety bugs.** Wrong values, events in the wrong order, emissions after complete: all of these show up as a finite trace that breaks an invariant. In practice, that is where most of the design errors are.
2. **Liveness depends on fairness assumptions.** "Eventually" only holds if you assume certain steps actually happen, so you have to state exactly which ones, with `WF` or `SF`. Getting fairness right is subtle; too much of it hides real bugs. Weiss's talk showed only the first step of this.
3. **Liveness is costly to check.** TLC has to search the state graph for cycles. That is slower, often limited to smaller models, and the counterexamples are harder to read.

The common workaround is what we discussed for time: replace "eventually" with "by frame D" and check it as an invariant.

For RxJS, there is a small group of operators where liveness is the property that matters most. These are the bugs that show up as a pipeline that simply hangs:
- **`forkJoin`** never emits if one source never completes.
- **`combineLatest`** stays silent until every source has emitted at least once.
- **`last()`, `reduce`, `toArray`** never emit on an infinite source.
- **`concatMap`** stalls everything behind an inner Observable that never completes.
- **`share` with refCount** can hang if a reconnect is never triggered.

A useful property for any of these is "every subscriber eventually gets a terminal notification or values", written as `sub ~> (sub = "complete" \/ sub = "error")` with fairness on the sources. When TLC finds a counterexample, it is a cycle where one source keeps stuttering, which is exactly the stuck stream you would otherwise find in production.

So a sensible split for your operator specs: check safety invariants for every operator, use deadline invariants with marble-style frames where timing matters, and keep full liveness checking for this small group of waiting operators.

## User:

> 10/30/2026 6:27:05

could we make any Rxjs Observable complete or error with the Rxjs timeout Operator

## Assistant:

> 10/30/2026 6:27:23

> Contrasting silence limits with total duration limits.
>
> - Contrasting silence limits with total duration limits.
> - **Done**

Not quite. `timeout` limits how long a stream can stay **silent**, not how long it can run. A stream that keeps emitting faster than the timeout will never complete or error.

**Base case: what `timeout` guarantees** (RxJS 7 config form)

```ts
source$.pipe(timeout({ first: 1000 }))   // first value must arrive within 1000 ms
source$.pipe(timeout({ each: 300 }))     // no gap between values may exceed 300 ms
source$.pipe(timeout(300))               // same as { each: 300 }; first defaults to each
```

If the limit is exceeded, the stream errors with a `TimeoutError`. If you want it to complete instead, use `with` to switch to a fallback:

```ts
source$.pipe(timeout({ each: 300, with: () => EMPTY }))   // goes quiet → completes
```

So `timeout` covers the "hanging" cases from before: a `forkJoin` input that never completes, a `concatMap` inner that stalls, a source that never emits.

**What `timeout` does not cover** is a stream that keeps talking:

```ts
interval(10).pipe(timeout(100))   // emits every 10 ms forever: never completes, never errors
```

To guarantee a terminal notification for *any* source, bound the total duration or the count instead:

| Bound on | Operator | Ends with |
|---|---|---|
| Silence | `timeout({ each: D })` | error (or `with` fallback) |
| Time to first value | `timeout({ first: D })` | error |
| Total duration | `takeUntil(timer(D))` | complete |
| Number of values | `take(n)` | complete |

`source$.pipe(timeout({ each: D }), takeUntil(timer(T)))` will always terminate, by error or completion, within at most `T` (provided time keeps advancing).

**In TLA+ terms:** without these operators, the property "the subscriber eventually gets complete or error" needs fairness assumptions about the *source*, which you can't control. With `takeUntil(timer(T))`, it needs only fairness on `Tick`, which is a far weaker assumption. Better still, it turns into a deadline invariant over `now`, so you can check it as safety instead of liveness. That is exactly the trick from two messages ago.

**Edge cases**
- **Synchronous sources.** `timeout` and `timer` rely on the scheduler, so they can't interrupt code running synchronously on the JavaScript thread. A synchronous source that never yields, like a huge `range` or a `new Observable` with a `while(true)`, blocks the event loop and the timer never fires. In the TLA+ model, this is a behaviour where `Tick` is never enabled, which is exactly the situation the `WF(Tick)` assumption rules out. The model trusts that time advances; the runtime only does if the source gives control back.
- **Teardown.** When `timeout` fires, it unsubscribes from the source. If the source's teardown doesn't actually cancel the underlying work (for example a `fetch` without an `AbortController`), the stream terminates but the work keeps running.
- **Per-subscription timers.** Each subscriber gets its own timeout. Behind `share()`, one subscriber timing out does not end the stream for the others.

## User:

> 10/30/2026 6:28:15

how could I create a custom Operator that cancels the Observable after a user requested time duration

## Assistant:

> 10/30/2026 6:29:39

> Checking the timer-before-subscribe ordering and the edge cases.
>
> - Checking the timer-before-subscribe ordering and the edge cases.
> - **Done**

I'll write the operator as a TypeScript file with marble tests, and run the tests before handing them over.

> - Ran a command
> - Created a file
> - Checking the expected error frame against the test's assertion.
> - Created a file
> - Ran a command
> - Shared files
> - **Done**

I wrote three variants in `time-limit.ts`, each a step up from the last. All 9 marble tests in `time-limit.spec.ts` pass, and the operator file passes a strict `tsc` check.

**1. Base case: `cancelAfter(ms)`** completes the stream `ms` after subscription. It's just existing operators:

```ts
export const cancelAfter = <T>(ms: number, scheduler = asyncScheduler): MonoTypeOperatorFunction<T> =>
  source => source.pipe(takeUntil(timer(ms, scheduler)));
```

Because `takeUntil` subscribes to the timer at subscription time, each subscriber gets its own deadline. A source that finishes earlier completes normally and the timer is dropped.

**2. `timeLimit({ ms, on: 'complete' | 'error' })`** is written from scratch with `new Observable`. The timer and the source share one teardown, so whichever ends first cancels the other. With `on: 'error'` it fails with a typed `TimeLimitError`.

**3. `cancelAfterUser(duration$, cancel$)`** covers a duration the user picks, and can change, while the stream runs:
- The deadline is always measured from subscription. Shortening from 10 s to 5 s after 7 s ends the stream immediately.
- `cancel$` (for example a Stop button's clicks) ends it at once.

The tests pin these down in marbles. For example, `cold('a-b-c-d-e|').pipe(cancelAfter(5))` must produce `'a-b-c|'` with source subscription `'^----!'`, which proves the source is actually unsubscribed at frame 5. Each case maps directly to the deadline invariant from the TLA+ discussion, roughly `now >= start + D => sub /= "active"`.

**Edge cases** (all documented or guarded in the code):
- **Invalid duration:** a negative or infinite `ms` throws a `RangeError` up front, rather than producing a timer that never fires.
- **Synchronous sources** that never give control back can't be interrupted. The timer only fires once the event loop is free.
- **Ending the stream doesn't stop the work.** For HTTP, the source needs an `AbortController` in its teardown for the request to really be cancelled.
- **Behind `share()`**, the limit applies to each subscriber separately. Put the operator before `share()` if the shared stream itself should end.

## User:

> 10/30/2026 6:32:25

excellent work, custom opertor cancelAfter(...) even with Testing

## Assistant:

> 10/30/2026 6:32:28

> - **Done**

Thank you, Hans. Writing the marble tests alongside the operator was easy here because the virtual-time frames line up exactly with the TLA+ `Tick` model we discussed.

If you want to close the loop, I could write the matching `CancelAfter.tla` spec next. You'd then have the design checked by TLC and the implementation checked by the marble tests, both against the same deadline invariant.

## User:

> 10/30/2026 6:33:17

oh great idea, yes lets write that spec

## Assistant:

> 10/30/2026 6:34:28

> Writing the actions and safety properties for the spec.
>
> - Writing the actions and safety properties for the spec.
> - **Done**

I'll write the spec with a TLC config, then run the model checker to confirm every property holds.

> Checking the deadline rule against SourceNext's connection requirement.
>
> - Ran a command
> - Created a file
> - Edited a file
> - Created a file
> - Command failed
> - Checking the deadline rule against SourceNext's connection requirement.
> - **Done**

The model checker didn't run here: the sandbox blocked executing the downloaded TLA+ tools jar. I checked the spec by hand instead, and I'll give you the command to run it yourself.

> Used tool
>
> - Shared files
> - **Done**

`CancelAfter.tla` and `CancelAfter.cfg` are ready. I couldn't run TLC here because the sandbox blocked executing the downloaded TLA+ tools jar, so the spec is checked by hand, not by the model checker. To run it on your machine:

```
java -cp tla2tools.jar tlc2.TLC -config CancelAfter.cfg CancelAfter.tla
```

The TLA+ extension for VS Code works too: open the `.tla` file and choose "Check model with TLC".

**How the spec maps to the operator.** Time works like marble frames: one `Tick` is one frame, the subscription starts at frame 0, and `D = 5` matches the marble test `cold('a-b-c-d-e|').pipe(cancelAfter(5))`. There are four actions:
- **`Tick`** advances one frame, but may not move past frame `D` while the timer is still due.
- **`SourceNext(v)`** passes a value straight through, as long as `cancelAfter` is still subscribed to the source.
- **`SourceEnd(how)`** is the source completing or erroring first, which also cancels the timer.
- **`Fire`** is `timer(D)` firing: it completes the subscriber and unsubscribes from the source.

**What it checks:**

| Property | Kind | Marble test equivalent |
|---|---|---|
| `NoEmitAfterDeadline` | invariant | nothing after frame 5 in `'a-b-c\|'` |
| `PassThrough` | invariant | values before the deadline arrive unchanged |
| `TerminatedByDeadline` | invariant | `\|` at frame 5 or earlier |
| `UnsubscribedWhenDone` | invariant | `'^----!'` |
| `TerminalIsFinal` | action property | the Observable contract |
| `Terminates` | liveness | every subscription ends, whatever the source does |

`Terminates` assumes fairness only on `Tick` and `Fire`, meaning time advances and a due timer fires. Nothing is assumed about the source, which is the point of the operator.

**What I checked by hand.** Each property holds because of a specific guard:
- `Tick` can't pass frame `D` while the subscriber is active.
- `SourceNext` needs the source to still be connected, and both `Fire` and `SourceEnd` disconnect it.
- No action ever sets the subscriber back to active or reconnects the source.

**Worth trying once it runs:** remove one guard at a time and TLC should give you a counterexample trace, which you can read as a marble diagram:
- Remove `~(sub = "active" /\ now = D)` from `Tick`, and `TerminatedByDeadline` fails because time can run past the deadline.
- Remove `connected` from `SourceNext`, and `NoEmitAfterDeadline` and `TerminalIsFinal` fail. That is the classic "forgot to unsubscribe" bug.
- Remove `WF_vars(Fire)` from `Spec`, and `Terminates` fails with a behaviour that stutters forever at frame 5.

**Edge case:** at exactly frame `D`, the spec allows a source value either before or after the timer fires. TLC checks both orders, while `TestScheduler` runs only one, the order in which the actions were scheduled. The properties hold either way, so the marble test's choice can't hide a bug here.

## User:

> 10/30/2026 6:35:29

that is also a great teach sample for TLA+ you gave with this spec

## Assistant:

> 10/30/2026 6:35:33

> - **Done**

Thank you, Hans. It also works well as a teaching example because the same deadline is pinned down three times: in `cancelAfter.ts` as code, in the marble test as an example run, and in the TLA+ spec as a property checked over every run.

For your course, the guard-removal exercise is probably the strongest part. Students break one guard, TLC returns a counterexample trace, and they translate it into the marble diagram that would have caught the bug. That teaches TLA+ and RxJS testing in the same step.

If you'd like, I can add a "From operator to spec" section to the TLA+ Symbol Reference page that walks through `cancelAfter` this way. It would update both the published page and your local `.html` copy.

## User:

> 10/30/2026 6:36:10

I found that there is also a TLA Typescript version, check what it is: https://github.com/aidenybai/tla-ts

## Assistant:

> 10/30/2026 6:36:41

> - Read a page
> - Deciding whether to run the npm package or just offer it.
> - Command failed
> - **Done**

tla-ts is not a TypeScript way of writing specs. It's a reimplementation of the TLA+ toolchain in TypeScript, so you still write ordinary `.tla` modules with a TLC-style `.cfg` file.

**What it does**
- **Model checker:** it describes itself as a drop-in replacement for TLC, the Java model checker. It runs in Node, Bun or the browser, and checks invariants, deadlocks and temporal properties, including liveness.
- **CLI:** `npx tla-ts Spec.tla` reads `Spec.cfg` and follows TLC's options and exit codes.
- **API:** `check({ source, config })` returns a status such as `"invariant-violation"`, a counterexample trace and state counts. It also exposes `parseModule`, `parseConfig` and typed errors.
- **Conformance:** it's tested against 542 models with recorded TLC results, reports the same state counts as TLC on its benchmarks, and claims to be about 1.5–2.4× faster.
- **Proofs:** it can generate proof obligations, but it doesn't include its own prover; for actual proving it calls Lamport's TLAPS prover.

**Maturity:** MIT license and about 350 commits, but only around 10 stars and no forks, so it's young. Some TLA+ features are still unsupported and raise an error. Liveness checking runs single-threaded, and in a browser multi-threading needs cross-origin isolation.

**Why it's interesting for your work**
- **Model checking in an RxJS test suite.** The `check()` API lets you run TLA+ specs from Vitest next to the marble tests: `CancelAfter.tla` checked by TLC semantics and `cancelAfter.ts` checked by `TestScheduler`, in one `npm test`.
- **Counterexample traces as data.** The trace comes back as a JavaScript object, so a small script could turn it into a marble diagram automatically. That was the manual step in the guard-removal exercise.
- **Model checking in a page.** It runs in the browser, so a documentation page could check a spec live, which would suit your course.

**Verify before relying on it:** this description comes from its README and I haven't seen it run. Before building on it, run `CancelAfter.tla` through both tla-ts and the official `tla2tools.jar` and compare the state counts and results.

I tried to run it on `CancelAfter.tla` here, but the sandbox blocked executing the npm package, the same as it blocked TLC earlier. On your machine, this would be the first real model-check of that spec:

```
npx tla-ts CancelAfter.tla
```

## User:

> 10/30/2026 6:37:44

do you evaluate tla-ts as a useful tool in practical application

## Assistant:

> 10/30/2026 6:37:59

> Weighing tla-ts's strengths and weaknesses for the user.
>
> - Weighing tla-ts's strengths and weaknesses for the user.
> - **Done**

Yes, but as a convenience layer, not as your main checker. I haven't run it, so this is based on its README and design, not on hands-on use.

**For everyday spec work, TLC remains the reference.** The official checker, with the VS Code TLA+ extension, has decades of use, Lamport's and Microsoft's teams behind it, and features like its trace explorer. Whenever correctness really matters, it should have the final word.

**Where tla-ts is genuinely useful:**
- **No Java needed.** `npx tla-ts Spec.tla` runs anywhere Node runs, which makes it easy to add spec checks to an existing TypeScript CI pipeline.
- **A programmatic API.** `check()` returns results and counterexample traces as JavaScript objects. That enables things TLC makes awkward: running specs from Vitest, turning traces into marble diagrams, or comparing spec results with implementation tests in one run.
- **It runs in the browser.** Live model checking in a documentation page or a course is the strongest unique use case. TLC can't do that.

**Risks you need to accept:**
- **A wrong "pass" is the worst failure a verification tool can have.** A checker bug that misses a counterexample gives you false confidence, which is worse than no check at all. The 542 conformance models are reassuring, but they're the project's own claim and haven't been independently confirmed.
- **The project is young and lightly adopted.** About 10 stars and no forks suggests one main author. If they stop maintaining it, you're on your own with an unfamiliar codebase.
- **Feature gaps are unknown.** It says some TLA+ features are unsupported, but not which ones. Hitting one in the middle of a spec is annoying, though at least it fails loudly with an error instead of returning a wrong result.
- **Liveness checking is single-threaded**, which is the slowest part of model checking anyway.

**Practical recommendation for your work**
1. Write and check specs with TLC as the authority.
2. Use tla-ts where JavaScript integration pays off: CI checks next to marble tests, trace-to-marble tooling, interactive course pages.
3. Pin its version, and add a check in CI that runs a few specs through both tools and fails if the state counts or results differ. That catches checker disagreements early.
4. Start with `CancelAfter.tla` plus the three guard-removal variants. Four cases where you know the expected result in advance quickly show whether tla-ts finds the same counterexamples as TLC.

For teaching in particular, it's a strong fit, because a mistake in an exercise costs little and the ability to check specs live in the browser is valuable.

## User:

> 10/30/2026 6:38:34

see you in the next session

## Assistant:

> 10/30/2026 6:38:37

See you next time, Hans. Everything from today is in your files: the TLA+ Symbol Reference page (with its local `.html` copy), `time-limit.ts` with its marble tests, and `CancelAfter.tla` with its `.cfg`. Running the spec through TLC or tla-ts on your machine would be a good first step next session.

Powered by Claude Exporter (https://www.ai-chat-exporter.net)
