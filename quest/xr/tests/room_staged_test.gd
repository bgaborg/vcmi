## Local check of the room's staged build (room.gd `staged`, main.gd's loading bar): it reports a rising share a frame
## apart, below 1 until it is whole, then `built`, with the same nodes as a room built at once.
## Run with quest/tools/test-local.sh.
extends SceneTree

const Room := preload("res://room.gd")

var failures := 0


func _initialize() -> void:
	var shares: Array[float] = []
	var room: Node3D = Room.new()
	room.staged = true
	room.building.connect(func(done: float): shares.append(done))
	var whole := [false]
	room.built.connect(func(): whole[0] = true)
	root.add_child(room)
	for _frame in 60:
		if whole[0]:
			break
		await process_frame
	var rising := true
	for i in range(1, shares.size()):
		rising = rising and shares[i] > shares[i - 1]
	_expect("the share rises a part at a time, below 1, then the room is whole", [shares.size() > 5, rising,
			not shares.is_empty() and shares.back() < 1.0, whole[0], room.visible], [true, true, true, true, true])
	var at_once: Node3D = Room.new()
	root.add_child(at_once)
	_expect("the same room as one built at once", room.find_children("*", "", true, false).size(),
			at_once.find_children("*", "", true, false).size())
	print("room_staged_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Variant, want: Variant) -> void:
	if typeof(got) != typeof(want) or got != want:
		failures += 1
		print("room_staged_test: FAIL ", name_, ": got ", got, ", want ", want)
