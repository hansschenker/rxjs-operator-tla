--------------------------------- MODULE Zip ---------------------------------
(***************************************************************************)
(* zip(a$, b$): pair the k-th value of a$ with the k-th value of b$.        *)
(*                                                                         *)
(* Values wait in a buffer per source until their partner arrives. Once    *)
(* every buffer holds a value, one value is taken from each and the pair   *)
(* is delivered. The result completes as soon as no more pairs can form:   *)
(* a source has completed and its buffer is empty. Either source's error   *)
(* is the result's error.                                                  *)
(*                                                                         *)
(* Operator family: combining. Compare CombineLatest.tla, which pairs by   *)
(* recency; zip pairs by position. The buffers are modelled explicitly,   *)
(* as RxJS 7 keeps them, and the invariants check that the buffered        *)
(* implementation equals the one-line definition "out[k] = <<a[k], b[k]>>".*)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values, MaxLen

VARIABLES a, aDone,     \* source A, as observed
          b, bDone,     \* source B, as observed
          bufA, bufB,   \* values waiting for a partner
          out, outDone  \* Seq of <<va, vb>> delivered to the subscriber

vars == <<a, aDone, b, bDone, bufA, bufB, out, outDone>>

Min(x, y) == IF x <= y THEN x ELSE y

TypeOK == /\ a \in Seq(Values) /\ b \in Seq(Values)
          /\ bufA \in Seq(Values) /\ bufB \in Seq(Values)
          /\ out \in Seq(Values \X Values)
          /\ aDone \in Status /\ bDone \in Status /\ outDone \in Status

Init == /\ a = <<>> /\ aDone = "active"
        /\ b = <<>> /\ bDone = "active"
        /\ bufA = <<>> /\ bufB = <<>>
        /\ out = <<>> /\ outDone = "active"

-----------------------------------------------------------------------------
(* Actions. Every source action is guarded by outDone = "active": once the *)
(* result has terminated, zip has unsubscribed from both sources.          *)

(* A value arrives: push it, and if both buffers are now non-empty take    *)
(* the head of each and deliver the pair. After a pair, complete if a      *)
(* completed source has nothing left to pair.                              *)
Arrive(pa, pb) ==
  IF pa /= <<>> /\ pb /= <<>>
    THEN /\ out'  = Append(out, <<Head(pa), Head(pb)>>)
         /\ bufA' = Tail(pa)
         /\ bufB' = Tail(pb)
         /\ outDone' = IF \/ (aDone' = "complete" /\ Tail(pa) = <<>>)
                          \/ (bDone' = "complete" /\ Tail(pb) = <<>>)
                         THEN "complete" ELSE "active"
    ELSE /\ bufA' = pa /\ bufB' = pb
         /\ UNCHANGED <<out, outDone>>

ANext(v) == /\ outDone = "active" /\ aDone = "active" /\ Len(a) < MaxLen
            /\ a' = Append(a, v)
            /\ UNCHANGED <<aDone, b, bDone>>
            /\ Arrive(Append(bufA, v), bufB)

BNext(v) == /\ outDone = "active" /\ bDone = "active" /\ Len(b) < MaxLen
            /\ b' = Append(b, v)
            /\ UNCHANGED <<a, aDone, bDone>>
            /\ Arrive(bufA, Append(bufB, v))

(* A source completes: if nothing of it is buffered, no more pairs can     *)
(* form and the result completes now. Otherwise its buffered values may    *)
(* still be paired, and the result completes when the last one is.         *)
AComplete == /\ outDone = "active" /\ aDone = "active"
             /\ aDone'   = "complete"
             /\ outDone' = IF bufA = <<>> THEN "complete" ELSE "active"
             /\ UNCHANGED <<a, b, bDone, bufA, bufB, out>>

BComplete == /\ outDone = "active" /\ bDone = "active"
             /\ bDone'   = "complete"
             /\ outDone' = IF bufB = <<>> THEN "complete" ELSE "active"
             /\ UNCHANGED <<a, aDone, b, bufA, bufB, out>>

AError == /\ outDone = "active" /\ aDone = "active"
          /\ aDone' = "error" /\ outDone' = "error"
          /\ UNCHANGED <<a, b, bDone, bufA, bufB, out>>

BError == /\ outDone = "active" /\ bDone = "active"
          /\ bDone' = "error" /\ outDone' = "error"
          /\ UNCHANGED <<a, aDone, b, bufA, bufB, out>>

Done == Terminal(outDone) /\ UNCHANGED vars

AStep == (\E v \in Values : ANext(v)) \/ AComplete \/ AError
BStep == (\E v \in Values : BNext(v)) \/ BComplete \/ BError

Next == AStep \/ BStep \/ Done

SpecFair  == Init /\ [][Next]_vars /\ WF_vars(AStep) /\ WF_vars(BStep)
SpecFairA == Init /\ [][Next]_vars /\ WF_vars(AStep)

-----------------------------------------------------------------------------
(* Invariants *)

(* The whole operator in one line: the k-th output pairs the k-th values.  *)
PairsByIndex == out = [k \in 1..Len(out) |-> <<a[k], b[k]>>]

(* No pair that could be delivered is withheld.                            *)
AllPossiblePairsDelivered == Len(out) = Min(Len(a), Len(b))

(* The buffers are exactly the values not yet paired.                      *)
BuffersAreUnpairedSuffixes == /\ bufA = SubSeq(a, Len(out) + 1, Len(a))
                              /\ bufB = SubSeq(b, Len(out) + 1, Len(b))

(* At least one buffer is always empty: as soon as both have a value, a    *)
(* pair goes out in the same step.                                         *)
OneSideWaits == bufA = <<>> \/ bufB = <<>>

(* The result completes exactly when a completed source has nothing left   *)
(* to pair.                                                                *)
CompletesWhenNoMorePairs ==
  outDone = "complete" <=> \/ (aDone = "complete" /\ bufA = <<>>)
                           \/ (bDone = "complete" /\ bufB = <<>>)

ErrorIfEither == (aDone = "error" \/ bDone = "error") => outDone = "error"

(* Demonstration, expected to fail: zip buffers without bound. A source    *)
(* that runs ahead of the other keeps every unpaired value in memory.      *)
BufferBounded == Len(bufA) <= 1 /\ Len(bufB) <= 1

(* Demonstration, expected to fail: zip does not pair latest with latest.  *)
(* This is combineLatest's invariant; the counterexample is the difference *)
(* between the two operators.                                              *)
LatestPair == (a /= <<>> /\ b /= <<>>) => (out /= <<>> /\ Last(out) = <<Last(a), Last(b)>>)

-----------------------------------------------------------------------------
(* Properties *)

ObservableContract == [][Contract(a, aDone) /\ Contract(b, bDone) /\ Contract(out, outDone)]_vars

(* A step delivers at most one pair.                                       *)
OnePairPerStep == [][out' /= out => Len(out') = Len(out) + 1]_vars

EventuallyTerminal == <>Terminal(outDone)

=============================================================================
