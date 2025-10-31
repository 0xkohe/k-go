requires "../core.k"
requires "../../syntax/concurrent.k"
requires "common.k"

// ============================================================================
// GO-RANGE-CHANNEL MODULE
// ============================================================================
// For-range over channel semantics.
// This module provides:
// - for v := range ch - receives from channel until closed
// - for range ch - executes for each received value (no variable)

module GO-RANGE-CHANNEL
  imports GO
  imports GO-CONTROL-FLOW
  imports GO-SYNTAX-CONCURRENT
  imports GO-CONCURRENT-COMMON
  imports INT
  imports LIST
  imports MAP
  imports STRING

  // ============================================================================
  // FOR-RANGE CHANNEL SEMANTICS
  // ============================================================================

  // Go specification: for range channel
  // for v := range ch - receives from channel until closed
  // Desugars to: for { v, ok := <-ch; if !ok { break }; body }

  syntax KItem ::= rangeChannelLoop(Id, ChanVal, Block)

  // for v := range ch
  rule <k> for ((X:Id , .IdentifierList) := range Ch:ChanVal) B:Block
        => enterScope(X := 0 ~> rangeChannelLoop(X, Ch, B)) ... </k>

  // for range ch (no variable)
  // Note: simplified - use a fixed dummy variable name
  rule <k> for range Ch:ChanVal B:Block
        => enterScope(rangeChannelLoop(String2Id("_range_dummy"), Ch, B)) ... </k>

  // Try to receive from channel
  // If channel has values or waiting senders, receive and continue
  rule <thread>...
         <tid> _Tid </tid>
         <k> rangeChannelLoop(X, channel(CId, T), B)
          => X = <-channel(CId, T) ~> B ~> rangeChannelLoop(X, channel(CId, T), B) ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(_SendQ, _RecvQ, (ListItem(_V) _BufRest:List), _Size, T, _Closed)
       ...</channels>

  // If channel has waiting sender (direct handoff)
  rule <thread>...
         <tid> _Tid </tid>
         <k> rangeChannelLoop(X, channel(CId, T), B)
          => X = <-channel(CId, T) ~> B ~> rangeChannelLoop(X, channel(CId, T), B) ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState((ListItem(_) _SendRest:List), _RecvQ, .List, _Size, T, false)
       ...</channels>

  // If channel is closed and empty, exit loop
  rule <thread>...
         <tid> _Tid </tid>
         <k> rangeChannelLoop(_X, channel(CId, TRange), _B) => exitScope ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(.List, _RecvQ, .List, _Size, TRange, true)
       ...</channels>

endmodule
