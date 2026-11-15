## Local check of the battle's sounds (battle_sounds.gd): WAV files decode (PCM, and the IMA ADPCM of Heroes 3's own
## sounds, checked on a real one when quest/tools/h3-extract.py snd:PIKEATTK has put it in quest/out/h3/sound/), and a
## stack that is hurt asks for its creature's wince sound at its card. Run with quest/tools/test-local.sh.
extends SceneTree

const BattleSounds := preload("res://battle_sounds.gd")
const BattleField := preload("res://battle_field.gd")

var failures := 0


## VcmiData's sound calls, without a game
class FakeData:
	extends RefCounted
	var asked: Array[int] = []

	func creature_sounds(creature: int) -> PackedStringArray:
		asked.append(creature)
		return PackedStringArray(["ATTK", "DFND", "KILL", "MOVE", "SHOT", "", "WNCE", "", ""])

	func sound_file(_name: String) -> PackedByteArray:
		return PackedByteArray()


func _initialize() -> void:
	# a 16-bit PCM WAV of three samples
	var pcm := _wav(1, 16, 0, PackedByteArray([1, 0, 2, 0, 3, 0]))
	var stream: AudioStreamWAV = BattleSounds.decode(pcm)
	_expect("PCM is kept", [stream.format, stream.mix_rate, stream.data], [AudioStreamWAV.FORMAT_16_BITS, 22050,
			PackedByteArray([1, 0, 2, 0, 3, 0])])
	# IMA ADPCM, one 5-byte block: the header's sample 0 and index 0, then nibbles 4 (+7, index 2) and 0 (+1, index 1)
	stream = BattleSounds.decode(_wav(17, 4, 5, PackedByteArray([0, 0, 0, 0, 0x04])))
	_expect("IMA ADPCM becomes 16-bit PCM", [stream.data.decode_s16(0), stream.data.decode_s16(2),
			stream.data.decode_s16(4), stream.data.size()], [0, 7, 8, 6])
	_expect("not a sound", [BattleSounds.decode(PackedByteArray([1, 2, 3])), BattleSounds.decode(_wav(85, 0, 0,
			PackedByteArray([1])))], [null, null])
	var real := ProjectSettings.globalize_path("res://../out/h3/sound/PIKEATTK.wav")
	if FileAccess.file_exists(real):
		stream = BattleSounds.decode(FileAccess.get_file_as_bytes(real))
		var loud := 0
		var clipped := 0
		for i in range(0, stream.data.size(), 2):
			loud += int(absi(stream.data.decode_s16(i)) > 3000)
			clipped += int(absi(stream.data.decode_s16(i)) >= 32767)
		# the pikeman's strike: 22 975 samples (as ffmpeg decodes it, within 33 of each), loud, hardly clipped (a wrong
		# decoder clips often or stays quiet)
		_expect("the pikeman's attack decodes", [stream.data.size() / 2, loud > 1000, clipped < 10], [22975, true,
				true])
	# a stack that loses creatures flinches: its creature's wince, at its card
	var field: Node3D = BattleField.new()
	var data := FakeData.new()
	field.sounds.data = data
	var stack := {"id": 1, "hex": 40, "side": 0, "count": 10, "creature": 7, "animation": "CPKMAN"}
	field.set_battle({"stacks": [stack]})
	var hurt := stack.duplicate()
	hurt["count"] = 6
	field.set_battle({"stacks": [hurt]})
	_expect("a hurt stack asks for its wince once", [data.asked, field.sounds._waiting.has("WNCE"),
			field.sounds._waiting.get("WNCE", [Vector3.INF])[0] == field.cards.card(1)["node"].position], [[7], true,
			true])
	field.sounds.wait_for_workers()
	field.sounds._loaded("WNCE", null) # the fake has no file: missing, not asked for again
	field.sounds.creature_sound(hurt, BattleSounds.Kind.WINCE, Vector3.ZERO)
	_expect("a missing sound is not read again", field.sounds._waiting.has("WNCE"), false)
	field.free()
	print("battle_sounds_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


## A mono 22 050 Hz WAV of format `format`
func _wav(format: int, bits: int, block: int, samples: PackedByteArray) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.append_array("RIFF".to_ascii_buffer())
	bytes.resize(8)
	bytes.encode_u32(4, 36 + samples.size())
	bytes.append_array("WAVEfmt ".to_ascii_buffer())
	var fmt := PackedByteArray()
	fmt.resize(20)
	fmt.encode_u32(0, 16)
	fmt.encode_u16(4, format)
	fmt.encode_u16(6, 1)
	fmt.encode_u32(8, 22050)
	fmt.encode_u16(16, block)
	fmt.encode_u16(18, bits)
	bytes.append_array(fmt)
	bytes.append_array("data".to_ascii_buffer())
	var size := PackedByteArray()
	size.resize(4)
	size.encode_u32(0, samples.size())
	bytes.append_array(size)
	bytes.append_array(samples)
	return bytes


func _expect(name_: String, got: Variant, want: Variant) -> void:
	if typeof(got) != typeof(want) or got != want:
		failures += 1
		print("battle_sounds_test: FAIL ", name_, ": got ", got, ", want ", want)
