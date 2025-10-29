requires "domains.md"
requires "core.k"

module GO-CONTROL-FLOW
  imports GO
  imports INT
  imports BOOL

  // Go specification: if statement with SimpleStmt creates an implicit block
  // Variables declared in S are only visible within the if statement
  rule <k> if S:SimpleStmt ; E:Exp B:Block => enterScope(S ~> if E B) ... </k>
  rule <k> if S:SimpleStmt ; E:Exp B1:Block else B2:Block => enterScope(S ~> if E B1 else B2) ... </k>
  rule <k> if S:SimpleStmt ; E:Exp B1:Block else I2:IfStmt => enterScope(S ~> if E B1 else I2) ... </k>

  // if condition evaluation and branch selection
  // These rules work both with and without exitScope (using ... to match rest)
  rule <k> if true  B:Block => B  ... </k>
  rule <k> if false _B:Block => .K ... </k>
  rule <k> if true  B1:Block else _B2:Block => B1 ... </k>
  rule <k> if false _B1:Block else B2:Block => B2 ... </k>
  rule <k> if true  B:Block else _I2:IfStmt => B ... </k>
  rule <k> if false _B:Block else I2:IfStmt => I2 ... </k>

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

  // Go specification: "for" RangeClause Block - range loop (Go 1.22+)
  // Integer range: for i := range n iterates from 0 to n-1

  // Context rules are needed because strict annotation on RangeClause doesn't
  // automatically propagate when RangeClause is nested inside ForStmt
  context for ((_ , .IdentifierList) := range HOLE:Exp) _
  context for range HOLE:Exp _

  // Single identifier case - handle parsed form "X , .IdentifierList"
  rule <k> for ((X:Id , .IdentifierList) := range N:Int) B:Block => enterScope(X := 0 ~> loop(X < N, X ++, B)) ... </k>
    requires N >Int 0

  rule <k> for ((_X:Id , .IdentifierList) := range N:Int) _B:Block => .K ... </k>
    requires N <=Int 0

  // Fallback for direct Id (if parsed that way)
  rule <k> for (X:Id := range N:Int) B:Block => enterScope(X := 0 ~> loop(X < N, X ++, B)) ... </k>
    requires N >Int 0

  rule <k> for (_X:Id := range N:Int) _B:Block => .K ... </k>
    requires N <=Int 0

  // Range without iteration variable: for range n
  // Go specification: executes the loop n times without exposing iteration variable
  syntax KItem ::= rangeLoop(Int, Int, Block)  // rangeLoop(current, limit, body)

  rule <k> for range N:Int B:Block => enterScope(rangeLoop(0, N, B)) ... </k>
    requires N >Int 0

  rule <k> for range N:Int _B:Block => .K ... </k>
    requires N <=Int 0

  rule <k> rangeLoop(I:Int, N:Int, B:Block) => B ~> rangeLoop(I +Int 1, N, B) ... </k>
    requires I <Int N

  rule <k> rangeLoop(I:Int, N:Int, _B:Block) => .K ... </k>
    requires I >=Int N

  // Handle break/continue in range loops
  rule <k> breakSignal ~> rangeLoop(_I, _N, _B) => .K ... </k>

  rule <k> continueSignal ~> rangeLoop(I, N, B) => rangeLoop(I +Int 1, N, B) ... </k>

endmodule
