#!/bin/bash
# macOS CI: run the same XCTest and Swift Testing harnesses as SwiftPM directly so its output buffering cannot hide a hang.
set -euo pipefail

test_bin_dir="${1:?Pass the directory from swift build --show-bin-path after swift build --build-tests}"
log_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/autodb-test-logs"
timeout_seconds="${AUTODB_TEST_TIMEOUT_SECONDS:-180}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "Test timeout must be a positive number of seconds" >&2; exit 2; }
mkdir -p "$log_dir"
run_log_dir="$(mktemp -d "$log_dir/run.XXXXXX")"

swift_path="$(xcrun --find swift)"
testing_helper="$(dirname "$swift_path")/../libexec/swift/pm/swiftpm-testing-helper"
xctest_path="$(xcrun --find xctest)"
platform_dir="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
[[ -x "$testing_helper" ]] || { echo "Missing Swift Testing harness: $testing_helper" >&2; exit 1; }

# Match SwiftPM's macOS runtime search paths when loading test bundles outside its harness.
export DYLD_FRAMEWORK_PATH="${DYLD_FRAMEWORK_PATH:+$DYLD_FRAMEWORK_PATH:}$platform_dir/Library/Frameworks:$platform_dir/Library/PrivateFrameworks"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:+$DYLD_LIBRARY_PATH:}$platform_dir/usr/lib"
export NSUnbufferedIO=YES
export NO_COLOR=1

test_pid=""
watchdog_pid=""

# Stop only the processes started by this script if CI cancels the step.
cleanup() {
	if [[ -n "$watchdog_pid" ]]; then kill "$watchdog_pid" 2>/dev/null || true; fi
	if [[ -n "$test_pid" ]]; then kill "$test_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Bound each harness run independently; preserve its exit status and sample the actual hung test process before terminating it.
run_tests() {
	local label="$1"
	shift
	echo "Starting $label (timeout: ${timeout_seconds}s)"
	"$@" &
	test_pid=$!
	(
		local elapsed=0
		while kill -0 "$test_pid" 2>/dev/null; do
			sleep 1
			elapsed=$((elapsed + 1))
			if (( elapsed % 30 == 0 )); then
				echo "$label is still running after ${elapsed}s (PID $test_pid)"
			fi
			if (( elapsed >= timeout_seconds )); then
				touch "$run_log_dir/$label.timeout"
				echo "::error::$label exceeded ${timeout_seconds}s; collecting a process sample"
				ps -p "$test_pid" -o pid,ppid,etime,%cpu,state,command || true
				/usr/bin/sample "$test_pid" 3 1 -file "$run_log_dir/$label.sample.txt" || true
				kill -TERM "$test_pid" 2>/dev/null || true
				sleep 5
				kill -KILL "$test_pid" 2>/dev/null || true
				exit
			fi
		done
	) &
	watchdog_pid=$!
	local status=0
	wait "$test_pid" || status=$?
	# Let the watchdog finish its forced-termination fallback when it has reached the deadline.
	if [[ ! -f "$run_log_dir/$label.timeout" ]]; then kill "$watchdog_pid" 2>/dev/null || true; fi
	wait "$watchdog_pid" 2>/dev/null || true
	test_pid=""
	watchdog_pid=""
	if [[ -f "$run_log_dir/$label.timeout" ]]; then status=124; fi
	echo "Finished $label (exit $status)"
	# Swift Testing uses EX_UNAVAILABLE when a bundle contains only XCTest tests.
	if [[ "$label" == *-swift-testing && "$status" == 69 ]]; then return 0; fi
	return "$status"
}

shopt -s nullglob
test_bundles=("$test_bin_dir"/*.xctest)
(( ${#test_bundles[@]} > 0 )) || { echo "No test bundles found in $test_bin_dir" >&2; exit 1; }

# Keep XCTest ahead of Swift Testing, matching swift test, including projects with multiple test bundles.
for bundle in "${test_bundles[@]}"; do
	SWIFT_TESTING_ENABLED=0 run_tests "$(basename "$bundle" .xctest)-xctest" "$xctest_path" "$bundle"
done
for bundle in "${test_bundles[@]}"; do
	name="$(basename "$bundle" .xctest)"
	run_tests "$name-swift-testing" "$testing_helper" --test-bundle-path "$bundle/Contents/MacOS/$name" --testing-library swift-testing
done
