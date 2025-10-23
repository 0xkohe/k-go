module F1
  imports INT 

  syntax Int ::= fac(Int) [function]

  rule fac(0) => 1
  rule fac(N) => N *Int fac(N -Int 1) requires N >Int 0  

endmodule
