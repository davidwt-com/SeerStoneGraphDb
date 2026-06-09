#!/usr/bin/env bash
#
# test-ct-parallel.sh — run the Common Test suites concurrently, one OS
# process per suite, and aggregate the results.
#
# Why this works (and a single `rebar3 ct` cannot parallelise in-VM):
#   The suites share node-global singletons — one Mnesia instance, named
#   gen_servers (graphdb_mgr, graphdb_attr, ...), and the `mnesia`/
#   `seerstone_graph_db` application env. Two suites in the SAME Erlang node
#   would clobber each other. So we fan out across separate OS processes
#   instead, giving each its own `REBAR_BASE_DIR` (isolated _build, ~1.4M,
#   ~7s compile). Each testcase already writes its Mnesia scratch to a
#   suite-prefixed, monotonic-unique dir under _build/test/ct_scratch, so
#   the on-disk Mnesia state never collides across concurrent suites.
#   (Verified empirically: concurrent suites run clean, zero lock errors.)
#
# Usage:
#   scripts/test-ct-parallel.sh [-j N] [--keep] [-l|--list] [FILTER ...]
#
#   -j N        max concurrent suites (default: min(nproc, #suites))
#   --keep      keep per-shard build dirs (default: removed; logs always kept)
#   -l, --list  list discovered suites and exit
#   FILTER ...  only run suites whose name contains one of these substrings
#               (e.g. `graphdb_rules`, or `rules class` for two)
#
# Per-suite logs land in _build/ct-parallel/logs/<suite>.log (gitignored).
# Exit status is 0 only if every selected suite passed.
#
# Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>

set -uo pipefail

# --- locate project root (script lives in <root>/scripts) -------------------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$ROOT"
REBAR3="$ROOT/rebar3"

# --- PATH guard: ensure Erlang/OTP is reachable -----------------------------
# Claude Code gets OTP on PATH via .claude/settings.local.json; an interactive
# user terminal usually does too. If not, fall back to a kerl install.
if ! command -v erl >/dev/null 2>&1; then
	for d in "$HOME"/.kerl/installations/*/bin; do
		if [ -x "$d/erl" ]; then PATH="$d:$PATH"; break; fi
	done
fi
if ! command -v erl >/dev/null 2>&1; then
	echo "error: 'erl' not on PATH and no kerl installation found" >&2
	exit 127
fi
[ -x "$REBAR3" ] || { echo "error: $REBAR3 not found or not executable" >&2; exit 127; }

# --- argument parsing -------------------------------------------------------
JOBS=""
KEEP=""
LIST_ONLY=""
FILTERS=()
while [ $# -gt 0 ]; do
	case "$1" in
		-j) JOBS="${2:?-j needs a value}"; shift 2 ;;
		-j*) JOBS="${1#-j}"; shift ;;
		--keep) KEEP=1; shift ;;
		-l|--list) LIST_ONLY=1; shift ;;
		-h|--help)
			sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		-*) echo "error: unknown option '$1'" >&2; exit 2 ;;
		*) FILTERS+=("$1"); shift ;;
	esac
done

# --- discover suites (deterministic order) ----------------------------------
mapfile -t ALL_SUITES < <(find apps -path '*/test/*_SUITE.erl' | sort)
if [ "${#ALL_SUITES[@]}" -eq 0 ]; then
	echo "error: no *_SUITE.erl files found under apps/*/test" >&2
	exit 1
fi

SUITES=()
if [ "${#FILTERS[@]}" -gt 0 ]; then
	for path in "${ALL_SUITES[@]}"; do
		name=$(basename "$path" .erl)
		for f in "${FILTERS[@]}"; do
			if [[ "$name" == *"$f"* ]]; then SUITES+=("$path"); break; fi
		done
	done
	if [ "${#SUITES[@]}" -eq 0 ]; then
		echo "error: no suites matched filter(s): ${FILTERS[*]}" >&2
		exit 1
	fi
else
	SUITES=("${ALL_SUITES[@]}")
fi

if [ -n "$LIST_ONLY" ]; then
	for path in "${SUITES[@]}"; do basename "$path" .erl; done
	exit 0
fi

# default JOBS = min(nproc, #suites)
NSUITES=${#SUITES[@]}
if [ -z "$JOBS" ]; then
	NPROC=$(nproc 2>/dev/null || echo 4)
	JOBS=$(( NPROC < NSUITES ? NPROC : NSUITES ))
fi

# --- workspace --------------------------------------------------------------
LOGDIR="$ROOT/_build/ct-parallel/logs"
mkdir -p "$LOGDIR"
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/ct-parallel.XXXXXX")
cleanup() { [ -n "$KEEP" ] || rm -rf "$TMPROOT"; }
trap cleanup EXIT

# strip ANSI colour codes from a stream
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- run one suite in an isolated build dir ---------------------------------
run_one() {
	local path="$1" name base log res start end ms rc summary count
	name=$(basename "$path" .erl)
	base="$TMPROOT/build/$name"
	log="$LOGDIR/$name.log"
	res="$TMPROOT/$name.result"
	mkdir -p "$base"

	start=$(date +%s%3N)
	REBAR_BASE_DIR="$base" "$REBAR3" ct --suite="$path" >"$log" 2>&1
	rc=$?
	end=$(date +%s%3N)
	ms=$(( end - start ))

	# Exit code is authoritative for pass/fail; the count is cosmetic.
	summary=$(strip_ansi <"$log" | grep -E 'All [0-9]+ tests passed|Failed [0-9]+|[0-9]+ tests? failed|FAILED' | tail -1)
	if [ "$rc" -eq 0 ]; then
		count=$(printf '%s' "$summary" | grep -oE 'All [0-9]+' | grep -oE '[0-9]+')
	else
		count=$(printf '%s' "$summary" | grep -oE '[0-9]+' | head -1)
	fi
	printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$ms" "${count:-0}" >"$res"

	# Bound disk: drop this shard's build dir as soon as it finishes.
	[ -n "$KEEP" ] || rm -rf "$base"
}

# --- dispatch with a bounded job pool ---------------------------------------
echo ">>> Running $NSUITES CT suite(s), up to $JOBS concurrent"
echo ">>> Logs: $LOGDIR/<suite>.log"
echo
WALL_START=$(date +%s%3N)
for path in "${SUITES[@]}"; do
	run_one "$path" &
	while [ "$(jobs -r -p | wc -l)" -ge "$JOBS" ]; do wait -n; done
done
wait
WALL_END=$(date +%s%3N)

# --- aggregate --------------------------------------------------------------
fmt_secs() { awk "BEGIN{printf \"%.1f\", $1/1000}"; }

NAME_W=26
printf '%-*s  %-6s  %7s  %8s\n' "$NAME_W" "SUITE" "RESULT" "TESTS" "TIME(s)"
printf '%-*s  %-6s  %7s  %8s\n' "$NAME_W" "$(printf '%.0s-' $(seq 1 $NAME_W))" "------" "-------" "--------"

total_tests=0
failed=0
for path in "${SUITES[@]}"; do
	name=$(basename "$path" .erl)
	res="$TMPROOT/$name.result"
	if [ ! -f "$res" ]; then
		printf '%-*s  %-6s  %7s  %8s\n' "$NAME_W" "$name" "ERROR" "?" "?"
		failed=$(( failed + 1 ))
		continue
	fi
	IFS=$'\t' read -r n rc ms cnt <"$res"
	secs=$(fmt_secs "$ms")
	if [ "$rc" -eq 0 ]; then
		printf '%-*s  %-6s  %7s  %8s\n' "$NAME_W" "$name" "pass" "$cnt" "$secs"
		total_tests=$(( total_tests + cnt ))
	else
		printf '%-*s  %-6s  %7s  %8s   -> %s\n' "$NAME_W" "$name" "FAIL" "$cnt" "$secs" "$LOGDIR/$name.log"
		failed=$(( failed + 1 ))
	fi
done

wall=$(fmt_secs $(( WALL_END - WALL_START )))
echo
if [ "$failed" -eq 0 ]; then
	echo ">>> All $NSUITES suites passed — $total_tests tests in ${wall}s wall."
	exit 0
else
	echo ">>> $failed of $NSUITES suites FAILED (see logs above). Wall: ${wall}s."
	exit 1
fi
