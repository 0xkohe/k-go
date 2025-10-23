requires "domains.md"
requires "core.k"

module GO-SYNTAX-FUNC
  imports GO-SYNTAX

  syntax Type ::= FunctionType
  syntax FunctionType ::= "func" Signature

  syntax Parameters ::= "(" ParamList ")"
  syntax ParamList  ::= List{Param, ","}
  syntax Param      ::= Id Type

  syntax Signature  ::= Parameters
                       | Parameters Type

  syntax Call      ::= Id "(" ArgList ")"
  syntax ArgList   ::= List{Exp, ","}

  syntax ReturnStmt ::= "return"
                      | "return" Exp [strict]

  syntax FuncDecl  ::= "func" Id Signature Block
  syntax Statement ::= FuncDecl | ReturnStmt | Call

  syntax TopDecl ::= FuncDecl

  syntax Exp ::= Call

  syntax ParamIds    ::= List{Id, ","}
  syntax ParamTypes  ::= List{Type, ","}

  syntax ParamIds   ::= idsOf(ParamList)     [function]
  syntax ParamTypes ::= typesOf(ParamList)   [function]
  rule idsOf(.ParamList) => .ParamIds
  rule idsOf((X:Id _T:Type , PL:ParamList)) => X , idsOf(PL)
  rule idsOf((X:Id _T:Type))                => X

  rule typesOf(.ParamList) => .ParamTypes
  rule typesOf((_X:Id T:Type , PL:ParamList)) => T , typesOf(PL)
  rule typesOf((_X:Id T:Type))                => T

  syntax ParamIds   ::= paramIdsOf(Parameters)   [function]
  syntax ParamTypes ::= paramTypesOf(Parameters) [function]
  rule paramIdsOf(( PL:ParamList))   => idsOf(PL)
  rule paramTypesOf(( PL:ParamList)) => typesOf(PL)

  syntax RetType ::= Type | "void"
  syntax RetType ::= retTypeOf(Signature) [function]
  rule retTypeOf(_PS:Parameters)         => void
  rule retTypeOf(_PS:Parameters RT:Type) => RT
endmodule
