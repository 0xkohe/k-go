#!/bin/bash

# K-Go Compatibility Test Suite
# Runs all test files in src/go/codes/ directory and reports results

set -eo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODES_DIR="${SCRIPT_DIR}/src/go/codes"
GO_DIR="${SCRIPT_DIR}/src/go"
LOG_DIR="${SCRIPT_DIR}/test-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/test-run-${TIMESTAMP}.log"

# Options
VERBOSE=false
NO_COMPILE=false
PATTERN=""
TIMEOUT=30  # seconds per test

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
ERROR_TESTS_PASSED=0
ERROR_TESTS_FAILED=0
ERROR_TESTS_RUN=0  # Track how many error tests were actually run

# Arrays to store results
declare -a FAILED_TEST_NAMES
declare -a FAILED_TEST_ERRORS
FAILED_TEST_NAMES=()
FAILED_TEST_ERRORS=()

# Parse command line arguments
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

K-Go Compatibility Test Suite - Run all test files in codes/ directory

OPTIONS:
    -v, --verbose           Enable verbose output (show test outputs)
    -n, --no-compile        Skip recompilation of main.k
    -p, --pattern PATTERN   Only run tests matching PATTERN
    -t, --timeout SECONDS   Timeout per test (default: 30)
    -h, --help             Show this help message

EXAMPLES:
    $0                          # Run all tests
    $0 --verbose                # Run with detailed output
    $0 --pattern "channel"      # Run only channel-related tests
    $0 --no-compile             # Skip compilation, run tests only

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--no-compile)
            NO_COMPILE=true
            shift
            ;;
        -p|--pattern)
            PATTERN="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Helper functions
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

log_verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "$1" | tee -a "$LOG_FILE"
    else
        echo -e "$1" >> "$LOG_FILE"
    fi
}

is_error_test() {
    local test_name="$1"
    # ファイル名に "error" が含まれていればエラーテスト
    if [[ "$test_name" == *error* ]]; then
        return 0
    fi
    return 1
}

# Setup
mkdir -p "$LOG_DIR"

# Print header
log "${CYAN}============================================${NC}"
log "${CYAN}   K-Go Compatibility Test Suite${NC}"
log "${CYAN}============================================${NC}"
log ""
log "Start time: $(date)"
log "Log file: $LOG_FILE"
log ""

# Check Docker
if ! docker compose ps | grep -q "k"; then
    log "${YELLOW}Warning: Docker container 'k' is not running${NC}"
    log "Starting container..."
    docker compose up -d
    sleep 2
fi

# Compile K definitions
if [ "$NO_COMPILE" = false ]; then
    log "${BLUE}Compiling main.k...${NC}"
    if docker compose exec k bash -c "cd go && kompile main.k" >> "$LOG_FILE" 2>&1; then
        log "${GREEN}✓ Compilation successful${NC}"
    else
        log "${RED}✗ Compilation failed${NC}"
        log "Check log file for details: $LOG_FILE"
        exit 1
    fi
    log ""
else
    log "${YELLOW}Skipping compilation (--no-compile)${NC}"
    log ""
fi

# Find all test files
cd "$CODES_DIR"
if [ -n "$PATTERN" ]; then
    TEST_FILES=($(ls -1 | grep -E "$PATTERN" | sort))
    log "${BLUE}Running tests matching pattern: ${PATTERN}${NC}"
else
    TEST_FILES=($(ls -1 | sort))
    log "${BLUE}Running all tests${NC}"
fi

TOTAL_TESTS=${#TEST_FILES[@]}
log "Found $TOTAL_TESTS test files"
log ""

# Run tests
START_TIME=$(date +%s)

for test_file in "${TEST_FILES[@]}"; do
    # Check if it's an error test
    IS_ERROR_TEST=false
    if is_error_test "$test_file"; then
        IS_ERROR_TEST=true
    fi

    log_verbose "${CYAN}Running: ${test_file}${NC}"

    # Run test with timeout
    TEST_START=$(date +%s)
    TEST_OUTPUT=$(mktemp)
    TEST_ERROR=$(mktemp)

    # Run test (same way for both verbose and non-verbose)
    # Keep docker exec in the foreground and close stdin to avoid SIGTTIN stalls.
    if timeout --foreground "$TIMEOUT" \
        docker compose exec -T \
        k bash -lc "cd go && krun codes/$test_file --definition main-kompiled/" \
        < /dev/null > "$TEST_OUTPUT" 2> "$TEST_ERROR"; then
        TEST_EXIT_CODE=0
    else
        TEST_EXIT_CODE=$?
    fi

    # Display output immediately if verbose
    if [ "$VERBOSE" = true ]; then
        cat "$TEST_OUTPUT"
    fi

    TEST_END=$(date +%s)
    TEST_DURATION=$((TEST_END - TEST_START))

    # Check result
    if [ "$IS_ERROR_TEST" = true ]; then
        ERROR_TESTS_RUN=$((ERROR_TESTS_RUN + 1))
        # For error tests, we expect non-zero exit code or error output
        if [ $TEST_EXIT_CODE -ne 0 ] || grep -q -i "error\|panic" "$TEST_ERROR" "$TEST_OUTPUT" 2>/dev/null; then
            log "${YELLOW}[EXPECTED_ERROR]${NC} $test_file (${TEST_DURATION}s)"
            ERROR_TESTS_PASSED=$((ERROR_TESTS_PASSED + 1))
        else
            log "${RED}[ERROR_TEST_FAILED]${NC} $test_file (${TEST_DURATION}s) - Should have failed but passed"
            ERROR_TESTS_FAILED=$((ERROR_TESTS_FAILED + 1))
            FAILED_TEST_NAMES+=("$test_file")
            FAILED_TEST_ERRORS+=("Expected error but test passed")
        fi
    else
        # For normal tests, we expect zero exit code
        if [ $TEST_EXIT_CODE -eq 0 ]; then
            log "${GREEN}[PASS]${NC} $test_file (${TEST_DURATION}s)"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            if [ $TEST_EXIT_CODE -eq 124 ]; then
                log "${RED}[TIMEOUT]${NC} $test_file (>${TIMEOUT}s)"
                FAILED_TEST_NAMES+=("$test_file")
                FAILED_TEST_ERRORS+=("Test timeout after ${TIMEOUT}s")
            else
                log "${RED}[FAIL]${NC} $test_file (${TEST_DURATION}s)"
                FAILED_TEST_NAMES+=("$test_file")
                ERROR_MSG=$(cat "$TEST_ERROR" | head -5 | tr '\n' ' ')
                if [ -z "$ERROR_MSG" ]; then
                    ERROR_MSG="Non-zero exit code: $TEST_EXIT_CODE"
                fi
                FAILED_TEST_ERRORS+=("$ERROR_MSG")
            fi
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    fi

    # Log test output if verbose
    if [ "$VERBOSE" = true ]; then
        log_verbose "  Output:"
        cat "$TEST_OUTPUT" | sed 's/^/    /' | tee -a "$LOG_FILE"
        if [ -s "$TEST_ERROR" ]; then
            log_verbose "  Errors:"
            cat "$TEST_ERROR" | sed 's/^/    /' | tee -a "$LOG_FILE"
        fi
        log_verbose ""
    fi

    # Save to log file
    {
        echo "=== Test: $test_file ==="
        echo "Exit code: $TEST_EXIT_CODE"
        echo "Duration: ${TEST_DURATION}s"
        echo "--- Output ---"
        cat "$TEST_OUTPUT"
        echo "--- Errors ---"
        cat "$TEST_ERROR"
        echo ""
    } >> "$LOG_FILE"

    # Cleanup temp files
    rm -f "$TEST_OUTPUT" "$TEST_ERROR"
done

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

# Print summary
log ""
log "${CYAN}============================================${NC}"
log "${CYAN}   Test Results Summary${NC}"
log "${CYAN}============================================${NC}"
log ""

NORMAL_TESTS=$((TOTAL_TESTS - ERROR_TESTS_RUN))
NORMAL_PASSED=$PASSED_TESTS
NORMAL_FAILED=$FAILED_TESTS

log "Total tests run:        $TOTAL_TESTS"
log ""
log "Normal tests:           $NORMAL_TESTS"
log "  ${GREEN}Passed:${NC}               $NORMAL_PASSED/$NORMAL_TESTS"
log "  ${RED}Failed:${NC}               $NORMAL_FAILED/$NORMAL_TESTS"
log ""
log "Expected error tests:   $ERROR_TESTS_RUN"
log "  ${YELLOW}Passed:${NC}               $ERROR_TESTS_PASSED/$ERROR_TESTS_RUN"
log "  ${RED}Failed:${NC}               $ERROR_TESTS_FAILED/$ERROR_TESTS_RUN"
log ""

# Calculate success rate
if [ $NORMAL_TESTS -gt 0 ]; then
    SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ($NORMAL_PASSED/$NORMAL_TESTS)*100}")
    log "Success rate:           ${SUCCESS_RATE}%"
fi

log "Total duration:         ${TOTAL_DURATION}s"
log ""

# Show failed tests details
if [ ${#FAILED_TEST_NAMES[@]} -gt 0 ]; then
    log "${RED}Failed tests:${NC}"
    for i in "${!FAILED_TEST_NAMES[@]}"; do
        log "  ${RED}✗${NC} ${FAILED_TEST_NAMES[$i]}"
        log "    ${FAILED_TEST_ERRORS[$i]}"
    done
    log ""
fi

log "Detailed log: $LOG_FILE"
log ""

# Exit with appropriate code
if [ $NORMAL_FAILED -gt 0 ] || [ $ERROR_TESTS_FAILED -gt 0 ]; then
    log "${RED}Some tests failed!${NC}"
    exit 1
else
    log "${GREEN}All tests passed!${NC}"
    exit 0
fi
