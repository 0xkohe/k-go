/*
module PEANO-2
  syntax Nat ::= "0" | S(Nat)
  syntax Nat ::= right: Nat "+" Nat

  configuration <k> $PGM:Nat </k>  // 初期構成：評価対象を入れる

  rule <k> X:Nat + 0 => X ...</k>
  rule <k> X:Nat + S(Y:Nat) => S(X + Y) ...</k>
  
    // ✅ Heating Rules（まだ評価されていない式を引っ張り出す）
  syntax KItem ::= freezerL(Nat) | freezerR(Nat)

  // 左側が値で、右側が未評価
  rule <k> V:Nat + E:Nat => E ~> freezerL(V) ...</k> [priority(51)]
  
  // 左側が未評価
  rule <k> E:Nat + Y:Nat => E ~> freezerR(Y) ...</k> [priority(52)]

  // ✅ Cooling Rules（freezerで部分式を戻す）
  rule <k> V2:Nat ~> freezerL(V1:Nat) => V1 + V2 ...</k>
  rule <k> V1:Nat ~> freezerR(V2:Nat) => V1 + V2 ...</k>
endmodule
*/

module PEANO-2
  imports INT

  syntax Val ::= "0" | S(Val)
               > right: Val "+" Val
  syntax Exp ::= Val
               > right: Exp "+" Exp

  // configuration <k> $PGM:Exp </k>

  // 加算の評価（値同士のとき）
  rule <k> 0 + Y:Val => Y ...</k>
  rule <k> S(X:Val) + Y:Val => S(X + Y) ...</k>

  // Heating（評価されていない式を評価する）
  syntax KItem ::= freezerL(Val) | freezerR(Exp)

  rule <k> V:Val + E:Exp => E ~> freezerL(V) ...</k> [priority(51)]
  rule <k> E:Exp + Y:Exp => E ~> freezerR(Y) ...</k> [priority(52)]

  // Cooling（評価結果を戻す）
  rule <k> V2:Val ~> freezerL(V1:Val) => V1 + V2 ...</k>
  rule <k> V1:Val ~> freezerR(E2:Exp) => V1 + E2 ...</k>

endmodule