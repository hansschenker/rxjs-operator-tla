------------------------------ MODULE CancelAfter ------------------------------
(***************************************************************************)
(* cancelAfter(D) = source => source.pipe(takeUntil(timer(D)))             *)
(*                                                                         *)
(* A custom operator: complete the subscriber D frames after subscription  *)
(* and unsubscribe from the source, whatever the source does.              *)
(*                                                                         *)
(* Operator family: timing. Compared with DebounceTime the timer here is   *)
(* fixed at subscription, so there is no deadline variable: the timer is   *)
(* due exactly when now = D and the subscriber is still active.            *)
(*                                                                         *)
(* The marble test this spec generalises (D = 5):                          *)
(*                                                                         *)
(*     source   a-b-c-d-e|                                                 *)
(*     result   a-b-c|          source subscription  ^----!                *)
(***************************************************************************)
EXTENDS RxBase, Integers

CONSTANTS Values,
          D,         \* the duration, in frames
          MaxTime,   \* model bound on `now`, must be >= D
          MaxLen     \* model bound on source values

ASSUME D \in Nat /\ D >= 1 /\ MaxTime >= D

VARIABLES now,
          in, inDone,      \* what the source delivered, with frame stamps
          out, outDone,    \* what the subscriber received
          connected        \* BOOLEAN: still subscribed to the source?

vars == <<now, in, inDone, out, outDone, connected>>

Event(v) == [t |-> now, v |-> v]

TypeOK == /\ now \in 0..MaxTime
          /\ in  \in Seq([t : 0..MaxTime, v : Values]) /\ inDone  \in Status
          /\ out \in Seq([t : 0..MaxTime, v : Values]) /\ outDone \in Status
          /\ connected \in BOOLEAN

(* timer(D) is due: the frame is D and it has not fired yet *)
TimerDue == outDone = "active" /\ now = D

Init == /\ now = 0
        /\ in  = <<>> /\ inDone  = "active"
        /\ out = <<>> /\ outDone = "active"
        /\ connected = TRUE

-----------------------------------------------------------------------------
(* Actions *)

(* Time advances one frame, but not past a due timer.                      *)
Tick == /\ now < MaxTime /\ ~TimerDue
        /\ now' = now + 1
        /\ UNCHANGED <<in, inDone, out, outDone, connected>>

(* The source delivers v; it passes straight through.                      *)
SourceNext(v) ==
  /\ connected /\ inDone = "active" /\ Len(in) < MaxLen
  /\ in'  = Append(in, Event(v))
  /\ out' = Append(out, Event(v))
  /\ UNCHANGED <<now, inDone, outDone, connected>>

(* The source terminates first; the timer is torn down with it.            *)
SourceEnd(how) ==
  /\ connected /\ inDone = "active"
  /\ inDone'    = how
  /\ outDone'   = how
  /\ connected' = FALSE
  /\ UNCHANGED <<now, in, out>>

(* timer(D) fires: complete the subscriber, unsubscribe from the source.   *)
Fire == /\ TimerDue
        /\ outDone'   = "complete"
        /\ connected' = FALSE
        /\ UNCHANGED <<now, in, inDone, out>>

Done == Terminal(outDone) /\ now = MaxTime /\ UNCHANGED vars

Next == \/ Tick
        \/ \E v \in Values : SourceNext(v)
        \/ \E how \in {"complete", "error"} : SourceEnd(how)
        \/ Fire
        \/ Done

(* Fairness only on time and on the timer. Nothing is assumed about the    *)
(* source, which is the whole point of the operator.                       *)
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Fire)

-----------------------------------------------------------------------------
(* Invariants *)

NoEmitAfterDeadline  == \A k \in DOMAIN out : out[k].t <= D
PassThrough          == out = in
TerminatedByDeadline == now > D => Terminal(outDone)
UnsubscribedWhenDone == Terminal(outDone) => ~connected
ActiveMeansConnected == outDone = "active" => connected

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract         == [][Contract(in, inDone) /\ Contract(out, outDone)]_vars
NoDeliveryAfterUnsubscribe == [][~connected => UNCHANGED in]_vars

(* Liveness: every subscription ends, whatever the source does.            *)
Terminates == <>Terminal(outDone)

=============================================================================
