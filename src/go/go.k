/*
Semicolons¶
The formal syntax uses semicolons ";" as terminators in a number of productions. Go programs may omit most of these semicolons using the following two rules:

When the input is broken into tokens, a semicolon is automatically inserted into the token stream immediately after a line's final token if that token is
an identifier
an integer, floating-point, imaginary, rune, or string literal
one of the keywords break, continue, fallthrough, or return
one of the operators and punctuation ++, --, ), ], or }
To allow complex statements to occupy a single line, a semicolon may be omitted before a closing ")" or "}".
To reflect idiomatic use, code examples in this document elide semicolons using these rules.
*/

requires "domains.md"

module GO-SYNTAX
  // for writing 3+3 without spaces
  imports UNSIGNED-INT-SYNTAX
  imports BOOL-SYNTAX
  imports ID-SYNTAX

  
  // Program / blocks
  // トップレベル宣言（TopDecl）を main の前に並べられるようにする
  syntax TopDecl        // ← ここでは“宣言の枠”だけ宣言（中身は別モジュールで追加）
  syntax TopDecls ::= List{TopDecl, ";"}
  syntax Program ::= "package" "main" TopDecls "func" "main" "(" ")" Block TopDecls


  syntax Block   ::= "{" StatementList ";" "}"
  syntax StatementList ::= List{Statement, ";"}

  // Types (int / bool only)
  syntax Type ::= "int" | "bool"

  // --- SimpleStmt (subset) ---
  syntax SimpleStmt ::= Assignment | ShortVarDecl | IncDecStmt
  syntax Assignment ::= Id "=" Exp [strict(2)]
  syntax ShortVarDecl ::= Id ":=" Exp [strict(2)]
  syntax IncDecStmt ::= Id "++" | Id "--"

  // Statements
  syntax Statement ::= SimpleStmt | Print | Block | IfStmt | ForStmt | BreakStmt | ContinueStmt
                     | "var" Id Type "=" Exp  [strict(3)]   // Declaration (typed)

  // print (Int only for now)
  syntax Print ::= "print" "(" Exp ")" [strict]

  // Unified Exp (int/bool)
  syntax Exp ::= Int | Bool | Id | "(" Exp ")" [bracket]
               > "!" Exp [seqstrict]
               | "-" Exp [seqstrict]
               > left:
                 Exp "*" Exp [left, seqstrict]
               | Exp "/" Exp [left, seqstrict]
               | Exp "%" Exp [left, seqstrict]
               > left:
                 Exp "+" Exp [left, seqstrict]
               | Exp "-" Exp [left, seqstrict]
               > non-assoc:
                 Exp "<"  Exp [seqstrict]
               | Exp ">"  Exp [seqstrict]
               | Exp "==" Exp [seqstrict]
               > left:
                 Exp "&&" Exp [left, seqstrict]
               | Exp "||" Exp [left, seqstrict]

  // If with optional init (SimpleStmt) — Go-style (no parentheses)
  syntax IfStmt ::= "if" Exp Block                                   [strict(1)]
                  | "if" Exp Block "else" Block                       [strict(1)]
                  | "if" Exp Block "else" IfStmt                      [strict(1)]
                  | "if" SimpleStmt ";" Exp Block                     // by rule
                  | "if" SimpleStmt ";" Exp Block "else" Block        // by rule
                  | "if" SimpleStmt ";" Exp Block "else" IfStmt       // by rule

  // --- For with ForClause only ---
  syntax ForStmt ::= "for" ForClause Block

  // break / continue (Go statements)
  syntax BreakStmt ::= "break"
  syntax ContinueStmt ::= "continue"

  /*
    ForStmt   = "for" [ Condition | ForClause | RangeClause ] Block .
    Condition = Expression .
    (we implement only ForClause here)
  */

  // Enumerate optional pieces (Init; Cond; Post) — no trailing ";" here
  syntax ForClause ::= SimpleStmt ";" Exp ";" SimpleStmt
                     | SimpleStmt ";" ";" SimpleStmt
                     | SimpleStmt ";" Exp ";"
                     | ";" Exp ";" SimpleStmt
                     | ";" ";" SimpleStmt
                     | ";" Exp ";"
                     | SimpleStmt ";" ";"
                     | ";" ";"
endmodule


module GO
  imports GO-SYNTAX
  imports INT
  imports LIST
  imports BOOL
  imports MAP
  imports ID

  configuration
    <T>
      <k> $PGM:Program </k>
      <out> .List </out>

      // typed environments
      <tenv> .Map </tenv>  // Id ↦ Type  (int|bool)
      <envI> .Map </envI>  // Id ↦ Int
      <envB> .Map </envB>  // Id ↦ Bool

      // scope stacks
      <tenvStack> .List </tenvStack>
      <envIStack> .List </envIStack>
      <envBStack> .List </envBStack>

  // ============ Function environment ============
  // Store bodies & signatures separately from variable envs.
      <fenv> .Map </fenv>    // Id ↦ FunDef
    </T>

  
  // TopDecls を列に落としてから main を実行
  syntax K ::= toSeqTop(TopDecls) [function]
  rule toSeqTop(.TopDecls) => .K
  rule toSeqTop(TD:TopDecl ; TL:TopDecls) => TD ~> toSeqTop(TL)

  // Entry
  rule <k> package main TL:TopDecls func main ( ) B:Block TL2:TopDecls
        => toSeqTop(TL) ~> toSeqTop(TL2) ~> B ... </k>

  // ============
  // Block scope
  // ============
  syntax KItem ::= enterScope(K) | "exitScope"
  syntax K ::= toSeq(StatementList) [function]
  rule toSeq(.StatementList) => .K
  rule toSeq(S:Statement ; SL:StatementList) => S ~> toSeq(SL)

  // Enter a new scope for each block
  rule <k> { SL:StatementList ; } => enterScope(toSeq(SL)) ... </k>

  // On entering: push envs, run body, then exitScope
  rule <k> enterScope(Body:K) => Body ~> exitScope ... </k>
       <tenv> T </tenv>
       <envI> I </envI>
       <envB> B </envB>
       <tenvStack> TS => TS ListItem(T) </tenvStack>
       <envIStack> IS => IS ListItem(I) </envIStack>
       <envBStack> BS => BS ListItem(B) </envBStack>

  // On exiting: restore saved envs
  rule <k> exitScope => .K ... </k>
       <tenvStack> (TS ListItem(T)) => TS </tenvStack>
       <envIStack> (IS ListItem(I)) => IS </envIStack>
       <envBStack> (BS ListItem(BV)) => BS </envBStack>
       <tenv> _ => T </tenv>
       <envI> _ => I </envI>
       <envB> _ => BV </envB>

  // print —— Int only
  rule <k> print(I:Int) => .K ... </k>
       <out> OL => OL ListItem(I) </out>

  // --- typed var decl / short var decl / assignment ---
  // var X int = I
  rule <k> var X:Id int = I:Int => .K ... </k>
       <tenv> R => R [ X <- int ] </tenv>
       <envI> Rho => Rho [ X <- I ] </envI>

  // var X bool = B
  rule <k> var X:Id bool = B:Bool => .K ... </k>
       <tenv> R => R [ X <- bool ] </tenv>
       <envB> Rho => Rho [ X <- B ] </envB>

  // short var decl: X := <exp>
  rule <k> X:Id := I:Int => .K ... </k>
       <tenv> R => R [ X <- int ] </tenv>
       <envI> Rho => Rho [ X <- I ] </envI>

  rule <k> X:Id := B:Bool => .K ... </k>
       <tenv> R => R [ X <- bool ] </tenv>
       <envB> Rho => Rho [ X <- B ] </envB>

  // assignment guarded by type env
  rule <k> X:Id = I:Int => .K ... </k>
       <tenv> ... X |-> int ... </tenv>
       <envI> Rho => Rho [ X <- I ] </envI>

  rule <k> X:Id = B:Bool => .K ... </k>
       <tenv> ... X |-> bool ... </tenv>
       <envB> Rho => Rho [ X <- B ] </envB>

  // lookups (context-sensitive)
  rule <k> X:Id => I ... </k>
       <envI> ... X |-> I:Int ... </envI>
  rule <k> X:Id => B ... </k>
       <envB> ... X |-> B:Bool ... </envB>

  // arithmetic
  rule <k> I1:Int + I2:Int => I1 +Int I2 ... </k>
  rule <k> I1:Int - I2:Int => I1 -Int I2 ... </k>
  rule <k> I1:Int * I2:Int => I1 *Int I2 ... </k>
  rule <k> I1:Int / I2:Int => I1 /Int I2 ... </k>
  rule <k> I1:Int % I2:Int => I1 %Int I2 ... </k>

  // comparisons / unary / boolean ops
  rule <k> I1:Int <  I2:Int => I1 <Int  I2 ... </k>
  rule <k> I1:Int >  I2:Int => I1 >Int  I2 ... </k>
  rule <k> I1:Int == I2:Int => I1 ==Int I2 ... </k>
  rule <k> - I:Int => 0 -Int I ... </k>

  rule <k> B1:Bool && B2:Bool => B1 andBool B2 ... </k>
  rule <k> B1:Bool || B2:Bool => B1 orBool  B2 ... </k>
  rule <k> ! B:Bool           => notBool B    ... </k>

  // ++ / --  (sugar to assignment; int only)
  rule <k> X:Id ++ => X = (X + 1) ... </k>
       <tenv> ... X |-> int ... </tenv>

  rule <k> X:Id -- => X = (X - 1) ... </k>
       <tenv> ... X |-> int ... </tenv>

  // --- If desugaring when init present ---
  rule <k> if S:SimpleStmt ; E:Exp B:Block => S ~> if E B ... </k>
  rule <k> if S:SimpleStmt ; E:Exp B1:Block else B2:Block => S ~> if E B1 else B2 ... </k>
  rule <k> if S:SimpleStmt ; E:Exp B1:Block else I2:IfStmt => S ~> if E B1 else I2 ... </k>

  // --- If semantics (no parens) ---
  rule <k> if true  B:Block => B  ... </k>
  rule <k> if false _B:Block => .K ... </k>
  rule <k> if true  B1:Block else _B2:Block => B1 ... </k>
  rule <k> if false _B1:Block else B2:Block => B2 ... </k>

  // --- ForClause → internal loop (scoped) ---
  // wrap every desugaring in enterScope(...) so init-binds are limited to the loop
  syntax KItem ::= loop(Exp, K, Block)
  syntax KItem ::= loopV(Exp, Exp, K, Block) [strict(1)]
  syntax KItem ::= "breakSignal" | "continueSignal"

  // For variants (8 patterns), all scoped:
  rule <k> for S1:SimpleStmt ; E:Exp ; S2:SimpleStmt B:Block => enterScope(S1 ~> loop(E, S2, B)) ... </k>
  rule <k> for S1:SimpleStmt ; ; S2:SimpleStmt B:Block       => enterScope(S1 ~> loop(true, S2, B)) ... </k>
  rule <k> for S1:SimpleStmt ; E:Exp ; B:Block               => enterScope(S1 ~> loop(E, .K, B)) ... </k>
  rule <k> for ; E:Exp ; S2:SimpleStmt B:Block               => enterScope(loop(E, S2, B)) ... </k>
  rule <k> for ; ; S2:SimpleStmt B:Block                     => enterScope(loop(true, S2, B)) ... </k>
  rule <k> for ; E:Exp ; B:Block                             => enterScope(loop(E, .K, B)) ... </k>
  rule <k> for S1:SimpleStmt ; ; B:Block                     => enterScope(S1 ~> loop(true, .K, B)) ... </k>
  rule <k> for ; ; B:Block                                   => enterScope(loop(true, .K, B)) ... </k>

  // loop step: re-evaluate condition each time via loopV
  rule <k> loop(E:Exp, SP:K, B:Block) => loopV(E, E, SP, B) ... </k>

  // cond true: run body, then post, then next iteration
  rule <k> loopV(true, E, SP:K, B:Block) => B ~> SP ~> loop(E, SP, B) ... </k>

  // cond false: exit
  rule <k> loopV(false, _E, _SP, _B) => .K ... </k>

  // --- break / continue semantics ---

  // surface → signals
  rule <k> break    => breakSignal    ... </k>
  rule <k> continue => continueSignal ... </k>

  // bubble signals until the nearest loop(...)
  rule <k> continueSignal ~> _KI:KItem => continueSignal ... </k> [owise]
  rule <k> breakSignal    ~> _KI:KItem => breakSignal    ... </k> [owise]

  // at loop boundary:
  // continue: execute the visible post (to the left), then re-enter loop
  rule <k> continueSignal ~> loop(E, SP, B) => SP ~> loop(E, SP, B) ... </k>

  // break: exit loop entirely (no post)
  rule <k> breakSignal ~> loop(_E, _SP, _B) => .K ... </k>

  // K result predicate
  syntax Bool ::= isKResult(K) [symbol(isKResult), function]
  rule isKResult(_:Int)  => true
  rule isKResult(_:Bool) => true
  rule isKResult(_)      => false [owise]
endmodule
