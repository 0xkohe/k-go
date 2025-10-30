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
  // make(T, n) - buffered channel of type T with buffer size n
  syntax Exp ::= "make" "(" ChannelType ")"
               | "make" "(" ChannelType "," Exp ")" [strict(2)]

  // Go specification: SendStmt = Channel "<-" Expression .
  // Go specification: Channel  = Expression .
  // Note: We use Exp directly instead of defining a Channel alias, as it would add no semantic value.
  //
  // Type constraints (enforced in semantics, not syntax):
  // - The channel expression must be of channel type
  // - The channel direction must permit send operations
  // - The type of the value to be sent must be assignable to the channel's element type
  syntax SendStmt ::= Exp "<-" Exp [strict, symbol(chanSend)]

  syntax Statement ::= SendStmt

  // Go specification: Receive operator
  // <-ch returns the value received from channel ch
  syntax Exp ::= "<-" Exp [strict(1), symbol(chanRecv)]

  // Go specification: close(ch) closes a channel
  // After close, receives return zero value and ok=false
  // Sends to closed channel cause panic
  syntax CloseStmt ::= "close" "(" Exp ")" [strict(1)]
  syntax Statement ::= CloseStmt

  // Go specification: Multi-valued receive (v, ok := <-ch)
  // ok is false if channel is closed, true otherwise
  // This is handled specially in short declaration syntax
  syntax Exp ::= recvWithOk(Exp) [strict(1)]

  // Special syntax for two-variable channel receive
  syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp [strict(2)]
endmodule
