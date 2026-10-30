------------------------------- MODULE Pipeline -------------------------------
(***************************************************************************)
(* source.pipe(filter(P), take(N)) as one specification.                   *)
(*                                                                         *)
(* Composition rule: the `out` of one stage is the `in` of the next.       *)
(* Both operators here are synchronous, so one source delivery runs the    *)
(* whole chain in a single step: filter decides, take counts, and if take  *)
(* completes it unsubscribes from filter, which unsubscribes from the      *)
(* source. Asynchronous stages (timers, inner Observables) would instead   *)
(* contribute their own actions, and TLC would interleave them.            *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values, N, MaxLen
ASSUME Values \subseteq Nat /\ N \in Nat /\ N >= 1

P(x) == x % 2 = 0          \* filter(x => x % 2 === 0)

VARIABLES src, srcDone,    \* what the source delivered
          mid, midDone,    \* what filter delivered to take
          out, outDone,    \* what take delivered to the subscriber
          subscribed       \* is the chain still subscribed to the source?

vars == <<src, srcDone, mid, midDone, out, outDone, subscribed>>

TypeOK == /\ src \in Seq(Values) /\ mid \in Seq(Values) /\ out \in Seq(Values)
          /\ srcDone \in Status /\ midDone \in Status /\ outDone \in Status
          /\ subscribed \in BOOLEAN

Init == /\ src = <<>> /\ mid = <<>> /\ out = <<>>
        /\ srcDone = "active" /\ midDone = "active" /\ outDone = "active"
        /\ subscribed = TRUE

-----------------------------------------------------------------------------
(* Actions *)

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

(* A terminal notification passes through both stages in one step.        *)
SourceEnd(how) ==
  /\ subscribed /\ srcDone = "active"
  /\ srcDone' = how /\ midDone' = how /\ outDone' = how
  /\ subscribed' = FALSE
  /\ UNCHANGED <<src, mid, out>>

Done == ~subscribed /\ UNCHANGED vars

Next == \/ \E v \in Values : SourceNext(v)
        \/ \E how \in {"complete", "error"} : SourceEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* Invariants *)

(* Each stage on its own *)
FilterCorrect == mid = SelectSeq(src, P)
TakeCorrect   == IsPrefix(out, mid) /\ Len(out) <= N

(* The composed property: what a user of the pipeline actually relies on  *)
EndToEnd == IsPrefix(out, SelectSeq(src, P)) /\ Len(out) <= N

(* take completes as soon as N values have passed the filter              *)
CompletesWhenEnoughPass == Len(SelectSeq(src, P)) >= N => outDone = "complete"

(* When take finishes early, filter was unsubscribed, not completed        *)
MiddleNeverCompletedEarly == (outDone = "complete" /\ srcDone = "active") => midDone = "active"

UnsubscribedWhenDone == Terminal(outDone) => ~subscribed

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][ /\ Contract(src, srcDone)
                          /\ Contract(mid, midDone)
                          /\ Contract(out, outDone) ]_vars

(* Unsubscription reaches the source through the whole chain.             *)
NoDeliveryAfterUnsubscribe == [][~subscribed => UNCHANGED src]_vars

Terminates == <>Terminal(outDone)

=============================================================================
