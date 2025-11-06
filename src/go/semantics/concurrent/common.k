requires "../core.k"
requires "../../syntax/concurrent.k"

// ============================================================================
// GO-CONCURRENT-COMMON MODULE
// ============================================================================
// Common definitions and helper functions for concurrent Go semantics.
// This module provides:
// - Channel value types (ChanVal)
// - Channel state definitions (ChanState)
// - Waiting states for blocked threads
// - Helper functions for type checking and zero values
// - Error types for panic and direction violations

module GO-CONCURRENT-COMMON
  imports GO
  imports GO-SYNTAX-CONCURRENT
  imports INT
  imports LIST
  imports MAP
  imports STRING
  imports BOOL

  // ============================================================================
  // CHANNEL VALUE TYPES
  // ============================================================================

  // Channel value type stored in <store>
  // channel(id, elementType) represents a runtime channel reference
  syntax ChanVal ::= channel(Int, Type)  // channel(id, elementType)
  syntax Exp ::= ChanVal

  // Val represents all types that can be sent through channels
  // Note: KResult is already defined in core.k as Int | Bool | FuncVal | Tuple
  // We extend it here to also include ChanVal
  syntax Val ::= ChanVal
  syntax KResult ::= Val

  // ============================================================================
  // CHANNEL STATE DEFINITIONS
  // ============================================================================

  // Channel state: chanState(sendQueue, recvQueue, buffer, bufferSize, elementType, closed)
  // - sendQueue: List of sendItem(tid, value) pairs waiting to send
  // - recvQueue: List of tid or recvOkItem(tid) waiting to receive
  // - buffer: List of values in the buffer (for buffered channels)
  // - bufferSize: Maximum buffer capacity (0 for unbuffered channels)
  // - elementType: Type of channel elements
  // - closed: Bool indicating if channel is closed
  syntax ChanState ::= chanState(List, List, List, Int, Type, Bool)

  // SendItem: represents a blocked sender with thread ID and value
  syntax SendItem ::= sendItem(Int, K)  // sendItem(tid, value)

  // RecvItem: distinguish between normal receive and receive-with-ok
  syntax RecvItem ::= Int              // tid for normal receive
                    | recvOkItem(Int)  // tid for receive-with-ok

  // ============================================================================
  // WAITING STATES FOR BLOCKED THREADS
  // ============================================================================

  // Internal: waiting states for blocked threads
  syntax KItem ::= waitingSend(Int, K)  // waitingSend(channelId, value)
                 | waitingRecv(Int)      // waitingRecv(channelId)
                 | waitingRecvOk(Int)    // waitingRecvOk(channelId) - for multi-value receive

  // ============================================================================
  // ERROR AND PANIC TYPES
  // ============================================================================

  // Channel direction errors (compile-time checks)
  syntax KItem ::= "ChanSendDirectionError" | "ChanRecvDirectionError"

  rule <k> ChanSendDirectionError ~> _ => .K </k>
  rule <k> ChanRecvDirectionError ~> _ => .K </k>

  // Panic implementation (simple version)
  // For now, panics just halt execution
  syntax KItem ::= "SendClosedPanic" | "CloseClosedPanic"

  rule <k> SendClosedPanic ~> _ => .K </k>
  rule <k> CloseClosedPanic ~> _ => .K </k>

  // ============================================================================
  // HELPER FUNCTIONS
  // ============================================================================

  // Helper: generate zero value for a type
  // Used when: receiving from closed channels, initializing variables
  // Generic implementation allows adding new types without modifying channel logic
  // Returns: 0 for int, false for bool, nil for channel types
  // Extensibility: Add "rule zeroValueForType(string) => """ for string support
  syntax K ::= zeroValueForType(Type) [function]
  rule zeroValueForType(int) => 0
  rule zeroValueForType(bool) => false
  rule zeroValueForType(chan _T:Type) => nil
  rule zeroValueForType(chan <- _T:Type) => nil
  rule zeroValueForType(<- chan _T:Type) => nil

  // Helper: Check if a channel type permits send operations
  // Used by: Priority 5 direction validation rules in send operations
  // Returns: true for bidirectional and send-only, false for receive-only
  // Purpose: Detect attempts to send on receive-only channels at compile-time
  syntax Bool ::= canSend(Type) [function]
  rule canSend(chan _T) => true              // bidirectional: yes
  rule canSend(chan <- _T) => true           // send-only: yes
  rule canSend(<- chan _T) => false          // receive-only: no
  rule canSend(_) => false [owise]           // not a channel: no

  // Helper: Check if a channel type permits receive operations
  // Used by: Priority 5 direction validation rules in receive operations
  // Returns: true for bidirectional and receive-only, false for send-only
  // Purpose: Detect attempts to receive from send-only channels at compile-time
  syntax Bool ::= canReceive(Type) [function]
  rule canReceive(chan _T) => true           // bidirectional: yes
  rule canReceive(chan <- _T) => false       // send-only: no
  rule canReceive(<- chan _T) => true        // receive-only: yes
  rule canReceive(_) => false [owise]        // not a channel: no

  // Helper: Extract element type from channel type
  // Used by: Type checking and generic channel operations
  // Returns: T for chan T, chan<- T, or <-chan T
  // Purpose: Get underlying element type regardless of direction
  syntax Type ::= elementType(Type) [function]
  rule elementType(chan T) => T
  rule elementType(chan <- T) => T
  rule elementType(<- chan T) => T

  // Helper: Extract channel ID from channel value
  // Used by: select statement and channel operations
  syntax Int ::= chanId(ChanVal) [function]
  rule chanId(channel(CId, _T)) => CId

  // Helper: Check if default case exists
  // Used by: select statement to determine blocking behavior
  syntax Bool ::= hasDefault(K) [function]
  rule hasDefault(.K) => false
  rule hasDefault(_) => true [owise]

  // Integrate channel values with core value helpers
  rule typeOfValue(channel(_CId, T)) => chan T
  rule goValueFromResult(channel(CId, T)) => goValue(chan T, channel(CId, T))

endmodule
