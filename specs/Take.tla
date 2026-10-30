-------------------------------- MODULE Take --------------------------------
(***************************************************************************)
(* take(N): deliver the first N values, then complete and unsubscribe.     *)
(*                                                                         *)
(* Operator family: truncating. What makes it different from map/filter   *)
(* is that the operator itself ends the stream, so it must also stop       *)
(* listening upstream. That gives the spec a `subscribed` variable.        *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values,   \* the values the source may deliver
          N,        \* the count passed to take(N)
          MaxLen    \* model bound: how many values the source may deliver

ASSUME N \in Nat /\ N >= 1       \* take(0) never subscribes; it is a special case
ASSUME MaxLen \in Nat

VARIABLES in,          \* Seq(Values): values received from the source
          inDone,      \* Status of the source, as observed by the operator
          out,         \* Seq(Values): values delivered to the subscriber
          outDone,     \* Status delivered to the subscriber
          subscribed   \* BOOLEAN: is take still subscribed to the source?

vars == <<in, inDone, out, outDone, subscribed>>

TypeOK == /\ in  \in Seq(Values) /\ inDone  \in Status
          /\ out \in Seq(Values) /\ outDone \in Status
          /\ subscribed \in BOOLEAN

Init == /\ in  = <<>> /\ inDone  = "active"
        /\ out = <<>> /\ outDone = "active"
        /\ subscribed = TRUE

-----------------------------------------------------------------------------
(* Actions *)

(* The source delivers v. take forwards it. If that was the N-th value it   *)
(* completes the subscriber and unsubscribes from the source in the same    *)
(* step, exactly as the real operator does inside its `next` handler.       *)
SourceNext(v) ==
  /\ subscribed /\ inDone = "active" /\ Len(in) < MaxLen
  /\ in'  = Append(in, v)
  /\ out' = Append(out, v)
  /\ IF Len(out') = N
       THEN outDone' = "complete" /\ subscribed' = FALSE
       ELSE UNCHANGED <<outDone, subscribed>>
  /\ UNCHANGED inDone

(* The source terminates before N values were seen: forward the terminal.  *)
SourceEnd(how) ==
  /\ subscribed /\ inDone = "active"
  /\ inDone'     = how
  /\ outDone'    = how
  /\ subscribed' = FALSE
  /\ UNCHANGED <<in, out>>

(* After unsubscribing nothing else can happen. This explicit stutter stops *)
(* TLC from reporting the intended end of a behaviour as a deadlock.        *)
Done == ~subscribed /\ UNCHANGED vars

Next == \/ \E v \in Values : SourceNext(v)
        \/ \E how \in {"complete", "error"} : SourceEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* Invariants: checked in every reachable state *)

AtMostN              == Len(out) <= N
OutIsPrefixOfIn      == IsPrefix(out, in)
CompletesAtN         == Len(out) = N => outDone = "complete"
StillActiveBelowN    == (Len(out) < N /\ inDone = "active") => outDone = "active"
ErrorPropagates      == inDone = "error" => outDone = "error"
UnsubscribedWhenDone == Terminal(outDone) => ~subscribed

-----------------------------------------------------------------------------
(* Properties: checked over steps or whole behaviours *)

(* Both streams respect the Observable contract on every step.             *)
ObservableContract == [][Contract(in, inDone) /\ Contract(out, outDone)]_vars

(* Once take has unsubscribed, the source delivers nothing more to it.     *)
NoDeliveryAfterUnsubscribe == [][~subscribed => UNCHANGED in]_vars

(* Liveness: every subscription ends. Holds because Next stays enabled     *)
(* while subscribed and Spec asserts weak fairness on it.                  *)
Terminates == <>Terminal(outDone)

=============================================================================
