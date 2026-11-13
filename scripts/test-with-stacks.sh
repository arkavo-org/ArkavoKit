#!/bin/bash
# Runs `swift test`. If the tests are still running after HANG_AFTER seconds, samples the test
# process's threads as a hang and stops it, so a hang fails with its stacks instead of running
# out the job's time. With SAMPLE_STALL=1 it also samples them 2 s into the swift-testing run,
# while CPU-heavy tests hold every thread. The samples go to the log and to $STACKS_DIR.
set -u

HANG_AFTER=${HANG_AFTER:-600}
SAMPLE_STALL=${SAMPLE_STALL:-0}
STACKS_DIR=${STACKS_DIR:-${RUNNER_TEMP:-/tmp}/test-stacks}
mkdir -p "$STACKS_DIR"
LOG="$STACKS_DIR/swift-test.log"

swift test "$@" > "$LOG" 2>&1 &
TEST_PID=$!
tail -n +1 -f "$LOG" &
TAIL_PID=$!

testing_pid() { pgrep -n -f swiftpm-testing-helper || pgrep -n xctest; }

take_sample() {  # name, seconds
    local pid
    pid=$(testing_pid) || { echo "::warning::no test process to sample ($1)"; return; }
    echo "::group::Thread sample ($1), pid $pid"
    sudo -n sample "$pid" "$2" -file "$STACKS_DIR/$1.txt" > /dev/null 2>&1 \
        || sample "$pid" "$2" -file "$STACKS_DIR/$1.txt" > /dev/null 2>&1
    cat "$STACKS_DIR/$1.txt"
    echo "::endgroup::"
}

sampled_stall=$([[ $SAMPLE_STALL == 1 ]] && echo false || echo true)
start=$SECONDS
while kill -0 "$TEST_PID" 2> /dev/null; do
    if ! $sampled_stall && grep -q "Test run started" "$LOG"; then
        sleep 2
        take_sample stall 3
        sampled_stall=true
    fi
    if (( SECONDS - start >= HANG_AFTER )); then
        echo "::error::swift test still running after ${HANG_AFTER}s; sampling and stopping it"
        take_sample hang 5
        pkill -f swiftpm-testing-helper
        pkill xctest
        kill "$TEST_PID" 2> /dev/null
        sleep 2
        kill "$TAIL_PID" 2> /dev/null
        exit 1
    fi
    sleep 1
done

wait "$TEST_PID"
status=$?
sleep 1
kill "$TAIL_PID" 2> /dev/null
exit $status
