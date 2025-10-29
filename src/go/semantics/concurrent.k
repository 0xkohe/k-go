requires "domains.md"
requires "core.k"
requires "func.k"
requires "../syntax/concurrent.k"

module GO-CONCURRENT
  imports GO
  imports GO-FUNC
  imports GO-SYNTAX-CONCURRENT
  imports INT
  imports LIST
  imports MAP

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
       <channels> Chans => Chans [ N <- chanState(.List, .List, .List, 0, T) ] </channels>

  // make(chan T, size) creates a buffered channel with given buffer size
  rule <k> make(chan T:Type, Size:Int) => channel(N, T) ... </k>
       <nextChanId> N:Int => N +Int 1 </nextChanId>
       <channels> Chans => Chans [ N <- chanState(.List, .List, .List, Size, T) ] </channels>
    requires Size >=Int 0

  // Channel state: chanState(sendQueue, recvQueue, buffer, bufferSize, elementType)
  // sendQueue: List of sendItem(tid, value) pairs waiting to send
  // recvQueue: List of tid waiting to receive
  // buffer: List of values in the buffer (for buffered channels)
  // bufferSize: Maximum buffer capacity (0 for unbuffered channels)
  // elementType: Type of channel elements
  syntax ChanState ::= chanState(List, List, List, Int, Type)

  // Go specification: Send statement
  // Channel <- Expression sends value to channel

  // Send operation for int channels
  // Priority 1: If there's a waiting receiver, deliver immediately
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), Buf, Size, int)
              => chanState(SendQ, RecvRest, Buf, Size, int))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecv(CId) => V ... </k>
       ...</thread>

  // Priority 2: If buffer has space, add to buffer (non-blocking)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, int)
              => chanState(SendQ, .List, Buf ListItem(V), Size, int))
       ...</channels>
    requires size(Buf) <Int Size

  // Priority 3: If buffer is full, block (add to send queue)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanSend(channel(CId, int), V:Int) => waitingSend(CId, V) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, int)
              => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, int))
       ...</channels>
    requires size(Buf) >=Int Size

  // Send operation for bool channels
  // Priority 1: If there's a waiting receiver, deliver immediately
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, (ListItem(RecvTid:Int) RecvRest:List), Buf, Size, bool)
              => chanState(SendQ, RecvRest, Buf, Size, bool))
       ...</channels>
       <thread>...
         <tid> RecvTid </tid>
         <k> waitingRecv(CId) => V ... </k>
       ...</thread>

  // Priority 2: If buffer has space, add to buffer (non-blocking)
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => .K ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, bool)
              => chanState(SendQ, .List, Buf ListItem(V), Size, bool))
       ...</channels>
    requires size(Buf) <Int Size

  // Priority 3: If buffer is full, block (add to send queue)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanSend(channel(CId, bool), V:Bool) => waitingSend(CId, V) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(SendQ, .List, Buf, Size, bool)
              => chanState(SendQ ListItem(sendItem(Tid, V)), .List, Buf, Size, bool))
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
                           (ListItem(V) BufRest:List), Size, T)
              => chanState(SendRest, RecvQ, BufRest ListItem(SV), Size, T))
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
         CId |-> (chanState(SendQ, RecvQ, (ListItem(V) BufRest:List), Size, T)
              => chanState(SendQ, RecvQ, BufRest, Size, T))
       ...</channels>

  // Priority 3: If waiting sender exists and buffer is empty, receive directly
  rule <thread>...
         <tid> _Tid </tid>
         <k> chanRecv(channel(CId, _T)) => V ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState((ListItem(sendItem(SendTid:Int, V)) SendRest:List), RecvQ, .List, Size, T)
              => chanState(SendRest, RecvQ, .List, Size, T))
       ...</channels>
       <thread>...
         <tid> SendTid </tid>
         <k> waitingSend(CId, _) => .K ... </k>
       ...</thread>

  // Priority 4: Nothing available, block (add to recv queue)
  rule <thread>...
         <tid> Tid </tid>
         <k> chanRecv(channel(CId, _T)) => waitingRecv(CId) ... </k>
       ...</thread>
       <channels>...
         CId |-> (chanState(.List, RecvQ, .List, Size, T)
              => chanState(.List, RecvQ ListItem(Tid), .List, Size, T))
       ...</channels>

  // Internal: waiting states for blocked threads
  syntax KItem ::= waitingSend(Int, K)  // waitingSend(channelId, value)
                 | waitingRecv(Int)      // waitingRecv(channelId)

  syntax SendItem ::= sendItem(Int, K)  // sendItem(tid, value)

endmodule
