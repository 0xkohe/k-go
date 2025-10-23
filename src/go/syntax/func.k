requires "domains.md"
requires "core.k"

module GO-SYNTAX-FUNC
  imports GO-SYNTAX

  // Grammar follows the official Go specification (2024-06-18).

  syntax Type ::= FunctionType
  syntax FunctionType ::= "func" FunctionSignature

  // Signature = Parameters [ Result ]
  syntax FunctionSignature ::= Parameters
                             | Parameters Result

  // Result = Parameters | Type
  // (This subset models only the single-Type result form.)
  syntax Result ::= Type

  // Parameters = "(" [ ParameterList [ "," ] ] ")"
  syntax Parameters ::= "(" ParameterList ")"
  syntax ParameterList ::= List{ParameterDecl, ","}
  syntax ParameterDecl ::= Id Type

  syntax Call      ::= Id "(" ArgList ")"
  syntax ArgList   ::= List{Exp, ","}

  syntax ReturnStmt ::= "return"
                      | "return" Exp [strict]

  syntax FunctionDecl ::= "func" Id FunctionSignature Block
  syntax Statement    ::= FunctionDecl | ReturnStmt | Call

  syntax TopDecl ::= FunctionDecl
  syntax Exp     ::= Call

  syntax ParamIds    ::= List{Id, ","}
  syntax ParamTypes  ::= List{Type, ","}

  syntax ParamIds   ::= idsOf(ParameterList)   [function]
  syntax ParamTypes ::= typesOf(ParameterList) [function]
  rule idsOf(.ParameterList) => .ParamIds
  rule idsOf((X:Id _T:Type , PL:ParameterList)) => X , idsOf(PL)
  rule idsOf((X:Id _T:Type))                    => X

  rule typesOf(.ParameterList) => .ParamTypes
  rule typesOf((_X:Id T:Type , PL:ParameterList)) => T , typesOf(PL)
  rule typesOf((_X:Id T:Type))                    => T

  syntax ParamIds   ::= paramIdsOf(Parameters)   [function]
  syntax ParamTypes ::= paramTypesOf(Parameters) [function]
  rule paramIdsOf(( PL:ParameterList))   => idsOf(PL)
  rule paramTypesOf(( PL:ParameterList)) => typesOf(PL)

  syntax Parameters ::= parametersOf(FunctionSignature) [function]
  rule parametersOf(PS:Parameters) => PS
  rule parametersOf(PS:Parameters _RT:Result) => PS

  syntax RetType ::= Type | "void"
  syntax RetType ::= retTypeOf(FunctionSignature) [function]
  rule retTypeOf(_PS:Parameters)           => void
  rule retTypeOf(_PS:Parameters RT:Result) => RT
endmodule
