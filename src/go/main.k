requires "go.k"
requires "func.k"
requires "concurrent.k"

module MAIN-SYNTAX
  imports GO-SYNTAX
  imports GO-SYNTAX-FUNC
  imports GO-SYNTAX-CONCURRENT
endmodule

module MAIN
  imports MAIN-SYNTAX
  imports GO
  imports GO-FUNC
  imports GO-CONTROL-FLOW
  imports GO-CONCURRENT
endmodule
