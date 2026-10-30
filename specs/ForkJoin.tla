------------------------------- MODULE ForkJoin -------------------------------
(***************************************************************************)
(* forkJoin(a$, b$): wait for both sources to complete, then deliver the   *)
(* pair of their last values and complete.                                 *)
(*                                                                         *)
(* Two rules decide everything else. A source that completes without      *)
(* having delivered a value makes the result complete at once, without a  *)
(* value. Either source's error is the result's error. Values arriving    *)
(* before completion are never delivered individually.                    *)
(*                                                                         *)
(* Operator family: combining. This is the operator with the best-known   *)
(* liveness hazard: a source that never completes (a Subject, an          *)
(* interval, a websocket) means the result never emits or completes.      *)
(* ForkJoin_silentB_demo.cfg is that hang as a TLC counterexample.        *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values, MaxLen

VARIABLES a, aDone,     \* source A, as observed
          b, bDone,     \* source B, as observed
          out, outDone  \* at most one <<va, vb>>, delivered on completion

vars == <<a, aDone, b, bDone, out, outDone>>

TypeOK == /\ a \in Seq(Values) /\ b \in Seq(Values) /\ out \in Seq(Values \X Values)
          /\ aDone \in Status /\ bDone \in Status /\ outDone \in Status

Init == /\ a = <<>> /\ aDone = "active"
        /\ b = <<>> /\ bDone = "active"
        /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* Actions. Every source action is guarded by outDone = "active": once the *)
(* result has terminated, forkJoin has unsubscribed from both sources.     *)

(* A value arrives and is remembered; nothing is delivered.                *)
ANext(v) == /\ outDone = "active" /\ aDone = "active" /\ Len(a) < MaxLen
            /\ a' = Append(a, v)
            /\ UNCHANGED <<aDone, b, bDone, out, outDone>>

BNext(v) == /\ outDone = "active" /\ bDone = "active" /\ Len(b) < MaxLen
            /\ b' = Append(b, v)
            /\ UNCHANGED <<a, aDone, bDone, out, outDone>>

(* A source completes. Without a value: the result completes empty, now.   *)
(* With a value, and the other source already complete: deliver the pair  *)
(* of last values and complete. Otherwise keep waiting.                    *)
AComplete ==
  /\ outDone = "active" /\ aDone = "active"
  /\ aDone' = "complete"
  /\ IF a = <<>>
       THEN outDone' = "complete" /\ UNCHANGED out
       ELSE IF bDone = "complete"
              THEN out' = Append(out, <<Last(a), Last(b)>>) /\ outDone' = "complete"
              ELSE UNCHANGED <<out, outDone>>
  /\ UNCHANGED <<a, b, bDone>>

BComplete ==
  /\ outDone = "active" /\ bDone = "active"
  /\ bDone' = "complete"
  /\ IF b = <<>>
       THEN outDone' = "complete" /\ UNCHANGED out
       ELSE IF aDone = "complete"
              THEN out' = Append(out, <<Last(a), Last(b)>>) /\ outDone' = "complete"
              ELSE UNCHANGED <<out, outDone>>
  /\ UNCHANGED <<a, aDone, b>>

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

SpecFair  == Init /\ [][Next]_vars /\ WF_vars(AStep) /\ WF_vars(BStep)
SpecFairA == Init /\ [][Next]_vars /\ WF_vars(AStep)

-----------------------------------------------------------------------------
(* Invariants *)

(* Nothing is delivered until both sources have completed.                 *)
NothingBeforeAllComplete == out /= <<>> => (aDone = "complete" /\ bDone = "complete")

(* At most one value, and it is the pair of last values.                   *)
AtMostOneEmission == Len(out) <= 1
EmitsLastValues   == out /= <<>> => out = <<<<Last(a), Last(b)>>>>

(* A source that ended without a value means the result has no value.     *)
EmptySourceMeansSilence == ((Terminal(aDone) /\ a = <<>>) \/ (Terminal(bDone) /\ b = <<>>)) => out = <<>>

(* The result completes exactly when both have completed, or one has      *)
(* completed without a value.                                              *)
CompletionRule ==
  outDone = "complete" <=> \/ (aDone = "complete" /\ bDone = "complete")
                           \/ (aDone = "complete" /\ a = <<>>)
                           \/ (bDone = "complete" /\ b = <<>>)

ErrorIfEither == (aDone = "error" \/ bDone = "error") => outDone = "error"

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(a, aDone) /\ Contract(b, bDone) /\ Contract(out, outDone)]_vars

(* The only delivery is the one that completes the result.                 *)
DeliveryCompletes == [][out' /= out => outDone' = "complete"]_vars

(* Holds under SpecFair, fails under SpecFairA: the forkJoin hang.         *)
EventuallyTerminal == <>Terminal(outDone)

(* Fails even under SpecFair, and even with errors excluded: a source may  *)
(* complete without a value, and then the result completes without one.   *)
EventuallyEmitsOrErrors == <>(out /= <<>> \/ outDone = "error")

=============================================================================
