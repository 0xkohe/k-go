requires "domains.md"
requires "core.k"
requires "func.k"
requires "../syntax/concurrent.k"

module GO-CONCURRENT
  imports GO
  imports GO-FUNC
  imports GO-CONTROL-FLOW
  imports GO-SYNTAX-CONCURRENT
  imports INT
  imports LIST
  imports MAP
  imports STRING

  // Channel value type stored in <store>
  syntax ChanVal ::= channel(Int, Type)  // channel(id, elementType)
  syntax Exp ::= ChanVal
  syntax Val ::= ChanVal
  syntax KResult ::= Val

  // Extend allValues to support channels in function arguments
  rule allValues(_V:ChanVal) => true
  rule allValues((_V:ChanVal , Rest:ArgList)) => allValues(Rest)

  // Extend bindParams to support channel parameters
  rule <k> bindParams((X:Id , Xs:ParamIds), (chan T:Type , Ts:ParamTypes), (CV:ChanVal , Vs:ArgList))
        => var X chan T = CV ~> bindParams(Xs, Ts, Vs) ... </k>

  rule <k> bindParams(X:Id, chan T:Type, CV:ChanVal)
        => var X chan T = CV ... </k>

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

  // Go specification: Channel type variable declaration
  // The zero value of channel type is nil
  rule <k> var X:Id chan T:Type => var X chan T = nil ... </k>

  // Accept both ChanVal (actual channel) and FuncVal (nil)
  rule <k> var X:Id chan T:Type = CV:ChanVal => .K ... </k>
       <tenv> R => R [ X <- chan T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- CV ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  rule <k> var X:Id chan T:Type = FV:FuncVal => .K ... </k>
       <tenv> R => R [ X <- chan T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- FV ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  // Go specification: Short variable declaration for channels
  // Infer type from channel value
  rule <k> X:Id := channel(CId:Int, T:Type) => .K ... </k>
       <tenv> R => R [ X <- chan T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- channel(CId, T) ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
    requires notBool (X in_keys(ScopeMap))

  // Go specification: Channel assignment
  rule <k> X:Id = CV:ChanVal => .K ... </k>
       <tenv> ... X |-> chan _T:Type ... </tenv>
       <env> ... X |-> L:Int ... </env>
       <store> Store => Store [ L <- CV ] </store>
       <constEnv> CE </constEnv>
    requires notBool (X in_keys(CE))

  // Go specification: Making channels
  // make(chan T) creates an unbuffered channel (bufferSize = 0)
  rule <k> make(chan T:Type) => channel(N, T) ... </k>
       <nextChanId> N:Int => N +Int 1 </nextChanId>
       <channels> Chans => Chans [ N <- chanState(.List, .List, .List, 0, T, false) ] </channels>

  // make(chan T, size) creates a buffered channel with given buffer size
  rule <k> make(chan T:Type, Size:Int) => channel(N, T) ... </k>
       <nextChanId> N:Int => N +Int 1 </nextChanId>
       <channels> Chans => Chans [ N <- chanState(.List, .List, .List, Size, T, false) ] </channels>
    requires Size >=Int 0

  // Channel state: chanState(sendQueue, recvQueue, buffer, bufferSize, elementType, closed)
  // sendQueue: List of sendItem(tid, value) pairs waiting to send
  // recvQueue: List of tid waiting to receive
  // buffer: List of values in the buffer (for buffered channels)
  // bufferSize: Maximum buffer capacity (0 for unbuffered channels)
  // elementType: Type of channel elements
  // closed: Bool indicating if channel is closed
  syntax ChanState ::= chanState(List, List, List, Int, Type, Bool)

  // Go specification: Send statement
  // Channel <- Expression sends value to channel

  // Send operation for int channels
  // Priority 0: Panic if channel is closed
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, int), _V:Int) => SendClosedPanic ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, int, true)
       ...</channels>

  // Priority 1a: If there's a normal waiting receiver, deliver immediately
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), Buf, Size, int, false)
              => chanState(SendQ, RecvRest, Buf, Size, int, false))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecv(CId) => V ... </k>
       ...</thread>

  // Priority 1b: If there's a waiting receiver with ok flag, deliver tuple(value, true)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(recvOkItem(RecvTid:Int)) RecvRest:List), Buf, Size, int, false)
              => chanState(SendQ, RecvRest, Buf, Size, int, false))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecvOk(CId) => tuple(ListItem(V) ListItem(true)) ... </k>
       ...</thread>

  // Priority 2: If buffer has space, add to buffer (non-blocking)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, int, false)
              => chanState(SendQ, .List, Buf ListItem(V), Size, int, false))
       ...</channels>
    requires size(Buf) <Int Size

  // Priority 3: If buffer is full, block (add to send queue)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, int, false)
              => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, int, false))
       ...</channels>
    requires size(Buf) >=Int Size

  // Send operation for bool channels
  // Priority 0: Panic if channel is closed
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, bool), _V:Bool) => SendClosedPanic ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, bool, true)
       ...</channels>

  // Priority 1a: If there's a normal waiting receiver, deliver immediately
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), Buf, Size, bool, false)
              => chanState(SendQ, RecvRest, Buf, Size, bool, false))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecv(CId) => V ... </k>
       ...</thread>

  // Priority 1b: If there's a waiting receiver with ok flag, deliver tuple(value, true)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(recvOkItem(RecvTid:Int)) RecvRest:List), Buf, Size, bool, false)
              => chanState(SendQ, RecvRest, Buf, Size, bool, false))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecvOk(CId) => tuple(ListItem(V) ListItem(true)) ... </k>
       ...</thread>

  // Priority 2: If buffer has space, add to buffer (non-blocking)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, bool, false)
              => chanState(SendQ, .List, Buf ListItem(V), Size, bool, false))
       ...</channels>
    requires size(Buf) <Int Size

  // Priority 3: If buffer is full, block (add to send queue)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => waitingSend(CId, V) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, bool, false)
              => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, bool, false))
       ...</channels>
    requires size(Buf) >=Int Size

  // Go specification: Receive operator
  // <-Channel receives value from channel

  // Receive operation
  // Priority 1: If buffer has values, take from buffer (and refill from send queue if any)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanRecv(channel(CId, _T)) => V ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState((ListItem(sendItem(SendTid:Int, SV)) SendRest:List), RecvQ,
                           (ListItem(V) BufRest:List), Size, T, Closed)
              => chanState(SendRest, RecvQ, BufRest ListItem(SV), Size, T, Closed))
       ...</channels>
       <thread>...
         <tid> SendTid </tid>
         <k> waitingSend(CId, _) => .K ... </k>
       ...</thread>

  // Priority 2: If buffer has values but no waiting sender, just take from buffer
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanRecv(channel(CId, _T)) => V ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, T, Closed)
              => chanState(SendQ, RecvQ, BufRest, Size, T, Closed))
       ...</channels>

  // Priority 3: If waiting sender exists and buffer is empty, receive directly
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanRecv(channel(CId, _T)) => V ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState((ListItem(sendItem(SendTid:Int, V)) SendRest:List), RecvQ, .List, Size, T, Closed)
              => chanState(SendRest, RecvQ, .List, Size, T, Closed))
       ...</channels>
       <thread>...
         <tid> SendTid </tid>
         <k> waitingSend(CId, _) => .K ... </k>
       ...</thread>

  // Priority 4: If channel is closed and nothing in buffer, return zero value
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanRecv(channel(CIdClosed, int)) => 0 ... </k>
       ...</thread>
       <channels>...
         CIdClosed |-> chanState(.List, _RecvQ, .List, _Size, int, true)
       ...</channels>

  rule <thread>...
         <tid> _Tid </tid>
         <k> chanRecv(channel(CIdClosed2, bool)) => false ... </k>
       ...</thread>
       <channels>...
         CIdClosed2 |-> chanState(.List, _RecvQ, .List, _Size, bool, true)
       ...</channels>

  // Priority 5: Nothing available and not closed, block (add to recv queue)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanRecv(channel(CId, _T)) => waitingRecv(CId) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(.List, RecvQ, .List, Size, T, false)
              => chanState(.List, RecvQ ListItem(Tid), .List, Size, T, false))
       ...</channels>

  // Go specification: close(ch) closes a channel
  // Panics if channel is already closed
  // Wakes all waiting receivers with zero value

  // close() on already closed channel panics
  rule <k> close(channel(CId, _T)) => CloseClosedPanic ... </k>
       <channels>...
         CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, _ElemT, true)
       ...</channels>

  // close() for int channel - wake all waiting receivers with zero value
  rule <thread>...
         <tid> _Tid </tid>
         <k> close(channel(CId, int)) => wakeReceivers(RecvQ, CId, 0) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, RecvQ, Buf, Size, int, false)
              => chanState(SendQ, .List, Buf, Size, int, true))
       ...</channels>

  // close() for bool channel - wake all waiting receivers with zero value
  rule <thread>...
         <tid> _Tid </tid>
         <k> close(channel(CId, bool)) => wakeReceivers(RecvQ, CId, false) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, RecvQ, Buf, Size, bool, false)
              => chanState(SendQ, .List, Buf, Size, bool, true))
       ...</channels>

  // Helper: wake all waiting receivers with zero value
  syntax KItem ::= wakeReceivers(List, Int, K)  // wakeReceivers(recvQueue, chanId, zeroValue)

  rule <k> wakeReceivers(.List, _CId, _ZeroVal) => .K ... </k>

  // Wake normal receiver with zero value
  rule <k> wakeReceivers((ListItem(RecvTid:Int) Rest:List), CId, ZeroVal)
        => wakeReceivers(Rest, CId, ZeroVal) ... </k>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecv(CId) => ZeroVal ... </k>
       ...</thread>

  // Wake receiver with ok flag: return tuple(zeroValue, false)
  rule <k> wakeReceivers((ListItem(recvOkItem(RecvTid:Int)) Rest:List), CId, ZeroVal)
        => wakeReceivers(Rest, CId, ZeroVal) ... </k>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecvOk(CId) => tuple(ListItem(ZeroVal) ListItem(false)) ... </k>
       ...</thread>

  // Go specification: Receive with ok value (v, ok := <-ch)
  // Returns (value, true) for successful receive
  // Returns (zeroValue, false) for closed channel

  // Helper: generate zero value for a type
  syntax K ::= zeroValueForType(Type) [function]
  rule zeroValueForType(int) => 0
  rule zeroValueForType(bool) => false
  rule zeroValueForType(chan _T:Type) => nil

  // Transform multi-value receive in different contexts
  // Context rules to evaluate channel expression first
  context _:Id, _:Id := <-HOLE:Exp
  context _:Id, _:Id = <-HOLE:Exp
  context var _:Id, _:Id = <-HOLE:Exp

  // Short variable declaration: v, ok := <-ch
  rule <k> X:Id, Y:Id := <-Ch:ChanVal
        => (X, Y) := recvWithOk(Ch) ... </k>

  rule <k> X:Id, Y:Id := <-Ch:FuncVal
        => (X, Y) := recvWithOk(Ch) ... </k>

  // Assignment: x, ok = <-ch
  rule <k> X:Id, Y:Id = <-Ch:ChanVal
        => (X, Y) = recvWithOk(Ch) ... </k>

  rule <k> X:Id, Y:Id = <-Ch:FuncVal
        => (X, Y) = recvWithOk(Ch) ... </k>

  // Variable declaration: var x, ok = <-ch
  // Transform to short declaration (simpler implementation)
  rule <k> var X:Id, Y:Id = <-Ch:ChanVal
        => (X, Y) := recvWithOk(Ch) ... </k>

  rule <k> var X:Id, Y:Id = <-Ch:FuncVal
        => (X, Y) := recvWithOk(Ch) ... </k>

  // recvWithOk implementation with proper priority order
  // Go spec: receive blocks until value is available or channel is closed

  // Priority 0: nil channel - block forever (nil is represented as FuncVal)
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(_FV:FuncVal) => waitingRecvOk(0) ... </k>
       ...</thread>
    [priority(10)]

  // Priority 1: Buffer has values and waiting sender - take from buffer, refill from sender
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, T)) => tuple(ListItem(V) ListItem(true)) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState((ListItem(sendItem(SendTid:Int, SV)) SendRest:List), RecvQ,
                           (ListItem(V) BufRest:List), Size, T, Closed)
              => chanState(SendRest, RecvQ, BufRest ListItem(SV), Size, T, Closed))
       ...</channels>
       <thread>...
         <tid> SendTid </tid>
         <k> waitingSend(CId, _) => .K ... </k>
       ...</thread>
    [priority(20)]

  // Priority 2: Buffer has values but no waiting sender - just take from buffer
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, T)) => tuple(ListItem(V) ListItem(true)) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, T, Closed)
              => chanState(SendQ, RecvQ, BufRest, Size, T, Closed))
       ...</channels>
    [priority(30)]

  // Priority 3: Waiting sender exists and buffer is empty - receive directly via handshake
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, T)) => tuple(ListItem(V) ListItem(true)) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState((ListItem(sendItem(SendTid:Int, V)) SendRest:List), RecvQ, .List, Size, T, Closed)
              => chanState(SendRest, RecvQ, .List, Size, T, Closed))
       ...</channels>
       <thread>...
         <tid> SendTid </tid>
         <k> waitingSend(CId, _) => .K ... </k>
       ...</thread>
    [priority(40)]

  // Priority 4: Channel is closed and buffer is empty - return (zeroValue, false)
  // For int channels
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, int)) => tuple(ListItem(0) ListItem(false)) ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(.List, _RecvQ, .List, _Size, int, true)
       ...</channels>
    [priority(50)]

  // For bool channels
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, bool)) => tuple(ListItem(false) ListItem(false)) ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(.List, _RecvQ, .List, _Size, bool, true)
       ...</channels>
    [priority(50)]

  // Priority 5: Nothing available and not closed - block (add to recv queue with ok flag)
  rule <thread>...
         <tid> Tid </tid>
         <k> recvWithOk(channel(CId, T)) => waitingRecvOk(CId) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(.List, RecvQ, .List, Size, T, false)
              => chanState(.List, RecvQ ListItem(recvOkItem(Tid)), .List, Size, T, false))
       ...</channels>
    [priority(60)]

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

  // Internal: waiting states for blocked threads
  syntax KItem ::= waitingSend(Int, K)  // waitingSend(channelId, value)
                 | waitingRecv(Int)      // waitingRecv(channelId)
                 | waitingRecvOk(Int)    // waitingRecvOk(channelId) - for multi-value receive

  syntax SendItem ::= sendItem(Int, K)  // sendItem(tid, value)

  // RecvItem: distinguish between normal receive and receive-with-ok
  syntax RecvItem ::= Int              // tid for normal receive
                    | recvOkItem(Int)  // tid for receive-with-ok

  // panic implementation (simple version)
  // For now, panics just halt execution
  syntax KItem ::= "SendClosedPanic" | "CloseClosedPanic"

  rule <k> SendClosedPanic ~> _ => .K </k>

  rule <k> CloseClosedPanic ~> _ => .K </k>

endmodule
