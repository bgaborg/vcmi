# Quest fork (branch `quest`)

This checkout is a fork of VCMI for a Meta Quest 3 build. The plan, with the current status and next steps, is [`quest/PROJECT_PLAN.md`](../quest/PROJECT_PLAN.md); repository rules are in [`AGENTS.md`](../AGENTS.md).

## Keep the fork easy to rebase on upstream VCMI

- Prefer solutions that need no change to VCMI code. Put Quest work in the Godot host (`quest/xr/`), in the quest Android source set (`android/vcmi-app/src/quest/`, `quest.gradle`) or in `quest/`.
- When a change to an upstream file cannot be avoided, keep it to a few lines, list it in `quest/PROJECT_PLAN.md` ("Changes to upstream files"), and prefer a generic hook that could be proposed upstream.
- Between two working options, take the one with fewer or smaller changes to upstream files, even if it is less complete (for example: Godot draws the pointer instead of changing VCMI's cursor code).

## Lint and test before each commit

- `quest/tools/install-hooks.sh` once per checkout. The pre-commit hook then lints the staged Quest files (`quest/tools/lint.sh`) and runs the host's local tests (`quest/tools/test-local.sh`) when `quest/xr` changed.
- Host logic that needs no game gets a headless test in `quest/xr/tests/`, run on the PC in seconds; the headset is for game behaviour.

## Test on the Android build for Quest 3

- The target is the Android APK on the headset. Do not substitute a Windows or other desktop build of VCMI.
- Work without the user: build (`quest/tools/make-apk.sh` in WSL), install, launch and drive the headset over adb with `quest/tools/quest.sh` (`awake` first, `start-xr`, `test <cmd>`, `screenshot`). How, with the lessons learned: `quest/PHASE2.md`, "Working on the headset". Ask the user only for one-time steps (a cable, wireless debugging, a system dialog).
- Save every screenshot under `quest/out/` with a descriptive name and send it to the user as the work progresses, together with what it shows.
