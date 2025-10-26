requires "domains.md"
requires "core.k"
requires "../syntax/func.k"

module GO-FUNC
  imports GO
  imports GO-SYNTAX-FUNC
  imports LIST
  imports MAP

  syntax FunDef ::= fun(ParamIds, ParamTypes, RetType, Block)

  rule <k> func F:Id Sig:FunctionSignature B:Block => .K ... </k>
       <tenv> TEnv => TEnv [ F <- (func Sig) ] </tenv>
       <fenv> FEnv => FEnv
         [ F <- fun(paramIdsOf(parametersOf(Sig)), paramTypesOf(parametersOf(Sig)), retTypeOf(Sig), B) ] </fenv>

  syntax KItem ::= runFunc(RetType, Block)
  syntax KItem ::= returnJoin(RetType)
  syntax KItem ::= bindParams(ParamIds, ParamTypes, ArgList)

  // Context rules to evaluate arguments
  context _:Id ( HOLE:Exp , _:ArgList )
  context _:Id ( _:Exp , HOLE:Exp , _:ArgList )
  context _:Id ( _:Exp , _:Exp , HOLE:Exp , _:ArgList )
  context _:Id ( HOLE:Exp )

  // Go specification: Named function call (looks up function definition)
  rule <k> F:Id (AL:ArgList) => enterScope(bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>
     <fenv> ... F |-> fun(PIs, PTs, RT, B) ... </fenv>
    requires allValues(AL)

  syntax Bool ::= allValues(ArgList) [function]
  rule allValues(.ArgList) => true
  rule allValues(_V:Int) => true
  rule allValues(_V:Bool) => true
  rule allValues(_V:FuncVal) => true
  rule allValues((_V:Int , Rest:ArgList)) => allValues(Rest)
  rule allValues((_V:Bool , Rest:ArgList)) => allValues(Rest)
  rule allValues((_V:FuncVal , Rest:ArgList)) => allValues(Rest)
  rule allValues(_) => false [owise]

  // If F is not in fenv, evaluate it as a variable and retry the call
  syntax KItem ::= retryCall(K, ArgList)
  rule <k> F:Id (AL:ArgList) => retryCall(F, AL) ... </k>
       <fenv> FEnv </fenv>
    requires notBool (F in_keys(FEnv))

  context retryCall(HOLE:KItem, _)

  rule <k> retryCall(FV:FuncVal, AL) => FV (AL) ... </k>

  // Go specification: Named function reference as function value
  // When a function name is referenced (not called), return its function value
  rule <k> F:Id => funcVal(PIs, PTs, RT, Body, .Map, .Map, .Map) ... </k>
       <tenv> ... F |-> (_:FunctionType) ... </tenv>
       <fenv> ... F |-> fun(PIs, PTs, RT, Body) ... </fenv>

  // Go specification: Function literal evaluation
  // Creates a function value with closure environment captured
  // NOW CAPTURES ONLY ENV (Id -> Loc), sharing the same store!
  rule <k> func Sig:FunctionSignature B:Block
        => funcVal(paramIdsOf(parametersOf(Sig)),
                   paramTypesOf(parametersOf(Sig)),
                   retTypeOf(Sig),
                   B,
                   TEnv,  // Capture current type environment
                   Env,   // Capture current environment (Id -> Loc)
                   .Map)  // No longer needed (kept for compatibility)
           ... </k>
       <tenv> TEnv </tenv>
       <env> Env </env>

  // Go specification: Function value call (with closure environment)
  syntax KItem ::= restoreClosureEnv(Map, Map, Map)

  rule <k> funcVal(PIs, PTs, RT, B, ClosTEnv, ClosEnv, _) (AL:ArgList)
        => enterScope(restoreClosureEnv(ClosTEnv, ClosEnv, .Map) ~> bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>

  // Restore closure environment (replace current environment)
  // The key change: we restore env (Id -> Loc) which SHARES the store!
  // This enables reference-based closure semantics
  rule <k> restoreClosureEnv(ClosTEnv, ClosEnv, _) => .K ... </k>
       <tenv> _ => ClosTEnv </tenv>
       <env> _ => ClosEnv </env>

  rule <k> bindParams(.ParamIds, .ParamTypes, .ArgList) => .K ... </k>

  // bindParams now uses var declarations which handle location allocation
  rule <k> bindParams((X:Id , Xs:ParamIds), (int  , Ts:ParamTypes), (V:Int  , Vs:ArgList))
        => var X int  = V ~> bindParams(Xs, Ts, Vs) ... </k>
  rule <k> bindParams((X:Id , Xs:ParamIds), (bool , Ts:ParamTypes), (V:Bool , Vs:ArgList))
        => var X bool = V ~> bindParams(Xs, Ts, Vs) ... </k>
  rule <k> bindParams((X:Id , Xs:ParamIds), (FT:FunctionType , Ts:ParamTypes), (FV:FuncVal , Vs:ArgList))
        => var X FT = FV ~> bindParams(Xs, Ts, Vs) ... </k>

  syntax KItem ::= returnSignal(K)

  // Return statement evaluation
  rule <k> return       => returnSignal(.K) ... </k>
  rule <k> return V:Exp => returnSignal(V) ... </k>

  // Multiple value return: convert ExpressionList to tuple
  // Only match when there are 2+ elements to avoid conflict with single Exp
  syntax KItem ::= evalReturnList(ExpressionList, List)

  rule <k> return EL:ExpressionList => evalReturnList(EL, .List) ... </k>
    requires lenExpList(EL) >=Int 2

  // Evaluate each element in ExpressionList and accumulate in List
  rule <k> evalReturnList((V:Int , Rest:ExpressionList), Acc:List)
        => evalReturnList(Rest, Acc ListItem(V)) ... </k>
  rule <k> evalReturnList((V:Bool , Rest:ExpressionList), Acc:List)
        => evalReturnList(Rest, Acc ListItem(V)) ... </k>
  rule <k> evalReturnList(V:Int, Acc:List)
        => returnTuple(tuple(Acc ListItem(V))) ... </k>
  rule <k> evalReturnList(V:Bool, Acc:List)
        => returnTuple(tuple(Acc ListItem(V))) ... </k>
  rule <k> evalReturnList(.ExpressionList, Acc:List)
        => returnTuple(tuple(Acc)) ... </k>

  // Context: evaluate non-value expressions in evalReturnList
  context evalReturnList((HOLE:Exp , _:ExpressionList), _)
  context evalReturnList(HOLE:Exp, _)

  // Internal tuple return
  rule <k> returnTuple(T:Tuple) => returnSignal(T) ... </k>

  rule <k> returnSignal(V) ~> exitScope => exitScope ~> returnSignal(V) ... </k>
  rule <k> returnSignal(V) ~> _KI:KItem => returnSignal(V) ... </k> [owise]

  // Single value returns
  rule <k> returnSignal(_V) ~> returnJoin(void) => .K ... </k>
  rule <k> returnSignal(V:Int)  ~> returnJoin(int)  => V ... </k>
  rule <k> returnSignal(V:Bool) ~> returnJoin(bool) => V ... </k>
  rule <k> returnSignal(FV:FuncVal) ~> returnJoin(_FT:FunctionType) => FV ... </k>

  // Multiple value returns (tuple)
  rule <k> returnSignal(tuple(L:List)) ~> returnJoin(_PS:Parameters) => tuple(L) ... </k>

  rule <k> returnJoin(void) => .K ... </k>
  // Non-void functions without explicit return remain stuck.
endmodule
