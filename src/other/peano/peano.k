module PEANO

  // syntax for natural numbers
  syntax Nat ::= "0" | S(Nat)

  // syntax for addition
  syntax Nat ::= Nat "+" Nat [function]

  rule X + 0 => X
  rule X + S(Y) => S(X + Y)
endmodule