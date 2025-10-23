requires "domains.md"
requires "core.k"

module GO-SYNTAX-FUNC
  imports GO-SYNTAX

  // Grammar follows the official Go specification.

  // Go specification: FunctionType = "func" Signature .
  syntax Type ::= FunctionType
  syntax FunctionType ::= "func" FunctionSignature

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
  syntax Call      ::= Id "(" ArgList ")"
  syntax ArgList   ::= List{Exp, ","}

  // Go specification: ReturnStmt = "return" [ ExpressionList ] .
  syntax ReturnStmt ::= "return"
                      | "return" ExpressionList [strict]

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
