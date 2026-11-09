#!/usr/bin/env bash
# Lints the Quest fork's own code by type (not upstream VCMI):
#   GDScript (quest/xr)                     gdlint, config quest/xr/gdlintrc
#   C++ (quest/bridge, quest/xr/extension,  clang-format with the repository's .clang-format (VCMI's style);
#        quest/bench)                       the builds add -Wall -Wextra -Werror
#   shell (quest/**/*.sh, git hooks)        shellcheck
#   Java (quest source set, quest/bench)    PMD 7, rules quest/tools/pmd-ruleset.xml (bug patterns, no classpath)
#   Python (quest/**/*.py)                  ruff
# Usage: quest/tools/lint.sh [files...]   (no files: all of them; others than the above are skipped)
#        FIX=1 quest/tools/lint.sh ...    applies clang-format instead of checking it
# The Python linters run pinned through uvx (https://docs.astral.sh/uv/); PMD from ~/vcmi-tools/pmd-bin-<version>
# (unzipped release) with a JDK on the PATH (Android Studio's jbr). The pre-commit hook runs it on the staged files.

set -eo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
GDTOOLKIT="gdtoolkit==4.5.0"
SHELLCHECK="shellcheck-py==0.11.0.1"
CLANG_FORMAT="clang-format@23.1.5"
RUFF="ruff@0.17.4"
PMD="${PMD:-$HOME/vcmi-tools/pmd-bin-7.7.0/bin/pmd}"

if [ $# -eq 0 ]; then
	mapfile -t FILES < <(git ls-files quest android/vcmi-app/src/quest)
else
	FILES=("$@")
fi

GD=() CPP=() SH=() JAVA=() PY=()
for f in "${FILES[@]}"; do
	[ -f "$f" ] || continue
	case "$f" in
		quest/xr/*.gd) GD+=("${f#quest/xr/}") ;;
		quest/bridge/*.cpp | quest/bridge/*.h | quest/xr/extension/*.cpp | quest/xr/extension/*.h | quest/bench/*.cpp) CPP+=("$f") ;;
		quest/*.sh | quest/tools/git-hooks/*) SH+=("$f") ;;
		quest/*.java | android/vcmi-app/src/quest/*.java) JAVA+=("$f") ;;
		quest/*.py) PY+=("$f") ;;
	esac
done

STATUS=0
fail() {
	echo "lint: $1 failed" >&2
	STATUS=1
}

if [ ${#GD[@]} -gt 0 ]; then
	# from quest/xr, where gdlint finds its gdlintrc
	(cd quest/xr && uvx -q --from "$GDTOOLKIT" gdlint "${GD[@]}") || fail "gdlint"
fi
if [ ${#CPP[@]} -gt 0 ]; then
	if [ -n "${FIX:-}" ]; then
		uvx -q "$CLANG_FORMAT" -i "${CPP[@]}" || fail "clang-format"
	else
		uvx -q "$CLANG_FORMAT" --dry-run --Werror "${CPP[@]}" || fail "clang-format (FIX=1 $0 applies it)"
	fi
fi
if [ ${#SH[@]} -gt 0 ]; then
	uvx -q --from "$SHELLCHECK" shellcheck "${SH[@]}" || fail "shellcheck"
fi
if [ ${#PY[@]} -gt 0 ]; then
	uvx -q "$RUFF" check "${PY[@]}" || fail "ruff"
fi
if [ ${#JAVA[@]} -gt 0 ]; then
	if [ -x "$PMD" ]; then
		LIST="$(mktemp)"
		printf '%s\n' "${JAVA[@]}" > "$LIST"
		"$PMD" check --no-progress --no-cache -R quest/tools/pmd-ruleset.xml -f text --file-list "$LIST" 2> >(grep -v '^\[WARN\]' >&2) || fail "PMD"
		rm -f "$LIST"
	else
		echo "lint: PMD not found ($PMD): Java not linted" >&2
	fi
fi
[ $STATUS -eq 0 ] && echo "lint: ok (${#GD[@]} GDScript, ${#CPP[@]} C++, ${#SH[@]} shell, ${#JAVA[@]} Java, ${#PY[@]} Python)"
exit $STATUS
