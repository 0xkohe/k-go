requires "../core.k"
requires "../../syntax/concurrent.k"
requires "common.k"

// ============================================================================
// GO-SELECT MODULE
// ============================================================================
// Select statement semantics for multiplexing channel operations.
// Implements Go's select statement in four phases:
// 1. Evaluate each communication clause exactly once
// 2. Check which clauses are immediately ready
// 3. Choose a ready clause (or default) to execute
// 4. If none are ready and no default exists, block until one becomes ready

module GO-SELECT
  imports GO
  imports GO-SYNTAX-CONCURRENT
  imports GO-CONCURRENT-COMMON
  imports INT
  imports LIST
  imports MAP

  // ============================================================================
  // SELECT EVALUATION CASES
  // ============================================================================

  syntax EvalCase ::= evalSendCase(ChanVal, K, K)
                    | evalRecvCase(ChanVal, K)
                    | evalRecvAssignCase(ChanVal, Id, K)
                    | evalRecvDeclCase(ChanVal, Id, K)
                    | evalRecvOkCase(ChanVal, Id, Id, K)
                    | evalDefaultCase(K)

  syntax KItem ::= selectEval(CommClauses)
                 | selectBuildCases(CommClauses, List)
                 | selectWithCases(List)
                 | selectCheckReady(List, List, K, List)
                 | selectChooseFrom(List, K, List)
                 | selectBlock(List, List)
                 | executeSelectCase(EvalCase)

  // ============================================================================
  // CONTEXT RULES FOR EVALUATION
  // ============================================================================

  context selectBuildCases(
            (case (HOLE:Exp <- _V:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)
  context selectBuildCases(
            (case (_Chan:Exp <- HOLE:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)
  context selectBuildCases(
            (case (<- HOLE:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)
  context selectBuildCases(
            (case (_X:Id = <- HOLE:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)
  context selectBuildCases(
            (case ((_X:Id , _Y:Id) = <- HOLE:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)
  context selectBuildCases(
            (case (_X:Id := <- HOLE:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)
  context selectBuildCases(
            (case ((_X:Id , _Y:Id) := <- HOLE:Exp) : _Body:Block)
             ; _Rest:CommClauses,
            _Acc:List)

  // ============================================================================
  // SELECT STATEMENT ENTRY
  // ============================================================================

  rule <k> select { Cases:CommClauses }
        => selectEval(Cases) ... </k>

  rule <k> selectEval(Cases:CommClauses)
        => selectBuildCases(Cases, .List) ... </k>

  // ============================================================================
  // PHASE 1: BUILD EVALUATED CASE LIST
  // ============================================================================

  rule <k> selectBuildCases(.CommClauses, Acc:List)
        => selectWithCases(Acc) ... </k>

  rule <k> selectBuildCases(
          (case (Chan:ChanVal <- V) : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalSendCase(Chan, V, Body))) ... </k>

  rule <k> selectBuildCases(
          (case (<- Chan:ChanVal) : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalRecvCase(Chan, Body))) ... </k>

  rule <k> selectBuildCases(
          (case (X:Id = <- Chan:ChanVal) : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalRecvAssignCase(Chan, X, Body))) ... </k>

  rule <k> selectBuildCases(
          (case ((X:Id , Y:Id) = <- Chan:ChanVal) : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalRecvOkCase(Chan, X, Y, Body))) ... </k>

  rule <k> selectBuildCases(
          (case (X:Id := <- Chan:ChanVal) : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalRecvDeclCase(Chan, X, Body))) ... </k>

  rule <k> selectBuildCases(
          (case ((X:Id , Y:Id) := <- Chan:ChanVal) : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalRecvOkCase(Chan, X, Y, Body))) ... </k>

  rule <k> selectBuildCases(
          (default : Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(
             Rest,
             Acc ListItem(evalDefaultCase(Body))) ... </k>

  // Skip nil channel cases (they can never proceed)
  rule <k> selectBuildCases(
          (case (_Nil:FuncVal <- _) : _Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(Rest, Acc) ... </k>

  rule <k> selectBuildCases(
          (case (<- _Nil:FuncVal) : _Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(Rest, Acc) ... </k>

  rule <k> selectBuildCases(
          (case ( _:Id = <- _Nil:FuncVal) : _Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(Rest, Acc) ... </k>

  rule <k> selectBuildCases(
          (case ((_:Id , _:Id) = <- _Nil:FuncVal) : _Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(Rest, Acc) ... </k>

  rule <k> selectBuildCases(
          (case ( _:Id := <- _Nil:FuncVal) : _Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(Rest, Acc) ... </k>

  rule <k> selectBuildCases(
          (case ((_:Id , _:Id) := <- _Nil:FuncVal) : _Body:Block)
           ; Rest:CommClauses,
          Acc:List)
        => selectBuildCases(Rest, Acc) ... </k>

  // ============================================================================
  // PHASE 2: CHECK READY CASES
  // ============================================================================

  rule <k> selectWithCases(Cases:List)
        => selectCheckReady(Cases, .List, .K, Cases) ... </k>

  rule <k> selectCheckReady(
          .List,
          Ready:List,
          DefaultBody:K,
          Orig:List)
        => selectChooseFrom(Ready, DefaultBody, Orig) ... </k>

  // Send case is ready if: channel closed, buffer has space, or receiver waiting
  rule <k> selectCheckReady(
          ListItem(evalSendCase(Chan, V, Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(
             Rest,
             Ready ListItem(evalSendCase(Chan, V, Body)),
             Default,
             Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQ:List, RecvQ, Buf, Size, _T, Closed)
       ...</channels>
    requires (Closed ==Bool true)
      orBool (size(Buf) <Int Size)
      orBool (size(RecvQ) >Int 0)

  rule <k> selectCheckReady(
          ListItem(evalSendCase(Chan, _V, _Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(Rest, Ready, Default, Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQ:List, RecvQ, Buf, Size, _T, false)
       ...</channels>
    requires (size(Buf) >=Int Size)
      andBool (size(RecvQ) ==Int 0)

  // Receive case is ready if: buffer has values, sender waiting, or channel closed
  rule <k> selectCheckReady(
          ListItem(evalRecvCase(Chan, Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(
             Rest,
             Ready ListItem(evalRecvCase(Chan, Body)),
             Default,
             Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (size(SendQ:List) >Int 0)
      orBool (Closed ==Bool true)

  rule <k> selectCheckReady(
          ListItem(evalRecvCase(Chan, _Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(Rest, Ready, Default, Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, false)
       ...</channels>
    requires (size(Buf) ==Int 0)
      andBool (size(SendQ:List) ==Int 0)

  // Receive assign case (same readiness as receive case)
  rule <k> selectCheckReady(
          ListItem(evalRecvAssignCase(Chan, X, Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(
             Rest,
             Ready ListItem(evalRecvAssignCase(Chan, X, Body)),
             Default,
             Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (size(SendQ:List) >Int 0)
      orBool (Closed ==Bool true)

  rule <k> selectCheckReady(
          ListItem(evalRecvAssignCase(Chan, _X, _Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(Rest, Ready, Default, Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, false)
       ...</channels>
    requires (size(Buf) ==Int 0)
      andBool (size(SendQ:List) ==Int 0)

  // Receive decl case (same readiness as receive case)
  rule <k> selectCheckReady(
          ListItem(evalRecvDeclCase(Chan, X, Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(
             Rest,
             Ready ListItem(evalRecvDeclCase(Chan, X, Body)),
             Default,
             Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (size(SendQ:List) >Int 0)
      orBool (Closed ==Bool true)

  rule <k> selectCheckReady(
          ListItem(evalRecvDeclCase(Chan, _X, _Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(Rest, Ready, Default, Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ:List, _RecvQ, Buf, _Size, _T, false)
       ...</channels>
    requires (size(Buf) ==Int 0)
      andBool (size(SendQ:List) ==Int 0)

  // Receive ok case (same readiness as receive case)
  rule <k> selectCheckReady(
          ListItem(evalRecvOkCase(Chan, V, Ok, Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(
             Rest,
             Ready ListItem(evalRecvOkCase(Chan, V, Ok, Body)),
             Default,
             Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (size(SendQ:List) >Int 0)
      orBool (Closed ==Bool true)

  rule <k> selectCheckReady(
          ListItem(evalRecvOkCase(Chan, _V, _Ok, _Body)) Rest:List,
          Ready:List,
          Default:K,
          Orig:List)
        => selectCheckReady(Rest, Ready, Default, Orig) ... </k>
       <channels>...
         chanId(Chan)
           |-> chanState(SendQ, _RecvQ, Buf, _Size, _T, false)
       ...</channels>
    requires (size(Buf) ==Int 0)
      andBool (size(SendQ:List) ==Int 0)

  // Default case (always record, never mark as ready)
  rule <k> selectCheckReady(
          ListItem(evalDefaultCase(Body)) Rest:List,
          Ready:List,
          _Default:K,
          Orig:List)
        => selectCheckReady(Rest, Ready, Body, Orig) ... </k>

  // ============================================================================
  // PHASE 3: CHOOSE FROM READY CASES
  // ============================================================================

  // Selection from ready list
  // Note: This implementation always selects the first ready case
  // True non-deterministic selection would require additional mechanism
  // (e.g., random number generation or explicit choice points)
  rule <k> selectChooseFrom(
          ListItem(Case:EvalCase) _Rest:List,
          _Default:K,
          _Orig:List)
        => executeSelectCase(Case) ... </k>

  rule <k> selectChooseFrom(
          .List,
          Default:K,
          _Orig:List)
        => executeSelectCase(evalDefaultCase(Default)) ... </k>
    requires hasDefault(Default)

  rule <k> selectChooseFrom(
          .List,
          Default:K,
          Orig:List)
        => selectBlock(Orig, Orig) ... </k>
    requires notBool hasDefault(Default)

  // ============================================================================
  // PHASE 4: BLOCKING BEHAVIOR
  // ============================================================================

  // Block until a send case becomes ready
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              _L1:List ListItem(evalSendCase(Chan, _V, _Body)) _L2:List,
              Orig:List)
          => selectCheckReady(Orig, .List, .K, Orig) ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQBlock:List, RecvQ, Buf, Size, _T, Closed)
       ...</channels>
    requires (Closed ==Bool true)
      orBool (size(Buf) <Int Size)
      orBool (size(RecvQ) >Int 0)

  // Block until a receive case becomes ready
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              _L1:List ListItem(evalRecvCase(Chan, _Body)) _L2:List,
              Orig:List)
          => selectCheckReady(Orig, .List, .K, Orig) ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQBlock:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (Closed ==Bool true)

  // Execute first ready receive case when sender available
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              ListItem(evalRecvCase(Chan, Body)) _Rest:List,
              _Orig:List)
          => chanRecv(Chan) ~> Body ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState((ListItem(sendItem(_SendTid:Int, _SV)) _SendRest:List), _RecvQ, .List, _Size, _T, false)
       ...</channels>

  // Block until a receive assign case becomes ready
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              _L1:List ListItem(evalRecvAssignCase(Chan, _X, _Body)) _L2:List,
              Orig:List)
          => selectCheckReady(Orig, .List, .K, Orig) ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQBlock:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (Closed ==Bool true)

  // Execute first ready receive assign case when sender available
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              ListItem(evalRecvAssignCase(Chan, X, Body)) _Rest:List,
              _Orig:List)
          => X = chanRecv(Chan) ~> Body ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState((ListItem(sendItem(_SendTid:Int, _SV)) _SendRest:List), _RecvQ, .List, _Size, _T, false)
       ...</channels>

  // Block until a receive decl case becomes ready
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              _L1:List ListItem(evalRecvDeclCase(Chan, _X, _Body)) _L2:List,
              Orig:List)
          => selectCheckReady(Orig, .List, .K, Orig) ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQBlock:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (Closed ==Bool true)

  // Execute first ready receive decl case when sender available
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              ListItem(evalRecvDeclCase(Chan, X, Body)) _Rest:List,
              _Orig:List)
          => X := chanRecv(Chan) ~> Body ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState((ListItem(sendItem(_SendTid:Int, _SV)) _SendRest:List), _RecvQ, .List, _Size, _T, false)
       ...</channels>

  // Block until a receive ok case becomes ready
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              _L1:List ListItem(evalRecvOkCase(Chan, _V, _Ok, _Body)) _L2:List,
              Orig:List)
          => selectCheckReady(Orig, .List, .K, Orig) ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState(_SendQBlock:List, _RecvQ, Buf, _Size, _T, Closed)
       ...</channels>
    requires (size(Buf) >Int 0)
      orBool (Closed ==Bool true)

  // Execute first ready receive ok case when sender available
  rule <thread>...
         <tid> _Tid </tid>
         <k> selectBlock(
              ListItem(evalRecvOkCase(Chan, V, Ok, Body)) _Rest:List,
              _Orig:List)
          => (V, Ok) := recvWithOk(Chan) ~> Body ... </k>
       ...</thread>
       <channels>...
         chanId(Chan)
           |-> chanState((ListItem(sendItem(_SendTid:Int, _SV)) _SendRest:List), _RecvQ, .List, _Size, _T, false)
       ...</channels>

  // ============================================================================
  // CASE EXECUTION
  // ============================================================================

  rule <k> executeSelectCase(evalSendCase(Chan, V, Body))
        => chanSend(Chan, V) ~> Body ... </k>

  rule <k> executeSelectCase(evalRecvCase(Chan, Body))
        => chanRecv(Chan) ~> Body ... </k>

  rule <k> executeSelectCase(evalRecvAssignCase(Chan, X, Body))
        => X = chanRecv(Chan) ~> Body ... </k>

  rule <k> executeSelectCase(evalRecvDeclCase(Chan, X, Body))
        => X := chanRecv(Chan) ~> Body ... </k>

  rule <k> executeSelectCase(evalRecvOkCase(Chan, V, Ok, Body))
        => (V, Ok) := recvWithOk(Chan) ~> Body ... </k>

  rule <k> executeSelectCase(evalDefaultCase(Body))
        => Body ... </k>

endmodule
