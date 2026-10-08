#!/usr/bin/env bash
# Runs every verification step for Nimbus Climb and prints one summary line per step.
#
#   tools/run_checks.sh                 # syntax + static analysis + full smoke test
#   tools/run_checks.sh --quick         # same, with a shorter smoke test (fewer layout seeds, ~15 s)
#   tools/run_checks.sh --static        # only the fast checks (syntax + check.mjs)
#   tools/run_checks.sh --smoke -v      # only the smoke test, verbose (every passing check is listed)
#   tools/run_checks.sh --smoke --only match_victory,damage_rules
#   tools/run_checks.sh --smoke --only layouts,cannon,courses --seeds 300
#   tools/run_checks.sh --smoke --only client_menu --echo   # show the game's print() / warn() output
#   tools/run_checks.sh --smoke --strict-members --strict   # also fail on warnings / unknown Instance members
#
# Any argument that is not --static / --smoke is passed on to tools/smoke.py (python3 tools/smoke.py --list shows the scenarios).
# Requirements: python3 + `pip install lupa`, node 18+ (npm packages are installed on first use).
# Exit status: 0 when every step passed, 1 otherwise (all steps always run).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

do_static=1
do_smoke=1
smoke_args=()
for arg in "$@"; do
	case "$arg" in
		--static) do_smoke=0 ;;
		--smoke) do_static=0 ;;
		-h | --help)
			sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) smoke_args+=("$arg") ;;
	esac
done

statuses=()
names=()
record() {
	names+=("$1")
	statuses+=("$2")
}

step() {
	local name="$1"
	shift
	echo
	echo "=== $name ==="
	"$@"
	local code=$?
	if [ $code -eq 0 ]; then
		record "$name" "ok"
	else
		record "$name" "FAILED (exit $code)"
	fi
}

need() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "missing dependency: $1 ($2)" >&2
		return 1
	fi
	return 0
}

if [ $do_static -eq 1 ]; then
	if need python3 "install Python 3" && python3 -c "import lupa" 2>/dev/null; then
		step "Lua syntax (src + tools)" python3 tools/syntax.py src tools/*.lua
	else
		echo "missing dependency: lupa (pip install lupa)" >&2
		record "Lua syntax (src + tools)" "FAILED (python3 / lupa missing)"
	fi

	if need node "install Node.js 18+" && need npm "comes with Node.js"; then
		if [ ! -d tools/node_modules/luaparse ]; then
			echo "installing luaparse (npm) ..."
			(cd tools && npm install --no-audit --no-fund --loglevel=error)
		fi
		step "Static analysis (tools/check.mjs)" node tools/check.mjs
	else
		record "Static analysis (tools/check.mjs)" "FAILED (node / npm missing)"
	fi
fi

if [ $do_smoke -eq 1 ]; then
	if need python3 "install Python 3" && python3 -c "import lupa" 2>/dev/null; then
		step "Smoke test (tools/smoke.py)" python3 tools/smoke.py ${smoke_args[@]+"${smoke_args[@]}"}
	else
		echo "missing dependency: lupa (pip install lupa)" >&2
		record "Smoke test (tools/smoke.py)" "FAILED (python3 / lupa missing)"
	fi
fi

echo
echo "=== summary ==="
failed=0
for i in "${!names[@]}"; do
	printf '  %-38s %s\n' "${names[$i]}" "${statuses[$i]}"
	if [ "${statuses[$i]}" != "ok" ]; then
		failed=1
	fi
done
if [ $failed -eq 0 ]; then
	echo "all checks passed"
else
	echo "some checks failed"
fi
exit $failed
