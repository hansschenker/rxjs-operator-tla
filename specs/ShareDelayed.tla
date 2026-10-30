----------------------------- MODULE ShareDelayed -----------------------------
(***************************************************************************)
(* share() with a delayed reset:                                           *)
(*                                                                         *)
(*     share({ resetOnRefCountZero: () => timer(ResetDelay) })             *)
(*                                                                         *)
(* and, with BufferSize > 0, the same with a ReplaySubject connector:      *)
(*                                                                         *)
(*     share({ connector: () => new ReplaySubject(BufferSize),             *)
(*             resetOnRefCountZero: () => timer(ResetDelay) })             *)
(*                                                                         *)
(* When the last subscription leaves, share() does not tear the            *)
(* connection down at once; it starts the notifier and resets only when   *)
(* that delivers. A subscription arriving before then cancels the reset   *)
(* and joins the still-running connection: the "grace period" that keeps *)
(* a websocket or a cache alive across a route change. ResetDelay = 0 is  *)
(* the default share(), which resets immediately.                          *)
(*                                                                         *)
(* Share.tla showed the two extremes: reset at once (no unobserved         *)
(* execution, but a re-execution on every rejoin) and never (a leak). The  *)
(* delay is the middle: the source may run unobserved, but for at most    *)
(* ResetDelay frames, which the invariant GraceBounded states as a         *)
(* deadline. The remaining question is the boundary frame, where the      *)
(* reset and a new subscription race; TLC explores both orders.           *)
(*                                                                         *)
(* Built from Share.tla (ResetOnComplete and ResetOnError fixed at TRUE,   *)
(* as in share()) and the Tick machinery of part 04.                       *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets, Integers

CONSTANTS Subs,          \* subscription ids; each subscribes once
          Values,
          BufferSize,    \* 0 for a Subject, n for a ReplaySubject(n)
          ResetDelay,    \* frames the connection is kept after the last leaves; 0 = at once
          MaxLen,        \* model bound: values per connection
          MaxTime        \* model bound on now

ASSUME BufferSize \in Nat /\ ResetDelay \in Nat /\ MaxLen \in Nat /\ MaxTime \in Nat

VARIABLES now,
          sub,           \* [Subs -> {"idle", "on", "complete", "error", "off"}]
          received,      \* [Subs -> Seq(Values)]
          conn,          \* [Subs -> Nat]: the connection each joined (0 = not yet)
          subject,       \* "none" | "live": the shared subject (terminals reset it)
          buffer,        \* the ReplaySubject's buffer; always empty for a Subject
          srcSent,       \* values delivered by the current connection
          connections,   \* how many times the source has been subscribed
          resetAt,       \* the frame the pending reset fires; Never when none is pending
          lastResetAt,   \* the frame the most recent reset fired; Never before the first
          resets,        \* how many delayed resets have fired
          terminations   \* how many times the source has completed or errored

vars == <<now, sub, received, conn, subject, buffer, srcSent, connections,
          resetAt, lastResetAt, resets, terminations>>

(* A reset scheduled past the horizon never fires in the model, but it is *)
(* still a pending reset, so the marker for "none pending" lies beyond    *)
(* every frame a reset can be scheduled for.                              *)
Never == MaxTime + ResetDelay + 1

RefCount == Cardinality({s \in Subs : sub[s] = "on"})

(* The grace period: a live connection with nobody subscribed.             *)
Grace == subject = "live" /\ RefCount = 0
ResetDue == Grace /\ now = resetAt

Max(a, b) == IF a >= b THEN a ELSE b
Min(a, b) == IF a <= b THEN a ELSE b

TypeOK == /\ now \in 0..MaxTime
          /\ sub \in [Subs -> {"idle", "on", "complete", "error", "off"}]
          /\ received \in [Subs -> Seq(Values)] /\ conn \in [Subs -> Nat]
          /\ subject \in {"none", "live"}
          /\ buffer \in Seq(Values) /\ Len(buffer) <= BufferSize
          /\ srcSent \in Seq(Values)
          /\ connections \in Nat /\ resets \in Nat /\ terminations \in Nat
          /\ resetAt \in 0..Never /\ lastResetAt \in 0..Never

Init == /\ now = 0
        /\ sub = [s \in Subs |-> "idle"] /\ received = [s \in Subs |-> <<>>] /\ conn = [s \in Subs |-> 0]
        /\ subject = "none" /\ buffer = <<>> /\ srcSent = <<>>
        /\ connections = 0 /\ resetAt = Never /\ lastResetAt = Never
        /\ resets = 0 /\ terminations = 0

-----------------------------------------------------------------------------
(* Actions *)

(* Time advances, but not past a due reset.                                *)
Tick == /\ now < MaxTime /\ ~ResetDue
        /\ now' = now + 1
        /\ UNCHANGED <<sub, received, conn, subject, buffer, srcSent, connections,
                       resetAt, lastResetAt, resets, terminations>>

(* A subscription arrives. With a live subject it joins it, which also     *)
(* cancels a pending reset. With none, share() subscribes the source.      *)
Subscribe(s) ==
  /\ sub[s] = "idle"
  /\ LET fresh == subject = "none"
         cnum  == IF fresh THEN connections + 1 ELSE connections
     IN /\ subject'     = "live"
        /\ srcSent'     = IF fresh THEN <<>> ELSE srcSent
        /\ connections' = cnum
        /\ sub'      = [sub      EXCEPT ![s] = "on"]
        /\ received' = [received EXCEPT ![s] = buffer]
        /\ conn'     = [conn     EXCEPT ![s] = cnum]
        /\ resetAt'  = Never
  /\ UNCHANGED <<now, buffer, lastResetAt, resets, terminations>>

(* A subscription leaves. If it was the last, the reset is scheduled, or   *)
(* done at once when ResetDelay = 0.                                       *)
Unsubscribe(s) ==
  /\ sub[s] = "on"
  /\ sub' = [sub EXCEPT ![s] = "off"]
  /\ IF RefCount = 1
       THEN IF ResetDelay = 0
              THEN /\ subject' = "none" /\ buffer' = <<>>
                   /\ resetAt' = Never /\ lastResetAt' = now /\ resets' = resets + 1
              ELSE /\ resetAt' = now + ResetDelay
                   /\ UNCHANGED <<subject, buffer, lastResetAt, resets>>
       ELSE UNCHANGED <<subject, buffer, resetAt, lastResetAt, resets>>
  /\ UNCHANGED <<now, received, conn, srcSent, connections, terminations>>

(* The notifier delivers: the connection is torn down.                     *)
ResetFire ==
  /\ ResetDue
  /\ subject' = "none" /\ buffer' = <<>>
  /\ resetAt' = Never /\ lastResetAt' = now /\ resets' = resets + 1
  /\ UNCHANGED <<now, sub, received, conn, srcSent, connections, terminations>>

(* The source delivers v: buffered, and multicast to whoever is on. During *)
(* the grace period that is nobody.                                        *)
SourceNext(v) ==
  /\ subject = "live" /\ Len(srcSent) < MaxLen
  /\ srcSent'  = Append(srcSent, v)
  /\ buffer'   = LET b == Append(buffer, v) IN IF Len(b) > BufferSize THEN Tail(b) ELSE b
  /\ received' = [t \in Subs |-> IF sub[t] = "on" THEN Append(received[t], v) ELSE received[t]]
  /\ UNCHANGED <<now, sub, conn, subject, connections, resetAt, lastResetAt, resets, terminations>>

(* The source terminates: share() resets at once, cancelling any pending  *)
(* delayed reset, and every current subscription gets the terminal.       *)
SourceEnd(how) ==
  /\ subject = "live"
  /\ subject' = "none" /\ buffer' = <<>> /\ resetAt' = Never
  /\ terminations' = terminations + 1
  /\ sub' = [t \in Subs |-> IF sub[t] = "on" THEN how ELSE sub[t]]
  /\ UNCHANGED <<now, received, conn, srcSent, connections, lastResetAt, resets>>

Quiescent == subject = "none" /\ \A s \in Subs : sub[s] /= "idle"
Done == (Quiescent \/ now = MaxTime) /\ UNCHANGED vars

Next == \/ Tick
        \/ \E s \in Subs : Subscribe(s) \/ Unsubscribe(s)
        \/ ResetFire
        \/ \E v \in Values : SourceNext(v)
        \/ \E how \in {"complete", "error"} : SourceEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants inherited from Share.tla *)

OnMeansLive == RefCount > 0 => subject = "live"

BufferIsRecent == subject = "live" =>
                    buffer = SubSeq(srcSent, Max(1, Len(srcSent) - BufferSize + 1), Len(srcSent))

Window(s) == \E i \in 1..(Len(srcSent) + 1) :
               /\ i + Len(received[s]) - 1 <= Len(srcSent)
               /\ received[s] = SubSeq(srcSent, i, i + Len(received[s]) - 1)
NoGaps == \A s \in Subs : (conn[s] = connections /\ conn[s] > 0) => Window(s)

InSyncAtTail == \A s \in Subs : sub[s] = "on" =>
                  \E i \in 1..(Len(srcSent) + 1) : received[s] = SubSeq(srcSent, i, Len(srcSent))

ReplayCoversBuffer == \A s \in Subs :
  (sub[s] \in {"on", "complete", "error"} /\ conn[s] = connections)
    => Len(received[s]) >= Min(BufferSize, Len(srcSent))

-----------------------------------------------------------------------------
(* Invariants about the grace period *)

(* A reset is pending exactly during a grace period.                       *)
ResetPendingIffGrace == (resetAt /= Never) <=> Grace

(* The source never runs unobserved for more than ResetDelay frames: the   *)
(* deadline form of "an unobserved connection is eventually torn down".    *)
GraceBounded == Grace => (now <= resetAt /\ resetAt <= now + ResetDelay)

(* With an immediate reset there is no grace period at all (Share.tla's   *)
(* SourceStopsWhenUnused).                                                 *)
NoGraceWhenImmediate == ResetDelay = 0 => ~Grace

(* Every connection after the first was preceded by a reset or a terminal. *)
OneExecutionPerTeardown == connections <= 1 + resets + terminations

-----------------------------------------------------------------------------
(* Properties *)

SubStatus(s) == CASE sub[s] \in {"idle", "on", "off"} -> "active"
                  [] sub[s] = "complete"              -> "complete"
                  [] sub[s] = "error"                 -> "error"
PerSubscriberContract == [][\A s \in Subs : Contract(received[s], SubStatus(s))]_vars

MulticastStep == [][Len(srcSent') = Len(srcSent) + 1 =>
                     \A s \in Subs : sub[s] = "on" => received'[s] = Append(received[s], Last(srcSent'))]_vars

Joins == \E s \in Subs : sub[s] = "idle" /\ sub'[s] = "on"

(* Joining a live connection never re-executes the source: this is what   *)
(* the grace period buys.                                                  *)
JoinKeepsConnection == [][(subject = "live" /\ Joins) => connections' = connections]_vars

(* A live, observed connection is only ever torn down by a terminal, never *)
(* by a reset.                                                             *)
ObservedIsNeverReset == [][(subject = "live" /\ subject' = "none" /\ RefCount > 0)
                            => terminations' = terminations + 1]_vars

(* Demonstration, expected to fail with a plain Subject: every value the   *)
(* source delivers reaches somebody. During the grace period it does not; *)
(* with a ReplaySubject it is at least buffered for the next to join.      *)
NoValueUnobserved == [][Len(srcSent') = Len(srcSent) + 1 => RefCount > 0]_vars

(* Demonstration, expected to fail: a subscription arriving in the frame  *)
(* in which the reset was due keeps the connection. It does when it comes *)
(* before the reset; when the reset fires first it re-executes the source.*)
(* TLC finds the second order.                                             *)
JoinAtDeadlineKeepsConnection == [][(Joins /\ now = lastResetAt) => connections' = connections]_vars

=============================================================================
