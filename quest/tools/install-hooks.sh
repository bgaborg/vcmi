#!/usr/bin/env bash
# Installs the Quest fork's git hooks (quest/tools/git-hooks/) into this checkout's .git/hooks. The repository keeps
# the Git LFS hooks there, so core.hooksPath is not changed: each hook here becomes a small script that calls the
# versioned one. Run once per checkout; safe to run again.

set -eo pipefail

REPO="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --git-path hooks)"
for hook in "$REPO"/quest/tools/git-hooks/*; do
	name="$(basename "$hook")"
	if [ -e "$HOOKS/$name" ] && ! grep -q "quest/tools/git-hooks/$name" "$HOOKS/$name"; then
		echo "install-hooks: $HOOKS/$name exists and is not ours; left as it is" >&2
		continue
	fi
	# shellcheck disable=SC2016 # the hook expands it when it runs
	printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/quest/tools/git-hooks/%s" "$@"\n' "$name" > "$HOOKS/$name"
	chmod +x "$HOOKS/$name" "$hook"
	echo "install-hooks: $name"
done
