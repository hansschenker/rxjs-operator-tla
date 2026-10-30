-------------------------------- MODULE Share --------------------------------
(***************************************************************************)
(* share() and shareReplay(n): one source subscription shared by many      *)
(* subscriptions.                                                          *)
(*                                                                         *)
(* RxJS 7 implements both with a single operator, share(config), and so    *)
(* does this module. The constants are that configuration:                 *)
(*                                                                         *)
(*   share()                          BufferSize          = 0              *)
(*                                    ResetOnComplete     = TRUE           *)
(*                                    ResetOnError        = TRUE           *)
(*                                    ResetOnRefCountZero = TRUE           *)
(*                                                                         *)
(*   shareReplay(n)                   BufferSize          = n              *)
(*                                    ResetOnComplete     = FALSE          *)
(*                                    ResetOnError        = TRUE           *)
(*                                    ResetOnRefCountZero = FALSE          *)
(*                                                                         *)
(*   shareReplay({bufferSize: n,      as shareReplay(n), with              *)
(*                refCount: true})    ResetOnRefCountZero = TRUE           *)
(*                                                                         *)
(* Operator family: multicasting. This is the first spec with several      *)
(* output streams, one per subscription, that start and stop independently *)
(* of each other and of the source. TLC explores every interleaving of     *)
(* subscribe, unsubscribe and source notifications, which is exactly where *)
(* the refCount bugs live.                                                 *)
(*                                                                         *)
(* How the RxJS 7 implementation maps onto the variables:                  *)
(*                                                                         *)
(*   subject   the shared Subject / ReplaySubject (undefined = "none")     *)
(*   buffer    the ReplaySubject's buffer (always empty for a Subject)     *)
(*   RefCount  the operator's refCount counter, derived here               *)
(*   reset()   subject' = "none" /\ buffer' = <<>>                         *)
(*                                                                         *)
(* A reset discards the subject; the next subscription creates a new one   *)
(* and re-subscribes to the source, which is a new "connection".           *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets, Integers

CONSTANTS Subs,                   \* subscription ids; each subscribes at most once
          Values,
          BufferSize,             \* 0 for share(), n for shareReplay(n)
          ResetOnComplete,        \* BOOLEAN
          ResetOnError,           \* BOOLEAN
          ResetOnRefCountZero,    \* BOOLEAN
          MaxLen,                 \* model bound: values per connection
          MaxConnections          \* model bound: subscriptions to the source

ASSUME BufferSize \in Nat /\ MaxLen \in Nat /\ MaxConnections \in Nat /\ MaxConnections >= 1
ASSUME {ResetOnComplete, ResetOnError, ResetOnRefCountZero} \subseteq BOOLEAN

VARIABLES sub,          \* [Subs -> SubState]: each subscription's lifecycle
          received,     \* [Subs -> Seq(Values)]: what each subscription received
          conn,         \* [Subs -> Nat]: the connection it joined (0 = not yet)
          subject,      \* "none" | "live" | "complete" | "error"
          buffer,       \* Seq(Values): the last BufferSize values of the connection
          srcSent,      \* Seq(Values): what the current connection delivered
          connections   \* Nat: how many times the source has been subscribed

vars == <<sub, received, conn, subject, buffer, srcSent, connections>>

SubState == {"idle",       \* has not subscribed yet
             "on",         \* subscribed and receiving
             "complete",   \* received complete
             "error",      \* received error
             "off"}        \* unsubscribed

RefCount == Cardinality({s \in Subs : sub[s] = "on"})

Max(a, b) == IF a >= b THEN a ELSE b
Min(a, b) == IF a <= b THEN a ELSE b

TypeOK == /\ sub \in [Subs -> SubState]
          /\ received \in [Subs -> Seq(Values)]
          /\ conn \in [Subs -> 0..MaxConnections]
          /\ subject \in {"none", "live", "complete", "error"}
          /\ buffer \in Seq(Values) /\ Len(buffer) <= BufferSize
          /\ srcSent \in Seq(Values)
          /\ connections \in 0..MaxConnections

Init == /\ sub = [s \in Subs |-> "idle"]
        /\ received = [s \in Subs |-> <<>>]
        /\ conn = [s \in Subs |-> 0]
        /\ subject = "none" /\ buffer = <<>>
        /\ srcSent = <<>> /\ connections = 0

-----------------------------------------------------------------------------
(* Actions *)

(* A new subscription arrives. If there is no subject, one is created and  *)
(* the source is subscribed (a new connection). The subscription then      *)
(* subscribes to the subject: a ReplaySubject replays its buffer first,    *)
(* and a subject that has already terminated terminates it at once.        *)
Subscribe(s) ==
  /\ sub[s] = "idle"
  /\ LET fresh == subject = "none"
         subj  == IF fresh THEN "live" ELSE subject
         buf   == IF fresh THEN <<>> ELSE buffer
         cnum  == IF fresh THEN connections + 1 ELSE connections
     IN /\ fresh => connections < MaxConnections
        /\ subject'     = subj
        /\ buffer'      = buf
        /\ srcSent'     = IF fresh THEN <<>> ELSE srcSent
        /\ connections' = cnum
        /\ sub'      = [sub      EXCEPT ![s] = IF subj = "live" THEN "on" ELSE subj]
        /\ received' = [received EXCEPT ![s] = buf]
        /\ conn'     = [conn     EXCEPT ![s] = cnum]

(* A subscription leaves. If it was the last one and the operator resets   *)
(* on refCount zero, the subject is discarded and the source unsubscribed. *)
Unsubscribe(s) ==
  /\ sub[s] = "on"
  /\ sub' = [sub EXCEPT ![s] = "off"]
  /\ IF RefCount = 1 /\ ResetOnRefCountZero
       THEN subject' = "none" /\ buffer' = <<>>
       ELSE UNCHANGED <<subject, buffer>>
  /\ UNCHANGED <<received, conn, srcSent, connections>>

(* The source delivers v: the buffer is updated and every current          *)
(* subscription receives it in this same step (multicast).                 *)
SourceNext(v) ==
  /\ subject = "live" /\ Len(srcSent) < MaxLen
  /\ srcSent'  = Append(srcSent, v)
  /\ buffer'   = LET b == Append(buffer, v) IN IF Len(b) > BufferSize THEN Tail(b) ELSE b
  /\ received' = [t \in Subs |-> IF sub[t] = "on" THEN Append(received[t], v) ELSE received[t]]
  /\ UNCHANGED <<sub, conn, subject, connections>>

(* The source terminates: every current subscription gets the terminal.    *)
(* Depending on the configuration the subject is reset (so that a later   *)
(* subscription re-subscribes the source) or kept in its terminal state   *)
(* (so that a later subscription is terminated immediately, after replay).*)
SourceEnd(how) ==
  /\ subject = "live"
  /\ LET reset == IF how = "complete" THEN ResetOnComplete ELSE ResetOnError
     IN /\ subject' = IF reset THEN "none" ELSE how
        /\ buffer'  = IF reset THEN <<>> ELSE buffer
  /\ sub' = [t \in Subs |-> IF sub[t] = "on" THEN how ELSE sub[t]]
  /\ UNCHANGED <<received, conn, srcSent, connections>>

CanSubscribe(s) == sub[s] = "idle" /\ (subject /= "none" \/ connections < MaxConnections)
Quiescent == subject /= "live" /\ \A s \in Subs : ~CanSubscribe(s)
Done == Quiescent /\ UNCHANGED vars

Next == \/ \E s \in Subs : Subscribe(s) \/ Unsubscribe(s)
        \/ \E v \in Values : SourceNext(v)
        \/ \E how \in {"complete", "error"} : SourceEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants *)

JoinedIffSubscribed == \A s \in Subs : (sub[s] = "idle") <=> (conn[s] = 0)

(* A subscription is receiving only while the shared source is live.       *)
OnMeansLive == RefCount > 0 => subject = "live"

(* The refCount rule: the source never runs with nobody subscribed.        *)
(* Holds for share() and shareReplay({refCount: true}). Fails for          *)
(* shareReplay(n), which keeps the source alive: see Share_leak_demo.cfg.  *)
SourceStopsWhenUnused == subject = "live" => RefCount > 0

(* The buffer is the last BufferSize values of the current connection.     *)
BufferIsRecent == subject /= "none" =>
                    buffer = SubSeq(srcSent, Max(1, Len(srcSent) - BufferSize + 1), Len(srcSent))

(* Every subscription receives a contiguous window of its connection's     *)
(* values: no gaps, no duplicates, no reordering.                          *)
Window(s) == \E i \in 1..(Len(srcSent) + 1) :
               /\ i + Len(received[s]) - 1 <= Len(srcSent)
               /\ received[s] = SubSeq(srcSent, i, i + Len(received[s]) - 1)
NoGaps == \A s \in Subs : conn[s] = connections => Window(s)

(* Everyone currently subscribed has seen everything up to the latest      *)
(* value: all live subscriptions agree on the tail of the stream.          *)
Suffix(s) == \E i \in 1..(Len(srcSent) + 1) : received[s] = SubSeq(srcSent, i, Len(srcSent))
InSyncAtTail == \A s \in Subs : sub[s] = "on" => Suffix(s)

(* Replay: a subscription receives at least the last BufferSize values of  *)
(* its connection, however late it joined.                                 *)
ReplayCoversBuffer == \A s \in Subs :
  (sub[s] \in {"on", "complete", "error"} /\ conn[s] = connections)
    => Len(received[s]) >= Min(BufferSize, Len(srcSent))

(* Demonstration, expected to fail for share(): the source is executed     *)
(* again for a subscription that arrives after a reset.                    *)
SingleExecution == connections <= 1

-----------------------------------------------------------------------------
(* Properties *)

SubStatus(s) == CASE sub[s] \in {"idle", "on", "off"} -> "active"
                  [] sub[s] = "complete"              -> "complete"
                  [] sub[s] = "error"                 -> "error"

(* Every subscription's stream respects the Observable contract.           *)
PerSubscriberContract == [][\A s \in Subs : Contract(received[s], SubStatus(s))]_vars

(* A value from the source reaches every current subscription in the same  *)
(* step, in order.                                                         *)
MulticastStep == [][srcSent' /= srcSent =>
                     \A s \in Subs : sub[s] = "on" => received'[s] = Append(received[s], Last(srcSent'))]_vars

(* Nothing is delivered to a subscription that has ended or left.          *)
NoDeliveryAfterEnd == [][\A s \in Subs :
                          sub[s] \in {"off", "complete", "error"} => received'[s] = received[s]]_vars

(* shareReplay: once the source has completed it is never subscribed again.*)
CompletedStays == [][subject = "complete" => subject' = "complete"]_vars

=============================================================================
