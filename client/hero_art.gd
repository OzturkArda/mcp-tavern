class_name HeroArt
extends RefCounted
## Procedural drawings of the fantasy characters seated at the table.
## Origin is the seat point on the table's back rim; negative y is up.

const SKIN := [Color("f6d7c3"), Color("ecc5a3"), Color("d9a47c"), Color("b47a52"), Color("8a5a3c"), Color("62402a")]
const HAIR := [Color("2b1d16"), Color("5a3825"), Color("8b5a2b"), Color("c68642"), Color("e8c87a"), Color("a8402e"), Color("cfcfcf"), Color("1d1d22")]
const INK := Color("2b1d16")

const STYLES := {
	"wizard": {"main": Color("3657c9"), "dark": Color("263f99"), "trim": Color("f2c94c"), "label": Color("8fb4ff")},
	"rogue": {"main": Color("3d4148"), "dark": Color("25282d"), "trim": Color("9b2c4a"), "label": Color("c9ccd1")},
	"cleric": {"main": Color("eceff3"), "dark": Color("bcc4cf"), "trim": Color("f0b429"), "label": Color("ffe08a")},
	"fighter": {"main": Color("9aa3ad"), "dark": Color("666e77"), "trim": Color("b02a2a"), "label": Color("ff8a80")},
	"ranger": {"main": Color("2f7d3b"), "dark": Color("1f5a28"), "trim": Color("8d5a2b"), "label": Color("8fdc9a")},
	"bard": {"main": Color("b8325e"), "dark": Color("8a2146"), "trim": Color("f5c542"), "label": Color("ff9cc0")},
	"paladin": {"main": Color("d7dde4"), "dark": Color("9aa5b1"), "trim": Color("e0a526"), "label": Color("ffd27a")},
	"druid": {"main": Color("6b8e23"), "dark": Color("4f6b19"), "trim": Color("8b5e3c"), "label": Color("c5e07a")},
	"warlock": {"main": Color("4b2a8a"), "dark": Color("2e1a57"), "trim": Color("b48cff"), "label": Color("c7a6ff")},
	"barbarian": {"main": Color("8a5a36"), "dark": Color("5e3c22"), "trim": Color("c0392b"), "label": Color("ffb38a")},
	"monk": {"main": Color("e8771e"), "dark": Color("b85a12"), "trim": Color("ffd08a"), "label": Color("ffb066")},
	"sorcerer": {"main": Color("a8262e"), "dark": Color("761a20"), "trim": Color("ffb347"), "label": Color("ff8f8f")},
}


static func style(look: String) -> Dictionary:
	return STYLES.get(look, STYLES["fighter"])


static func label_color(look: String) -> Color:
	return style(look)["label"]


## Highest point of the character (for placing speech bubbles), in local units.
static func top_y(look: String) -> float:
	match look:
		"wizard":
			return -205.0
		"druid":
			return -178.0
		"paladin", "barbarian":
			return -165.0
		"sorcerer":
			return -170.0
		"rogue", "ranger", "warlock":
			return -150.0
	return -140.0


static func ell(c: Vector2, rx: float, ry: float, n: int = 32) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * i / n
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


static func arc_pts(c: Vector2, rx: float, ry: float, a0: float, a1: float, n: int = 16) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n + 1:
		var a := a0 + (a1 - a0) * i / n
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	return pts


static func fill_ell(ci: CanvasItem, c: Vector2, rx: float, ry: float, col: Color) -> void:
	ci.draw_colored_polygon(ell(c, rx, ry), col)


static func poly(ci: CanvasItem, pts: Array, col: Color, offset: Vector2 = Vector2.ZERO) -> void:
	var packed := PackedVector2Array()
	for pt in pts:
		packed.append(pt + offset)
	ci.draw_colored_polygon(packed, col)


static func star(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 8:
		var a := -PI / 2 + i * PI / 4
		var rr := r if i % 2 == 0 else r * 0.38
		pts.append(c + Vector2(cos(a), sin(a)) * rr)
	ci.draw_colored_polygon(pts, col)


static func palette(seed: int) -> Dictionary:
	return {"skin": SKIN[seed % SKIN.size()], "hair": HAIR[(seed / 7) % HAIR.size()]}


# ------------------------------------------------------------------ chair

static func draw_chair(ci: CanvasItem) -> void:
	var wood := Color("4a2c1a")
	var light := Color("6b4128")
	ci.draw_rect(Rect2(-48, -150, 96, 150), wood)
	ci.draw_rect(Rect2(-48, -150, 96, 150), light, false, 3.0)
	ci.draw_rect(Rect2(-36, -138, 72, 18), light.darkened(0.15))
	fill_ell(ci, Vector2(-48, -152), 8, 8, light)
	fill_ell(ci, Vector2(48, -152), 8, 8, light)


# ------------------------------------------------------------------ body

## p: t, talk (bool), blink (bool), glance (-1..1), seed (int), skin, hair
static func draw_hero(ci: CanvasItem, look: String, p: Dictionary) -> void:
	var s := style(look)
	_behind(ci, look, s, p)
	_torso(ci, look, s, p)
	_head(ci, look, s, p)


static func draw_hands(ci: CanvasItem, look: String, p: Dictionary) -> void:
	var s := style(look)
	var skin: Color = p.skin
	var sleeve: Color = s.dark
	if look == "barbarian":
		sleeve = skin.darkened(0.08)
	for side in [-1, 1]:
		ci.draw_line(Vector2(side * 50, -8), Vector2(side * 40, 14), sleeve, 16.0)
		fill_ell(ci, Vector2(side * 40, 16), 10, 8, skin)
		if look in ["fighter", "paladin"]:
			fill_ell(ci, Vector2(side * 44, 6), 10, 7, s.main)


static func _behind(ci: CanvasItem, look: String, s: Dictionary, p: Dictionary) -> void:
	var t: float = p.t
	match look:
		"wizard":
			ci.draw_line(Vector2(60, 20), Vector2(60, -150), Color("6b4128"), 6.0)
			var glow := 0.6 + 0.4 * sin(t * 2.4)
			ci.draw_circle(Vector2(60, -160), 16, Color(0.5, 0.75, 1.0, 0.18 * glow))
			poly(ci, [Vector2(0, -12), Vector2(7, 0), Vector2(0, 12), Vector2(-7, 0)], Color("9fd3ff"), Vector2(60, -160))
		"ranger":
			var bow := arc_pts(Vector2(-60, -80), 110, 110, -0.6, 0.6, 18)
			ci.draw_polyline(bow, Color("7a4a24"), 5.0)
			ci.draw_line(bow[0], bow[bow.size() - 1], Color(0.9, 0.9, 0.85, 0.8), 1.0)
			ci.draw_line(Vector2(-26, -56), Vector2(-46, -130), Color("6b4128"), 11.0)
			for i in 3:
				var tip := Vector2(-40 - i * 5, -132 - i * 2)
				ci.draw_line(tip + Vector2(0, 10), tip, Color("ddd"), 2.0)
				poly(ci, [Vector2(0, 0), Vector2(-4, 8), Vector2(4, 8)], Color("c0392b"), tip)
		"bard":
			ci.draw_line(Vector2(-50, -20), Vector2(-74, -104), Color("5a3418"), 6.0)
			ci.draw_rect(Rect2(-82, -118, 12, 16), Color("5a3418"))
			fill_ell(ci, Vector2(-52, -14), 22, 26, Color("b07030"))
			fill_ell(ci, Vector2(-52, -18), 6, 6, Color("3a2210"))
		"fighter":
			ci.draw_line(Vector2(34, -50), Vector2(60, -150), Color("c9d1d9"), 7.0)
			ci.draw_line(Vector2(42, -78), Vector2(62, -70), Color("7a5a2a"), 6.0)
			ci.draw_line(Vector2(30, -36), Vector2(36, -60), Color("5a3418"), 6.0)
		"paladin":
			poly(ci, [Vector2(-52, -60), Vector2(52, -60), Vector2(64, 14), Vector2(-64, 14)], Color("8b1e24"))
		"druid":
			ci.draw_line(Vector2(-60, 20), Vector2(-60, -160), Color("6b4a2a"), 7.0)
			fill_ell(ci, Vector2(-66, -160), 9, 5, Color("7cb342"))
			fill_ell(ci, Vector2(-54, -166), 9, 5, Color("9ccc65"))
			var pulse := 0.6 + 0.4 * sin(t * 1.8 + 1.0)
			ci.draw_circle(Vector2(-60, -172), 7, Color(0.6, 1.0, 0.5, 0.75 * pulse))
		"barbarian":
			ci.draw_line(Vector2(-30, -10), Vector2(-62, -150), Color("5a3418"), 8.0)
			poly(ci, [Vector2(0, 0), Vector2(-30, -14), Vector2(-26, 22), Vector2(4, 16)], Color("b8c0c8"), Vector2(-58, -150))
		"cleric":
			ci.draw_arc(Vector2(0, -100), 44, 0, TAU, 40, Color(1.0, 0.85, 0.4, 0.35), 3.0)


static func _torso(ci: CanvasItem, look: String, s: Dictionary, p: Dictionary) -> void:
	var main: Color = s.main
	var dark: Color = s.dark
	var trim: Color = s.trim
	var skin: Color = p.skin
	var t: float = p.t
	ci.draw_line(Vector2(-38, -50), Vector2(-50, 0), dark, 18.0)
	ci.draw_line(Vector2(38, -50), Vector2(50, 0), dark, 18.0)
	var body := [Vector2(-34, -66), Vector2(34, -66), Vector2(44, -44), Vector2(46, 14), Vector2(-46, 14), Vector2(-44, -44)]
	poly(ci, body, main)
	poly(ci, [Vector2(14, -66), Vector2(34, -66), Vector2(44, -44), Vector2(46, 14), Vector2(24, 14)], Color(dark, 0.5))
	fill_ell(ci, Vector2(-36, -54), 15, 13, main)
	fill_ell(ci, Vector2(36, -54), 15, 13, main.lerp(dark, 0.5))
	match look:
		"wizard":
			ci.draw_rect(Rect2(-5, -66, 10, 80), trim)
			star(ci, Vector2(-22, -30), 6, trim)
			star(ci, Vector2(24, -8), 5, Color(trim, 0.8))
		"rogue":
			ci.draw_line(Vector2(-40, -56), Vector2(40, 10), Color("5a3418"), 8.0)
			ci.draw_rect(Rect2(-6, -28, 12, 10), Color("c9a227"))
			poly(ci, [Vector2(-20, -66), Vector2(0, -40), Vector2(20, -66)], trim)
		"cleric":
			ci.draw_rect(Rect2(-7, -66, 14, 80), trim)
			ci.draw_circle(Vector2(0, -34), 10, trim.lightened(0.2))
			for i in 8:
				var a := i * TAU / 8
				ci.draw_line(Vector2(0, -34) + Vector2(cos(a), sin(a)) * 11, Vector2(0, -34) + Vector2(cos(a), sin(a)) * 16, trim, 2.0)
		"fighter":
			poly(ci, [Vector2(-28, -60), Vector2(28, -60), Vector2(30, -20), Vector2(0, -6), Vector2(-30, -20)], main.lightened(0.15))
			ci.draw_line(Vector2(-42, -58), Vector2(42, 8), trim, 9.0)
		"ranger":
			ci.draw_line(Vector2(36, -60), Vector2(-40, 8), Color("6b4128"), 7.0)
			poly(ci, [Vector2(-34, -66), Vector2(34, -66), Vector2(24, -48), Vector2(-24, -48)], main.lightened(0.15))
		"bard":
			for i in 3:
				ci.draw_circle(Vector2(0, -44 + i * 18), 3.5, trim)
			for i in 5:
				ci.draw_circle(Vector2(-16 + i * 8, -66), 6, Color("f4f1ea"))
		"paladin":
			ci.draw_rect(Rect2(-20, -62, 40, 76), Color("2a5db0"))
			ci.draw_rect(Rect2(-4, -54, 8, 46), trim)
			ci.draw_rect(Rect2(-14, -40, 28, 8), trim)
		"druid":
			ci.draw_line(Vector2(-44, -6), Vector2(44, -6), Color("a07a4a"), 4.0)
			poly(ci, [Vector2(0, -16), Vector2(8, -6), Vector2(0, 4), Vector2(-8, -6)], Color("8bc34a"), Vector2(0, -34))
		"warlock":
			poly(ci, [Vector2(-22, -66), Vector2(0, -26), Vector2(22, -66)], dark)
			var pulse := 0.5 + 0.5 * sin(t * 3.0)
			ci.draw_circle(Vector2(0, -24), 9, Color(0.75, 0.55, 1.0, 0.3 * pulse))
			ci.draw_circle(Vector2(0, -24), 5, trim)
		"barbarian":
			poly(ci, [Vector2(-22, -66), Vector2(22, -66), Vector2(10, -20), Vector2(-10, -20)], skin.darkened(0.05))
			for i in 7:
				fill_ell(ci, Vector2(-42 + i * 14, -62 + absf(3 - i) * 2), 11, 9, Color("a0794f").lerp(Color("c9a36b"), (i % 2) * 0.5))
			ci.draw_line(Vector2(-40, -40), Vector2(40, 10), Color("3e2614"), 7.0)
		"monk":
			ci.draw_line(Vector2(-22, -66), Vector2(10, -16), dark, 4.0)
			ci.draw_line(Vector2(22, -66), Vector2(-4, -30), dark, 4.0)
			ci.draw_rect(Rect2(-46, -8, 92, 10), trim)
			for i in 9:
				var a := 0.15 * PI + i * 0.7 * PI / 8
				ci.draw_circle(Vector2(0, -66) + Vector2(cos(a) * 22, sin(a) * 26), 3.0, Color("5a3418"))
		"sorcerer":
			poly(ci, [Vector2(-24, -66), Vector2(0, -44), Vector2(24, -66)], trim)
			var pulse := 0.6 + 0.4 * sin(t * 4.0)
			ci.draw_circle(Vector2(0, -30), 10, Color(1.0, 0.6, 0.2, 0.3 * pulse))
			ci.draw_circle(Vector2(0, -30), 5, Color("ffd166"))


static func _head(ci: CanvasItem, look: String, s: Dictionary, p: Dictionary) -> void:
	var skin: Color = p.skin
	var hc := Vector2(0, -100)
	ci.draw_rect(Rect2(-9, -82, 18, 18), skin.darkened(0.18))
	_head_back(ci, look, s, p, hc)
	if look in ["ranger", "druid"]:
		poly(ci, [Vector2(-24, -6), Vector2(-44, -24), Vector2(-26, 8)], skin, hc)
		poly(ci, [Vector2(24, -6), Vector2(44, -24), Vector2(26, 8)], skin, hc)
	else:
		fill_ell(ci, hc + Vector2(-27, 2), 6, 8, skin)
		fill_ell(ci, hc + Vector2(27, 2), 6, 8, skin)
	fill_ell(ci, hc, 28, 30, skin)
	_face(ci, look, p, hc)
	_head_front(ci, look, s, p, hc)
	if look != "rogue":
		_mouth(ci, look, p, hc)


static func _head_back(ci: CanvasItem, look: String, s: Dictionary, p: Dictionary, hc: Vector2) -> void:
	var hair: Color = p.hair
	var seed: int = p.seed
	var t: float = p.t
	match look:
		"rogue", "ranger", "warlock":
			fill_ell(ci, hc + Vector2(0, -2), 38, 40, s.dark)
			poly(ci, [Vector2(-22, -30), Vector2(0, -52), Vector2(22, -30)], s.dark, hc)
		"cleric", "bard", "druid":
			if seed % 2 == 0:
				fill_ell(ci, hc + Vector2(0, 12), 33, 40, hair)
		"wizard":
			fill_ell(ci, hc + Vector2(0, 6), 32, 30, Color("d9d9d9"))
		"barbarian":
			for i in 7:
				var a := PI * 0.85 + i * PI * 1.3 / 6
				fill_ell(ci, hc + Vector2(cos(a) * 26, sin(a) * 26 + 6), 13, 13, hair)
		"sorcerer":
			var outer := PackedVector2Array([hc + Vector2(-32, 10)])
			var inner := PackedVector2Array([hc + Vector2(-22, 6)])
			for i in 9:
				var x := -30.0 + i * 7.5
				var h := 46.0 + 10.0 * sin(t * 7.0 + i * 1.7) + (12.0 if i % 2 == 0 else 0.0)
				outer.append(hc + Vector2(x, -14))
				outer.append(hc + Vector2(x + 3.75, -14 - h))
				if i > 0 and i < 8:
					inner.append(hc + Vector2(x * 0.7, -14))
					inner.append(hc + Vector2(x * 0.7 + 2.6, -14 - h * 0.62))
			outer.append(hc + Vector2(32, -14))
			outer.append(hc + Vector2(32, 10))
			inner.append(hc + Vector2(22, -14))
			inner.append(hc + Vector2(22, 6))
			ci.draw_colored_polygon(outer, Color("ff7a1a"))
			ci.draw_colored_polygon(inner, Color("ffd166"))


static func _face(ci: CanvasItem, look: String, p: Dictionary, hc: Vector2) -> void:
	var blink: bool = p.blink
	var talk: bool = p.talk
	var glance := Vector2(float(p.glance) * 2.0, 0)
	var hair: Color = p.hair
	var skin: Color = p.skin
	var eye_col := Color("c9a7ff") if look == "warlock" else INK
	var eh := 0.9 if blink else 4.6
	for side in [-1, 1]:
		var ec := hc + Vector2(side * 10, -2)
		if look == "warlock" and not blink:
			ci.draw_circle(ec, 8, Color(0.75, 0.6, 1.0, 0.25))
		fill_ell(ci, ec + glance, 3.4, eh, eye_col)
		if not blink and look != "warlock":
			ci.draw_circle(ec + glance + Vector2(1.0, -1.6), 1.2, Color(1, 1, 1, 0.9))
		var lift := -2.5 if talk else 0.0
		var brow := Color("dddddd") if look == "wizard" else hair.darkened(0.25)
		ci.draw_line(ec + Vector2(-5, -9 + lift), ec + Vector2(5, -10 + lift), brow, 2.5)
	ci.draw_circle(hc + Vector2(-17, 9), 5, Color(1, 0.45, 0.45, 0.22))
	ci.draw_circle(hc + Vector2(17, 9), 5, Color(1, 0.45, 0.45, 0.22))
	ci.draw_line(hc + Vector2(0, 3), hc + Vector2(2, 8), skin.darkened(0.28), 2.0)
	if look == "barbarian":
		ci.draw_line(hc + Vector2(-22, 4), hc + Vector2(-12, 4), Color("2f6fd0"), 2.5)
		ci.draw_line(hc + Vector2(-22, 9), hc + Vector2(-12, 9), Color("2f6fd0"), 2.5)


static func _mouth(ci: CanvasItem, look: String, p: Dictionary, hc: Vector2) -> void:
	var mc := hc + Vector2(0, 16)
	if look == "wizard" or look == "barbarian":
		mc.y += 2
	if p.talk:
		var open := 2.0 + 4.0 * absf(sin(float(p.t) * 15.0))
		fill_ell(ci, mc, 5.5, open, Color("6b1f1f"))
	else:
		ci.draw_arc(mc + Vector2(0, -5), 6.0, 0.35, PI - 0.35, 10, Color("6b2a20"), 2.0)


static func _hood_rim(ci: CanvasItem, hc: Vector2, col: Color) -> void:
	var pts := arc_pts(hc + Vector2(0, -2), 38, 40, PI * 0.95, TAU + PI * 0.05, 20)
	var inner := arc_pts(hc + Vector2(0, -8), 25, 20, TAU, PI, 16)
	pts.append_array(inner)
	ci.draw_colored_polygon(pts, col)


static func _fringe(ci: CanvasItem, hc: Vector2, hair: Color) -> void:
	var pts := arc_pts(hc + Vector2(0, -2), 30, 31, PI * 1.02, TAU - PI * 0.02, 18)
	pts.append(hc + Vector2(20, -14))
	pts.append(hc + Vector2(8, -10))
	pts.append(hc + Vector2(-6, -16))
	pts.append(hc + Vector2(-22, -10))
	ci.draw_colored_polygon(pts, hair)


static func _head_front(ci: CanvasItem, look: String, s: Dictionary, p: Dictionary, hc: Vector2) -> void:
	var hair: Color = p.hair
	var t: float = p.t
	var main: Color = s.main
	var dark: Color = s.dark
	var trim: Color = s.trim
	match look:
		"wizard":
			var beard := Color("eceff1")
			poly(ci, [Vector2(-25, 4), Vector2(-16, 22), Vector2(-7, 46), Vector2(0, 62), Vector2(7, 46), Vector2(16, 22), Vector2(25, 4), Vector2(14, 12), Vector2(0, 14), Vector2(-14, 12)], beard, hc)
			fill_ell(ci, hc + Vector2(-8, 12), 9, 4, beard.darkened(0.05))
			fill_ell(ci, hc + Vector2(8, 12), 9, 4, beard.darkened(0.05))
			fill_ell(ci, hc + Vector2(0, -22), 44, 9, dark)
			poly(ci, [Vector2(-26, -24), Vector2(26, -24), Vector2(14, -58), Vector2(34, -104), Vector2(-2, -64)], main, hc)
			ci.draw_line(hc + Vector2(-25, -30), hc + Vector2(25, -30), trim, 6.0)
			star(ci, hc + Vector2(4, -50), 6, trim)
			star(ci, hc + Vector2(-10, -38), 4, Color(trim, 0.8))
		"rogue":
			_hood_rim(ci, hc, main)
			poly(ci, [Vector2(-27, 4), Vector2(27, 4), Vector2(23, 22), Vector2(0, 31), Vector2(-23, 22)], Color("1e2024"), hc)
			ci.draw_line(hc + Vector2(-26, 4), hc + Vector2(26, 4), Color("34373d"), 2.0)
		"cleric":
			_fringe(ci, hc, hair)
			ci.draw_arc(hc + Vector2(0, 4), 30, PI * 1.13, PI * 1.87, 16, trim, 3.5)
			ci.draw_circle(hc + Vector2(0, -25), 4.5, Color("4dabf7"))
		"fighter", "paladin":
			var steel := main if look == "fighter" else Color("c8d0d8")
			var dome := arc_pts(hc + Vector2(0, -4), 32, 34, PI, TAU, 20)
			ci.draw_colored_polygon(dome, steel)
			ci.draw_arc(hc + Vector2(0, -4), 26, PI * 1.15, PI * 1.45, 8, Color(1, 1, 1, 0.45), 3.0)
			var band := dark if look == "fighter" else trim
			ci.draw_line(hc + Vector2(-32, -6), hc + Vector2(32, -6), band, 6.0)
			ci.draw_rect(Rect2(hc + Vector2(-3, -6), Vector2(6, 16)), band)
			poly(ci, [Vector2(-32, -6), Vector2(-24, -6), Vector2(-22, 16), Vector2(-31, 12)], steel.darkened(0.1), hc)
			poly(ci, [Vector2(32, -6), Vector2(24, -6), Vector2(22, 16), Vector2(31, 12)], steel.darkened(0.2), hc)
			if look == "paladin":
				var sway := sin(t * 1.3) * 2.0
				for i in 5:
					fill_ell(ci, hc + Vector2(-4 - i * 7 + sway, -40 - i * 4 + i * i * 1.2), 9, 7, Color("d63031").darkened(i * 0.06))
		"ranger":
			_fringe(ci, hc, hair)
			_hood_rim(ci, hc, main)
		"bard":
			_fringe(ci, hc, hair)
			var cap := PackedVector2Array()
			for pt in ell(Vector2.ZERO, 31, 11, 24):
				cap.append(hc + Vector2(6, -27) + pt.rotated(-0.22))
			ci.draw_colored_polygon(cap, Color("6b2d8c"))
			poly(ci, [Vector2(14, -30), Vector2(34, -46), Vector2(58, -78), Vector2(44, -50), Vector2(20, -26)], trim, hc)
		"druid":
			_fringe(ci, hc, hair)
			var antler := Color("7a5536")
			for side in [-1, 1]:
				ci.draw_polyline(PackedVector2Array([hc + Vector2(side * 14, -26), hc + Vector2(side * 24, -52), hc + Vector2(side * 36, -70)]), antler, 4.0)
				ci.draw_line(hc + Vector2(side * 24, -52), hc + Vector2(side * 14, -70), antler, 3.5)
				ci.draw_line(hc + Vector2(side * 31, -62), hc + Vector2(side * 44, -62), antler, 3.0)
			for i in 6:
				var a := PI * 1.12 + i * PI * 0.76 / 5
				fill_ell(ci, hc + Vector2(cos(a) * 29, sin(a) * 29 + 3), 6, 4, Color("7cb342") if i % 2 else Color("aed581"))
		"warlock":
			_hood_rim(ci, hc, main)
			for side in [-1, 1]:
				poly(ci, [Vector2(side * 16, -30), Vector2(side * 30, -46), Vector2(side * 26, -66), Vector2(side * 22, -48), Vector2(side * 8, -34)], Color("2d2a33"), hc)
			var orb := hc + Vector2(54, -10 + sin(t * 2.0) * 6)
			ci.draw_circle(orb, 13, Color(0.7, 0.5, 1.0, 0.18))
			ci.draw_circle(orb, 7, trim)
			ci.draw_circle(orb + Vector2(-2, -2), 2.5, Color(1, 1, 1, 0.7))
		"barbarian":
			var beard := hair
			poly(ci, [Vector2(-28, -2), Vector2(-24, 24), Vector2(-12, 40), Vector2(0, 46), Vector2(12, 40), Vector2(24, 24), Vector2(28, -2), Vector2(16, 12), Vector2(0, 14), Vector2(-16, 12)], beard, hc)
			var dome := arc_pts(hc + Vector2(0, -6), 31, 30, PI, TAU, 18)
			ci.draw_colored_polygon(dome, Color("aab3bc"))
			ci.draw_line(hc + Vector2(-31, -7), hc + Vector2(31, -7), Color("6d757e"), 5.0)
			for side in [-1, 1]:
				poly(ci, [Vector2(side * 26, -14), Vector2(side * 46, -22), Vector2(side * 56, -42), Vector2(side * 52, -60), Vector2(side * 46, -40), Vector2(side * 30, -26)], Color("f1ead8"), hc)
		"monk":
			fill_ell(ci, hc + Vector2(-8, -20), 9, 5, Color(1, 1, 1, 0.3))
			fill_ell(ci, hc + Vector2(0, -34), 8, 7, hair)
			ci.draw_line(hc + Vector2(-28, -10), hc + Vector2(28, -10), trim.darkened(0.3), 4.0)
		"sorcerer":
			_fringe(ci, hc, Color("ff8c2a"))
			for i in 3:
				var a := t * 1.8 + i * TAU / 3
				var sp := hc + Vector2(cos(a) * 46, sin(a) * 14 - 30)
				ci.draw_circle(sp, 3.0, Color(1.0, 0.8, 0.3, 0.9))
				ci.draw_circle(sp, 7.0, Color(1.0, 0.6, 0.2, 0.2))
