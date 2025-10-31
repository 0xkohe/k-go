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
  //
  // Three channel directions provide compile-time type safety:
  // 1. chan T       - bidirectional (can send and receive)
  // 2. chan<- T     - send-only (can only send, receive is compile error)
  // 3. <-chan T     - receive-only (can only receive, send is compile error)
  //
  // Direction enforcement:
  // - Checked at semantic analysis time via priority rules in concurrent.k
  // - Bidirectional channels can be implicitly converted to directional types
  // - Directional channels cannot be converted back to bidirectional
  // - Direction information stored in <tenv>, not in runtime channel value
  //
  // Symbol annotations:
  // - Enable pattern matching in semantics module (canSend/canReceive helpers)
  // - Required for K's rule application system to distinguish directions
  syntax ChannelType ::= "chan" Type                    [symbol(chanBidirectional)]
                       | "chan" "<-" Type               [symbol(chanSendOnly)]
                       | "<-" "chan" Type               [symbol(chanRecvOnly)]

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
  syntax Exp ::= recvWithOk(Exp)

  // Special syntax for two-variable channel receive in different contexts
  // Short variable declaration: v, ok := <-ch
  // Note: The Exp (channel) must be evaluated first, so we remove strict
  // and handle evaluation in semantics
  syntax ShortVarDecl ::= Id "," Id ":=" "<-" Exp

  // Assignment: x, ok = <-ch
  syntax Assignment ::= Id "," Id "=" "<-" Exp
  syntax Statement ::= Assignment

  // Variable declaration: var x, ok = <-ch
  syntax VarSpec ::= "var" Id "," Id "=" "<-" Exp
  syntax TopDecl ::= VarSpec
  syntax Statement ::= VarSpec

  // ============================================================================
  // SELECT STATEMENT SYNTAX
  // ============================================================================
  // Go specification: SelectStmt = "select" "{" { CommClause } "}" .
  //
  // Select chooses which of a set of possible send or receive operations
  // will proceed. It looks similar to a switch but all cases refer to
  // communication operations.

  syntax SelectStmt ::= "select" "{" CommClauses "}"
  syntax Statement ::= SelectStmt

  // CommClause = CommCase ":" StatementList .
  // For simplicity, we require blocks for each case (valid Go syntax)
  // We use semicolon separator for clearer parsing
  syntax CommClauses ::= List{CommClause, ";"}
  syntax CommClause ::= CommCase ":" Block

  // CommCase = "case" ( SendStmt | RecvStmt ) | "default" .
  // Note: We reuse existing syntax for recv operations to avoid ambiguity
  // RecvExpr is just Exp (the "<-" Exp syntax is already defined)
  syntax CommCase ::= "case" SendStmt        // case ch <- v
                    | "case" Exp             // case <-ch (Exp includes "<-" Exp)
                    | "case" Assignment      // case x = <-ch or x, y = <-ch (reuse existing)
                    | "case" ShortVarDecl    // case x := <-ch or x, ok := <-ch (reuse existing)
                    | "default"

endmodule
