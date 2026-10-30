----------------------------- MODULE DebounceTime -----------------------------
(***************************************************************************)
(* debounceTime(D): deliver a value only once the source has been quiet    *)
(* for D frames after it. On complete, a pending value is flushed first.   *)
(* On error, a pending value is dropped.                                   *)
(*                                                                         *)
(* Operator family: timing. TLA+ has no clock, so time is a variable `now` *)
(* that a Tick action advances by one frame, exactly like the virtual time *)
(* of RxJS's TestScheduler. One marble frame is one Tick.                  *)
(*                                                                         *)
(* The one rule that makes this work: Tick is blocked while a timer is due *)
(* in the current frame, so a due timer always fires before time moves on. *)
(***************************************************************************)
EXTENDS RxBase, Integers

CONSTANTS Values,
          None,      \* model value: "no value pending"
          D,         \* the debounce duration, in frames
          MaxTime,   \* model bound on `now`
          MaxLen     \* model bound on source values

ASSUME D \in Nat /\ D >= 1

VARIABLES now,        \* current frame
          in, inDone,
          out, outDone,
          pending,    \* the most recent value, waiting for its timer; or None
          deadline    \* the frame in which pending is due

vars == <<now, in, inDone, out, outDone, pending, deadline>>

(* Notifications carry their frame (t) and, for outputs, how many inputs   *)
(* had been received when they were delivered (n). The count is what lets  *)
(* an invariant tell "input before this output" from "input after it"      *)
(* inside the same frame.                                                  *)
InEvent(v)  == [t |-> now, v |-> v]
OutEvent(v) == [t |-> now, v |-> v, n |-> Len(in)]

TypeOK == /\ now \in 0..MaxTime
          /\ in  \in Seq([t : 0..MaxTime, v : Values]) /\ inDone  \in Status
          /\ out \in Seq([t : 0..MaxTime, v : Values, n : 0..MaxLen]) /\ outDone \in Status
          /\ pending \in Values \cup {None}
          /\ deadline \in 0..MaxTime

TimerDue == pending /= None /\ now = deadline

Init == /\ now = 0
        /\ in  = <<>> /\ inDone  = "active"
        /\ out = <<>> /\ outDone = "active"
        /\ pending = None /\ deadline = 0

-----------------------------------------------------------------------------
(* Actions *)

(* Logical time advances one frame. A due timer must fire first.           *)
Tick == /\ now < MaxTime /\ ~TimerDue
        /\ now' = now + 1
        /\ UNCHANGED <<in, inDone, out, outDone, pending, deadline>>

(* The source delivers v: remember it and (re)start the timer.             *)
SourceNext(v) ==
  /\ inDone = "active" /\ Len(in) < MaxLen /\ now + D <= MaxTime
  /\ in'       = Append(in, InEvent(v))
  /\ pending'  = v
  /\ deadline' = now + D
  /\ UNCHANGED <<now, inDone, out, outDone>>

(* The timer fires: the remembered value goes out.                         *)
Fire == /\ TimerDue
        /\ out'     = Append(out, OutEvent(pending))
        /\ pending' = None
        /\ UNCHANGED <<now, in, inDone, outDone, deadline>>

(* On complete, a pending value is flushed before completing.              *)
SourceComplete ==
  /\ inDone = "active"
  /\ inDone'  = "complete" /\ outDone' = "complete"
  /\ out'     = IF pending /= None THEN Append(out, OutEvent(pending)) ELSE out
  /\ pending' = None
  /\ UNCHANGED <<now, in, deadline>>

(* On error, the pending value is dropped and the error passes through.    *)
SourceError ==
  /\ inDone = "active"
  /\ inDone'  = "error" /\ outDone' = "error"
  /\ pending' = None
  /\ UNCHANGED <<now, in, out, deadline>>

Done == Terminal(outDone) /\ UNCHANGED vars

Next == \/ Tick
        \/ \E v \in Values : SourceNext(v)
        \/ Fire
        \/ SourceComplete
        \/ SourceError
        \/ Done

(* Fairness only on the operator's own machinery: time advances and due    *)
(* timers fire. Nothing is assumed about the source.                       *)
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick) /\ WF_vars(Fire)

-----------------------------------------------------------------------------
(* Invariants *)

(* An output delivered by the timer carries the last input received, that  *)
(* input arrived exactly D frames earlier, and nothing arrived in between. *)
Debounced(e) == /\ e.n \in DOMAIN in
                /\ in[e.n].v = e.v
                /\ in[e.n].t = e.t - D

(* An output delivered by the completion flush carries the last input.     *)
Flushed(e) == /\ outDone = "complete" /\ e = Last(out)
              /\ e.n = Len(in) /\ e.v = Last(in).v

EveryOutputIsDebouncedOrFlushed == \A k \in DOMAIN out : Debounced(out[k]) \/ Flushed(out[k])

(* Timing bookkeeping *)
NoMoreOutThanIn        == Len(out) <= Len(in)
TimerNeverOverdue      == pending /= None => now <= deadline
NothingPendingWhenDone == Terminal(outDone) => pending = None
InputTimesMonotone     == \A i \in DOMAIN in : i + 1 \in DOMAIN in => in[i].t <= in[i + 1].t

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(in, inDone) /\ Contract(out, outDone)]_vars

(* Liveness: a pending value is always resolved, by firing, flushing or    *)
(* dropping. Needs fairness on Tick and Fire only.                         *)
PendingResolves == (pending /= None) ~> (pending = None)

=============================================================================
