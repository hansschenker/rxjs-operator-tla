----------------------------- MODULE RetryOnShare -----------------------------
(***************************************************************************)
(* retry and share composed, in the two orders people write them:          *)
(*                                                                         *)
(*   Placement = "before"   shared$ = source$.pipe(retry(Count), share())  *)
(*                          every subscription: shared$                    *)
(*                                                                         *)
(*   Placement = "after"    shared$ = source$.pipe(share())                *)
(*                          s \in Retrying: shared$.pipe(retry(Count))     *)
(*                          others:         shared$                        *)
(*                                                                         *)
(* "before" is one retry for everybody: the subject never sees an error    *)
(* until the retries are used up, and every subscription receives the      *)
(* values of every attempt. "after" is a retry per subscription: the       *)
(* source's error reaches every current subscription, the ones without a   *)
(* retry end there, and the ones with a retry resubscribe to the shared    *)
(* stream, which re-executes the source if share() has reset its subject. *)
(*                                                                         *)
(* That last condition is the trap this module demonstrates. share()      *)
(* resets on error by default (ResetOnError = TRUE). With                  *)
(* share({resetOnError: false}) the subject stays errored, a retry's      *)
(* resubscription errors again at once, and all retries are used up       *)
(* without the source running a second time.                              *)
(*                                                                         *)
(* Built from Share.tla (one received stream per subscription, a shared   *)
(* subject, a connection count) and Retry.tla (a counter per retry).      *)
(* share()'s replay buffer and manual unsubscription are left out.        *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets

CONSTANTS Subs,            \* subscription ids; each subscribes once
          Retrying,        \* which of them apply retry(Count); used when Placement = "after"
          Values,
          Count,           \* retries allowed
          Placement,       \* "before" | "after"
          ResetOnError,    \* share()'s resetOnError; TRUE by default in RxJS 7
          MaxLen           \* model bound: values per source execution

ASSUME Retrying \subseteq Subs
ASSUME Placement \in {"before", "after"} /\ ResetOnError \in BOOLEAN
ASSUME Count \in Nat /\ Count >= 1

VARIABLES sub,            \* [Subs -> {"idle", "on", "error", "complete"}]
          received,       \* [Subs -> Seq(Values)]: everything a subscription received
          mark,           \* [Subs -> Nat]: Len(received) when it last joined a connection
          conn,           \* [Subs -> Nat]: the connection it is receiving from
          soFar,          \* [Subs -> Nat]: retries used by each downstream retry
          sharedSoFar,    \* retries used by the upstream retry
          subject,        \* "none" | "live" | "error": share()'s subject
          srcSent,        \* values delivered by the current execution of the source
          connections,    \* how many times the source has been subscribed
          srcErrors,      \* how many times the source has errored
          srcCompletes    \* how many times the source has completed

vars == <<sub, received, mark, conn, soFar, sharedSoFar,
          subject, srcSent, connections, srcErrors, srcCompletes>>

RefCount   == Cardinality({s \in Subs : sub[s] = "on"})
Retries(s) == Placement = "after" /\ s \in Retrying
Exhausted(s) == soFar[s] = Count

TypeOK == /\ sub \in [Subs -> {"idle", "on", "error", "complete"}]
          /\ received \in [Subs -> Seq(Values)]
          /\ mark \in [Subs -> Nat] /\ conn \in [Subs -> Nat]
          /\ soFar \in [Subs -> 0..Count] /\ sharedSoFar \in 0..Count
          /\ subject \in {"none", "live", "error"}
          /\ srcSent \in Seq(Values)
          /\ connections \in Nat /\ srcErrors \in Nat /\ srcCompletes \in Nat

Init == /\ sub = [s \in Subs |-> "idle"] /\ received = [s \in Subs |-> <<>>]
        /\ mark = [s \in Subs |-> 0] /\ conn = [s \in Subs |-> 0]
        /\ soFar = [s \in Subs |-> 0] /\ sharedSoFar = 0
        /\ subject = "none" /\ srcSent = <<>>
        /\ connections = 0 /\ srcErrors = 0 /\ srcCompletes = 0

-----------------------------------------------------------------------------
(* Actions *)

(* Subscription s subscribes to the shared stream, for the first time or   *)
(* as a retry. With no subject, share() creates one and subscribes the     *)
(* source: a new connection. An errored subject (no reset) errors s at     *)
(* once.                                                                   *)
Join(s) ==
  LET fresh == subject = "none"
      subj  == IF fresh THEN "live" ELSE subject
      cnum  == IF fresh THEN connections + 1 ELSE connections
  IN /\ subject'     = subj
     /\ srcSent'     = IF fresh THEN <<>> ELSE srcSent
     /\ connections' = cnum
     /\ sub'  = [sub  EXCEPT ![s] = IF subj = "live" THEN "on" ELSE subj]
     /\ mark' = [mark EXCEPT ![s] = Len(received[s])]
     /\ conn' = [conn EXCEPT ![s] = cnum]

Subscribe(s) ==
  /\ sub[s] = "idle"
  /\ Join(s)
  /\ UNCHANGED <<received, soFar, sharedSoFar, srcErrors, srcCompletes>>

(* A downstream retry resubscribes after the shared stream errored.        *)
Retry(s) ==
  /\ Retries(s) /\ sub[s] = "error" /\ soFar[s] < Count
  /\ soFar' = [soFar EXCEPT ![s] = @ + 1]
  /\ Join(s)
  /\ UNCHANGED <<received, sharedSoFar, srcErrors, srcCompletes>>

(* The source delivers v to the subject, which multicasts it.              *)
SourceNext(v) ==
  /\ subject = "live" /\ Len(srcSent) < MaxLen
  /\ srcSent'  = Append(srcSent, v)
  /\ received' = [t \in Subs |-> IF sub[t] = "on" THEN Append(received[t], v) ELSE received[t]]
  /\ UNCHANGED <<sub, mark, conn, soFar, sharedSoFar, subject, connections, srcErrors, srcCompletes>>

(* The source completes: share() resets, every subscription completes.    *)
SourceComplete ==
  /\ subject = "live"
  /\ srcCompletes' = srcCompletes + 1
  /\ subject' = "none"
  /\ sub' = [t \in Subs |-> IF sub[t] = "on" THEN "complete" ELSE sub[t]]
  /\ UNCHANGED <<received, mark, conn, soFar, sharedSoFar, srcSent, connections, srcErrors>>

(* The source errors. Upstream retry with retries left: the source is      *)
(* subscribed again and nobody downstream notices. Otherwise the subject  *)
(* receives the error, resets or not, and every current subscription      *)
(* receives it.                                                            *)
SourceError ==
  /\ subject = "live"
  /\ srcErrors' = srcErrors + 1
  /\ IF Placement = "before" /\ sharedSoFar < Count
       THEN /\ sharedSoFar' = sharedSoFar + 1
            /\ connections' = connections + 1
            /\ srcSent'     = <<>>
            /\ mark' = [t \in Subs |-> IF sub[t] = "on" THEN Len(received[t]) ELSE mark[t]]
            /\ conn' = [t \in Subs |-> IF sub[t] = "on" THEN connections + 1 ELSE conn[t]]
            /\ UNCHANGED <<sub, subject>>
       ELSE /\ subject' = IF ResetOnError THEN "none" ELSE "error"
            /\ sub' = [t \in Subs |-> IF sub[t] = "on" THEN "error" ELSE sub[t]]
            /\ UNCHANGED <<sharedSoFar, connections, srcSent, mark, conn>>
  /\ UNCHANGED <<received, soFar, srcCompletes>>

CanRetry(s) == Retries(s) /\ sub[s] = "error" /\ soFar[s] < Count
Quiescent == subject /= "live" /\ \A s \in Subs : sub[s] /= "idle" /\ ~CanRetry(s)
Done == Quiescent /\ UNCHANGED vars

Next == \/ \E s \in Subs : Subscribe(s) \/ Retry(s)
        \/ \E v \in Values : SourceNext(v)
        \/ SourceComplete
        \/ SourceError
        \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants that hold for both placements *)

OnMeansLive == RefCount > 0 => subject = "live"

(* What a subscription has received since it joined its current connection *)
(* is a suffix of that connection's values: multicast keeps everyone in    *)
(* sync at the tail, across retries too.                                   *)
SinceJoin(s) == SubSeq(received[s], mark[s] + 1, Len(received[s]))
InSyncAtTail == \A s \in Subs : sub[s] = "on" =>
                  \E i \in 1..(Len(srcSent) + 1) : SinceJoin(s) = SubSeq(srcSent, i, Len(srcSent))

(* share() de-duplicates retries: every termination of the source causes   *)
(* at most one re-execution, however many subscriptions retry.             *)
OneExecutionPerTermination == connections <= 1 + srcErrors + srcCompletes

RetriesBounded == sharedSoFar <= Count /\ \A s \in Subs : soFar[s] <= Count

-----------------------------------------------------------------------------
(* Invariants that separate the placements *)

(* A subscription without its own retry sees an error only after more     *)
(* than Count source errors. Holds for retry-before-share; fails for       *)
(* retry-after-share, where the first error reaches it.                    *)
SharedProtection == \A s \in Subs \ Retrying : sub[s] = "error" => srcErrors > Count

(* With retry upstream, nobody sees an error until the retries are gone.   *)
NoErrorBeforeExhaustion == Placement = "before" => \A s \in Subs : sub[s] = "error" => sharedSoFar = Count

(* A downstream retry that has used all its retries has caused the source  *)
(* to run again each time. Holds with resetOnError; fails without it,      *)
(* where the retries are used up against the same errored subject.         *)
RetriesReexecute == \A s \in Subs :
  (Retries(s) /\ Exhausted(s) /\ sub[s] = "error") => connections >= 1 + Count

-----------------------------------------------------------------------------
(* Properties *)

(* The Observable contract, seen from the end of each subscription's      *)
(* pipeline: a downstream retry that still has retries left has received   *)
(* the error, but its subscriber has not.                                  *)
EndStatus(s) == CASE sub[s] \in {"idle", "on"}         -> "active"
                  [] sub[s] = "complete"               -> "complete"
                  [] sub[s] = "error" /\ CanRetry(s)   -> "active"
                  [] sub[s] = "error" /\ ~CanRetry(s)  -> "error"
PerSubscriberContract == [][\A s \in Subs : Contract(received[s], EndStatus(s))]_vars

(* A value reaches every current subscription in the same step.           *)
MulticastStep == [][Len(srcSent') = Len(srcSent) + 1 =>
                     \A s \in Subs : sub[s] = "on" => received'[s] = Append(received[s], Last(srcSent'))]_vars

(* With retry downstream, a source error reaches every current             *)
(* subscription, retrying or not.                                          *)
ErrorReachesEveryone == [][(Placement = "after" /\ srcErrors' = srcErrors + 1) =>
                            \A s \in Subs : sub[s] = "on" => sub'[s] = "error"]_vars

=============================================================================
