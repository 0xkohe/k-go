requires "domains.md"
requires "../syntax/core.k"
requires "../syntax/func.k"
requires "../syntax/concurrent.k"

module GO
  imports GO-SYNTAX
  imports GO-SYNTAX-FUNC
  imports GO-SYNTAX-CONCURRENT
  imports INT
  imports LIST
  imports BOOL
  imports MAP
  imports ID
  imports STRING

  configuration
    <T>
      <threads>
        <thread multiplicity="*" type="Set" initial="">
          <tid> 0 </tid>
          <k> $PGM:Program </k>
          <tenv> .Map </tenv>
          <env> .Map </env>  // Id -> Location (unified environment for all types)
          <envStack> .List </envStack>  // Stack for block scoping
          <tenvStack> .List </tenvStack>
          <constEnv> .Map </constEnv>  // Id -> ConstValue (compile-time constants)
          <constEnvStack> .List </constEnvStack>  // Stack for constant block scoping
          <scopeDecls> .List </scopeDecls>
        </thread>
      </threads>
      <nextTid> 1 </nextTid>
      <out> .List </out>
      <store> .Map </store>  // Location -> Value (all values stored here)
      <nextLoc> 0 </nextLoc>  // Next available location
      <fenv> .Map </fenv>  // Function definitions (name -> definition)
      <channels> .Map </channels>  // Channel ID -> Channel state
      <nextChanId> 0 </nextChanId>
    </T>

  // Location type for store-based semantics
  syntax Loc ::= Int

  // Unified wrapper for runtime values paired with their declared types.
  // The first component stores the static type information that lives in <tenv>
  // (can be a simple Type, FunctionType, or ChannelType), while the second
  // component carries the actual runtime value stored in <store>.
  syntax GoValue ::= goValue(KItem, KResult)

  syntax KItem ::= goValueType(GoValue) [function]
  rule goValueType(goValue(T, _)) => T

  syntax KResult ::= goValueData(GoValue) [function]
  rule goValueData(goValue(_, V)) => V

  syntax Bool ::= typeMatches(KItem, GoValue) [function]
  rule typeMatches(T, goValue(T, _)) => true
  rule typeMatches(_, _) => false [owise]

  syntax GoValue ::= asGoValue(KItem, KResult) [function]
  rule asGoValue(int, V:Int) => goValue(int, V)
  rule asGoValue(bool, V:Bool) => goValue(bool, V)
  rule asGoValue(FT:FunctionType, FV:FuncVal) => goValue(FT, FV)
  rule asGoValue(Ty, V) => goValue(Ty, V) [owise]

  syntax KItem ::= allocateVar(Id, GoValue)
                 | allocateVarTyped(Id, GoValue, KItem)
                 | updateVar(Id, GoValue)
                 | initConst(Id, GoValue)
                 | initConstTyped(Id, GoValue, KItem)

  syntax K ::= toSeqTop(TopDecls) [function]
  rule toSeqTop(.TopDecls) => .K
  rule toSeqTop(TD:TopDecl ; TL:TopDecls) => TD ~> toSeqTop(TL)

  rule <k> package main TL:TopDecls func main ( ) B:Block TL2:TopDecls => toSeqTop(TL) ~> toSeqTop(TL2) ~> B ... </k>

  syntax KItem ::= enterScope(K) | "exitScope"
  syntax K ::= toSeq(StatementList) [function]
  rule toSeq(.StatementList) => .K
  rule toSeq(S:Statement ; SL:StatementList) => S ~> toSeq(SL)

  rule <k> { SL:StatementList ; } => enterScope(toSeq(SL)) ... </k>

  rule <k> enterScope(Body:K) => Body ~> exitScope ... </k>
       <tenv> T </tenv>
       <env> E </env>
       <tenvStack> TS => TS ListItem(T) </tenvStack>
       <envStack> ES => ES ListItem(E) </envStack>
       <constEnv> CE </constEnv>
       <constEnvStack> CS => CS ListItem(CE) </constEnvStack>
       <scopeDecls> SD => SD ListItem(.Map) </scopeDecls>

  rule <k> exitScope => .K ... </k>
       <tenvStack> (TS ListItem(T)) => TS </tenvStack>
       <envStack> (ES ListItem(E)) => ES </envStack>
       <tenv> _ => T </tenv>
       <env> _ => E </env>
       <constEnvStack> (CS ListItem(CE)) => CS </constEnvStack>
       <constEnv> _ => CE </constEnv>
       <scopeDecls> (SD ListItem(_)) => SD </scopeDecls>

  // print function for Int
  rule <k> print(I:Int) => .K ... </k>
       <out> OL => OL ListItem(I) </out>

  // print function for Bool (converts to 0/1 for output)
  rule <k> print(true) => .K ... </k>
       <out> OL => OL ListItem(1) </out>

  rule <k> print(false) => .K ... </k>
       <out> OL => OL ListItem(0) </out>

  // Variable declarations with store-based semantics
  rule <k> var X:Id int => var X int = 0 ... </k>
  rule <k> var X:Id bool => var X bool = false ... </k>
  rule <k> var X:Id FT:FunctionType => var X FT = nil ... </k>

  rule <k> var X:Id int = I:Int => allocateVar(X, goValue(int, I)) ... </k>

  rule <k> var X:Id bool = B:Bool => allocateVar(X, goValue(bool, B)) ... </k>

  // Go specification: Function type variable declaration
  // The zero value of function type is nil
  rule <k> var X:Id FT:FunctionType = FV:FuncVal => allocateVar(X, goValue(FT, FV)) ... </k>

  // Go specification: Constant declarations
  // Constants are compile-time values stored directly in constEnv
  // They don't consume runtime memory (no env/store allocation)
  // BUGFIX: Now tracks in scopeDecls for redeclaration detection

  syntax KItem ::= "constRedeclError"

  // Error rules for const redeclaration in same scope (priority 10)
  rule <k> const X:Id = _ => constRedeclError ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires X in_keys(ScopeMap)
    [priority(10)]

  rule <k> const X:Id _T:Type = _ => constRedeclError ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires X in_keys(ScopeMap)
    [priority(10)]

  // const x = value (type inference from value) - now with scopeDecls tracking
  rule <k> const X:Id = I:Int => initConst(X, goValue(int, I)) ... </k>

  rule <k> const X:Id = B:Bool => initConst(X, goValue(bool, B)) ... </k>

  // const x Type = value (explicit type) - now with scopeDecls tracking
  rule <k> const X:Id int = I:Int => initConst(X, goValue(int, I)) ... </k>

  rule <k> const X:Id bool = B:Bool => initConst(X, goValue(bool, B)) ... </k>

  rule <k> allocateVar(X:Id, GV:GoValue) => allocateVarTyped(X, GV, goValueType(GV)) ... </k>

  rule <k> allocateVarTyped(X:Id, GV:GoValue, Ty:KItem) => .K ... </k>
       <tenv> TEnv => TEnv [ X <- Ty ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- goValueData(GV) ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  rule <k> initConst(X:Id, GV:GoValue) => initConstTyped(X, GV, goValueType(GV)) ... </k>

  rule <k> initConstTyped(X:Id, GV:GoValue, Ty:KItem) => .K ... </k>
       <tenv> TEnv => TEnv [ X <- Ty ] </tenv>
       <constEnv> CE => CE [ X <- goValueData(GV) ] </constEnv>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  rule <k> updateVar(X:Id, GV:GoValue) => .K ... </k>
       <tenv> ... X |-> Ty ... </tenv>
       <env> ... X |-> L:Int ... </env>
       <store> Store => Store [ L <- goValueData(GV) ] </store>
       <constEnv> CE </constEnv>
    requires notBool (X in_keys(CE))
     andBool typeMatches(Ty, GV)

  // Short variable declarations with store-based semantics
  rule <k> X:Id := I:Int => allocateVar(X, goValue(int, I)) ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
       requires notBool (X in_keys(ScopeMap))

  rule <k> X:Id := B:Bool => allocateVar(X, goValue(bool, B)) ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
       requires notBool (X in_keys(ScopeMap))

  // Go specification: Short variable declaration with function value
  // Infer function type from funcVal
  syntax FunctionType ::= inferFuncType(ParamTypes, RetType) [function]
  rule inferFuncType(PTs, RT) => func parametersFromTypes(PTs) resultFromRetType(RT)

  syntax Parameters ::= parametersFromTypes(ParamTypes) [function]
  rule parametersFromTypes(.ParamTypes) => ( .ParameterList )
  rule parametersFromTypes(T:Type , Rest:ParamTypes) => ( T , paramListFromTypes(Rest) )
  rule parametersFromTypes(T:Type) => ( T )

  syntax ParameterList ::= paramListFromTypes(ParamTypes) [function]
  rule paramListFromTypes(.ParamTypes) => .ParameterList
  rule paramListFromTypes(T:Type , Rest:ParamTypes) => T , paramListFromTypes(Rest)
  rule paramListFromTypes(T:Type) => T

  syntax Result ::= resultFromRetType(RetType) [function]
  rule resultFromRetType(void) => ( .ParameterList )
  rule resultFromRetType(T:Type) => T
  rule resultFromRetType(PS:Parameters) => PS

  syntax KItem ::= typeOfValue(KResult) [function]
  rule typeOfValue(_I:Int) => int
  rule typeOfValue(_B:Bool) => bool
  rule typeOfValue(funcVal(_PIs, PTs, RT, _Body, _TEnv, _Env, _Meta)) => inferFuncType(PTs, RT)

  syntax GoValue ::= goValueFromResult(KResult) [function]
  rule goValueFromResult(V:KResult) => goValue(typeOfValue(V), V)

  // Match FuncVal with explicit parameter structure
  rule <k> X:Id := funcVal(PIs:ParamIds, PTs:ParamTypes, RT:RetType, Body:Block, TEnv:Map, Env:Map, _:Map)
        => allocateVar(X, goValue(inferFuncType(PTs, RT), funcVal(PIs, PTs, RT, Body, TEnv, Env, .Map))) ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
       requires notBool (X in_keys(ScopeMap))

  syntax KItem ::= "shortDeclError"

  // Error rules for short declaration of already declared variable
  // These have higher priority to be checked before normal declaration rules
  rule <k> X:Id := _ => shortDeclError ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires X in_keys(ScopeMap)
    [priority(10)]

  // Go specification: constants cannot be assigned
  // Check if identifier is a constant after value evaluation
  syntax KItem ::= "constAssignmentError"

  rule <k> X:Id = _ => constAssignmentError ... </k>
       <constEnv> ... X |-> _ ... </constEnv>
    [priority(10)]

  // Assignment with store-based semantics (update value at location)
  // These rules only match if X is not in constEnv
  rule <k> X:Id = I:Int => updateVar(X, goValue(int, I)) ... </k>
       <tenv> ... X |-> int ... </tenv>

  rule <k> X:Id = B:Bool => updateVar(X, goValue(bool, B)) ... </k>
       <tenv> ... X |-> bool ... </tenv>

  rule <k> X:Id = FV:FuncVal => updateVar(X, goValue(FT, FV)) ... </k>
       <tenv> ... X |-> FT:FunctionType ... </tenv>

  // ============================================================================
  // BLANK IDENTIFIER ASSIGNMENT
  // ============================================================================
  // Go specification: "The blank identifier provides a way to ignore right-hand
  // side values in an assignment: _ = x // evaluate x but ignore it"
  //
  // Any typed value may be assigned to the blank identifier. The value is
  // evaluated for side effects but discarded (not stored anywhere).
  //
  // Implementation: Blank identifier '_' is parsed as a regular Id,
  // but we check for the string "_" and discard the value.

  // Discard any KResult value assigned to blank identifier '_'
  // Check if X is the identifier "_" and discard the value
  rule <k> X:Id = I:Int => .K ... </k>
    requires Id2String(X) ==String "_"
    [priority(5)]

  rule <k> X:Id = B:Bool => .K ... </k>
    requires Id2String(X) ==String "_"
    [priority(5)]

  rule <k> X:Id = FV:FuncVal => .K ... </k>
    requires Id2String(X) ==String "_"
    [priority(5)]

  // Simplification: single-element IdentifierList/ExpressionList to Id/Exp
  // K's List macro can represent single elements as lists, need to simplify
  rule <k> IL:IdentifierList = EL:ExpressionList => extractSingleId(IL) = extractSingleExp(EL) ... </k>
    requires lenIdList(IL) ==Int 1 andBool lenExpList(EL) ==Int 1

  rule <k> IL:IdentifierList := EL:ExpressionList => extractSingleId(IL) := extractSingleExp(EL) ... </k>
    requires lenIdList(IL) ==Int 1 andBool lenExpList(EL) ==Int 1

  syntax Id ::= extractSingleId(IdentifierList) [function]
  rule extractSingleId(X:Id) => X
  rule extractSingleId(X:Id , .IdentifierList) => X

  syntax Exp ::= extractSingleExp(ExpressionList) [function]
  rule extractSingleExp(E:Exp) => E
  rule extractSingleExp(E:Exp , .ExpressionList) => E

  // Multiple assignment from tuple (from function call)
  // a, b = f() where f() returns tuple(...)
  syntax KItem ::= assignFromTuple(IdentifierList, List)
  syntax KItem ::= evalForAssign(IdentifierList, K)
  syntax KItem ::= evalAssignList(IdentifierList, ExpressionList, List)

  // Multi-variable assignment from single expression (function call returning tuple)
  rule <k> IL:IdentifierList = (E:Exp , .ExpressionList) => evalForAssign(IL, E) ... </k>
    requires lenIdList(IL) >=Int 2

  // Multi-variable assignment from multiple expressions (a, b = x+1, y+2)
  rule <k> IL:IdentifierList = EL:ExpressionList => evalAssignList(IL, EL, .List) ... </k>
    requires lenIdList(IL) >=Int 2
     andBool lenExpList(EL) >=Int 2

  // Evaluate each expression in ExpressionList for assignment
  // Note: We list each value type explicitly because K requires concrete sorts in patterns
  rule <k> evalAssignList(IL, (V:Int , Rest:ExpressionList), Acc:List)
        => evalAssignList(IL, Rest, Acc ListItem(V)) ... </k>

  rule <k> evalAssignList(IL, (V:Bool , Rest:ExpressionList), Acc:List)
        => evalAssignList(IL, Rest, Acc ListItem(V)) ... </k>

  rule <k> evalAssignList(IL, (FV:FuncVal , Rest:ExpressionList), Acc:List)
        => evalAssignList(IL, Rest, Acc ListItem(FV)) ... </k>

  rule <k> evalAssignList(IL, V:Int, Acc:List)
        => assignFromTuple(IL, Acc ListItem(V)) ... </k>

  rule <k> evalAssignList(IL, V:Bool, Acc:List)
        => assignFromTuple(IL, Acc ListItem(V)) ... </k>

  rule <k> evalAssignList(IL, FV:FuncVal, Acc:List)
        => assignFromTuple(IL, Acc ListItem(FV)) ... </k>

  rule <k> evalAssignList(IL, .ExpressionList, Acc:List)
        => assignFromTuple(IL, Acc) ... </k>

  // Context: evaluate expressions in evalAssignList
  context evalAssignList(_, (HOLE:Exp , _:ExpressionList), _)
  context evalAssignList(_, HOLE:Exp, _)

  context evalForAssign(_, HOLE:KItem)

  rule <k> evalForAssign(IL, tuple(L:List)) => assignFromTuple(IL, L) ... </k>

  rule <k> assignFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:KResult) LRest:List))
        => updateVar(X, asGoValue(Ty, V)) ~> assignFromTuple(ILRest, LRest) ... </k>
       <tenv> ... X |-> Ty ... </tenv>

  rule <k> assignFromTuple(X:Id, ListItem(V:KResult))
        => updateVar(X, asGoValue(Ty, V)) ... </k>
       <tenv> ... X |-> Ty ... </tenv>

  rule <k> assignFromTuple(.IdentifierList, .List) => .K ... </k>

  // Multiple short variable declaration (handles mix of new and existing identifiers)
  syntax KItem ::= evalForShortDecl(IdentifierList, K, Map)
  syntax KItem ::= shortDeclFromTuple(IdentifierList, List, Map)
  syntax KItem ::= evalShortDeclList(IdentifierList, ExpressionList, List, Map)

  // Multi-variable short declaration from single expression (function call returning tuple)
  rule <k> IL:IdentifierList := (E:Exp , .ExpressionList) => evalForShortDecl(IL, E, ScopeMap) ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires lenIdList(IL) >=Int 2
     andBool hasNewIdList(IL, ScopeMap)

  rule <k> IL:IdentifierList := (_E:Exp , .ExpressionList) => shortDeclError ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires lenIdList(IL) >=Int 2
     andBool notBool hasNewIdList(IL, ScopeMap)

  // Multi-variable short declaration from multiple expressions (a, b := x+1, y+2)
  rule <k> IL:IdentifierList := EL:ExpressionList => evalShortDeclList(IL, EL, .List, ScopeMap) ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires lenIdList(IL) >=Int 2
     andBool lenExpList(EL) >=Int 2
     andBool hasNewIdList(IL, ScopeMap)

  rule <k> IL:IdentifierList := EL:ExpressionList => shortDeclError ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires lenIdList(IL) >=Int 2
     andBool lenExpList(EL) >=Int 2
     andBool notBool hasNewIdList(IL, ScopeMap)

  // Evaluate each expression in ExpressionList and accumulate
  // Note: We list each value type explicitly because K requires concrete sorts in patterns
  rule <k> evalShortDeclList(IL, (V:Int , Rest:ExpressionList), Acc:List, ScopeMap)
        => evalShortDeclList(IL, Rest, Acc ListItem(V), ScopeMap) ... </k>

  rule <k> evalShortDeclList(IL, (V:Bool , Rest:ExpressionList), Acc:List, ScopeMap)
        => evalShortDeclList(IL, Rest, Acc ListItem(V), ScopeMap) ... </k>

  rule <k> evalShortDeclList(IL, (FV:FuncVal , Rest:ExpressionList), Acc:List, ScopeMap)
        => evalShortDeclList(IL, Rest, Acc ListItem(FV), ScopeMap) ... </k>

  rule <k> evalShortDeclList(IL, V:Int, Acc:List, ScopeMap)
        => shortDeclFromTuple(IL, Acc ListItem(V), ScopeMap) ... </k>

  rule <k> evalShortDeclList(IL, V:Bool, Acc:List, ScopeMap)
        => shortDeclFromTuple(IL, Acc ListItem(V), ScopeMap) ... </k>

  rule <k> evalShortDeclList(IL, FV:FuncVal, Acc:List, ScopeMap)
        => shortDeclFromTuple(IL, Acc ListItem(FV), ScopeMap) ... </k>

  rule <k> evalShortDeclList(IL, .ExpressionList, Acc:List, ScopeMap)
        => shortDeclFromTuple(IL, Acc, ScopeMap) ... </k>

  // Context: evaluate expressions in evalShortDeclList
  context evalShortDeclList(_, (HOLE:Exp , _:ExpressionList), _, _)
  context evalShortDeclList(_, HOLE:Exp, _, _)

  context evalForShortDecl(_, HOLE:KItem, _)

  rule <k> evalForShortDecl(IL, tuple(L:List), ScopeMap) => shortDeclFromTuple(IL, L, ScopeMap) ... </k>

  rule <k> shortDeclFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:KResult) LRest:List), ScopeMap)
        => allocateVar(X, goValueFromResult(V)) ~> shortDeclFromTuple(ILRest, LRest, ScopeMap) ... </k>
    requires notBool (X in_keys(ScopeMap))

  rule <k> shortDeclFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:KResult) LRest:List), ScopeMap)
        => updateVar(X, asGoValue(Ty, V)) ~> shortDeclFromTuple(ILRest, LRest, ScopeMap) ... </k>
       <tenv> ... X |-> Ty ... </tenv>
    requires X in_keys(ScopeMap)

  rule <k> shortDeclFromTuple(X:Id, ListItem(V:KResult), ScopeMap) => allocateVar(X, goValueFromResult(V)) ... </k>
    requires notBool (X in_keys(ScopeMap))

  rule <k> shortDeclFromTuple(X:Id, ListItem(V:KResult), ScopeMap) => updateVar(X, asGoValue(Ty, V)) ... </k>
       <tenv> ... X |-> Ty ... </tenv>
    requires X in_keys(ScopeMap)

  rule <k> shortDeclFromTuple(.IdentifierList, .List, _ScopeMap) => .K ... </k>

  // Identifier lookup: check constants first, then variables
  // Constants have priority (compile-time values)
  rule <k> X:Id => V ... </k>
       <constEnv> ... X |-> V ... </constEnv>
    [priority(10)]

  // Variable lookup with store-based semantics
  rule <k> X:Id => V ... </k>
       <env> ... X |-> L:Int ... </env>
       <store> ... L |-> V ... </store>
    [priority(20)]

  rule <k> I1:Int + I2:Int => I1 +Int I2 ... </k>
  rule <k> I1:Int - I2:Int => I1 -Int I2 ... </k>
  rule <k> I1:Int * I2:Int => I1 *Int I2 ... </k>
  rule <k> I1:Int / I2:Int => I1 /Int I2 ... </k>
  rule <k> I1:Int % I2:Int => I1 %Int I2 ... </k>

  rule <k> I1:Int <  I2:Int => I1 <Int  I2 ... </k>
  rule <k> I1:Int <= I2:Int => I1 <=Int I2 ... </k>
  rule <k> I1:Int >  I2:Int => I1 >Int  I2 ... </k>
  rule <k> I1:Int >= I2:Int => I1 >=Int I2 ... </k>
  rule <k> I1:Int == I2:Int => I1 ==Int I2 ... </k>
  rule <k> I1:Int != I2:Int => notBool (I1 ==Int I2) ... </k>

  rule <k> B1:Bool == B2:Bool => B1 ==Bool B2 ... </k>
  rule <k> B1:Bool != B2:Bool => notBool (B1 ==Bool B2) ... </k>
  rule <k> - I:Int => 0 -Int I ... </k>

  context HOLE && _E:Exp
  rule <k> true && E:Exp => E ... </k>
  rule <k> false && _E:Exp => false ... </k>

  context HOLE || _E:Exp
  rule <k> true || _E:Exp => true ... </k>
  rule <k> false || E:Exp => E ... </k>
  rule <k> ! B:Bool           => notBool B    ... </k>

  // Direct implementation of increment/decrement (avoids parsing ambiguity)
  rule <k> X:Id ++ => .K ... </k>
       <env> ... X |-> L:Int ... </env>
       <store> ... L |-> (V:Int => V +Int 1) ... </store>

  rule <k> X:Id -- => .K ... </k>
       <env> ... X |-> L:Int ... </env>
       <store> ... L |-> (V:Int => V -Int 1) ... </store>

  syntax KResult ::= Int | Bool | FuncVal | Tuple

  // Helper to convert ExpressionList to List for values
  syntax List ::= expListToList(ExpressionList) [function]
  rule expListToList(.ExpressionList) => .List
  rule expListToList(E:Exp , EL:ExpressionList) => ListItem(E) expListToList(EL)
  rule expListToList(E:Exp) => ListItem(E)

  // Helper to create tuple from ExpressionList
  rule makeTuple(EL:ExpressionList) => tuple(expListToList(EL))

  // Helper to get length of ExpressionList
  syntax Int ::= lenExpList(ExpressionList) [function]
  rule lenExpList(.ExpressionList) => 0
  rule lenExpList(_:Exp , EL:ExpressionList) => 1 +Int lenExpList(EL)
  rule lenExpList(_:Exp) => 1

  // Helper to get length of IdentifierList
  syntax Int ::= lenIdList(IdentifierList) [function]
  rule lenIdList(.IdentifierList) => 0
  rule lenIdList(_:Id , IL:IdentifierList) => 1 +Int lenIdList(IL)
  rule lenIdList(_:Id) => 1

  syntax Bool ::= hasNewIdList(IdentifierList, Map) [function]
  rule hasNewIdList(.IdentifierList, _M:Map) => false
  rule hasNewIdList(X:Id , IL:IdentifierList, M:Map) => notBool (X in_keys(M)) orBool hasNewIdList(IL, M)
  rule hasNewIdList(X:Id, M:Map) => notBool (X in_keys(M))
endmodule
