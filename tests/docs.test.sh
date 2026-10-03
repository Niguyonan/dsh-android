#!/bin/sh
# Host-side tests for the documentation's own claims.
#
# Documentation in this repository is not decoration: the README's layout table
# says "everything in this table exists", the runbook tells someone holding a
# phone which commands to type, and `docs/security.md` is the record of what was
# measured. All three rot silently — a renamed verb or a moved file turns a
# working instruction into a broken promise that nobody notices until it is
# followed at the worst moment.
#
# So the claims that can be checked mechanically, are:
#
#   * every `tools/*.sh` the docs name exists, except the Phase 6 tools the docs
#     name *as* not written
#   * every `dshd <verb>` the docs name is a verb dshd actually dispatches
#   * every path in the README's layout table exists
#   * every test suite in tests/ is invoked by tests/run.sh, and everything
#     run.sh invokes exists
#   * the suite count in the README matches the suites that run
#
# What it cannot check is whether the prose is true. That is what the other
# suites are for.
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF_DIR/.." && pwd)
cd "$REPO" || exit 1

DOCS="README.md docs/runbook.md docs/security.md docs/root-solutions.md \
docs/phase-0-probe-ledger.md"

# Tools the docs deliberately name as not written yet. Anything else that is
# named has to exist: a runbook that tells someone to run a script that is not
# there is worse than one that says nothing.
UNWRITTEN="tools/backup.sh tools/update.sh tools/rollback.sh tools/doctor.sh"

# --- tiny test framework ----------------------------------------------------

TESTS_RUN=0
TESTS_FAILED=0

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf 'FAIL %s\n' "$1"
  [ $# -gt 1 ] && printf '     %s\n' "$2"
  return 0
}

check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

is_unwritten() {
  for u in $UNWRITTEN; do
    [ "$u" = "$1" ] && return 0
  done
  return 1
}

# --- scripts the docs name --------------------------------------------------

printf '\n== every script the docs name exists ==\n'

missing=""
for tool in $(grep -ho 'tools/[a-z-]*\.sh' $DOCS | sort -u); do
  is_unwritten "$tool" && continue
  [ -f "$tool" ] || missing="$missing $tool"
done
check "every documented tools/*.sh exists (or is named as unwritten)" "" "$missing"

if [ -n "$missing" ]; then
  fail "the missing ones, for the record" "$missing"
fi

# The four unwritten ones have to be *described* as unwritten where they appear,
# or the allowlist above quietly becomes a licence to document vapor.
for u in $UNWRITTEN; do
  base=$(basename "$u")
  if grep -q "$base" $DOCS; then
    # The mention and the word "not written" have to be near each other.
    if grep -A2 -B2 "$base" $DOCS | grep -qi 'not written\|not there yet\|Phase 6'; then
      pass "$base is named as not written where it is named"
    else
      fail "$base is named as not written where it is named" \
        "$(grep -h "$base" $DOCS | head -2)"
    fi
  fi
done

# --- verbs the docs name ----------------------------------------------------

printf '\n== every verb the docs name is a verb dshd dispatches ==\n'

# `dshd stop` and `dshd setup|start|stop|restart|…` are both documentation; the
# second one is how the README's diagram lists the verbs it supports.
verbs=$(grep -ho 'dshd[[:space:]][a-z][a-z|-]*' $DOCS | sed 's/^dshd[[:space:]]*//' |
  tr '|' '\n' | grep . | sort -u)
unknown=""
for v in $verbs; do
  grep -qE "^ *$v\) " bin/dshd || unknown="$unknown $v"
done
check "every documented dshd verb is dispatched" "" "$unknown"

# The other direction: a verb nobody documents is a verb nobody can find. The
# internal ones are excluded by name, because they exist for dshd itself.
internal="supervise version help"
undocumented=""
for v in $(sed -n '/^  case "\$cmd" in/,/esac/p' bin/dshd |
  sed -n 's/^ *\([a-z-]*\)) .*/\1/p' | sort -u); do
  case " $internal " in *" $v "*) continue ;; esac
  printf '%s\n' "$verbs" | grep -qx "$v" || undocumented="$undocumented $v"
done
check "every user-facing verb is documented somewhere" "" "$undocumented"

# --- the layout table -------------------------------------------------------

printf '\n== the README layout table is true ==\n'

table=$(sed -n '/^| Path | Phase | What it is |/,/^$/p' README.md)
count=$(printf '%s\n' "$table" | grep -c '^| `')
case "$count" in
  0) fail "the layout table was found" "no rows matched" ;;
  *) pass "the layout table was found ($count rows)" ;;
esac

gone=""
printf '%s\n' "$table" | grep '^| `' | while IFS= read -r row; do
  path=$(printf '%s\n' "$row" | sed -n 's/^| `\([^`]*\)`.*/\1/p')
  [ -n "$path" ] || continue
  printf '%s\n' "$path"
done >"$SELF_DIR/.layout-paths.$$"

while IFS= read -r path; do
  [ -e "$path" ] || gone="$gone $path"
done <"$SELF_DIR/.layout-paths.$$"
rm -f "$SELF_DIR/.layout-paths.$$"
check "every path in the layout table exists" "" "$gone"

# --- the suites -------------------------------------------------------------

printf '\n== the suites that run are the suites that exist ==\n'

declared=$(ls tests/*.test.sh | LC_ALL=C sort | tr '\n' ' ')
invoked=$(grep -o 'tests/[a-z-]*\.test\.sh' tests/run.sh | LC_ALL=C sort -u | tr '\n' ' ')
check "every suite in tests/ is invoked by tests/run.sh" "$declared" "$invoked"

sh_suites=$(printf '%s\n' "$invoked" | tr ' ' '\n' | grep -c .)
total=$((sh_suites + 1)) # plus the guard suite, which is node --test
case "$(grep -c 'node --test' tests/run.sh)" in
  1) pass "the guard suite is invoked too" ;;
  *) fail "the guard suite is invoked too" "$(grep -c 'node --test' tests/run.sh) invocations" ;;
esac

words="one two three four five six seven eight nine ten eleven twelve"
word=$(printf '%s\n' $words | sed -n "${total}p")
if grep -q "$word suites" README.md; then
  pass "the README's suite count ($word) matches the $total that run"
else
  fail "the README's suite count matches the $total that run" \
    "expected the phrase '$word suites' in README.md"
fi

printf '\n%d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ] || exit 1
exit 0
