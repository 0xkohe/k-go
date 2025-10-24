requires "domains.md"
requires "core.k"

module GO-SYNTAX-FUNC
  imports GO-SYNTAX
  imports MAP

  // Grammar follows the official Go specification.

  // Go specification: FunctionType = "func" Signature .
  syntax Type ::= FunctionType
  syntax FunctionType ::= "func" FunctionSignature

  // Go specification: Function values
  // A function value represents a function (named or anonymous) with a closure environment
  // FuncVal stores: parameter IDs, parameter types, return type, body, and captured environment
  syntax FuncVal ::= funcVal(ParamIds, ParamTypes, RetType, Block, Map, Map)
                     // funcVal(paramIds, paramTypes, retType, body, closureEnvI, closureEnvB)
  syntax Exp ::= FuncVal

  // Go specification: The zero value of function type is nil
  syntax FuncVal ::= "nil"

  // Go specification: Signature = Parameters [ Result ] .
  syntax FunctionSignature ::= Parameters
                             | Parameters Result

  // Go specification: Result = Parameters | Type .
  // Now supports both single Type and Parameters (for multiple return values)
  syntax Result ::= Type | Parameters

  // Go specification: Parameters = "(" [ ParameterList [ "," ] ] ")" .
  syntax Parameters ::= "(" ParameterList ")"
  syntax ParameterList ::= List{ParameterDecl, ","}

  // Go specification: ParameterDecl = [ IdentifierList ] [ "..." ] Type .
  // Supports both named and unnamed parameters
  syntax ParameterDecl ::= Id Type      // named parameter
                         | Type         // unnamed parameter (for return types)

  // Function calls (not explicitly in spec grammar, but part of PrimaryExpr → Call)
  // Go specification: PrimaryExpr Arguments
  syntax Call      ::= Id "(" ArgList ")" [prefer]  // Named function call
                     | Exp "(" ArgList ")" [strict(1), avoid]  // Function value call (evaluate Exp first)
  syntax ArgList   ::= List{Exp, ","}

  // Go specification: ReturnStmt = "return" [ ExpressionList ] .
  syntax ReturnStmt ::= "return"             // void return
                      | "return" Exp [strict, prefer] // single value return (prefer for single element)
                      | "return" ExpressionList [avoid] // multiple value return

  // Internal: For rewriting multi-value returns
  syntax ReturnStmt ::= returnTuple(Tuple)

  // Go specification: FunctionDecl = "func" FunctionName [ TypeParameters ] Signature [ FunctionBody ] .
  // Simplified: no type parameters, FunctionBody is always present
  syntax FunctionDecl ::= "func" Id FunctionSignature Block

  // Go specification: Statement includes various statement types
  // Note: Call as ExpressionStmt
  syntax Statement    ::= FunctionDecl | ReturnStmt
  syntax SimpleStmt   ::= Call  // Call can be used as SimpleStmt (ExpressionStmt)

  // Go specification: TopLevelDecl = Declaration | FunctionDecl | MethodDecl .
  syntax TopDecl ::= FunctionDecl

  // Go specification: Expression includes Call as part of PrimaryExpr
  syntax Exp     ::= Call

  syntax ParamIds    ::= List{Id, ","}
  syntax ParamTypes  ::= List{Type, ","}

  syntax ParamIds   ::= idsOf(ParameterList)   [function]
  syntax ParamTypes ::= typesOf(ParameterList) [function]
  rule idsOf(.ParameterList) => .ParamIds
  rule idsOf((X:Id _T:Type , PL:ParameterList)) => X , idsOf(PL)
  rule idsOf((X:Id _T:Type))                    => X
  rule idsOf((_T:Type , PL:ParameterList))      => idsOf(PL)  // unnamed param
  rule idsOf(_T:Type)                           => .ParamIds  // unnamed param

  rule typesOf(.ParameterList) => .ParamTypes
  rule typesOf((_X:Id T:Type , PL:ParameterList)) => T , typesOf(PL)
  rule typesOf((_X:Id T:Type))                    => T
  rule typesOf((T:Type , PL:ParameterList))       => T , typesOf(PL)  // unnamed param
  rule typesOf(T:Type)                            => T  // unnamed param

  syntax ParamIds   ::= paramIdsOf(Parameters)   [function]
  syntax ParamTypes ::= paramTypesOf(Parameters) [function]
  rule paramIdsOf(( PL:ParameterList))   => idsOf(PL)
  rule paramTypesOf(( PL:ParameterList)) => typesOf(PL)

  syntax Parameters ::= parametersOf(FunctionSignature) [function]
  rule parametersOf(PS:Parameters) => PS
  rule parametersOf(PS:Parameters _RT:Result) => PS

  syntax RetType ::= Type | "void" | Parameters
  syntax RetType ::= retTypeOf(FunctionSignature) [function]
  rule retTypeOf(_PS:Parameters)           => void
  rule retTypeOf(_PS:Parameters RT:Type) => RT
  rule retTypeOf(_PS:Parameters RT:Parameters) => RT  // multiple return types
endmodule
