requires "go.k"
requires "func.k"

module MAIN-SYNTAX
  imports GO-SYNTAX   
  imports GO-SYNTAX-FUNC
endmodule

module MAIN
  imports MAIN-SYNTAX 
  imports GO         
  imports GO-FUNC
endmodule
