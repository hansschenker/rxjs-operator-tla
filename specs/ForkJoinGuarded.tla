---------------------------- MODULE ForkJoinGuarded ----------------------------
(***************************************************************************)
(* forkJoin([a$, guard(b$)]): the pipeline-level cures for the forkJoin    *)
(* hang of ForkJoin_silentB_demo, applied to the problem source b$.        *)
(*                                                                         *)
(*   Guard = "none"                   forkJoin([a$, b$])                   *)
(*   Guard = "take1"                  forkJoin([a$, b$.pipe(take(1))])     *)
(*   Guard = "takeUntilTimer"         forkJoin([a$, b$.pipe(               *)
(*                                      takeUntil(timer(D)))])             *)
(*   Guard = "takeUntilTimerDefault"  forkJoin([a$, b$.pipe(               *)
(*                                      takeUntil(timer(D)),               *)
(*                                      defaultIfEmpty(Default))])         *)
(*                                                                         *)
(* What is wrong with b$ is a fairness assumption, so the module has three *)
(* specifications that differ only in what b$ is assumed to do:           *)
(*                                                                         *)
(*   SpecSilentB   b$ may never deliver or terminate (a Subject nobody     *)
(*                 calls)                                                  *)
(*   SpecChattyB   b$ keeps delivering but is never made to complete (an   *)
(*                 interval, a websocket)                                  *)
(*   SpecFair      b$ behaves                                              *)
(*                                                                         *)
(* The guard decides which of these forkJoin survives, and at what price:  *)
(* take(1) needs one value, takeUntil(timer) can complete the branch       *)
(* empty, which makes forkJoin complete without a value; defaultIfEmpty    *)
(* closes that gap.                                                        *)
(*                                                                         *)
(* Built from ForkJoin.tla, with the guard as a layer between b$ and       *)
(* forkJoin (bSeen, bBranchDone) and the Tick machinery of part 04.        *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Guard,      \* "none" | "take1" | "takeUntilTimer" | "takeUntilTimerDefault"
          Values,
          Default,    \* model value: the defaultIfEmpty value
          D,          \* the timer's duration, in frames
          MaxTime,    \* model bound on now; only matters with a timer
          MaxLen      \* model bound: values per source

ASSUME Guard \in {"none", "take1", "takeUntilTimer", "takeUntilTimerDefault"}
ASSUME D \in Nat /\ D >= 1 /\ MaxTime \in Nat

UsesTimer == Guard \in {"takeUntilTimer", "takeUntilTimerDefault"}

VARIABLES now,
          a, aDone,              \* source A, as observed by forkJoin
          b, bDone,              \* source B, as it behaves
          bSeen, bBranchDone,    \* B's branch, as observed by forkJoin: after the guard
          bSub,                  \* BOOLEAN: is the guard still subscribed to B?
          out, outDone           \* at most one <<va, vb>>, delivered on completion

vars == <<now, a, aDone, b, bDone, bSeen, bBranchDone, bSub, out, outDone>>

AllValues == Values \cup {Default}

TypeOK == /\ now \in 0..MaxTime
          /\ a \in Seq(Values) /\ b \in Seq(Values) /\ bSeen \in Seq(AllValues)
          /\ aDone \in Status /\ bDone \in Status /\ bBranchDone \in Status /\ outDone \in Status
          /\ bSub \in BOOLEAN
          /\ out \in Seq(Values \X AllValues)

Init == /\ now = 0
        /\ a = <<>> /\ aDone = "active"
        /\ b = <<>> /\ bDone = "active"
        /\ bSeen = <<>> /\ bBranchDone = "active" /\ bSub = TRUE
        /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* forkJoin's rule, as a function of the next state of its two inputs:     *)
(* complete empty if an input completed without a value, join if both     *)
(* completed, otherwise wait.                                              *)

Outcome(aD, av, bD, bv) ==
  IF (aD = "complete" /\ av = <<>>) \/ (bD = "complete" /\ bv = <<>>) THEN "empty"
  ELSE IF aD = "complete" /\ bD = "complete" THEN "join"
  ELSE "wait"

Settle(aD, av, bD, bv) ==
  LET o == Outcome(aD, av, bD, bv)
  IN /\ out'     = IF o = "join" THEN Append(out, <<Last(av), Last(bv)>>) ELSE out
     /\ outDone' = IF o = "wait" THEN outDone ELSE "complete"

(* What the branch delivers when it completes: defaultIfEmpty fills a gap. *)
Finished(seen) == IF Guard = "takeUntilTimerDefault" /\ seen = <<>> THEN <<Default>> ELSE seen

TimerDue == UsesTimer /\ bBranchDone = "active" /\ now = D

-----------------------------------------------------------------------------
(* Actions *)

Tick == /\ UsesTimer /\ now < MaxTime /\ ~TimerDue
        /\ now' = now + 1
        /\ UNCHANGED <<a, aDone, b, bDone, bSeen, bBranchDone, bSub, out, outDone>>

ANext(v) == /\ outDone = "active" /\ aDone = "active" /\ Len(a) < MaxLen
            /\ a' = Append(a, v)
            /\ UNCHANGED <<now, aDone, b, bDone, bSeen, bBranchDone, bSub, out, outDone>>

AComplete == /\ outDone = "active" /\ aDone = "active"
             /\ aDone' = "complete"
             /\ UNCHANGED <<now, a, b, bDone, bSeen, bBranchDone, bSub>>
             /\ Settle("complete", a, bBranchDone, bSeen)

AError == /\ outDone = "active" /\ aDone = "active"
          /\ aDone' = "error" /\ outDone' = "error"
          /\ UNCHANGED <<now, a, b, bDone, bSeen, bBranchDone, bSub, out>>

(* B delivers. Without take(1) the value passes into the branch; with it   *)
(* the branch completes on this first value and unsubscribes from B.       *)
BNext(v) ==
  /\ outDone = "active" /\ bSub /\ bDone = "active" /\ Len(b) < MaxLen
  /\ b' = Append(b, v)
  /\ IF Guard = "take1"
       THEN /\ bSeen' = <<v>> /\ bBranchDone' = "complete" /\ bSub' = FALSE
            /\ Settle(aDone, a, "complete", <<v>>)
       ELSE /\ bSeen' = Append(bSeen, v)
            /\ UNCHANGED <<bBranchDone, bSub, out, outDone>>
  /\ UNCHANGED <<now, a, aDone, bDone>>

(* B completes on its own: the branch completes, with the default if the  *)
(* guard supplies one and nothing was delivered.                           *)
BComplete ==
  /\ outDone = "active" /\ bSub /\ bDone = "active"
  /\ bDone' = "complete"
  /\ bSeen' = Finished(bSeen) /\ bBranchDone' = "complete" /\ bSub' = FALSE
  /\ UNCHANGED <<now, a, aDone, b>>
  /\ Settle(aDone, a, "complete", Finished(bSeen))

BError == /\ outDone = "active" /\ bSub /\ bDone = "active"
          /\ bDone' = "error" /\ bBranchDone' = "error" /\ bSub' = FALSE
          /\ outDone' = "error"
          /\ UNCHANGED <<now, a, aDone, b, bSeen, out>>

(* The timer fires: takeUntil completes the branch and unsubscribes B.     *)
Fire ==
  /\ outDone = "active" /\ TimerDue
  /\ bSeen' = Finished(bSeen) /\ bBranchDone' = "complete" /\ bSub' = FALSE
  /\ UNCHANGED <<now, a, aDone, b, bDone>>
  /\ Settle(aDone, a, "complete", Finished(bSeen))

Done == Terminal(outDone) /\ UNCHANGED vars

AStep == (\E v \in Values : ANext(v)) \/ AComplete \/ AError
BStep == (\E v \in Values : BNext(v)) \/ BComplete \/ BError
Next  == Tick \/ AStep \/ BStep \/ Fire \/ Done

(* The guard's own machinery is always fair: time passes, due timers fire. *)
Machinery   == WF_vars(AStep) /\ WF_vars(Tick) /\ WF_vars(Fire)
SpecSilentB == Init /\ [][Next]_vars /\ Machinery
SpecChattyB == Init /\ [][Next]_vars /\ Machinery /\ WF_vars(\E v \in Values : BNext(v))
SpecFair    == Init /\ [][Next]_vars /\ Machinery /\ WF_vars(BStep)

-----------------------------------------------------------------------------
(* Invariants *)

(* forkJoin's own guarantees, over the guarded branch.                     *)
NothingBeforeAllComplete == out /= <<>> => (aDone = "complete" /\ bBranchDone = "complete")
AtMostOneEmission        == Len(out) <= 1
EmitsJoinedValues        == out /= <<>> => out = <<<<Last(a), Last(bSeen)>>>>
UnsubscribedWhenBranchDone == Terminal(bBranchDone) => ~bSub

(* What each guard lets through.                                           *)
BranchMatchesGuard ==
  CASE Guard = "none"                  -> bSeen = b
    [] Guard = "take1"                 -> bSeen = SubSeq(b, 1, IF Len(b) >= 1 THEN 1 ELSE 0)
    [] Guard = "takeUntilTimer"        -> bSeen = b
    [] Guard = "takeUntilTimerDefault" -> bSeen = b \/ (b = <<>> /\ bSeen = <<Default>>)

(* With a timer, the branch is over once the deadline has passed.          *)
BranchEndsByDeadline == UsesTimer => (now > D => Terminal(bBranchDone))

(* The guard never completes the branch empty: if the branch is empty on   *)
(* completion, B itself completed without a value, which no guard can      *)
(* help. Holds for no guard, take(1) and the defaultIfEmpty variant; fails *)
(* for takeUntil(timer) alone, whose timer completes an empty branch, and  *)
(* then forkJoin completes without a value.                                *)
BranchCompletesWithValue == (bBranchDone = "complete" /\ bSeen = <<>>) => (bDone = "complete" /\ b = <<>>)

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][ /\ Contract(a, aDone)
                          /\ Contract(bSeen, bBranchDone)
                          /\ Contract(out, outDone) ]_vars

DeliveryCompletes == [][out' /= out => outDone' = "complete"]_vars

(* The hang, or its cure, depending on the guard and on what B does.       *)
EventuallyTerminal == <>Terminal(outDone)

=============================================================================
