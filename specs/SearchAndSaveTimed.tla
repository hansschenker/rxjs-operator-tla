-------------------------- MODULE SearchAndSaveTimed --------------------------
(***************************************************************************)
(* SearchAndSave.tla with two things the first version left out: saves    *)
(* take time, and saves can fail.                                          *)
(*                                                                         *)
(*     terms$.pipe(switchMap(search), concatMap(r => save(r).pipe(h)))     *)
(*                                                                         *)
(* where h is the handling of a failed save:                               *)
(*                                                                         *)
(*     SaveFailure = "propagate"    h = identity: the error ends the       *)
(*                                  pipeline, and the queued saves with it *)
(*     SaveFailure = "retryInner"   h = retry(Count): the save is retried  *)
(*                                  in place, the queue waits              *)
(*     SaveFailure = "catchInner"   h = catchError(() => EMPTY): the save  *)
(*                                  is skipped, the queue moves on         *)
(*                                                                         *)
(* A save attempt takes between SaveMin and SaveMax frames, chosen by the  *)
(* environment when the attempt starts. Time is the Tick machinery of     *)
(* part 04: a due save must finish or fail before the frame ends.          *)
(*                                                                         *)
(* The strategies are fixed at switchMap and concatMap; SearchAndSave.tla  *)
(* covers the others. There is no liveness property here: "every save is  *)
(* eventually acknowledged" is stated as the deadline invariant            *)
(* AckLatencyBounded instead, as part 04 recommends.                       *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets, Integers

CONSTANTS SaveFailure,        \* "propagate" | "retryInner" | "catchInner"
          Count,              \* retries per save, for retryInner
          SaveMin, SaveMax,   \* frames a save attempt takes
          MaxTerms,           \* model bound: search terms
          ResultsPerSearch,   \* each search delivers exactly this many results
          MaxTime             \* model bound on now

ASSUME SaveFailure \in {"propagate", "retryInner", "catchInner"}
ASSUME Count \in Nat /\ SaveMin \in Nat /\ SaveMax \in Nat /\ 1 <= SaveMin /\ SaveMin <= SaveMax
ASSUME MaxTerms \in Nat /\ ResultsPerSearch \in Nat /\ ResultsPerSearch >= 1 /\ MaxTime \in Nat

VARIABLES now,
          termsDone, subscribed,   \* the terms
          search,                  \* Seq of [state, sent]: one search per term
          mid, midDone,            \* results delivered into concatMap
          save,                    \* Seq of save records, one per result
          out, outDone,            \* acknowledgements delivered to the subscriber
          saveErrors               \* how many save attempts have failed

vars == <<now, termsDone, subscribed, search, mid, midDone, save, out, outDone, saveErrors>>

SearchState == {"active", "done", "cancelled"}
SaveState   == {"pending", "active", "done", "skipped", "cancelled"}

(* A save record:                                                          *)
(*   res        the result it saves                                        *)
(*   arrivedAt  the frame the result reached concatMap                     *)
(*   ahead      how many saves were queued or running at that moment       *)
(*   dueAt      the frame the current attempt finishes, while active       *)
(*   attempts   attempts started so far                                    *)
(*   ackedAt    the frame it was acknowledged, once done                   *)
SaveRec == [state : SaveState, res : (1..MaxTerms) \X (1..ResultsPerSearch),
            arrivedAt : 0..MaxTime, ahead : Nat, dueAt : Nat, attempts : Nat, ackedAt : 0..MaxTime]

ActiveSearches == {k \in DOMAIN search : search[k].state = "active"}
ActiveSaves    == {m \in DOMAIN save : save[m].state = "active"}
PendingSaves   == {m \in DOMAIN save : save[m].state = "pending"}
LiveSaves      == ActiveSaves \cup PendingSaves
QuietSearches(f) == \A k \in DOMAIN f : f[k].state /= "active"
QuietSaves(f)    == \A m \in DOMAIN f : f[m].state \notin {"pending", "active"}

MaxAttempts == IF SaveFailure = "retryInner" THEN Count + 1 ELSE 1
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

SetState(f, S, st) == [i \in DOMAIN f |-> IF i \in S THEN [f[i] EXCEPT !.state = st] ELSE f[i]]

(* concatMap starts the first queued save, if there is one, with a         *)
(* duration d chosen by the environment.                                   *)
StartNext(f, d) ==
  IF PendingSaves = {} \/ ActiveSaves /= {} THEN f
  ELSE LET m == Min(PendingSaves)
       IN [f EXCEPT ![m].state = "active", ![m].dueAt = now + d, ![m].attempts = 1]

(* A save is due: its attempt finishes in this frame.                      *)
SaveDue == \E m \in ActiveSaves : save[m].dueAt = now

TypeOK == /\ now \in 0..MaxTime
          /\ termsDone \in Status /\ midDone \in Status /\ outDone \in Status
          /\ subscribed \in BOOLEAN
          /\ search \in Seq([state : SearchState, sent : 0..ResultsPerSearch])
          /\ mid \in Seq((1..MaxTerms) \X (1..ResultsPerSearch))
          /\ save \in Seq(SaveRec)
          /\ out \in Seq((1..MaxTerms) \X (1..ResultsPerSearch))
          /\ saveErrors \in Nat

Init == /\ now = 0
        /\ termsDone = "active" /\ subscribed = TRUE
        /\ search = <<>> /\ mid = <<>> /\ midDone = "active"
        /\ save = <<>> /\ out = <<>> /\ outDone = "active"
        /\ saveErrors = 0

-----------------------------------------------------------------------------
(* Actions *)

(* Logical time advances, but not past a save that is due.                 *)
Tick == /\ now < MaxTime /\ ~SaveDue
        /\ now' = now + 1
        /\ UNCHANGED <<termsDone, subscribed, search, mid, midDone, save, out, outDone, saveErrors>>

(* A new term: switchMap cancels the running search and starts a new one.  *)
TermNext ==
  /\ subscribed /\ termsDone = "active" /\ Len(search) < MaxTerms
  /\ search' = Append(SetState(search, ActiveSearches, "cancelled"), [state |-> "active", sent |-> 0])
  /\ UNCHANGED <<now, termsDone, subscribed, mid, midDone, save, out, outDone, saveErrors>>

TermsComplete ==
  /\ subscribed /\ termsDone = "active"
  /\ termsDone' = "complete" /\ subscribed' = FALSE
  /\ LET midC == QuietSearches(search)
     IN /\ midDone' = IF midC THEN "complete" ELSE midDone
        /\ outDone' = IF midC /\ QuietSaves(save) THEN "complete" ELSE outDone
  /\ UNCHANGED <<now, search, mid, save, out, saveErrors>>

(* A search delivers a result. switchMap forwards it and concatMap queues  *)
(* a save for it, starting it at once if nothing is running.               *)
SearchNext(k) ==
  /\ k \in ActiveSearches /\ search[k].sent < ResultsPerSearch
  /\ search' = [search EXCEPT ![k].sent = @ + 1]
  /\ LET r   == <<k, search[k].sent + 1>>
         rec == [state |-> "pending", res |-> r, arrivedAt |-> now, ahead |-> Cardinality(LiveSaves),
                 dueAt |-> 0, attempts |-> 0, ackedAt |-> 0]
     IN /\ mid' = Append(mid, r)
        /\ \E d \in SaveMin..SaveMax :
             save' = IF LiveSaves = {}
                       THEN Append(save, [rec EXCEPT !.state = "active", !.dueAt = now + d, !.attempts = 1])
                       ELSE Append(save, rec)
  /\ UNCHANGED <<now, termsDone, subscribed, midDone, out, outDone, saveErrors>>

SearchComplete(k) ==
  /\ k \in ActiveSearches /\ search[k].sent = ResultsPerSearch
  /\ LET s2   == [search EXCEPT ![k].state = "done"]
         midC == termsDone = "complete" /\ QuietSearches(s2)
     IN /\ search'  = s2
        /\ midDone' = IF midC THEN "complete" ELSE midDone
        /\ outDone' = IF midC /\ QuietSaves(save) THEN "complete" ELSE outDone
  /\ UNCHANGED <<now, termsDone, subscribed, mid, save, out, saveErrors>>

(* A save's attempt finishes: the acknowledgement goes out, the next       *)
(* queued save starts.                                                     *)
SaveDone(m) ==
  /\ m \in ActiveSaves /\ save[m].dueAt = now
  /\ \E d \in SaveMin..SaveMax :
       LET v2 == StartNext([save EXCEPT ![m].state = "done", ![m].ackedAt = now], d)
       IN /\ save'    = v2
          /\ outDone' = IF midDone = "complete" /\ QuietSaves(v2) THEN "complete" ELSE outDone
  /\ out' = Append(out, save[m].res)
  /\ UNCHANGED <<now, termsDone, subscribed, search, mid, midDone, saveErrors>>

(* A save's attempt fails. What happens next is the handling h.            *)
SaveError(m) ==
  /\ m \in ActiveSaves
  /\ saveErrors' = saveErrors + 1
  /\ \E d \in SaveMin..SaveMax :
       IF SaveFailure = "retryInner" /\ save[m].attempts <= Count
         THEN /\ save' = [save EXCEPT ![m].dueAt = now + d, ![m].attempts = @ + 1]
              /\ UNCHANGED <<search, subscribed, outDone>>
         ELSE IF SaveFailure = "catchInner"
           THEN LET v2 == StartNext([save EXCEPT ![m].state = "skipped"], d)
                IN /\ save'    = v2
                   /\ outDone' = IF midDone = "complete" /\ QuietSaves(v2) THEN "complete" ELSE outDone
                   /\ UNCHANGED <<search, subscribed>>
           ELSE /\ save'       = SetState(save, LiveSaves, "cancelled")
                /\ search'     = SetState(search, ActiveSearches, "cancelled")
                /\ subscribed' = FALSE
                /\ outDone'    = "error"
  /\ UNCHANGED <<now, termsDone, mid, midDone, out>>

(* The model stops at a terminal or at the time horizon.                   *)
Done == (Terminal(outDone) \/ now = MaxTime) /\ UNCHANGED vars

Next == \/ Tick \/ TermNext \/ TermsComplete
        \/ \E k \in DOMAIN search : SearchNext(k) \/ SearchComplete(k)
        \/ \E m \in DOMAIN save : SaveDone(m) \/ SaveError(m)
        \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants inherited from SearchAndSave, for switchMap then concatMap *)

AtMostOneSearch       == Cardinality(ActiveSearches) <= 1
OnlyNewestSearch      == ActiveSearches \subseteq {Len(search)}
ResultsNotInterleaved == \A i \in DOMAIN mid : i + 1 \in DOMAIN mid => mid[i][1] <= mid[i + 1][1]
SavesSerialised       == Cardinality(ActiveSaves) <= 1
SavesInOrder          == \A m \in ActiveSaves :
                           /\ \A j \in 1..(m - 1)         : save[j].state \in {"done", "skipped"}
                           /\ \A j \in (m + 1)..Len(save) : save[j].state = "pending"
OneSavePerResult      == Len(save) = Len(mid) /\ \A m \in DOMAIN save : save[m].res = mid[m]
NoStaleSave           == \A i \in DOMAIN out : i + 1 \in DOMAIN out => out[i][1] <= out[i + 1][1]

(* The acknowledgements are exactly the results whose save is done, in    *)
(* order. With catchInner some are missing; with the others none is.      *)
AcksAreDoneSaves == out = SelectSeq(mid, LAMBDA r : \E m \in DOMAIN save : save[m].res = r /\ save[m].state = "done")

-----------------------------------------------------------------------------
(* Invariants about failure *)

RetriesBounded == \A m \in DOMAIN save : save[m].attempts <= MaxAttempts

(* A save is cancelled only after more than Count failures. Holds for      *)
(* retryInner and catchInner; fails for propagate, where the first failed  *)
(* save takes the whole queue with it.                                     *)
QueueSurvivesRetries == \A m \in DOMAIN save : save[m].state = "cancelled" => saveErrors > Count

(* On completion every result was acknowledged. Fails for catchInner,     *)
(* which completes with the skipped saves silently missing.               *)
EveryResultAcked == outDone = "complete" => out = mid

-----------------------------------------------------------------------------
(* Invariants about time *)

(* A running save is never overdue: a due attempt finishes or fails before *)
(* time moves on.                                                          *)
TimerNeverOverdue == \A m \in ActiveSaves : now <= save[m].dueAt

(* The deadline form of "every save is eventually acknowledged": the wait  *)
(* from a result's arrival to its acknowledgement is bounded by the saves  *)
(* ahead of it in the queue, each taking at most SaveMax frames per        *)
(* attempt.                                                                *)
Latency(m) == save[m].ackedAt - save[m].arrivedAt
AckLatencyBounded == \A m \in DOMAIN save :
  save[m].state = "done" => Latency(m) <= (save[m].ahead + 1) * SaveMax * MaxAttempts

(* The same bound without the retries. Fails for retryInner: a retried    *)
(* save delays itself and everything queued behind it.                    *)
AckLatencyBoundedNoRetry == \A m \in DOMAIN save :
  save[m].state = "done" => Latency(m) <= (save[m].ahead + 1) * SaveMax

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(mid, midDone) /\ Contract(out, outDone)]_vars

(* An acknowledgement comes from the active save, at the frame it is due.  *)
AckWhenDue == [][out' /= out => \E m \in ActiveSaves : save[m].res = Last(out') /\ save[m].dueAt = now]_vars

=============================================================================
