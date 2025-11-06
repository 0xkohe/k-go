requires "../core.k"
requires "../../syntax/concurrent.k"
requires "common.k"

// ============================================================================
// GO-CHANNEL-OPS MODULE
// ============================================================================
// Channel operation semantics including:
// - Channel variable declarations (var, :=, assignment)
// - Channel creation (make)
// - Send and receive operations with priority-based rules
// - Channel close operation
// - Multi-value receive (v, ok := <-ch)

module GO-CHANNEL-OPS
  imports GO
  imports GO-CONTROL-FLOW
  imports GO-SYNTAX-CONCURRENT
  imports GO-CONCURRENT-COMMON
  imports INT
  imports LIST
  imports MAP
  imports STRING

  // ============================================================================
  // CHANNEL VARIABLE DECLARATIONS
  // ============================================================================

  // Go specification: Channel type variable declaration
  // The zero value of channel type is nil
  rule <k> var X:Id chan T:Type => var X chan T = nil ... </k>
  rule <k> var X:Id chan <- T:Type => var X chan <- T = nil ... </k>
  rule <k> var X:Id <- chan T:Type => var X <- chan T = nil ... </k>

  // Accept both ChanVal (actual channel) and FuncVal (nil)
  // Bidirectional channel
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

  // Send-only channel
  rule <k> var X:Id chan <- T:Type = CV:ChanVal => .K ... </k>
       <tenv> R => R [ X <- chan <- T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- CV ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  rule <k> var X:Id chan <- T:Type = FV:FuncVal => .K ... </k>
       <tenv> R => R [ X <- chan <- T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- FV ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  // Receive-only channel
  rule <k> var X:Id <- chan T:Type = CV:ChanVal => .K ... </k>
       <tenv> R => R [ X <- <- chan T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- CV ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  rule <k> var X:Id <- chan T:Type = FV:FuncVal => .K ... </k>
       <tenv> R => R [ X <- <- chan T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- FV ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>

  // ============================================================================
  // CHANNEL SHORT DECLARATIONS
  // ============================================================================

  // Go specification: Short variable declaration for channels
  // Error rule: check for redeclaration first (higher priority)
  rule <k> X:Id := _CV:ChanVal => shortDeclError ... </k>
       <scopeDecls> (_SD ListItem(ScopeMap)) </scopeDecls>
    requires X in_keys(ScopeMap)
    [priority(10)]

  // Infer type from channel value
  rule <k> X:Id := channel(CId:Int, T:Type) => .K ... </k>
       <tenv> R => R [ X <- chan T ] </tenv>
       <env> Env => Env [ X <- L ] </env>
       <store> Store => Store [ L <- channel(CId, T) ] </store>
       <nextLoc> L:Int => L +Int 1 </nextLoc>
       <scopeDecls> (SD ListItem(ScopeMap)) => SD ListItem(ScopeMap [ X <- true ]) </scopeDecls>
    requires notBool (X in_keys(ScopeMap))

  // ============================================================================
  // CHANNEL ASSIGNMENTS
  // ============================================================================

  // Go specification: Channel assignment
  rule <k> X:Id = CV:ChanVal => .K ... </k>
       <tenv> ... X |-> chan _T:Type ... </tenv>
       <env> ... X |-> L:Int ... </env>
       <store> Store => Store [ L <- CV ] </store>
       <constEnv> CE </constEnv>
    requires notBool (X in_keys(CE))

  // ============================================================================
  // CHANNEL CREATION
  // ============================================================================

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

  // ============================================================================
  // SEND OPERATIONS
  // ============================================================================

  // Go specification: Send statement
  // Channel <- Expression sends value to channel
  //
  // GENERIC SEND OPERATIONS
  // These rules work for any value type (int, bool, channel, function)
  // Refactored from type-specific rules to reduce code duplication by ~50%
  //
  // Priority-based rule ordering ensures correct Go semantics:
  // - Priority 0: Closed channel errors (must detect before any operation)
  // - Priority 1: Direct handoff (rendezvous - sender meets receiver immediately)
  // - Priority 2: Buffered non-blocking (use buffer when available)
  // - Priority 3: Blocking (queue sender when no immediate progress possible)
  //
  // These priorities prevent stuck states and ensure deterministic behavior

  // DIRECTION VALIDATION (Priority 5)
  // Fires BEFORE identifier lookup to prevent invalid operations early
  // Checks <tenv> for channel type and validates direction permissions
  rule <k> (X:Id <- _V) => ChanSendDirectionError ... </k>
       <tenv>... X |-> CT:ChannelType ...</tenv>
    requires notBool canSend(CT)
    [priority(5)]

  // SEND PRIORITY RULES
  // Priority 0: Closed channel panic (highest priority - safety check)
  // Sending to a closed channel is a programming error in Go
  // Must fire first to prevent any operations on closed channels
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, _T:Type), _V) => SendClosedPanic ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, _ElemT, true)
       ...</channels>

  // Priority 1a: Direct handoff to waiting normal receiver (rendezvous)
  // When a receiver is already blocked, deliver immediately without buffering
  // This is the core of unbuffered channel semantics (synchronous communication)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, T:Type), V) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), Buf, Size, T, false)
              => chanState(SendQ, RecvRest, Buf, Size, T, false))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecv(CId) => V ... </k>
       ...</thread>

  // Priority 1b: Direct handoff to receiver with ok flag
  // Similar to 1a, but receiver is using multi-value receive (v, ok := <-ch)
  // Delivers tuple(value, true) to indicate successful receive from open channel
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, T:Type), V) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(recvOkItem(RecvTid:Int)) RecvRest:List), Buf, Size, T, false)
              => chanState(SendQ, RecvRest, Buf, Size, T, false))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecvOk(CId) => tuple(ListItem(V) ListItem(true)) ... </k>
       ...</thread>

  // Priority 2: Buffer has space - non-blocking send
  // Most common case for buffered channels: sender completes immediately
  // Buffer stores value for later retrieval by receiver
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, T:Type), V) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, T, false)
              => chanState(SendQ, .List, Buf ListItem(V), Size, T, false))
       ...</channels>
    requires size(Buf) <Int Size

  // Priority 3: Buffer full - blocking send
  // Sender is added to sendQueue and transitions to waitingSend state
  // Will be woken when receiver takes from buffer (making space available)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanSend(channel(CId, T:Type), V) => waitingSend(CId, V) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, T, false)
              => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, T, false))
       ...</channels>
    requires size(Buf) >=Int Size

  // ============================================================================
  // RECEIVE OPERATIONS
  // ============================================================================

  // Go specification: Receive operator
  // <-Channel receives value from channel
  //
  // GENERIC RECEIVE OPERATIONS
  // Priority-based ordering for correctness:
  // - Priority 1: Buffer + waiting sender (take from buffer, refill from sendQueue)
  // - Priority 2: Buffer only (take from buffer when no waiting senders)
  // - Priority 3: Direct handoff (unbuffered rendezvous)
  // - Priority 4: Closed channel (return zero value)
  // - Priority 5: Block (add to recvQueue when nothing available)

  // DIRECTION VALIDATION (Priority 5)
  // Checks receive permission before attempting operation
  rule <k> (<- X:Id) => ChanRecvDirectionError ... </k>
       <tenv>... X |-> CT:ChannelType ...</tenv>
    requires notBool canReceive(CT)
    [priority(5)]

  // RECEIVE PRIORITY RULES
  // Priority 1: Buffer has values + waiting sender - refill buffer while receiving
  // This maintains FIFO order: take oldest from buffer, add newest from sendQueue
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
         <k> chanRecv(channel(CId, T:Type)) => zeroValueForType(T) ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(.List, _RecvQ, .List, _Size, T, true)
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

  // ============================================================================
  // CLOSE OPERATION
  // ============================================================================

  // Go specification: close(ch) closes a channel
  // Panics if channel is already closed
  // Wakes all waiting receivers with zero value

  // close() on already closed channel panics
  rule <k> close(channel(CId, _T)) => CloseClosedPanic ... </k>
       <channels>...
         CId |-> chanState(_SendQ, _RecvQ, _Buf, _Size, _ElemT, true)
       ...</channels>

  // close() for any channel type - wake all waiting receivers with zero value
  rule <thread>...
         <tid> _Tid </tid>
         <k> close(channel(CId, T:Type)) => wakeReceivers(RecvQ, CId, zeroValueForType(T)) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, RecvQ, Buf, Size, T, false)
              => chanState(SendQ, .List, Buf, Size, T, true))
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

  // ============================================================================
  // MULTI-VALUE RECEIVE (v, ok := <-ch)
  // ============================================================================

  // Go specification: Receive with ok value (v, ok := <-ch)
  // Returns (value, true) for successful receive
  // Returns (zeroValue, false) for closed channel

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
  // Separate rules for each type to avoid parser issues with nested function calls
  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, int))
          => tuple(ListItem(0) ListItem(false)) ... </k>
       ...</thread>
       <channels>...
         CId |-> chanState(.List, _RecvQ, .List, _Size, int, true)
       ...</channels>
    [priority(50)]

  rule <thread>...
         <tid> _Tid </tid>
         <k> recvWithOk(channel(CId, bool))
          => tuple(ListItem(false) ListItem(false)) ... </k>
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

endmodule
