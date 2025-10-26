requires "domains.md"
requires "core.k"
requires "func.k"

module GO-SYNTAX-CONCURRENT
  imports GO-SYNTAX
  imports GO-SYNTAX-FUNC
  imports UNSIGNED-INT-SYNTAX
  imports BOOL-SYNTAX
  imports ID-SYNTAX

  // Go specification: GoStmt = "go" Expression .
  // The expression must be a function or method call
  syntax GoStmt ::= "go" Exp

  syntax Statement ::= GoStmt

  // Go specification: ChannelType = ( "chan" | "chan" "<-" | "<-" "chan" ) ElementType .
  // For now, we support bidirectional channels only
  syntax ChannelType ::= "chan" Type

  syntax Type ::= ChannelType

  // Go specification: Making channels
  // make(T) - unbuffered channel of type T
  // make(T, n) - buffered channel of type T with buffer size n (future)
  syntax Exp ::= "make" "(" ChannelType ")"

  // Go specification: SendStmt = Channel "<-" Expression .
  syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]

  syntax Statement ::= SendStmt

  // Go specification: Receive operator
  // <-ch returns the value received from channel ch
  syntax Exp ::= "<-" Exp [strict(1), symbol(chanRecv)]
endmodule
