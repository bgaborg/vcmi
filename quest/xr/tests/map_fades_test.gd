## Local check of the map objects' fades (map_fades.gd): an object fades in from clear to whole and out to clear in
## its time, the ones that faded out are reported once, and the texture holds the alpha at the texel of the id.
## Run with quest/tools/test-local.sh.
extends SceneTree

const MapFades := preload("res://map_fades.gd")

var failures := 0


func _initialize() -> void:
	var fades: RefCounted = MapFades.new()
	_expect("everything shows at first", [fades.alpha(0), fades.alpha(64742), fades.active()], [1.0, 1.0, false])
	fades.fade_in(300)
	_expect("a new object starts clear", fades.alpha(300), 0.0)
	fades.advance(MapFades.SECONDS / 2.0)
	_expect("half way", absf(fades.alpha(300) - 0.5) < 0.01, true)
	fades.fade_out(64742) # the heaviest map's last object: the texture's far end
	var gone: PackedInt32Array = fades.advance(MapFades.SECONDS)
	_expect("in: whole; out: clear and reported", [fades.alpha(300), fades.alpha(64742), gone], [1.0, 0.0,
			PackedInt32Array([64742])])
	_expect("nothing fades any more", [fades.active(), fades.advance(0.1)], [false, PackedInt32Array()])
	_expect("but the faded-out object's sprites still need the texture", fades.needed(), true)
	var image: Image = fades._image # what advance uploads (the headless renderer keeps no texture data)
	_expect("the texture has the id's texel", [image.get_pixel(64742 % 256, 64742 / 256).r, image.get_pixel(300 % 256,
			300 / 256).r], [0.0, 1.0])
	fades.forget(64742)
	_expect("its sprites gone: nothing needs the texture", [fades.needed(), fades.alpha(64742)], [false, 1.0])
	fades.fade_out(5)
	fades.advance(MapFades.SECONDS / 2.0)
	fades.fade_in(5) # it came back halfway: from where it is, not from clear
	_expect("a fade turned back starts where it was", absf(fades.alpha(5) - 0.5) < 0.01, true)
	fades.fade_out(7)
	fades.fade_out(8)
	fades.advance(MapFades.SECONDS) # 7 and 8 faded out
	fades.fade_out(6) # fading out
	fades.fade_in(9) # coming in
	fades.end_fade_outs() # a sprite rebuild: the faded-out sprites are gone, the fade in goes on
	_expect("a rebuild ends the fades out, not the fades in", [fades.alpha(6), fades.alpha(8), fades.alpha(9),
			fades.active(), fades.needed()], [1.0, 1.0, 0.0, true, true])
	fades.advance(MapFades.SECONDS)
	_expect("then nothing is needed", fades.needed(), false)
	fades.fade_out(-1)
	fades.fade_out(70000)
	_expect("ids outside the table are ignored", fades.active(), false)
	fades.reset()
	_expect("reset: all whole", [fades.alpha(5), fades.alpha(64742), fades.active()], [1.0, 1.0, false])
	print("map_fades_test: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(1 if failures else 0)


func _expect(name_: String, got: Variant, want: Variant) -> void:
	if typeof(got) != typeof(want) or got != want:
		failures += 1
		print("map_fades_test: FAIL ", name_, ": got ", got, ", want ", want)
