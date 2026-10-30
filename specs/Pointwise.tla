------------------------------ MODULE Pointwise ------------------------------
(***************************************************************************)
(* Synchronous one-in / at-most-one-out operators:                         *)
(*                                                                         *)
(*     map(F)   filter(P)   scan(Acc, Seed)   distinctUntilChanged()       *)
(*                                                                         *)
(* Operator family: pointwise. Their whole behaviour is a function of the  *)
(* input trace, so each one is specified by a single equation              *)
(*                                                                         *)
(*     out = Spec(in)                                                      *)
(*                                                                         *)
(* The actions below compute the outputs incrementally, the way the        *)
(* operators do at runtime. The invariants restate each operator           *)
(* declaratively over the whole trace. TLC checks that the two agree in    *)
(* every reachable state, for every input trace up to MaxLen.              *)
(*                                                                         *)
(* All four share one `outDone`, because none of them terminates early:    *)
(* terminal notifications pass straight through.                           *)
(***************************************************************************)
EXTENDS RxBase

CONSTANTS Values, MaxLen
ASSUME Values \subseteq Nat

(* The user functions handed to the operators *)
F(x)      == x * 2         \* map(x => x * 2)
P(x)      == x % 2 = 0     \* filter(x => x % 2 === 0)
Acc(a, x) == a + x         \* scan((acc, x) => acc + x, 0)
Seed      == 0

VARIABLES in, inDone,
          mapOut, filterOut, scanOut, distinctOut,
          outDone

vars == <<in, inDone, mapOut, filterOut, scanOut, distinctOut, outDone>>

TypeOK == /\ in \in Seq(Values) /\ inDone \in Status /\ outDone \in Status
          /\ mapOut \in Seq(Nat) /\ filterOut \in Seq(Values)
          /\ scanOut \in Seq(Nat) /\ distinctOut \in Seq(Values)

Init == /\ in = <<>> /\ inDone = "active" /\ outDone = "active"
        /\ mapOut = <<>> /\ filterOut = <<>> /\ scanOut = <<>> /\ distinctOut = <<>>

-----------------------------------------------------------------------------
(* Actions: how each operator reacts to one value, incrementally *)

SourceNext(v) ==
  /\ inDone = "active" /\ Len(in) < MaxLen
  /\ in'          = Append(in, v)
  /\ mapOut'      = Append(mapOut, F(v))
  /\ filterOut'   = IF P(v) THEN Append(filterOut, v) ELSE filterOut
  /\ scanOut'     = Append(scanOut, Acc(IF scanOut = <<>> THEN Seed ELSE Last(scanOut), v))
  /\ distinctOut' = IF distinctOut /= <<>> /\ Last(distinctOut) = v
                      THEN distinctOut
                      ELSE Append(distinctOut, v)
  /\ UNCHANGED <<inDone, outDone>>

SourceEnd(how) ==
  /\ inDone = "active"
  /\ inDone'  = how
  /\ outDone' = how
  /\ UNCHANGED <<in, mapOut, filterOut, scanOut, distinctOut>>

Done == Terminal(inDone) /\ UNCHANGED vars

Next == \/ \E v \in Values : SourceNext(v)
        \/ \E how \in {"complete", "error"} : SourceEnd(how)
        \/ Done

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Declarative definitions: what each operator *means* over a whole trace *)

MapSpec(s)    == [i \in DOMAIN s |-> F(s[i])]
FilterSpec(s) == SelectSeq(s, P)

RECURSIVE ScanSpec(_)
ScanSpec(s) ==
  IF s = <<>> THEN <<>>
  ELSE LET prev == ScanSpec(SubSeq(s, 1, Len(s) - 1))
           acc  == IF prev = <<>> THEN Seed ELSE Last(prev)
       IN  Append(prev, Acc(acc, Last(s)))

RECURSIVE DistinctSpec(_)
DistinctSpec(s) ==
  IF s = <<>> THEN <<>>
  ELSE LET prev == DistinctSpec(SubSeq(s, 1, Len(s) - 1))
       IN  IF prev /= <<>> /\ Last(prev) = Last(s) THEN prev ELSE Append(prev, Last(s))

-----------------------------------------------------------------------------
(* Invariants *)

MapCorrect      == mapOut      = MapSpec(in)
FilterCorrect   == filterOut   = FilterSpec(in)
ScanCorrect     == scanOut     = ScanSpec(in)
DistinctCorrect == distinctOut = DistinctSpec(in)

(* Weaker facts that follow from the equations, stated for readability    *)
SameLength      == Len(mapOut) = Len(in) /\ Len(scanOut) = Len(in)
NeverLonger     == Len(filterOut) <= Len(in) /\ Len(distinctOut) <= Len(in)
FilterIsSubset  == Range(filterOut) \subseteq Range(in)
NoAdjacentDupes == \A i \in DOMAIN distinctOut :
                     i + 1 \in DOMAIN distinctOut => distinctOut[i] /= distinctOut[i + 1]

(* Termination is pure propagation for this family                        *)
TerminalPassesThrough == outDone = inDone

ObservableContract == [][ /\ Contract(in, inDone)
                          /\ Contract(mapOut, outDone)
                          /\ Contract(filterOut, outDone)
                          /\ Contract(scanOut, outDone)
                          /\ Contract(distinctOut, outDone) ]_vars

=============================================================================
