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

  rule <k> F:Id (AL:ArgList) => enterScope(bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>
     <fenv> ... F |-> fun(PIs, PTs, RT, B) ... </fenv>

  rule <k> bindParams(.ParamIds, .ParamTypes, .ArgList) => .K ... </k>

  rule <k> bindParams((X:Id , Xs:ParamIds), (int  , Ts:ParamTypes), (V:Int  , Vs:ArgList))
        => var X int  = V ~> bindParams(Xs, Ts, Vs) ... </k>
  rule <k> bindParams((X:Id , Xs:ParamIds), (bool , Ts:ParamTypes), (V:Bool , Vs:ArgList))
        => var X bool = V ~> bindParams(Xs, Ts, Vs) ... </k>

  syntax KItem ::= returnSignal(K)

  // Void return
  rule <k> return => returnSignal(.K) ... </k>

  // Single return value
  rule <k> return V:Int , .ExpressionList => returnSignal(V) ... </k>
  rule <k> return V:Bool , .ExpressionList => returnSignal(V) ... </k>

  // Multiple return values (ExpressionList with 2+ elements)
  rule <k> return (E1:Exp , E2:Exp) => returnSignal(tuple(ListItem(E1) ListItem(E2))) ... </k>
  rule <k> return (E1:Exp , E2:Exp , EL:ExpressionList) => returnSignal(tuple(ListItem(E1) ListItem(E2) expListToList(EL))) ... </k>

  rule <k> returnSignal(V) ~> exitScope => exitScope ~> returnSignal(V) ... </k>

  rule <k> returnSignal(V) ~> _KI:KItem => returnSignal(V) ... </k> [owise]

  // Void return
  rule <k> returnSignal(_V) ~> returnJoin(void) => .K ... </k>

  // Single value return
  rule <k> returnSignal(V:Int)  ~> returnJoin(int)  => V ... </k>
  rule <k> returnSignal(V:Bool) ~> returnJoin(bool) => V ... </k>

  // Multiple value return
  rule <k> returnSignal(tuple(L:List)) ~> returnJoin(PS:Parameters) => tuple(L) ... </k>
    requires matchTypes(L, paramTypesOf(PS))

  rule <k> returnJoin(void) => .K ... </k>
  // Non-void functions without explicit return remain stuck.

  // Helper to check if types match
  syntax Bool ::= matchTypes(List, ParamTypes) [function]
  rule matchTypes(.List, .ParamTypes) => true
  rule matchTypes((ListItem(_:Int) L), (int , PTS)) => matchTypes(L, PTS)
  rule matchTypes((ListItem(_:Bool) L), (bool , PTS)) => matchTypes(L, PTS)
  rule matchTypes(ListItem(_:Int), int) => true
  rule matchTypes(ListItem(_:Bool), bool) => true
  rule matchTypes(_, _) => false [owise]
endmodule
