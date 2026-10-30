------------------------------- MODULE Flatten -------------------------------
(***************************************************************************)
(* The four higher-order mapping operators in one specification:           *)
(*                                                                         *)
(*     switchMap    Strategy = "switch"    cancel the running inner        *)
(*     mergeMap     Strategy = "merge"     run all inners concurrently     *)
(*     concatMap    Strategy = "concat"    queue the new inner             *)
(*     exhaustMap   Strategy = "exhaust"   drop the new inner              *)
(*                                                                         *)
(* Operator family: flattening. The k-th outer value is projected to an    *)
(* inner Observable that delivers <<k, 1>> .. <<k, MaxInner>> and then     *)
(* completes, or errors. The strategies differ only in what happens to a   *)
(* new inner while an older one is still live, so that difference is       *)
(* isolated in one place: the CASE inside OuterNext.                       *)
(*                                                                         *)
(* Inner values arrive as separate steps, so TLC explores every            *)
(* interleaving of outer and inner events. That is where the bugs are.     *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets

CONSTANTS Strategy,   \* "switch" | "merge" | "concat" | "exhaust"
          MaxOuter,   \* model bound: outer values
          MaxInner    \* each inner delivers exactly this many values

ASSUME Strategy \in {"switch", "merge", "concat", "exhaust"}
ASSUME MaxOuter \in Nat /\ MaxInner \in Nat /\ MaxInner >= 1

VARIABLES outerDone,   \* Status of the outer source
          inner,       \* Seq of [state, sent]: one record per outer value received
          out,         \* Seq of <<k, j>>: values delivered to the subscriber
          outDone,     \* Status delivered to the subscriber
          subscribed   \* BOOLEAN: still subscribed to the outer source?

vars == <<outerDone, inner, out, outDone, subscribed>>

InnerState == {"pending",     \* concat: queued behind an earlier inner
               "active",      \* subscribed; may deliver values
               "done",        \* completed
               "errored",     \* errored (tears everything down)
               "cancelled",   \* unsubscribed before it finished
               "dropped"}     \* exhaust: ignored because another inner was active

Rec(st, n) == [state |-> st, sent |-> n]

Active  == {k \in DOMAIN inner : inner[k].state = "active"}
Pending == {k \in DOMAIN inner : inner[k].state = "pending"}
Live    == Active \cup Pending

Quiet(f) == \A k \in DOMAIN f : f[k].state \in {"done", "errored", "cancelled", "dropped"}

SetState(f, S, st) ==
  [k \in DOMAIN f |-> IF k \in S THEN [f[k] EXCEPT !.state = st] ELSE f[k]]

Min(S) == CHOOSE m \in S : \A x \in S : m <= x

TypeOK == /\ outerDone \in Status /\ outDone \in Status /\ subscribed \in BOOLEAN
          /\ inner \in Seq([state : InnerState, sent : 0..MaxInner])
          /\ out \in Seq((1..MaxOuter) \X (1..MaxInner))

Init == /\ outerDone = "active" /\ inner = <<>>
        /\ out = <<>> /\ outDone = "active" /\ subscribed = TRUE

-----------------------------------------------------------------------------
(* Actions *)

(* The outer source delivers a value. The project function creates a new   *)
(* inner Observable; the strategy decides what to do with it.              *)
OuterNext ==
  /\ subscribed /\ outerDone = "active" /\ Len(inner) < MaxOuter
  /\ inner' =
       CASE Strategy = "switch"  -> Append(SetState(inner, Active, "cancelled"), Rec("active", 0))
         [] Strategy = "merge"   -> Append(inner, Rec("active", 0))
         [] Strategy = "concat"  -> Append(inner, Rec(IF Live = {} THEN "active" ELSE "pending", 0))
         [] Strategy = "exhaust" -> Append(inner, Rec(IF Active = {} THEN "active" ELSE "dropped", 0))
  /\ UNCHANGED <<outerDone, out, outDone, subscribed>>

(* An active inner delivers its next value.                                *)
InnerNext(k) ==
  /\ k \in Active /\ inner[k].sent < MaxInner
  /\ inner' = [inner EXCEPT ![k].sent = @ + 1]
  /\ out'   = Append(out, <<k, inner[k].sent + 1>>)
  /\ UNCHANGED <<outerDone, outDone, subscribed>>

(* An active inner completes. concatMap then starts the next queued one.   *)
(* The output completes once the outer has completed and nothing is live.  *)
InnerComplete(k) ==
  /\ k \in Active /\ inner[k].sent = MaxInner
  /\ LET done == [inner EXCEPT ![k].state = "done"]
         next == IF Strategy = "concat" /\ Pending /= {}
                   THEN [done EXCEPT ![Min(Pending)].state = "active"]
                   ELSE done
     IN /\ inner'   = next
        /\ outDone' = IF outerDone = "complete" /\ Quiet(next) THEN "complete" ELSE outDone
  /\ UNCHANGED <<outerDone, out, subscribed>>

(* An active inner errors: the error goes downstream and everything else   *)
(* is torn down.                                                           *)
InnerError(k) ==
  /\ k \in Active
  /\ inner'      = [SetState(inner, Live, "cancelled") EXCEPT ![k].state = "errored"]
  /\ outDone'    = "error"
  /\ subscribed' = FALSE
  /\ UNCHANGED <<outerDone, out>>

(* The outer completes. Live inners carry on; the output completes when    *)
(* they are all finished (possibly right now).                             *)
OuterComplete ==
  /\ subscribed /\ outerDone = "active"
  /\ outerDone'  = "complete"
  /\ outDone'    = IF Quiet(inner) THEN "complete" ELSE outDone
  /\ subscribed' = FALSE
  /\ UNCHANGED <<inner, out>>

OuterError ==
  /\ subscribed /\ outerDone = "active"
  /\ outerDone'  = "error"
  /\ inner'      = SetState(inner, Live, "cancelled")
  /\ outDone'    = "error"
  /\ subscribed' = FALSE
  /\ UNCHANGED out

Done == Terminal(outDone) /\ UNCHANGED vars

Next == \/ OuterNext \/ OuterComplete \/ OuterError
        \/ \E k \in DOMAIN inner : InnerNext(k) \/ InnerComplete(k) \/ InnerError(k)
        \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(* Same machine, weaker assumption: everything is fair except inner         *)
(* completion. An inner may deliver all of its values and then never       *)
(* complete, like an HTTP Observable that never closes.                    *)
SpecInnerMayHang == /\ Init /\ [][Next]_vars
                    /\ WF_vars(OuterNext) /\ WF_vars(OuterComplete)
                    /\ WF_vars(\E k \in DOMAIN inner : InnerNext(k))

-----------------------------------------------------------------------------
(* Invariants shared by all four strategies *)

ValuesOf(k) == SelectSeq(out, LAMBDA e : e[1] = k)

(* Each inner's values arrive in order, without gaps or duplicates.        *)
PerInnerOrder == \A k \in DOMAIN inner :
                   ValuesOf(k) = [j \in 1..inner[k].sent |-> <<k, j>>]

(* The output does not complete while anything could still deliver.       *)
NotCompleteWhileLive == outDone = "complete" => (outerDone = "complete" /\ Quiet(inner))

(* After an error nothing is left running.                                 *)
ErrorTearsDown == outDone = "error" => Live = {}

(* Inners that were never subscribed never deliver.                        *)
DroppedNeverDeliver == \A k \in DOMAIN inner : inner[k].state = "dropped" => inner[k].sent = 0

-----------------------------------------------------------------------------
(* Invariants that distinguish the strategies.                             *)
(* Which strategy satisfies which is recorded in the Flatten_*.cfg files.  *)

AtMostOneActive == Cardinality(Active) <= 1

(* Values are grouped by inner, in outer order: no interleaving.           *)
NoInterleaving  == \A i \in DOMAIN out : i + 1 \in DOMAIN out => out[i][1] <= out[i + 1][1]

(* Only the newest inner can be running (switch).                          *)
NewestOnly      == Active \subseteq {Len(inner)}

(* Inners are served strictly in arrival order (concat): everything before *)
(* the active one is finished, everything after it is still queued.        *)
InOrder         == \A k \in Active :
                     /\ \A j \in 1..(k - 1)          : inner[j].state \in {"done", "errored"}
                     /\ \A j \in (k + 1)..Len(inner) : inner[j].state = "pending"

(* No inner is cancelled unless the whole stream errored.                  *)
NoCancellation  == outDone /= "error" => \A k \in DOMAIN inner : inner[k].state /= "cancelled"

(* No inner is dropped.                                                    *)
NoDrop          == \A k \in DOMAIN inner : inner[k].state /= "dropped"

(* On completion every inner that was started has delivered everything.   *)
NothingLost     == outDone = "complete" => \A k \in DOMAIN inner : inner[k].sent = MaxInner

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(out, outDone)]_vars

(* A newly delivered value always comes from an inner that was active.     *)
OnlyActiveInnersDeliver == [][out' /= out => Last(out')[1] \in Active]_vars

(* Liveness: the output eventually terminates. Relies on weak fairness,    *)
(* i.e. on every inner eventually completing. Drop WF_vars(Next) from Spec  *)
(* and concatMap shows the classic stall behind an inner that never ends.  *)
Completes == <>Terminal(outDone)

(* Every queued inner eventually gets its turn. Under SpecInnerMayHang     *)
(* this fails for concatMap: inner 2 waits forever behind an inner 1 that  *)
(* never completes. See Flatten_stall_concat.cfg.                          *)
PendingInnersEventuallyRun == \A k \in 1..MaxOuter : [](k \in Pending => <>(k \notin Pending))

=============================================================================
