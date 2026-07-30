# shellcheck shell=bash
# Assertions for the tracker suite.
#
# ── Why every assertion must be a function call ──────────────────────
#
# Never a bare [[ ]] and never `! cmd`. bash 3.2 is the system bash on macOS and
# a tier this suite runs on, and there neither trips `set -e` nor the ERR trap
# when it is not the last statement of the test body:
#
#   bash-3.2 -c 'set -e; f(){ [[ 1 == 2 ]]; echo REACHED; }; f'   -> REACHED
#   bash-3.2 -c 'set -e; f(){ ! true; echo REACHED; }; f'         -> REACHED
#
# A failing *function* call does propagate, on 3.2 as on 5.x, which is the whole
# reason for wrapping. This suite had 476 bare assertions and only its 263
# last-statement ones were load-bearing; the rest could assert anything and stay
# green. That is the mechanism that hid nine defects found while auditing it.
#
# Vendored from tmux-toolkit/tests/assert.bash. Argument order is
# (actual, expected) throughout, matching the direction the old bare assertions
# were written in. Note that tmux-worktree's helper of the same name uses
# (expected, actual); do not copy calls between the two suites.

# $status and $output are set by bats' `run`, so shellcheck cannot see the
# assignment. Declared here rather than disabled at every call site.
# shellcheck disable=SC2154
_afail() { printf 'assertion failed: %s\n' "$*" >&2; return 1; }

assert_ok()     { [[ "$status" -eq 0 ]] || _afail "expected success, got status $status: $output"; }
assert_fail()   { [[ "$status" -ne 0 ]] || _afail "expected failure, got status 0: $output"; }
assert_status() { [[ "$status" -eq "$1" ]] || _afail "expected status $1, got $status: $output"; }

assert_eq()     { [[ "$1" == "$2" ]] || _afail "expected '$2', got '$1'"; }
assert_ne()     { [[ "$1" != "$2" ]] || _afail "expected anything but '$2'"; }
assert_num_eq() { [[ "$1" -eq "$2" ]] || _afail "expected $2, got '$1'"; }
assert_num_ne() { [[ "$1" -ne "$2" ]] || _afail "expected not $2, got '$1'"; }
assert_num_gt() { [[ "$1" -gt "$2" ]] || _afail "expected > $2, got '$1'"; }
assert_num_ge() { [[ "$1" -ge "$2" ]] || _afail "expected >= $2, got '$1'"; }
assert_num_lt() { [[ "$1" -lt "$2" ]] || _afail "expected < $2, got '$1'"; }
assert_num_le() { [[ "$1" -le "$2" ]] || _afail "expected <= $2, got '$1'"; }

assert_contains() { [[ "$1" == *"$2"* ]] || _afail "'$1' does not contain '$2'"; }
refute_contains() { [[ "$1" != *"$2"* ]] || _afail "'$1' unexpectedly contains '$2'"; }

# Glob compare, so $2 is deliberately unquoted. Use for a pattern that is not a
# plain substring; assert_contains covers the *"x"* case more legibly.
# shellcheck disable=SC2053
assert_match()   { [[ "$1" == $2 ]] || _afail "'$1' does not match glob '$2'"; }
# shellcheck disable=SC2053
refute_match()   { [[ "$1" != $2 ]] || _afail "'$1' unexpectedly matches glob '$2'"; }
# ERE, not a glob. Separate from assert_match because =~ and == take different
# languages and silently accepting the wrong one is how a test stops testing.
assert_match_re() { [[ "$1" =~ $2 ]] || _afail "'$1' does not match regex '$2'"; }

assert_empty()     { [[ -z "$1" ]] || _afail "expected empty, got '$1'"; }
assert_not_empty() { [[ -n "$1" ]] || _afail "expected a value, got empty"; }

assert_file()    { [[ -f "$1" ]] || _afail "no such file: $1"; }
refute_file()    { [[ ! -f "$1" ]] || _afail "file should not exist: $1"; }
assert_dir()     { [[ -d "$1" ]] || _afail "no such directory: $1"; }
refute_dir()     { [[ ! -d "$1" ]] || _afail "directory should not exist: $1"; }
assert_exists()  { [[ -e "$1" ]] || _afail "does not exist: $1"; }
refute_exists()  { [[ ! -e "$1" ]] || _afail "should not exist: $1"; }
assert_symlink() { [[ -L "$1" ]] || _afail "not a symlink: $1"; }
assert_exec()    { [[ -x "$1" ]] || _afail "not executable: $1"; }
assert_readable() { [[ -r "$1" ]] || _afail "not readable: $1"; }
assert_nonempty_file() { [[ -s "$1" ]] || _afail "empty or missing file: $1"; }

# `! cmd` has the same bash 3.2 problem as a bare [[ ]].
refute() { if "$@"; then _afail "expected '$*' to fail"; fi; }

# assert_one_of <actual> <allowed>... - for a state that legitimately has more
# than one correct value. Replaces `[[ "$x" == "a" || "$x" == "b" ]]`, which as a
# bare compound was inert *and* unreadable.
assert_one_of() {
    local actual="$1"; shift
    local c
    for c in "$@"; do
        [[ "$actual" == "$c" ]] && return 0
    done
    _afail "expected one of [$*], got '$actual'"
}
