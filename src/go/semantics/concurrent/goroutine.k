requires "../core.k"
requires "../func.k"
requires "../../syntax/concurrent.k"
requires "common.k"

// ============================================================================
// GO-GOROUTINE MODULE
// ============================================================================
// Goroutine semantics for Go's concurrent execution model.
// This module provides:
// - Goroutine spawning (go statement)
// - Thread creation and environment copying
// - Channel value support in function parameters

module GO-GOROUTINE
  imports GO
  imports GO-FUNC
  imports GO-SYNTAX-CONCURRENT
  imports GO-CONCURRENT-COMMON
  imports INT
  imports LIST
  imports MAP

  // ============================================================================
  // FUNCTION PARAMETER SUPPORT FOR CHANNELS
  // ============================================================================

  // Extend allValues to support channels in function arguments
  rule allValues(_V:ChanVal) => true
  rule allValues((_V:ChanVal , Rest:ArgList)) => allValues(Rest)

  // Extend bindParams to support channel parameters

  // Bidirectional channel parameter
  rule <k> bindParams((X:Id , Xs:ParamIds), (chan T:Type , Ts:ParamTypes), (CV:ChanVal , Vs:ArgList))
        => var X chan T = CV ~> bindParams(Xs, Ts, Vs) ... </k>

  rule <k> bindParams(X:Id, chan T:Type, CV:ChanVal)
        => var X chan T = CV ... </k>

  // Send-only channel parameter (accepts bidirectional channel too)
  rule <k> bindParams((X:Id , Xs:ParamIds), (chan <- T:Type , Ts:ParamTypes), (CV:ChanVal , Vs:ArgList))
        => var X chan <- T = CV ~> bindParams(Xs, Ts, Vs) ... </k>

  rule <k> bindParams(X:Id, chan <- T:Type, CV:ChanVal)
        => var X chan <- T = CV ... </k>

  // Receive-only channel parameter (accepts bidirectional channel too)
  rule <k> bindParams((X:Id , Xs:ParamIds), (<- chan T:Type , Ts:ParamTypes), (CV:ChanVal , Vs:ArgList))
        => var X <- chan T = CV ~> bindParams(Xs, Ts, Vs) ... </k>

  rule <k> bindParams(X:Id, <- chan T:Type, CV:ChanVal)
        => var X <- chan T = CV ... </k>

  // ============================================================================
  // GOROUTINE SPAWNING
  // ============================================================================

  // Go specification: go statement creates a new goroutine
  // GoStmt = "go" Expression
  // The expression must be a function or method call
  // Note: The expression is NOT evaluated in the current thread,
  // but executed in the new goroutine

  // Go statement: spawn a new thread to execute the function call
  rule <thread>...
         <tid> _ParentTid </tid>
         <k> go FCall:Exp => .K ... </k>
         <tenv> TEnv </tenv>
         <env> Env </env>
         <constEnv> CEnv </constEnv>
       ...</thread>
       (.Bag =>
         <thread>...
           <tid> N </tid>
           <k> FCall </k>
           <tenv> TEnv </tenv>
           <env> Env </env>
           <envStack> .List </envStack>
           <tenvStack> .List </tenvStack>
           <constEnv> CEnv </constEnv>
           <constEnvStack> .List </constEnvStack>
           <scopeDecls> .List </scopeDecls>
         ...</thread>)
       <nextTid> N:Int => N +Int 1 </nextTid>

endmodule
