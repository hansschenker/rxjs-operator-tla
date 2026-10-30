----------------------------- MODULE CombineLatest -----------------------------
(***************************************************************************)
(* combineLatest([a$, b$]): once both sources have delivered a value, emit *)
(* the pair of latest values whenever either delivers again. Complete when *)
(* both have completed; error as soon as either errors.                    *)
(*                                                                         *)
(* Operator family: combining. Two independent sources means TLC explores  *)
(* every interleaving of their notifications.                              *)
(*                                                                         *)
(* This module is also the liveness demonstration. It has two             *)
(* specifications that differ only in their fairness assumptions:         *)
(*                                                                         *)
(*   SpecFair    both sources make progress     -> EventuallyTerminal holds *)
(*   SpecFairA   only source A makes progress   -> EventuallyTerminal fails *)
(*                                                                         *)
(* The failure is the "pipeline hangs" bug: nothing is wrong with the      *)
(* operator, the property simply depends on an assumption about a source   *)
(* that the operator cannot enforce. See CombineLatest_SilentB.cfg.        *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values, MaxLen

VARIABLES a, aDone,     \* source A, as observed
          b, bDone,     \* source B, as observed
          out, outDone  \* Seq of <<va, vb>> delivered to the subscriber

vars == <<a, aDone, b, bDone, out, outDone>>

TypeOK == /\ a \in Seq(Values) /\ b \in Seq(Values) /\ out \in Seq(Values \X Values)
          /\ aDone \in Status /\ bDone \in Status /\ outDone \in Status

Init == /\ a = <<>> /\ aDone = "active"
        /\ b = <<>> /\ bDone = "active"
        /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* Actions. Every source action is guarded by outDone = "active": once the *)
(* result has terminated, combineLatest has unsubscribed from both.        *)

ANext(v) == /\ outDone = "active" /\ aDone = "active" /\ Len(a) < MaxLen
            /\ a'   = Append(a, v)
            /\ out' = IF b /= <<>> THEN Append(out, <<v, Last(b)>>) ELSE out
            /\ UNCHANGED <<aDone, b, bDone, outDone>>

BNext(v) == /\ outDone = "active" /\ bDone = "active" /\ Len(b) < MaxLen
            /\ b'   = Append(b, v)
            /\ out' = IF a /= <<>> THEN Append(out, <<Last(a), v>>) ELSE out
            /\ UNCHANGED <<a, aDone, bDone, outDone>>

AComplete == /\ outDone = "active" /\ aDone = "active"
             /\ aDone'   = "complete"
             /\ outDone' = IF bDone = "complete" THEN "complete" ELSE "active"
             /\ UNCHANGED <<a, b, bDone, out>>

BComplete == /\ outDone = "active" /\ bDone = "active"
             /\ bDone'   = "complete"
             /\ outDone' = IF aDone = "complete" THEN "complete" ELSE "active"
             /\ UNCHANGED <<a, aDone, b, out>>

AError == /\ outDone = "active" /\ aDone = "active"
          /\ aDone' = "error" /\ outDone' = "error"
          /\ UNCHANGED <<a, b, bDone, out>>

BError == /\ outDone = "active" /\ bDone = "active"
          /\ bDone' = "error" /\ outDone' = "error"
          /\ UNCHANGED <<a, aDone, b, out>>

Done == Terminal(outDone) /\ UNCHANGED vars

AStep == (\E v \in Values : ANext(v)) \/ AComplete \/ AError
BStep == (\E v \in Values : BNext(v)) \/ BComplete \/ BError

Next == AStep \/ BStep \/ Done

(* Both sources keep going until they terminate.                          *)
SpecFair  == Init /\ [][Next]_vars /\ WF_vars(AStep) /\ WF_vars(BStep)

(* Only source A is guaranteed to make progress. B may stay silent forever.*)
SpecFairA == Init /\ [][Next]_vars /\ WF_vars(AStep)

-----------------------------------------------------------------------------
(* Invariants *)

EmitsOnlyWhenBothSeen == out /= <<>> => (a /= <<>> /\ b /= <<>>)

(* Once both have delivered, the last output is always the latest pair.   *)
LatestPair == (a /= <<>> /\ b /= <<>>) => (out /= <<>> /\ Last(out) = <<Last(a), Last(b)>>)

(* At most one output per source delivery.                                *)
OutputBound == out /= <<>> => Len(out) <= Len(a) + Len(b) - 1

CompletesOnlyWhenBothComplete == outDone = "complete" => (aDone = "complete" /\ bDone = "complete")
ErrorIfEither == (aDone = "error" \/ bDone = "error") => outDone = "error"

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(a, aDone) /\ Contract(b, bDone) /\ Contract(out, outDone)]_vars

EventuallyTerminal == <>Terminal(outDone)

(* Does NOT hold even under SpecFair: a source may complete without ever  *)
(* delivering a value, and then combineLatest never emits. Checked in      *)
(* CombineLatest_EmptySource.cfg, where the counterexample shows this.     *)
EventuallyEmits == <>(out /= <<>>)

=============================================================================
