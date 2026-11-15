extends Node3D
## The battle's sounds from where they happen on the table (quest/PROJECT_PLAN.md phase 6, spatial audio): a stack's own
## sounds when it moves, strikes, shoots, flinches or dies (battle_cards.gd `acted`), and a spell's cast sound on its
## target. The game's own sound effects are muted meanwhile (VcmiData.set_table_battle). Each sound is read from the
## game's files once, on a worker, and kept for the battle. Tested by tests/battle_sounds_test.gd.
## The node's space is the field's (battle_cards.gd), so a sound's place is a card's.

## a creature's sounds by kind, as VcmiData.creature_sounds lists them
enum Kind { ATTACK, DEFEND, KILLED, MOVE, SHOOT, CAST, WINCE, START_MOVING, END_MOVING }

const VOICES := 8 ## sounds at once; a ninth takes the voice that has played longest
const STEP := [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88,
		97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724,
		796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
		4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
		24623, 27086, 29794, 32767] ## the IMA ADPCM step sizes
const INDEX := [-1, -1, -1, -1, 2, 4, 6, 8] ## how the step changes by a nibble's size

var data: RefCounted ## VcmiData, set by battle_field.gd poll; none in the PC preview and the `battle` sample
var volume := 1.0 ## the game's sound effects volume, 0 to 1 (VcmiData.battle sound_volume)
var _streams := {} ## sound name: AudioStream, null while it is read or when it is missing
var _waiting := {} ## sound name: [places], played once it is read
var _creatures := {} ## creature id: PackedStringArray (VcmiData.creature_sounds)
var _voices: Array[AudioStreamPlayer3D] = []
var _tasks: Array[int] = []


func _init() -> void:
	for i in VOICES:
		var voice := AudioStreamPlayer3D.new()
		voice.unit_size = 2.0 # metres at full volume: the whole table is near
		voice.max_polyphony = 1
		add_child(voice)
		_voices.append(voice)


## Stack `stack` (battle_cards.gd's stack dictionary, with its "creature") does `kind` at `at`
func creature_sound(stack: Dictionary, kind: int, at: Vector3) -> void:
	var creature: int = stack.get("creature", -1)
	if data == null or creature < 0:
		return
	if not _creatures.has(creature):
		_creatures[creature] = data.creature_sounds(creature)
	var names: PackedStringArray = _creatures[creature]
	if kind < names.size():
		play(names[kind], at)


## Sound `sound` (a name for VcmiData.sound_file) at `at`; read first when it is new
func play(sound: String, at: Vector3) -> void:
	if sound == "" or data == null or volume <= 0.0:
		return
	var stream: AudioStream = _streams.get(sound)
	if stream != null:
		_voice_play(stream, at)
		return
	if _waiting.has(sound):
		_waiting[sound].append(at)
		return
	if _streams.has(sound): # missing
		return
	_streams[sound] = null
	_waiting[sound] = [at]
	var source := data
	_tasks.append(WorkerThreadPool.add_task(func(): _loaded.call_deferred(sound, decode(source.sound_file(sound)))))


## A sound file as the game's files hold it: a WAV (PCM, or the IMA ADPCM of Heroes 3's own sounds, which Godot does not
## read) or an Ogg Vorbis file (sound mods); null when it is none of these
static func decode(bytes: PackedByteArray) -> AudioStream:
	if bytes.size() > 4 and bytes.slice(0, 4).get_string_from_ascii() == "OggS":
		return AudioStreamOggVorbis.load_from_buffer(bytes)
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF":
		return null
	var format := 0
	var channels := 1
	var rate := 22050
	var block := 0
	var bits := 16
	var samples := PackedByteArray()
	var at := 12
	while at + 8 <= bytes.size():
		var chunk := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := bytes.decode_u32(at + 4)
		if chunk == "fmt " and at + 24 <= bytes.size():
			format = bytes.decode_u16(at + 8)
			channels = bytes.decode_u16(at + 10)
			rate = bytes.decode_u32(at + 12)
			block = bytes.decode_u16(at + 20)
			bits = bytes.decode_u16(at + 22)
		elif chunk == "data":
			samples = bytes.slice(at + 8, mini(at + 8 + size, bytes.size()))
		at += 8 + size + (size & 1)
	var wav := AudioStreamWAV.new()
	wav.mix_rate = rate
	wav.stereo = channels == 2
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	if format == 1 and bits == 16:
		wav.data = samples
	elif format == 1 and bits == 8: # unsigned in a WAV, signed in Godot
		for i in samples.size():
			samples[i] = (samples[i] + 128) & 255
		wav.format = AudioStreamWAV.FORMAT_8_BITS
		wav.data = samples
	elif format == 17 and channels == 1 and block > 4:
		wav.data = _ima_adpcm(samples, block)
	else:
		return null
	return wav


## Mono IMA ADPCM in blocks of `block` bytes (a header of the first sample and the step index, then two samples a byte,
## the low nibble first) as 16-bit PCM
static func _ima_adpcm(adpcm: PackedByteArray, block: int) -> PackedByteArray:
	var pcm := PackedByteArray()
	@warning_ignore("integer_division")
	pcm.resize((adpcm.size() / block + 1) * ((block - 4) * 2 + 1) * 2)
	var out := 0
	for start in range(0, adpcm.size() - 3, block):
		var sample := adpcm.decode_s16(start)
		var index := clampi(adpcm[start + 2], 0, 88)
		pcm.encode_s16(out, sample)
		out += 2
		for i in range(start + 4, mini(start + block, adpcm.size())):
			for nibble in [adpcm[i] & 15, adpcm[i] >> 4]:
				var step: int = STEP[index]
				var change := step >> 3
				if nibble & 4:
					change += step
				if nibble & 2:
					change += step >> 1
				if nibble & 1:
					change += step >> 2
				sample = clampi(sample - change if nibble & 8 else sample + change, -32768, 32767)
				index = clampi(index + INDEX[nibble & 7], 0, 88)
				pcm.encode_s16(out, sample)
				out += 2
	pcm.resize(out)
	return pcm


## The battle is over: its sounds go (the next battle has other creatures)
func clear() -> void:
	wait_for_workers() # the voices play on: the battle's last blow is not cut
	_streams.clear()
	_waiting.clear()
	_creatures.clear()


## At exit and before a clear: the workers still use the game's files
func wait_for_workers() -> void:
	for task in _tasks:
		WorkerThreadPool.wait_for_task_completion(task)
	_tasks.clear()


func _loaded(sound: String, stream: AudioStream) -> void:
	if not _waiting.has(sound): # a clear came between
		return
	var places: Array = _waiting[sound]
	_waiting.erase(sound)
	if stream == null: # missing: stays null, not asked for again
		return
	_streams[sound] = stream
	for at: Vector3 in places:
		_voice_play(stream, at)


## On a free voice, else on the one that has played longest
func _voice_play(stream: AudioStream, at: Vector3) -> void:
	var voice: AudioStreamPlayer3D = _voices[0]
	for other in _voices:
		if not other.playing:
			voice = other
			break
		if other.get_playback_position() > voice.get_playback_position():
			voice = other
	voice.volume_db = linear_to_db(volume)
	voice.position = at
	voice.stream = stream
	voice.play()
