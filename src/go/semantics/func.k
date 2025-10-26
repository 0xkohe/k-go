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

  // Go specification: Named function call (looks up function definition)
  rule <k> F:Id (AL:ArgList) => enterScope(bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>
     <fenv> ... F |-> fun(PIs, PTs, RT, B) ... </fenv>

  // If F is not in fenv, evaluate it as a variable and retry the call
  syntax KItem ::= retryCall(K, ArgList)
  rule <k> F:Id (AL:ArgList) => retryCall(F, AL) ... </k>
       <fenv> FEnv </fenv>
    requires notBool (F in_keys(FEnv))

  context retryCall(HOLE:KItem, _)

  rule <k> retryCall(FV:FuncVal, AL) => FV (AL) ... </k>

  // Go specification: Named function reference as function value
  // When a function name is referenced (not called), return its function value
  rule <k> F:Id => funcVal(PIs, PTs, RT, Body, .Map, .Map) ... </k>
       <tenv> ... F |-> (_:FunctionType) ... </tenv>
       <fenv> ... F |-> fun(PIs, PTs, RT, Body) ... </fenv>

  // Go specification: Function value call (with closure environment)
  syntax KItem ::= restoreClosureEnv(Map, Map)

  rule <k> funcVal(PIs, PTs, RT, B, ClosEnvI, ClosEnvB) (AL:ArgList)
        => enterScope(restoreClosureEnv(ClosEnvI, ClosEnvB) ~> bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>

  // Restore closure environment by merging with current environment
  rule <k> restoreClosureEnv(ClosEnvI, ClosEnvB) => .K ... </k>
       <envI> CurEnvI => CurEnvI ClosEnvI </envI>
       <envB> CurEnvB => CurEnvB ClosEnvB </envB>

  rule <k> bindParams(.ParamIds, .ParamTypes, .ArgList) => .K ... </k>

  rule <k> bindParams((X:Id , Xs:ParamIds), (int  , Ts:ParamTypes), (V:Int  , Vs:ArgList))
        => var X int  = V ~> bindParams(Xs, Ts, Vs) ... </k>
  rule <k> bindParams((X:Id , Xs:ParamIds), (bool , Ts:ParamTypes), (V:Bool , Vs:ArgList))
        => var X bool = V ~> bindParams(Xs, Ts, Vs) ... </k>

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

  // Multiple value returns (tuple)
  rule <k> returnSignal(tuple(L:List)) ~> returnJoin(_PS:Parameters) => tuple(L) ... </k>

  rule <k> returnJoin(void) => .K ... </k>
  // Non-void functions without explicit return remain stuck.
endmodule
