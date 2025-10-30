# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a K Framework project implementing a subset of the Go programming language semantics. The project uses Docker for K Framework tooling and defines formal semantics for Go language features including functions, control flow, scoping, and basic types.

## Reference Documentation

For detailed information:
- **K Framework**: See `K_framework_documentation.md` in the root directory for comprehensive K Framework language reference, semantics, and tooling information.
- **Go specification**: See `src/go/go_language_specification.txt` for the official Go language specification when implementing or extending Go features.

**Important**: When implementing Go language features, always refer to the Go specification and align naming, terminology, and syntax elements as closely as possible with the official specification to maintain consistency and correctness.

## Development Environment

The project runs inside a Docker container with K Framework pre-installed:

```bash
# Start the Docker container
docker compose up -d

# Enter the container
docker compose exec k bash
```

All development work should be done inside the container at `/app` (mapped to `./src` on the host).

## Key Commands

### Compiling K Definitions

```bash
# Basic compilation
kompile <definition>.k

# With verbose output and LLVM backend (for debugging)
kompile <definition>.k --verbose --enable-llvm-debug --backend llvm

# Manual LLVM compilation (advanced)
llvm-kompile /app/<definition>.k/<definition>-kompiled/definition.kore /app/<definition>.k/<definition>-kompiled/dt main -g -O1 -o /app/<definition>.k/<definition>-kompiled/interpreter -- -g
```

### Running Programs

```bash
# Run a program file (files live under src/go/codes/)
krun codes/code

# Run with debugger
krun codes/code --debugger

# Run with specific program argument
krun -cPGM=0 --debugger
```

### Testing After Changes

After modifying K definitions, run the following commands from the project root to verify changes:

```bash
# 1. Recompile the definitions
docker compose exec k bash -c "cd go && kompile main.k"

# 2. Run test program to verify changes
docker compose exec k bash -c "cd go && krun codes/code --definition main-kompiled/"
```

These commands ensure that:
- The K definitions compile without errors
- Existing test programs still execute correctly
- No regressions are introduced by the changes

## Architecture

### Primary Go Implementation (`src/go/`)

The main Go language implementation is modular:

- **`go.k`**: Core language features including:
  - Basic types (int, bool)
  - Variables (var) and constants (const) with type inference
  - Short variable declarations (:=) with same-scope redeclaration checking
  - Expressions and operators (arithmetic, comparison, boolean)
  - Control flow (if/else, for loops with ForClause and RangeClause)
  - Block scoping with environment stacks
  - Break/continue statements
  - Automatic semicolon insertion rules

- **`func.k`**: Function semantics extension adding:
  - Function declarations with typed parameters
  - Function calls with call-by-value semantics
  - Return statements (single value or void)
  - Function literals (closures) with environment capture
  - Lexical scoping for function parameters

- **`concurrent.k`**: Concurrency semantics adding:
  - Goroutines (go statement) with thread spawning
  - Channels (make, send, receive, close)
  - Buffered and unbuffered channels
  - Channel directions (chan T, chan<- T, <-chan T)
  - Direction validation with error checking
  - Multi-value receive (v, ok := <-ch)
  - For-range over channels
  - Generic channel operations for int, bool, chan, func types

- **`main.k`**: Entry point that imports and combines all modules

### Configuration Cells

The K configuration uses multiple cells for state management:

- `<threads>`: Collection of thread cells (for concurrency)
- `<thread>`: Individual thread state (multiplicity="*")
  - `<tid>`: Thread ID (unique integer)
  - `<k>`: Computation cell (program being executed)
  - `<tenv>`: Type environment mapping identifiers to types
  - `<env>`: Environment mapping identifiers to locations (`Loc`)
  - `<envStack>`, `<tenvStack>`: Stack cells for block scoping
  - `<constEnv>`: Constant environment (compile-time constants)
  - `<constEnvStack>`: Stack for constant block scoping
  - `<scopeDecls>`: Stack of Maps tracking which identifiers were declared in each scope
- `<nextTid>`: Counter for next thread ID
- `<out>`: Output accumulator (for print statements)
- `<store>`: Shared store mapping `Loc` to actual values (ints, bools, channels, closures)
- `<nextLoc>`: Counter for the next free location
- `<fenv>`: Function environment storing function definitions
- `<channels>`: Map from channel ID to channel state
- `<nextChanId>`: Counter for next channel ID

### Type System

The implementation uses store-based semantics:
- `<tenv>` tracks each identifier's declared type for static checks
- `<env>` maps identifiers to `Loc` entries inside the shared `<store>`
- `<store>` holds the actual runtime values (ints, bools, closures) keyed by `Loc`
- `<nextLoc>` allocates fresh locations for declarations and short declarations

### Scoping Mechanism

Block scoping is implemented via:
1. `enterScope(K)` saves current environments to stacks and creates new scope in `scopeDecls`
2. Execute block body
3. `exitScope` restores environments from stacks and removes scope from `scopeDecls`

### Constants vs Variables

The implementation distinguishes between compile-time constants and runtime variables:

**Constants (const)**:
- Stored directly in `<constEnv>` (no env/store indirection)
- Values known at compile time and never change
- Cannot be reassigned (enforced by `constAssignmentError` with priority rules)
- Support both type inference (`const x = 10`) and explicit types (`const x int = 10`)
- Priority(10) lookup rules ensure constants are resolved before variables

**Variables (var)**:
- Stored in `<store>` with `<env>` mapping identifiers to locations
- Values can be modified at runtime
- Use 2-step lookup: env → location → store → value
- Priority(20) lookup rules (checked after constants)

### Control Flow

- **For loops**:
  - **ForClause**: Desugared into internal `loop(condition, post, body)` construct with all 8 ForClause variants supported
  - **RangeClause** (Go 1.22+): Integer range support (`for i := range n` iterates from 0 to n-1)
    - `for i := range n` - single iteration variable
    - `for range n` - no iteration variable (executes n times)
    - For-range over channels: `for v := range ch`
- **Break/Continue**: Implemented as signals that bubble up to nearest loop boundary
- **Return**: Implemented as `returnSignal(value)` that bubbles to `returnJoin(type)` boundary

### Concurrency Architecture

The implementation supports Go's CSP-style concurrency with goroutines and channels:

**Goroutines:**
- Implemented as separate `<thread>` cells in the configuration
- Each thread has its own `<tid>`, `<k>` computation, and environment cells
- The `go` statement spawns a new thread with a copy of the current environment
- Thread scheduling is non-deterministic (handled by K's rewrite engine)

**Channels:**
- Runtime values: `channel(id, elementType)` stored in `<store>`
- Channel state: `chanState(sendQueue, recvQueue, buffer, bufferSize, elementType, closed)`
  - `sendQueue`: List of `sendItem(tid, value)` for blocked senders
  - `recvQueue`: List of `tid` or `recvOkItem(tid)` for blocked receivers
  - `buffer`: List of buffered values (for buffered channels)
  - `bufferSize`: Maximum buffer capacity (0 for unbuffered channels)
  - `elementType`: Type of values the channel carries
  - `closed`: Boolean indicating if channel is closed

**Channel Operation Priority Rules:**
Channel send and receive operations use carefully ordered priority rules to ensure correctness:
1. **Priority 0**: Error conditions (panic on send to closed channel)
2. **Priority 1**: Direct handoff (sender meets receiver, no buffering) - rendezvous
3. **Priority 2**: Buffered operations (non-blocking when buffer has space/values)
4. **Priority 3+**: Blocking operations (add to wait queue when no immediate progress)

These priorities prevent stuck states and ensure Go's channel semantics.

**Channel Directions:**
- Type system distinguishes: `chan T` (bidirectional), `chan<- T` (send-only), `<-chan T` (receive-only)
- Direction checking occurs at compile-time (semantic analysis via Priority 5 rules)
- Bidirectional channels implicitly convert to directional channels (e.g., in function parameters)
- Direction violations result in `ChanSendDirectionError` or `ChanRecvDirectionError`
- Helper functions: `canSend(Type)`, `canReceive(Type)`, `elementType(Type)`

**Generic Channel Operations:**
- Refactored to work with any value type (int, bool, channel, function)
- Single set of rules handles all channel types
- Zero values computed via `zeroValueForType(Type)` function
- ~45% code reduction compared to type-specific implementations
- Easy to extend for new types (strings, structs, etc.)

### Example Programs

Test programs are located under `src/go/codes/` (e.g., `codes/code`, `codes/code-s`). These demonstrate:
- Function declarations and calls
- Variable declarations (var) and constant declarations (const)
- Short variable declarations (:=) with redeclaration checking
- Assignments (with const assignment prohibition)
- Arithmetic and boolean expressions
- If statements with optional initialization
- For loops with ForClause and RangeClause (integer range)
- Break/continue statements
- Nested block scoping

### Other Examples (`src/other/`)

- **`peano/`**: Peano arithmetic implementation
- **`f1/`**: Simple K language example
- **`binary-increment-tm/`**: Binary increment Turing machine
- **`peano-2/`**: Alternative Peano implementation

Each example directory contains:
- `.k` file: K Framework definition
- `code` file: Test program
- `-kompiled/` directory: Compiled artifacts (generated by `kompile`)

## Working with K Definitions

When modifying `.k` files:
1. Edit the definition file
2. Run `kompile` to compile it
3. Test changes with `krun codes/code`
4. Use `--debugger` flag for step-through debugging

The compiled artifacts in `-kompiled/` directories are generated and should not be manually edited.

## Current Go Language Support

**Supported features:**
- **Basic types**: int, bool
- **Variable declarations** (var) with zero-value initialization
- **Constant declarations** (const) with type inference and explicit types
  - Compile-time constants stored in `constEnv`
  - Assignment to constants prohibited with error detection
  - Priority-based lookup (constants before variables)
- **Short declarations** (:=) with same-scope redeclaration prevention
- **Arithmetic operators**: +, -, *, /, %, unary -
- **Comparison operators**: <, >, ==, !=, <=, >=
- **Boolean operators**: &&, ||, !
- **Increment/decrement**: ++, --
- **Control flow**: if/else, for loops (ForClause and RangeClause)
  - Integer range (Go 1.22+): `for i := range n`, `for range n`
  - For-range over channels: `for v := range ch`
- **Functions**: declarations, calls, multiple return values (tuples)
  - Function literals (closures) with lexical scope capture
  - First-class functions (functions as values)
  - Higher-order functions (functions taking/returning functions)
- **Block scoping** with `scopeDecls` tracking for redeclaration checking
- **Break/continue statements**
- **Print function** (int and bool)
- **Concurrency**:
  - **Goroutines**: go statement spawns concurrent execution
  - **Channels**:
    - Unbuffered (`make(chan T)`) and buffered (`make(chan T, n)`)
    - **Channel directions**: `chan T`, `chan<- T`, `<-chan T`
    - Send (`ch <- v`) and receive (`<-ch`) operations
    - Multi-value receive (`v, ok := <-ch`) for closed channel detection
    - `close(ch)` with panic on double-close or send-on-closed
    - For-range iteration over channels
    - Generic support: `chan int`, `chan bool`, `chan (chan T)`, `chan func`
  - Priority-based rule system for send/receive operations
  - FIFO ordering guarantees for buffered channels
  - Direction validation with compile-time error checking

**Not yet supported:**
- Struct types, arrays, slices, maps
- Pointers
- String type (partial - literals only, no operations)
- For-range over collections (arrays, slices, maps, strings)
- Switch statements
- **select statement** for multiplexing channels
- sync package (WaitGroup, Mutex, etc.)
- Context package
- Defer statements
- Panic/recover mechanism (basic panic implemented for channels only)
- Package system beyond single main package
- Methods and interfaces
