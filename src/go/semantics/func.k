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

  // Helper to evaluate all arguments before calling
  syntax KItem ::= evalAndCall(Id, ArgList, ParamIds, ParamTypes, RetType, Block)

  // Go specification: Named function call (looks up function definition)
  rule <k> F:Id (AL:ArgList) => evalAndCall(F, AL, PIs, PTs, RT, B) ... </k>
     <fenv> ... F |-> fun(PIs, PTs, RT, B) ... </fenv>

  // Evaluate arguments using context for each position
  context evalAndCall(_, (HOLE , _), _, _, _, _)
  context evalAndCall(_, (_ , HOLE , _), _, _, _, _)
  context evalAndCall(_, (_ , _ , HOLE), _, _, _, _)
  context evalAndCall(_, (HOLE), _, _, _, _)

  // Once all arguments are evaluated, proceed with the call
  rule <k> evalAndCall(F, AL, PIs, PTs, RT, B) => enterScope(bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>
    requires allValues(AL)

  syntax Bool ::= allValues(ArgList) [function]
  rule allValues(.ArgList) => true
  rule allValues(V:Int) => true
  rule allValues(V:Bool) => true
  rule allValues(V:FuncVal) => true
  rule allValues((V:Int , Rest:ArgList)) => allValues(Rest)
  rule allValues((V:Bool , Rest:ArgList)) => allValues(Rest)
  rule allValues((V:FuncVal , Rest:ArgList)) => allValues(Rest)
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
  rule <k> func Sig:FunctionSignature B:Block
        => funcVal(paramIdsOf(parametersOf(Sig)),
                   paramTypesOf(parametersOf(Sig)),
                   retTypeOf(Sig),
                   B,
                   TEnv,  // Capture current type environment
                   EnvI,  // Capture current integer environment
                   EnvB)  // Capture current boolean environment
           ... </k>
       <tenv> TEnv </tenv>
       <envI> EnvI </envI>
       <envB> EnvB </envB>

  // Go specification: Function value call (with closure environment)
  syntax KItem ::= restoreClosureEnv(Map, Map, Map)

  rule <k> funcVal(PIs, PTs, RT, B, ClosTEnv, ClosEnvI, ClosEnvB) (AL:ArgList)
        => enterScope(restoreClosureEnv(ClosTEnv, ClosEnvI, ClosEnvB) ~> bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>

  // Restore closure environment (replace current environment)
  // Functions should only see captured environment + their parameters
  rule <k> restoreClosureEnv(ClosTEnv, ClosEnvI, ClosEnvB) => .K ... </k>
       <tenv> _ => ClosTEnv </tenv>
       <envI> _ => ClosEnvI </envI>
       <envB> _ => ClosEnvB </envB>

  rule <k> bindParams(.ParamIds, .ParamTypes, .ArgList) => .K ... </k>

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
