## Local check that the host's scripts compile (a parse error would otherwise show only after an APK build and a start
## on the headset). Run with quest/tools/test-local.sh.
extends SceneTree


func _initialize() -> void:
	var failures := 0
	for path in ["res://main.gd", "res://room.gd", "res://table_math.gd", "res://preview/preview.gd"]:
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			failures += 1
			print("scripts_test: FAIL ", path, " does not compile")
	print("scripts_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)
