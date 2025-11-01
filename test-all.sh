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
JOBS=4      # parallel jobs

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
    -j, --jobs N            Number of parallel jobs (default: 4)
    -h, --help             Show this help message

EXAMPLES:
    $0                          # Run all tests
    $0 --verbose                # Run with detailed output
    $0 --pattern "channel"      # Run only channel-related tests
    $0 --no-compile             # Skip compilation, run tests only
    $0 --jobs 8                 # Run with 8 parallel jobs

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
        -j|--jobs)
            JOBS="$2"
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

# Run a single test and save results to a temporary file
run_single_test() {
    local test_file="$1"
    local result_file="$2"

    # Check if it's an error test
    local IS_ERROR_TEST=false
    if is_error_test "$test_file"; then
        IS_ERROR_TEST=true
    fi

    # Run test with timeout
    local TEST_START=$(date +%s)
    local TEST_OUTPUT=$(mktemp)
    local TEST_ERROR=$(mktemp)

    local TEST_EXIT_CODE=0
    if timeout --foreground "$TIMEOUT" \
        docker compose exec -T \
        k bash -lc "cd go && krun codes/$test_file --definition main-kompiled/" \
        < /dev/null > "$TEST_OUTPUT" 2> "$TEST_ERROR"; then
        TEST_EXIT_CODE=0
    else
        TEST_EXIT_CODE=$?
    fi

    local TEST_END=$(date +%s)
    local TEST_DURATION=$((TEST_END - TEST_START))

    # Determine test result
    local STATUS=""
    local ERROR_MSG=""

    if [ "$IS_ERROR_TEST" = true ]; then
        # For error tests, we expect non-zero exit code or error output
        if [ $TEST_EXIT_CODE -ne 0 ] || grep -q -i "error\|panic" "$TEST_ERROR" "$TEST_OUTPUT" 2>/dev/null; then
            STATUS="EXPECTED_ERROR"
        else
            STATUS="ERROR_TEST_FAILED"
            ERROR_MSG="Expected error but test passed"
        fi
    else
        # For normal tests, we expect zero exit code AND complete execution
        if [ $TEST_EXIT_CODE -eq 0 ]; then
            # Check if all <k> cells contain only .K (complete execution)
            # Use awk to extract content between <k> and </k> tags
            K_CELLS_OK=true
            K_CELL_CONTENT=""

            # Extract all <k> cell contents, one per line
            while IFS= read -r cell_content; do
                # Remove all whitespace and check if it's empty or just .K
                clean_content=$(echo "$cell_content" | tr -d ' \n\t\r')
                if [ -n "$clean_content" ] && [ "$clean_content" != ".K" ]; then
                    K_CELLS_OK=false
                    K_CELL_CONTENT="$clean_content"
                    break
                fi
            done < <(awk '/<k>/{flag=1; content=""; next} /<\/k>/{if(flag){print content; flag=0; content=""}} flag{content=content $0}' "$TEST_OUTPUT" 2>/dev/null)

            if [ "$K_CELLS_OK" = true ]; then
                STATUS="PASS"
            else
                # Truncate long output for error message
                if [ ${#K_CELL_CONTENT} -gt 100 ]; then
                    K_CELL_TRUNCATED="${K_CELL_CONTENT:0:100}..."
                else
                    K_CELL_TRUNCATED="$K_CELL_CONTENT"
                fi
                STATUS="FAIL"
                ERROR_MSG="Execution incomplete: <k> cell contains '$K_CELL_TRUNCATED' (expected '.K')"
            fi
        else
            if [ $TEST_EXIT_CODE -eq 124 ]; then
                STATUS="TIMEOUT"
                ERROR_MSG="Test timeout after ${TIMEOUT}s"
            else
                STATUS="FAIL"
                ERROR_MSG=$(cat "$TEST_ERROR" | head -5 | tr '\n' ' ')
                if [ -z "$ERROR_MSG" ]; then
                    ERROR_MSG="Non-zero exit code: $TEST_EXIT_CODE"
                fi
            fi
        fi
    fi

    # Save result as structured format
    {
        echo "TEST_FILE=$test_file"
        echo "STATUS=$STATUS"
        echo "DURATION=$TEST_DURATION"
        echo "EXIT_CODE=$TEST_EXIT_CODE"
        echo "ERROR_MSG=$ERROR_MSG"
        echo "IS_ERROR_TEST=$IS_ERROR_TEST"
        echo "---OUTPUT---"
        cat "$TEST_OUTPUT"
        echo "---ERROR---"
        cat "$TEST_ERROR"
        echo "---END---"
    } > "$result_file"

    # Cleanup temp files
    rm -f "$TEST_OUTPUT" "$TEST_ERROR"
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

# Find all test files (exclude .expected files)
cd "$CODES_DIR"
if [ -n "$PATTERN" ]; then
    TEST_FILES=($(ls -1 | grep -v '\.expected$' | grep -E "$PATTERN" | sort))
    log "${BLUE}Running tests matching pattern: ${PATTERN}${NC}"
else
    TEST_FILES=($(ls -1 | grep -v '\.expected$' | sort))
    log "${BLUE}Running all tests${NC}"
fi

TOTAL_TESTS=${#TEST_FILES[@]}
log "Found $TOTAL_TESTS test files"
log ""

# Run tests
START_TIME=$(date +%s)

# Create temporary directory for test results
RESULTS_DIR=$(mktemp -d)
trap "rm -rf $RESULTS_DIR" EXIT

# Export variables and functions needed by parallel execution
export TIMEOUT
export LOG_FILE
export -f run_single_test is_error_test

log "${BLUE}Running tests with ${JOBS} parallel jobs...${NC}"
log ""

# Run tests in parallel using xargs
printf "%s\n" "${TEST_FILES[@]}" | \
    xargs -I {} -P "$JOBS" bash -c "run_single_test '{}' '$RESULTS_DIR/{}.result'"

log "${BLUE}Processing results...${NC}"
log ""

# Process results in file name order
for test_file in "${TEST_FILES[@]}"; do
    result_file="$RESULTS_DIR/${test_file}.result"

    if [ ! -f "$result_file" ]; then
        log "${RED}[ERROR]${NC} Result file not found for $test_file"
        continue
    fi

    # Parse result file
    TEST_FILE=""
    STATUS=""
    DURATION=""
    EXIT_CODE=""
    ERROR_MSG=""
    IS_ERROR_TEST=""
    OUTPUT_CONTENT=""
    ERROR_CONTENT=""

    # Read variables from result file
    while IFS='=' read -r key value; do
        case "$key" in
            TEST_FILE) TEST_FILE="$value" ;;
            STATUS) STATUS="$value" ;;
            DURATION) DURATION="$value" ;;
            EXIT_CODE) EXIT_CODE="$value" ;;
            ERROR_MSG) ERROR_MSG="$value" ;;
            IS_ERROR_TEST) IS_ERROR_TEST="$value" ;;
            "---OUTPUT---")
                # Read until ---ERROR---
                OUTPUT_CONTENT=""
                while IFS= read -r line; do
                    if [ "$line" = "---ERROR---" ]; then
                        break
                    fi
                    OUTPUT_CONTENT+="$line"$'\n'
                done
                ;;
            "---ERROR---")
                # Read until ---END---
                ERROR_CONTENT=""
                while IFS= read -r line; do
                    if [ "$line" = "---END---" ]; then
                        break
                    fi
                    ERROR_CONTENT+="$line"$'\n'
                done
                ;;
        esac
    done < "$result_file"

    # Display result
    case "$STATUS" in
        PASS)
            log "${GREEN}[PASS]${NC} $TEST_FILE (${DURATION}s)"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            ;;
        EXPECTED_ERROR)
            log "${YELLOW}[EXPECTED_ERROR]${NC} $TEST_FILE (${DURATION}s)"
            ERROR_TESTS_PASSED=$((ERROR_TESTS_PASSED + 1))
            ERROR_TESTS_RUN=$((ERROR_TESTS_RUN + 1))
            ;;
        ERROR_TEST_FAILED)
            log "${RED}[ERROR_TEST_FAILED]${NC} $TEST_FILE (${DURATION}s) - Should have failed but passed"
            ERROR_TESTS_FAILED=$((ERROR_TESTS_FAILED + 1))
            ERROR_TESTS_RUN=$((ERROR_TESTS_RUN + 1))
            FAILED_TEST_NAMES+=("$TEST_FILE")
            FAILED_TEST_ERRORS+=("$ERROR_MSG")
            ;;
        TIMEOUT)
            log "${RED}[TIMEOUT]${NC} $TEST_FILE (>${TIMEOUT}s)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("$TEST_FILE")
            FAILED_TEST_ERRORS+=("$ERROR_MSG")
            ;;
        FAIL)
            log "${RED}[FAIL]${NC} $TEST_FILE (${DURATION}s)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            FAILED_TEST_NAMES+=("$TEST_FILE")
            FAILED_TEST_ERRORS+=("$ERROR_MSG")
            ;;
    esac

    # Log verbose output if requested
    if [ "$VERBOSE" = true ] && [ -n "$OUTPUT_CONTENT" ]; then
        log_verbose "  Output:"
        echo "$OUTPUT_CONTENT" | sed 's/^/    /' | tee -a "$LOG_FILE"
        if [ -n "$ERROR_CONTENT" ]; then
            log_verbose "  Errors:"
            echo "$ERROR_CONTENT" | sed 's/^/    /' | tee -a "$LOG_FILE"
        fi
        log_verbose ""
    fi

    # Save to log file
    {
        echo "=== Test: $TEST_FILE ==="
        echo "Exit code: $EXIT_CODE"
        echo "Duration: ${DURATION}s"
        echo "Status: $STATUS"
        echo "--- Output ---"
        echo "$OUTPUT_CONTENT"
        echo "--- Errors ---"
        echo "$ERROR_CONTENT"
        echo ""
    } >> "$LOG_FILE"
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
