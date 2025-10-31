requires "domains.md"
requires "core.k"
requires "func.k"
requires "../syntax/concurrent.k"
requires "concurrent/common.k"
requires "concurrent/goroutine.k"
requires "concurrent/channel-ops.k"
requires "concurrent/range-channel.k"
requires "concurrent/select.k"

// ============================================================================
// GO-CONCURRENT MODULE (AGGREGATOR)
// ============================================================================
// This module aggregates all concurrent semantics submodules:
// - common.k: Shared definitions, types, and helper functions
// - goroutine.k: Goroutine spawning and thread management
// - channel-ops.k: Channel operations (make, send, receive, close)
// - range-channel.k: For-range over channels
// - select.k: Select statement for multiplexing channels
//
// This aggregator maintains backward compatibility with existing imports
// while providing a cleaner modular structure for maintainability.

module GO-CONCURRENT
  imports GO
  imports GO-FUNC
  imports GO-CONTROL-FLOW
  imports GO-SYNTAX-CONCURRENT
  imports GO-CONCURRENT-COMMON
  imports GO-GOROUTINE
  imports GO-CHANNEL-OPS
  imports GO-RANGE-CHANNEL
  imports GO-SELECT
  imports INT
  imports LIST
  imports MAP
  imports STRING

endmodule
