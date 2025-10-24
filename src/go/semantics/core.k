requires "domains.md"
requires "../syntax/core.k"
requires "../syntax/func.k"

module GO
  imports GO-SYNTAX
  imports GO-SYNTAX-FUNC
  imports INT
  imports LIST
  imports BOOL
  imports MAP
  imports ID

  configuration
    <T>
      <k> $PGM:Program </k>
      <out> .List </out>
      <tenv> .Map </tenv>
      <envI> .Map </envI>
      <envB> .Map </envB>
      <envF> .Map </envF>  // Function values environment
      <tenvStack> .List </tenvStack>
      <envIStack> .List </envIStack>
      <envBStack> .List </envBStack>
      <envFStack> .List </envFStack>  // Function values environment stack
      <fenv> .Map </fenv>  // Function definitions (name -> definition)
    </T>

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
       <envI> I </envI>
       <envB> B </envB>
       <envF> F </envF>
       <tenvStack> TS => TS ListItem(T) </tenvStack>
       <envIStack> IS => IS ListItem(I) </envIStack>
       <envBStack> BS => BS ListItem(B) </envBStack>
       <envFStack> FS => FS ListItem(F) </envFStack>

  rule <k> exitScope => .K ... </k>
       <tenvStack> (TS ListItem(T)) => TS </tenvStack>
       <envIStack> (IS ListItem(I)) => IS </envIStack>
       <envBStack> (BS ListItem(BV)) => BS </envBStack>
       <envFStack> (FS ListItem(FV)) => FS </envFStack>
       <tenv> _ => T </tenv>
       <envI> _ => I </envI>
       <envB> _ => BV </envB>
       <envF> _ => FV </envF>

  rule <k> print(I:Int) => .K ... </k>
       <out> OL => OL ListItem(I) </out>

  rule <k> var X:Id int = I:Int => .K ... </k>
       <tenv> R => R [ X <- int ] </tenv>
       <envI> Rho => Rho [ X <- I ] </envI>

  rule <k> var X:Id bool = B:Bool => .K ... </k>
       <tenv> R => R [ X <- bool ] </tenv>
       <envB> Rho => Rho [ X <- B ] </envB>

  // Go specification: Function type variable declaration
  // The zero value of function type is nil
  rule <k> var X:Id FT:FunctionType = FV:FuncVal => .K ... </k>
       <tenv> R => R [ X <- FT ] </tenv>
       <envF> Rho => Rho [ X <- FV ] </envF>

  rule <k> X:Id := I:Int => .K ... </k>
       <tenv> R => R [ X <- int ] </tenv>
       <envI> Rho => Rho [ X <- I ] </envI>

  rule <k> X:Id := B:Bool => .K ... </k>
       <tenv> R => R [ X <- bool ] </tenv>
       <envB> Rho => Rho [ X <- B ] </envB>

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

  rule <k> X:Id := funcVal(_, PTs, RT, _, _, _, _) #as FV:FuncVal => .K ... </k>
       <tenv> R => R [ X <- inferFuncType(PTs, RT) ] </tenv>
       <envF> Rho => Rho [ X <- FV ] </envF>

  rule <k> X:Id = I:Int => .K ... </k>
       <tenv> ... X |-> int ... </tenv>
       <envI> Rho => Rho [ X <- I ] </envI>

  rule <k> X:Id = B:Bool => .K ... </k>
       <tenv> ... X |-> bool ... </tenv>
       <envB> Rho => Rho [ X <- B ] </envB>

  rule <k> X:Id = FV:FuncVal => .K ... </k>
       <tenv> ... X |-> _FT:FunctionType ... </tenv>
       <envF> Rho => Rho [ X <- FV ] </envF>

  // Simplification: single-element IdentifierList to Id
  // K's List macro can represent single Id as IdentifierList, need to simplify
  rule <k> IL:IdentifierList = E:Exp => extractSingleId(IL) = E ... </k>
    requires lenIdList(IL) ==Int 1

  rule <k> IL:IdentifierList := E:Exp => extractSingleId(IL) := E ... </k>
    requires lenIdList(IL) ==Int 1

  syntax Id ::= extractSingleId(IdentifierList) [function]
  rule extractSingleId(X:Id) => X
  rule extractSingleId(X:Id , .IdentifierList) => X

  // Multiple assignment from tuple (from function call)
  // a, b = f() where f() returns tuple(...)
  syntax KItem ::= assignFromTuple(IdentifierList, List)
  syntax KItem ::= evalForAssign(IdentifierList, K)

  // Multi-variable assignment (2+ identifiers)
  rule <k> IL:IdentifierList = (E:Exp , .ExpressionList) => evalForAssign(IL, E) ... </k>
    requires lenIdList(IL) >=Int 2

  context evalForAssign(_, HOLE:KItem)

  rule <k> evalForAssign(IL, tuple(L:List)) => assignFromTuple(IL, L) ... </k>

  rule <k> assignFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:Int) LRest:List)) => assignFromTuple(ILRest, LRest) ... </k>
       <tenv> ... X |-> int ... </tenv>
       <envI> Rho => Rho [ X <- V ] </envI>

  rule <k> assignFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:Bool) LRest:List)) => assignFromTuple(ILRest, LRest) ... </k>
       <tenv> ... X |-> bool ... </tenv>
       <envB> Rho => Rho [ X <- V ] </envB>

  rule <k> assignFromTuple(X:Id, ListItem(V:Int)) => .K ... </k>
       <tenv> ... X |-> int ... </tenv>
       <envI> Rho => Rho [ X <- V ] </envI>

  rule <k> assignFromTuple(X:Id, ListItem(V:Bool)) => .K ... </k>
       <tenv> ... X |-> bool ... </tenv>
       <envB> Rho => Rho [ X <- V ] </envB>

  rule <k> assignFromTuple(.IdentifierList, .List) => .K ... </k>

  // Multiple short variable declaration from tuple
  syntax KItem ::= declareFromTuple(IdentifierList, List)
  syntax KItem ::= evalForDeclare(IdentifierList, K)

  // Multi-variable short declaration (2+ identifiers)
  rule <k> IL:IdentifierList := (E:Exp , .ExpressionList) => evalForDeclare(IL, E) ... </k>
    requires lenIdList(IL) >=Int 2

  context evalForDeclare(_, HOLE:KItem)

  rule <k> evalForDeclare(IL, tuple(L:List)) => declareFromTuple(IL, L) ... </k>

  rule <k> declareFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:Int) LRest:List)) => declareFromTuple(ILRest, LRest) ... </k>
       <tenv> TEnv => TEnv [ X <- int ] </tenv>
       <envI> Rho => Rho [ X <- V ] </envI>

  rule <k> declareFromTuple((X:Id , ILRest:IdentifierList), (ListItem(V:Bool) LRest:List)) => declareFromTuple(ILRest, LRest) ... </k>
       <tenv> TEnv => TEnv [ X <- bool ] </tenv>
       <envB> Rho => Rho [ X <- V ] </envB>

  rule <k> declareFromTuple(X:Id, ListItem(V:Int)) => .K ... </k>
       <tenv> TEnv => TEnv [ X <- int ] </tenv>
       <envI> Rho => Rho [ X <- V ] </envI>

  rule <k> declareFromTuple(X:Id, ListItem(V:Bool)) => .K ... </k>
       <tenv> TEnv => TEnv [ X <- bool ] </tenv>
       <envB> Rho => Rho [ X <- V ] </envB>

  rule <k> declareFromTuple(.IdentifierList, .List) => .K ... </k>

  rule <k> X:Id => I ... </k>
       <envI> ... X |-> I:Int ... </envI>
  rule <k> X:Id => B ... </k>
       <envB> ... X |-> B:Bool ... </envB>
  rule <k> X:Id => FV ... </k>
       <envF> ... X |-> FV:FuncVal ... </envF>

  rule <k> I1:Int + I2:Int => I1 +Int I2 ... </k>
  rule <k> I1:Int - I2:Int => I1 -Int I2 ... </k>
  rule <k> I1:Int * I2:Int => I1 *Int I2 ... </k>
  rule <k> I1:Int / I2:Int => I1 /Int I2 ... </k>
  rule <k> I1:Int % I2:Int => I1 %Int I2 ... </k>

  rule <k> I1:Int <  I2:Int => I1 <Int  I2 ... </k>
  rule <k> I1:Int >  I2:Int => I1 >Int  I2 ... </k>
  rule <k> I1:Int == I2:Int => I1 ==Int I2 ... </k>
  rule <k> - I:Int => 0 -Int I ... </k>

  rule <k> B1:Bool && B2:Bool => B1 andBool B2 ... </k>
  rule <k> B1:Bool || B2:Bool => B1 orBool  B2 ... </k>
  rule <k> ! B:Bool           => notBool B    ... </k>

  rule <k> X:Id ++ => X = (X + 1) ... </k>
       <tenv> ... X |-> int ... </tenv>

  rule <k> X:Id -- => X = (X - 1) ... </k>
       <tenv> ... X |-> int ... </tenv>

  rule <k> if S:SimpleStmt ; E:Exp B:Block => S ~> if E B ... </k>
  rule <k> if S:SimpleStmt ; E:Exp B1:Block else B2:Block => S ~> if E B1 else B2 ... </k>
  rule <k> if S:SimpleStmt ; E:Exp B1:Block else I2:IfStmt => S ~> if E B1 else I2 ... </k>

  rule <k> if true  B:Block => B  ... </k>
  rule <k> if false _B:Block => .K ... </k>
  rule <k> if true  B1:Block else _B2:Block => B1 ... </k>
  rule <k> if false _B1:Block else B2:Block => B2 ... </k>

  // Go specification: For loop internals
  syntax KItem ::= loop(Exp, K, Block)
  syntax KItem ::= loopV(Exp, Exp, K, Block) [strict(1)]
  syntax KItem ::= "breakSignal" | "continueSignal"

  // Go specification: "for" Block - infinite loop
  rule <k> for B:Block => enterScope(loop(true, .K, B)) ... </k>

  // Go specification: "for" Condition Block - condition-only loop
  rule <k> for E:Condition B:Block => enterScope(loop(E, .K, B)) ... </k>

  // Go specification: "for" ForClause Block - full for loop
  rule <k> for S1:SimpleStmt ; E:Exp ; S2:SimpleStmt B:Block => enterScope(S1 ~> loop(E, S2, B)) ... </k>
  rule <k> for S1:SimpleStmt ; ; S2:SimpleStmt B:Block       => enterScope(S1 ~> loop(true, S2, B)) ... </k>
  rule <k> for S1:SimpleStmt ; E:Exp ; B:Block               => enterScope(S1 ~> loop(E, .K, B)) ... </k>
  rule <k> for ; E:Exp ; S2:SimpleStmt B:Block               => enterScope(loop(E, S2, B)) ... </k>
  rule <k> for ; ; S2:SimpleStmt B:Block                     => enterScope(loop(true, S2, B)) ... </k>
  rule <k> for ; E:Exp ; B:Block                             => enterScope(loop(E, .K, B)) ... </k>
  rule <k> for S1:SimpleStmt ; ; B:Block                     => enterScope(S1 ~> loop(true, .K, B)) ... </k>
  rule <k> for ; ; B:Block                                   => enterScope(loop(true, .K, B)) ... </k>

  rule <k> loop(E:Exp, SP:K, B:Block) => loopV(E, E, SP, B) ... </k>

  rule <k> loopV(true, E, SP:K, B:Block) => B ~> SP ~> loop(E, SP, B) ... </k>

  rule <k> loopV(false, _E, _SP, _B) => .K ... </k>

  rule <k> break    => breakSignal    ... </k>
  rule <k> continue => continueSignal ... </k>

  rule <k> continueSignal ~> _KI:KItem => continueSignal ... </k> [owise]
  rule <k> breakSignal    ~> _KI:KItem => breakSignal    ... </k> [owise]

  rule <k> continueSignal ~> loop(E, SP, B) => SP ~> loop(E, SP, B) ... </k>

  rule <k> breakSignal ~> loop(_E, _SP, _B) => .K ... </k>

  syntax Bool ::= isKResult(K) [symbol(isKResult), function]
  rule isKResult(_:Int)  => true
  rule isKResult(_:Bool) => true
  rule isKResult(tuple(_)) => true
  rule isKResult(_:FuncVal) => true
  rule isKResult(_)      => false [owise]


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
endmodule
