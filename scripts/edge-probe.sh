#!/usr/bin/env bash
# The external probe (2026-10-18, persona audit PA-14): what a reader meets,
# through Cloudflare, from a machine that is not the server.
#
#   scripts/edge-probe.sh                                   https://heyresearch.xyz
#   scripts/edge-probe.sh --base-url https://example.test
#
# Options
#   --base-url URL     site to probe (default https://heyresearch.xyz)
#   --timeout SECONDS  per-request timeout (default 20)
#
# Every check HEY ran before this one reached the origin through 127.0.0.1 —
# the deploy smoke, the daily smoke, liveness, the warm-up — so nothing saw a
# route the edge answered slowly, a reset, or a 520. This reads the routes the
# performance budget marks `edge` (packages/domain/src/reliability/
# performance-budget.json, or HEY_PERF_BUDGET_FILE; docs/PERFORMANCE_BUDGET.md)
# with a cache-buster, each `tries` times, and fails when
#   - a route answers a server error or nothing on `minFailedTries` tries,
#   - a route's median server time is over its limit plus the edge allowance
#     (the edge-to-origin hop from wherever the probe runs), or
#   - the 90th percentile of every timed read is over `edge.p90LimitSeconds`;
# and checks that the browser icons answer a cacheable 200 (PB-45). A path
# ending in an unfinished percent-escape answering a 5xx is a warning (PB-47:
# an edge rule the founder sets). Server time is first byte minus connection
# setup; a route handler's own time, from its Server-Timing header, is printed
# beside it, so a slow answer says whether the handler worked or waited.
#
# Needs curl, jq and awk; no secret, no credential, nothing written but stdout
# and, on GitHub Actions, the job summary. Reads are labelled `hey-internal/`,
# so HEY's own analytics count them as internal. Run every six hours by
# .github/workflows/edge-probe.yml; exit status is non-zero when a check fails.

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# A failed check is a result, not a reason to abort: report every check, then exit non-zero.
set +e

BASE_URL=https://heyresearch.xyz
TIMEOUT=20
while (( $# > 0 )); do
  case "$1" in
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-20}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
BASE_URL="${BASE_URL%/}"
require_cmd curl jq awk sort
BUDGET_FILE="${HEY_PERF_BUDGET_FILE:-$REPO_DIR/packages/domain/src/reliability/performance-budget.json}"
jq -e '.routes | length > 0' "$BUDGET_FILE" >/dev/null 2>&1 || die "no readable performance budget at $BUDGET_FILE"

CURL=(curl -sS --max-time "$TIMEOUT" -A "hey-internal/edge-probe (scripts/edge-probe.sh)" -H 'Accept: text/html,application/json')
HEADERS="$(mktemp)"; SAMPLES="$(mktemp)"; SUMMARY_ROWS="$(mktemp)"
trap 'rm -f "$HEADERS" "$SAMPLES" "$SUMMARY_ROWS"' EXIT

PASSED=0; FAILED=0; WARNED=0
annotate() { [[ "${GITHUB_ACTIONS:-}" == true ]] && printf '::%s title=Edge probe::%s\n' "$1" "$2"; return 0; }
pass() { PASSED=$((PASSED + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$*"; annotate error "$*"; }
warnc() { WARNED=$((WARNED + 1)); printf 'WARN  %s\n' "$*"; annotate warning "$*"; }
row() { printf '| %s | %s | %s | %s |\n' "$@" >> "$SUMMARY_ROWS"; }

gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
median() { printf '%s\n' "$@" | sort -n | awk '{ v[NR] = $1 } END { print v[int((NR + 1) / 2)] }'; }
# Every value of one header, joined (Cloudflare sends server-timing twice beside HEY's own).
header_of() { tr -d '\r' < "$HEADERS" | awk -v n="$1" -F': ' 'tolower($1) == n { v = v (v == "" ? "" : ", ") $2 } END { print v }'; }

# probe METHOD PATH BODY TRY -> "<status> <server seconds> <handler ms or ->", headers in $HEADERS.
probe() {
  local method="$1" path="$2" data="$3" try="$4" url sep='?' out args=() handler
  if [[ "$method" == POST ]]; then
    url="$BASE_URL$path"
    args=(-X POST -H 'Content-Type: application/json' --data "$data")
  else
    [[ "$path" == *\?* ]] && sep='&'
    url="$BASE_URL$path${sep}edge-probe=$(date +%s)-$$-$try"
  fi
  : > "$HEADERS"
  out="$("${CURL[@]}" ${args[@]+"${args[@]}"} -o /dev/null -D "$HEADERS" -w '%{http_code} %{time_pretransfer} %{time_starttransfer}' "$url" 2>/dev/null)" || true
  [[ -n "$out" ]] || out='000 0 0'
  # HEY's own metric only (`handler`, apps/web/src/lib/observability.ts); Cloudflare's cfEdge/cfOrigin are not read.
  handler="$(header_of server-timing | grep -oE 'handler;[^,]*dur=[0-9.]+' | head -n 1 | sed 's/.*dur=//')"
  awk -v h="${handler:--}" '{ s = $3 - $2; if (s < 0) s = 0; printf "%s %.3f %s\n", $1, s, h }' <<< "$out"
}

printf 'edge probe: %s (%s)\n' "$BASE_URL" "$(utc_now)"
TRIES="$(jq -r '.tries' "$BUDGET_FILE")"
MIN_FAILED="$(jq -r '.minFailedTries' "$BUDGET_FILE")"
P90_LIMIT="$(jq -r '.edge.p90LimitSeconds' "$BUDGET_FILE")"

# --------------------------------------------------------------- the routes
# Fields are never empty ("-" stands in): read with a tab IFS folds empty fields away.
while IFS=$'\t' read -r method path data label target limit; do
  [[ "$data" == - ]] && data=""
  [[ "$label" == - ]] && label="$path"
  codes=""; failed=0; secs=(); handlers=(); challenged=0
  for (( i = 1; i <= TRIES; i++ )); do
    read -r code s handler <<< "$(probe "$method" "$path" "$data" "$i")"
    codes+="$code "
    [[ "$code" == 403 && -n "$(header_of cf-mitigated)" ]] && challenged=1
    case "$code" in
      5??|000) failed=$((failed + 1)) ;;
      2??|3??) secs+=("$s"); printf '%s\n' "$s" >> "$SAMPLES"; [[ "$handler" != - ]] && handlers+=("${handler%.*} ms") ;;
    esac
  done
  if (( challenged == 1 )); then
    fail "$label -> ${codes% }: the edge challenged the probe (cf-mitigated); allow hey-internal/edge-probe past the bot rules"
    row "$label" "${codes% }" "-" "challenged"
    continue
  fi
  if (( failed >= MIN_FAILED )); then
    fail "$label -> ${codes% } (server error or no answer)"
    row "$label" "${codes% }" "-" "FAIL"
    continue
  fi
  if (( ${#secs[@]} * 2 <= TRIES )); then
    warnc "$label -> ${codes% }; not timed (a renamed project? the routes are in $BUDGET_FILE)"
    row "$label" "${codes% }" "-" "not timed"
    continue
  fi
  med="$(median "${secs[@]}")"
  detail="median ${med}s of $(IFS=/; echo "${secs[*]}")${handlers[0]+ (handler $(IFS=/; echo "${handlers[*]}"))}; target ${target}s, limit ${limit}s"
  if gt "$med" "$limit"; then
    fail "$label -> $detail: over its limit"
    row "$label" "${codes% }" "${med}s" "over limit ${limit}s"
  elif gt "$med" "$target"; then
    warnc "$label -> $detail: over its target"
    row "$label" "${codes% }" "${med}s" "over target ${target}s"
  else
    pass "$label -> $detail"
    row "$label" "${codes% }" "${med}s" "ok"
  fi
done < <(jq -r '.classes as $c | .edge.allowanceSeconds as $allow | def plus: (. + $allow) * 100 | round / 100 | tostring;
  .routes[] | select(.edge) | [(.method // "GET"), .path, (.body // "-"), (.label // "-"), (.targetSeconds | plus), ($c[.class].limitSeconds | plus)] | @tsv' "$BUDGET_FILE")

if [[ -s "$SAMPLES" ]]; then
  p90="$(sort -n "$SAMPLES" | awk '{ v[NR] = $1 } END { i = int(NR * 0.9 + 0.999999); if (i < 1) i = 1; print v[i] }')"
  n="$(wc -l < "$SAMPLES" | tr -d ' ')"
  if gt "$p90" "$P90_LIMIT"; then
    fail "p90 of $n timed reads ${p90}s, over ${P90_LIMIT}s"
  else
    pass "p90 of $n timed reads ${p90}s (limit ${P90_LIMIT}s)"
  fi
fi

# ------------------------------------------------------------ browser icons
# Browsers, unfurlers and scanners ask for these on their own (2026-10-18,
# PB-45): each was a 122 KB uncached not-found render on the one web container.
for path in /favicon.ico /apple-touch-icon.png; do
  read -r code _ _ <<< "$(probe GET "$path" "" 1)"
  type="$(header_of content-type)"; cache="$(header_of cache-control)"
  if [[ "$code" == 200 && "$type" == image/* && "$cache" == *public* ]]; then
    pass "$path -> 200 $type, cache-control: $cache"
  else
    fail "$path -> ${code} ${type:-no type}, cache-control: ${cache:-none}; expected a cacheable 200 image"
  fi
done

# ------------------------------------------------ unfinished percent-escape
# PB-47: Cloudflare lets a path ending in `%` or `%h` through and the origin's
# HTTP/2 server resets it, so the edge answers 520. The repair is an edge rule
# (docs/PERFORMANCE_BUDGET.md, "Malformed paths"); until it is set, a warning.
for path in '/x%A' '/x%'; do
  : > "$HEADERS"
  code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL$path" 2>/dev/null)"
  case "$code" in
    4??) pass "unfinished percent-escape $path -> $code" ;;
    *) warnc "unfinished percent-escape $path -> ${code:-000}, expected a 4xx: the edge rule in docs/PERFORMANCE_BUDGET.md (Malformed paths) is not set" ;;
  esac
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '### Edge probe: %s\n\n%s · passed %d · failed %d · warned %d\n\n' "$BASE_URL" "$(utc_now)" "$PASSED" "$FAILED" "$WARNED"
    printf '| Route | Status | Median server time | Verdict |\n| --- | --- | --- | --- |\n'
    cat "$SUMMARY_ROWS"
  } >> "$GITHUB_STEP_SUMMARY"
fi

printf 'EDGE_PROBE_SUMMARY passed=%d failed=%d warned=%d base=%s\n' "$PASSED" "$FAILED" "$WARNED" "$BASE_URL"
(( FAILED == 0 ))
