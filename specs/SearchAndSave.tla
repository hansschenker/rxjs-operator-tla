---------------------------- MODULE SearchAndSave ----------------------------
(***************************************************************************)
(* A pipeline with two asynchronous boundaries:                            *)
(*                                                                         *)
(*     terms$.pipe(switchMap(search), concatMap(save))                     *)
(*                                                                         *)
(* Each search term starts a search (an inner Observable delivering        *)
(* ResultsPerSearch results, then completing). Each result starts a save   *)
(* (an inner Observable delivering one acknowledgement, then completing).  *)
(* The subscriber receives the acknowledgements.                           *)
(*                                                                         *)
(* Both stages take their flattening strategy from a constant, so one      *)
(* module checks the intended pair (switch, concat) and demonstrates what  *)
(* each other choice breaks:                                               *)
(*                                                                         *)
(*     SearchStrategy = "merge"    stale results of an old search get      *)
(*                                 saved after a newer search's results    *)
(*     SaveStrategy   = "switch"   a save in flight is cancelled by the    *)
(*                                 next result: a lost write               *)
(*     SaveStrategy   = "merge"    saves overlap and may finish out of     *)
(*                                 order                                   *)
(*     SaveStrategy   = "exhaust"  a result arriving during a save is      *)
(*                                 never saved                             *)
(*                                                                         *)
(* Composition (part 05 of the analysis): a result's delivery by a search  *)
(* and its arrival at concatMap are the same step, because switchMap       *)
(* forwards synchronously. Searches and saves finishing are separate       *)
(* steps, so TLC interleaves them with each other and with new terms.      *)
(***************************************************************************)
EXTENDS RxBase, FiniteSets

CONSTANTS SearchStrategy,    \* strategy of the first stage; switchMap is "switch"
          SaveStrategy,      \* strategy of the second stage; concatMap is "concat"
          MaxTerms,          \* model bound: search terms
          ResultsPerSearch   \* each search delivers exactly this many results

Strategies == {"switch", "merge", "concat", "exhaust"}
ASSUME SearchStrategy \in Strategies /\ SaveStrategy \in Strategies
ASSUME MaxTerms \in Nat /\ ResultsPerSearch \in Nat /\ ResultsPerSearch >= 1

VARIABLES termsDone, subscribed,   \* the outer source of search terms
          search,                  \* Seq of [state, sent]: one search per term
          mid, midDone,            \* results delivered by switchMap into concatMap
          save,                    \* Seq of [state, res]: one save per result
          out, outDone             \* acknowledgements delivered to the subscriber

vars == <<termsDone, subscribed, search, mid, midDone, save, out, outDone>>

InnerState == {"pending", "active", "done", "cancelled", "dropped"}

-----------------------------------------------------------------------------
(* The flattening strategies as functions on a sequence of inner records.  *)
(* Start(f, strategy, rec) adds a new inner; Finish(f, strategy, i) ends   *)
(* inner i. These are the two places where the strategies differ, exactly *)
(* as in Flatten.tla.                                                      *)

ActiveOf(f)  == {i \in DOMAIN f : f[i].state = "active"}
PendingOf(f) == {i \in DOMAIN f : f[i].state = "pending"}
LiveOf(f)    == ActiveOf(f) \cup PendingOf(f)
Quiet(f)     == LiveOf(f) = {}

SetState(f, S, st) == [i \in DOMAIN f |-> IF i \in S THEN [f[i] EXCEPT !.state = st] ELSE f[i]]
Min(S) == CHOOSE m \in S : \A x \in S : m <= x

Start(f, strategy, rec) ==
  CASE strategy = "switch"  -> Append(SetState(f, ActiveOf(f), "cancelled"), rec)
    [] strategy = "merge"   -> Append(f, rec)
    [] strategy = "concat"  -> Append(f, [rec EXCEPT !.state = IF Quiet(f) THEN "active" ELSE "pending"])
    [] strategy = "exhaust" -> Append(f, [rec EXCEPT !.state = IF ActiveOf(f) = {} THEN "active" ELSE "dropped"])

Finish(f, strategy, i) ==
  LET done == [f EXCEPT ![i].state = "done"]
  IN  IF strategy = "concat" /\ PendingOf(f) /= {}
        THEN [done EXCEPT ![Min(PendingOf(f))].state = "active"]
        ELSE done

ActiveSearches == ActiveOf(search)
ActiveSaves    == ActiveOf(save)

-----------------------------------------------------------------------------

TypeOK == /\ termsDone \in Status /\ midDone \in Status /\ outDone \in Status
          /\ subscribed \in BOOLEAN
          /\ search \in Seq([state : InnerState, sent : 0..ResultsPerSearch])
          /\ mid \in Seq((1..MaxTerms) \X (1..ResultsPerSearch))
          /\ save \in Seq([state : InnerState, res : (1..MaxTerms) \X (1..ResultsPerSearch)])
          /\ out \in Seq((1..MaxTerms) \X (1..ResultsPerSearch))

Init == /\ termsDone = "active" /\ subscribed = TRUE
        /\ search = <<>> /\ mid = <<>> /\ midDone = "active"
        /\ save = <<>> /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* Actions *)

(* A new search term arrives: the first stage starts a search for it.      *)
TermNext ==
  /\ subscribed /\ termsDone = "active" /\ Len(search) < MaxTerms
  /\ search' = Start(search, SearchStrategy, [state |-> "active", sent |-> 0])
  /\ UNCHANGED <<termsDone, subscribed, mid, midDone, save, out, outDone>>

(* The terms complete. Stage 1 completes if no search is live; stage 2    *)
(* completes if, in addition, no save is live.                             *)
TermsComplete ==
  /\ subscribed /\ termsDone = "active"
  /\ termsDone' = "complete" /\ subscribed' = FALSE
  /\ LET midC == Quiet(search)
     IN /\ midDone' = IF midC THEN "complete" ELSE midDone
        /\ outDone' = IF midC /\ Quiet(save) THEN "complete" ELSE outDone
  /\ UNCHANGED <<search, mid, save, out>>

(* A search delivers a result. switchMap forwards it, and concatMap starts *)
(* a save for it, all in this one step.                                    *)
SearchNext(k) ==
  /\ k \in ActiveSearches /\ search[k].sent < ResultsPerSearch
  /\ search' = [search EXCEPT ![k].sent = @ + 1]
  /\ LET r == <<k, search[k].sent + 1>>
     IN /\ mid'  = Append(mid, r)
        /\ save' = Start(save, SaveStrategy, [state |-> "active", res |-> r])
  /\ UNCHANGED <<termsDone, subscribed, midDone, out, outDone>>

(* A search completes after its last result.                               *)
SearchComplete(k) ==
  /\ k \in ActiveSearches /\ search[k].sent = ResultsPerSearch
  /\ LET s2   == Finish(search, SearchStrategy, k)
         midC == termsDone = "complete" /\ Quiet(s2)
     IN /\ search'  = s2
        /\ midDone' = IF midC THEN "complete" ELSE midDone
        /\ outDone' = IF midC /\ Quiet(save) THEN "complete" ELSE outDone
  /\ UNCHANGED <<termsDone, subscribed, mid, save, out>>

(* A save finishes: its acknowledgement is delivered and it completes.     *)
SaveDone(m) ==
  /\ m \in ActiveSaves
  /\ LET v2 == Finish(save, SaveStrategy, m)
     IN /\ save'    = v2
        /\ out'     = Append(out, save[m].res)
        /\ outDone' = IF midDone = "complete" /\ Quiet(v2) THEN "complete" ELSE outDone
  /\ UNCHANGED <<termsDone, subscribed, search, mid, midDone>>

Done == Terminal(outDone) /\ UNCHANGED vars

Next == \/ TermNext \/ TermsComplete
        \/ \E k \in DOMAIN search : SearchNext(k) \/ SearchComplete(k)
        \/ \E m \in DOMAIN save : SaveDone(m)
        \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

-----------------------------------------------------------------------------
(* Invariants for the intended pipeline, switchMap then concatMap          *)

(* Stage 1: at most one search in flight, and it is the newest.            *)
AtMostOneSearch       == Cardinality(ActiveSearches) <= 1
OnlyNewestSearch      == ActiveSearches \subseteq {Len(search)}
ResultsNotInterleaved == \A i \in DOMAIN mid : i + 1 \in DOMAIN mid => mid[i][1] <= mid[i + 1][1]

(* Stage 2: saves run one at a time, in order, and none is lost.           *)
SavesSerialised == Cardinality(ActiveSaves) <= 1
SavesInOrder    == \A m \in ActiveSaves :
                     /\ \A j \in 1..(m - 1)        : save[j].state = "done"
                     /\ \A j \in (m + 1)..Len(save) : save[j].state = "pending"
NoLostSave      == \A m \in DOMAIN save : save[m].state /= "cancelled"
NoDroppedSave   == \A m \in DOMAIN save : save[m].state /= "dropped"

(* Across the boundary: every result gets exactly one save, the            *)
(* acknowledgements come back in result order, and nothing of a newer      *)
(* search is saved before something of an older one.                       *)
OneSavePerResult       == Len(save) = Len(mid) /\ \A m \in DOMAIN save : save[m].res = mid[m]
AcksArePrefixOfResults == IsPrefix(out, mid)
NoStaleSave            == \A i \in DOMAIN out : i + 1 \in DOMAIN out => out[i][1] <= out[i + 1][1]
EveryResultSaved       == outDone = "complete" => out = mid

(* Termination order: terms, then searches, then saves.                    *)
MidCompletesAfterSearches == midDone = "complete" => (termsDone = "complete" /\ Quiet(search))
CompletesOnlyWhenAllSaved == outDone = "complete" => (midDone = "complete" /\ Quiet(save))

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(mid, midDone) /\ Contract(out, outDone)]_vars

(* A result always comes from a search that was active.                    *)
OnlyActiveSearchesDeliver == [][mid' /= mid => Last(mid')[1] \in ActiveSearches]_vars

(* An acknowledgement always comes from a save that was active.            *)
OnlyActiveSavesAcknowledge == [][out' /= out => \E m \in ActiveSaves : save[m].res = Last(out')]_vars

Completes == <>Terminal(outDone)

=============================================================================
