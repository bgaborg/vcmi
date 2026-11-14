## The battlefield's hexes on the war table: pure maths, tested on the PC (quest/xr/tests/battle_math_test.gd).
## Field pixels are the 2D battle's own: an 800 x 556 picture, hex `i` in column i % 17 of row i / 17, placed as
## BattleFieldController::hexPositionLocal does (even rows half a hex to the right). Columns 0 and 16 are the side
## columns: only the heroes stand there (BattleHex::isAvailable).
extends RefCounted

const FIELD := Vector2(800.0, 556.0) ## pixels of the 2D battlefield
const COLUMNS := 17
const ROWS := 11
const PITCH := Vector2(44.0, 42.0) ## pixels from a hex to the next one in its row, and from a row to the next
const FIRST := Vector2(14.0 + 22.0, 86.0 + 26.0) ## the centre of hex 0 of an odd row (the cell picture is 45 x 52)
## the 2D field's hexes are a little taller than regular ones: y times this, and the nearest centre is the hex
const REGULAR := PITCH.x * 0.8660254 / PITCH.y
const NO_HEX := -1


## the centre of `hex` in field pixels
static func hex_centre(hex: int) -> Vector2:
	@warning_ignore("integer_division")
	var row := hex / COLUMNS
	return FIRST + Vector2(PITCH.x * (hex % COLUMNS) + (PITCH.x / 2.0 if row % 2 == 0 else 0.0), PITCH.y * row)


## the hex under field pixel `at`, or NO_HEX off the field
static func hex_at(at: Vector2) -> int:
	var best := NO_HEX
	var nearest := INF
	var guess := roundi((at.y - FIRST.y) / PITCH.y)
	for row in range(maxi(guess - 1, 0), mini(guess + 2, ROWS)):
		var shift := PITCH.x / 2.0 if row % 2 == 0 else 0.0
		var column := clampi(roundi((at.x - FIRST.x - shift) / PITCH.x), 0, COLUMNS - 1)
		var offset := at - hex_centre(row * COLUMNS + column)
		var distance := Vector2(offset.x, offset.y * REGULAR).length()
		if distance < nearest:
			nearest = distance
			best = row * COLUMNS + column
	# a regular hex of this width reaches PITCH.x / sqrt(3) from its centre at its corners
	return best if nearest <= PITCH.x / sqrt(3.0) else NO_HEX


## field pixels to metres on a page `area` wide and deep (x right, y towards the player), the field's middle at the
## page's: the field fills the page's depth
static func field_to_page(at: Vector2, area: Vector2) -> Vector2:
	return (at - FIELD / 2.0) * (area.y / FIELD.y)


static func page_to_field(at: Vector2, area: Vector2) -> Vector2:
	return at * (FIELD.y / area.y) + FIELD / 2.0
