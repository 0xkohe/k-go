// GO func extension for the toy Go-in-K definition
// -------------------------------------------------
// Adds: function types (FunctionType := "func" Signature), function declarations,
// calls, parameters, and return semantics (single return value or void).
//
// NOTE: This is a minimal, conservative model consistent with the existing
// GO-SYNTAX / GO modules you provided. It supports:
// - typed parameters only (no grouped param names, no variadics)
// - at most one return value (int or bool) or no return
// - call-by-value
// - lexical scoping for parameters via the same block scope machinery
// - missing return in non-void functions leaves the computation stuck (by design)

requires "domains.md"
requires "go.k"

module GO-SYNTAX-FUNC
  imports GO-SYNTAX

  // ===== Function types =====
  // FunctionType  = "func" Signature .
  // Signature     = Parameters [ Result ] .
  // Result        = Type .   // (only single return value for this model)

  // Make function type a Type variant
  syntax Type ::= FunctionType 
  syntax FunctionType ::= "func" Signature

  // Parameters and Signatures
  syntax Parameters ::= "(" ParamList ")"
  syntax ParamList  ::= List{Param, ","}
  syntax Param      ::= Id Type          // e.g., x int

  syntax Signature  ::= Parameters
                       | Parameters Type // with single return type

  // Calls (as expression or statement)
  syntax Call      ::= Id "(" ArgList ")" // [strict(2)]
  syntax ArgList   ::= List{Exp, ","}

  // return statements
  syntax ReturnStmt ::= "return"
                      | "return" Exp [strict]

  // Declarations and statements
  syntax FuncDecl  ::= "func" Id Signature Block 
  syntax Statement ::= FuncDecl | ReturnStmt | Call
  
  syntax TopDecl ::= FuncDecl

  // Calls are also expressions (so you can do x := f(1,2))
  syntax Exp ::= Call

  // ---------- helper list sorts used later (purely syntactic) ----------
  syntax ParamIds    ::= List{Id, ","}
  syntax ParamTypes  ::= List{Type, ","}

  // Extractors for parameters/signatures (used by semantics module)
  syntax ParamIds   ::= idsOf(ParamList)     [function]
  syntax ParamTypes ::= typesOf(ParamList)   [function]
  rule idsOf(.ParamList) => .ParamIds
  rule idsOf((X:Id _T:Type , PL:ParamList)) => X , idsOf(PL)
  rule idsOf((X:Id _T:Type))                => X

  rule typesOf(.ParamList) => .ParamTypes
  rule typesOf((_X:Id T:Type , PL:ParamList)) => T , typesOf(PL)
  rule typesOf((_X:Id T:Type))                => T

  // syntax ParamIds   ::= paramIdsOf(Parameters)   [function]
  // syntax ParamTypes ::= paramTypesOf(Parameters) [function]
  // rule paramIdsOf(( ) )            => .ParamIds
  // rule paramIdsOf(( PL:ParamList)) => idsOf(PL)

  // rule paramTypesOf(( ) )            => .ParamTypes
  // rule paramTypesOf((PL:ParamList)) => typesOf(PL)
  syntax ParamIds   ::= paramIdsOf(Parameters)   [function]
  syntax ParamTypes ::= paramTypesOf(Parameters) [function]
  // Parameters は常に "(" ParamList ")" の形（空も含む）
  rule paramIdsOf(( PL:ParamList))   => idsOf(PL)
  rule paramTypesOf(( PL:ParamList)) => typesOf(PL)

  syntax RetType ::= Type | "void"
  syntax RetType ::= retTypeOf(Signature) [function]
  rule retTypeOf(_PS:Parameters)        => void
  rule retTypeOf(_PS:Parameters RT:Type) => RT
endmodule


module GO-FUNC
  imports GO
  imports GO-SYNTAX-FUNC
  imports LIST
  imports MAP

  // ============ Function environment ============
  // Store bodies & signatures separately from variable envs.
  // configuration
  //   <T> 
  //     <fenv> .Map </fenv>    // Id ↦ FunDef
  //   </T>

  syntax FunDef ::= fun(ParamIds, ParamTypes, RetType, Block)

  // ---------- Declaration: func f Sig { ... } ----------
  // 1) Record its type in <tenv> as a FunctionType "func Sig"
  // 2) Record its body & parameter meta in <fenv>
// rule <k> funcDecl(F:Id, S:Signature, B:Block) => .K ... </k>
  //rule <k> func F:Id S:Signature B:Block => .K ... </k>
  //
  // rule <k> func F:Id S:Signature B:Block => .K ... </k>
  //      <tenv>  R  => R  [ F <- (func S) ] </tenv>
  //      <fenv>  FE => FE [ F <- fun(paramIdsOf(S), paramTypesOf(S), retTypeOf(S), B) ] </fenv>
       
  rule <k> func F:Id PS:Parameters B:Block => .K ... </k>
       <tenv> TEnv => TEnv [ F <- (func PS) ] </tenv>
       <fenv> FEnv => FEnv [ F <- fun(paramIdsOf(PS), paramTypesOf(PS), void, B) ] </fenv>
  
  rule <k> func F:Id PS:Parameters RT:Type B:Block => .K ... </k>
       <tenv> TEnv => TEnv [ F <- (func (PS RT)) ] </tenv>
       <fenv> FEnv => FEnv [ F <- fun(paramIdsOf(PS), paramTypesOf(PS), RT, B) ] </fenv>


  // ============ Calls ============
  // Evaluate arguments left-to-right (seqstrict on Call) then bind as local vars
  // and run the body inside a fresh scope. Return semantics handled via signals.

  syntax KItem ::= runFunc(RetType, Block)
  syntax KItem ::= returnJoin(RetType)
  syntax KItem ::= bindParams(ParamIds, ParamTypes, ArgList)

  // Call desugaring: f(a,b) \n=> enterScope( bind params ; body ; return-join )
  // rule <k> F:Id (AL:ArgList) => enterScope(bindParams(PIs, PTs, AL) ~> B ~> returnJoin(RT)) ... </k>
     //<fenv> ... F |-> fun(PIs, PTs, RT, B) ... </fenv>
       

  rule <k> F:Id (AL:ArgList) => enterScope(bindParams(PIs, PTs, AL) ~> B) ~> returnJoin(RT) ... </k>
     <fenv> ... F |-> fun(PIs, PTs, RT, B) ... </fenv>

  // Bind parameters by translating each (name, type, argVal) triple into a typed var-decl
  // 空引数: .ArgList
  rule <k> bindParams(.ParamIds, .ParamTypes, .ArgList) => .K ... </k>

  // Multiple element cases (left-consing)
  rule <k> bindParams((X:Id , Xs:ParamIds), (int  , Ts:ParamTypes), (V:Int  , Vs:ArgList))
        => var X int  = V ~> bindParams(Xs, Ts, Vs) ... </k>
  rule <k> bindParams((X:Id , Xs:ParamIds), (bool , Ts:ParamTypes), (V:Bool , Vs:ArgList))
        => var X bool = V ~> bindParams(Xs, Ts, Vs) ... </k>

  // ============ Return semantics ============
  syntax KItem ::= returnSignal(K)   // carries a value for non-void; empty for void

  // Surface returns → signals
  rule <k> return       => returnSignal(.K) ... </k>
  rule <k> return V:Exp => returnSignal(V) ... </k> 
  
  rule <k> returnSignal(V) ~> exitScope => exitScope ~> returnSignal(V) ... </k>

  // Bubble returnSignal upward until the matching returnJoin boundary
  rule <k> returnSignal(V) ~> _KI:KItem => returnSignal(V) ... </k> [owise]

  // At boundary for void functions: consume signal, produce no value
  rule <k> returnSignal(_V) ~> returnJoin(void) => .K ... </k>
  // At boundary for non-void: expose the returned value as the call's value
  rule <k> returnSignal(V:Int)  ~> returnJoin(int)  => V ... </k>
  rule <k> returnSignal(V:Bool) ~> returnJoin(bool) => V ... </k>

  // If body falls through and function is void, just drop the join
  rule <k> returnJoin(void) => .K ... </k>
  // If non-void and no return encountered, there is no rule: stuck state (models missing return)

  // (Optional) A call used as a Statement simply discards its value if any,
  // thanks to the surrounding context, so no extra rule is needed.
endmodule

/*

  func fact(n int) int {
    if n == 0 {
      return 1;
    } else {
      return n * fact(n - 1);
    };
  };

  var r int = fact(5);
  print(r);

*/