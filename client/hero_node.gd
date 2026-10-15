class_name HeroNode
extends Node2D
## One member seated at the table: chair + body here, hands/mug/place card in
## `front` (above the table), speech bubble and status in `overlay`.

const AWAY_AFTER_S := 15 * 60
const BUBBLE_BG := Color("f4ead5")
const BUBBLE_EDGE := Color("7a5a33")
const VENDOR_COLORS := {"claude": Color("d97757"), "codex": Color("10a37f"), "human": Color("f2c94c")}

## Set by the client's text-size control; scales speech bubbles and status pills.
static var text_scale := 1.0

var member: Dictionary = {}
var look := "fighter"
var seed := 0
var pal: Dictionary = {}
var t := 0.0
var appear_at := 0.0
var leaving := false
var leave_at := 0.0
var talk_until := 0.0
var bubble_text := ""
var bubble_until := 0.0
var bubble_start := 0.0
var glance := 0.0
var glance_target := 0.0
var next_blink := 0.0
var blink_until := 0.0
var target_pos := Vector2.ZERO
var target_scale := 1.0
var hovered := false
var claims: Array = []
## Turn state from the hub: "" (not involved), "waiting" (asked, not seen yet),
## "seen", "working", or "passed". turn_since is when it last changed (unix).
var turn_state := ""
var turn_since := 0.0
var is_me := false
var front: Node2D
var overlay: Node2D
var font: Font
var serif: Font
var bubble_box := StyleBoxFlat.new()
var pill_box := StyleBoxFlat.new()


func setup(m: Dictionary, ui_font: Font, name_font: Font) -> void:
	font = ui_font
	serif = name_font
	seed = hash(String(m.get("name", "")).to_lower()) & 0x7fffffff
	pal = HeroArt.palette(seed)
	t = float(seed % 1000) / 100.0
	appear_at = _now()
	next_blink = appear_at + 1.0 + float(seed % 300) / 100.0
	front = Node2D.new()
	front.z_as_relative = false
	front.z_index = 3
	add_child(front)
	front.draw.connect(_draw_front)
	overlay = Node2D.new()
	overlay.z_as_relative = false
	overlay.z_index = 12
	add_child(overlay)
	overlay.draw.connect(_draw_overlay)
	bubble_box.set_border_width_all(2)
	bubble_box.set_corner_radius_all(10)
	bubble_box.shadow_color = Color(0, 0, 0, 0.35)
	bubble_box.shadow_size = 6
	pill_box.bg_color = Color(0.08, 0.06, 0.05, 0.72)
	pill_box.set_corner_radius_all(9)
	update_member(m)


func update_member(m: Dictionary) -> void:
	member = m
	look = String(m.get("look", "fighter"))


func say(text: String) -> void:
	var now := _now()
	# Bubbles are plain text: drop markdown markers and collapse whitespace.
	var clean := text.strip_edges().replace("```", "").replace("**", "").replace("`", "")
	var re := RegEx.create_from_string("\\s+")
	clean = re.sub(clean, " ", true)
	if clean.length() > 150:
		clean = clean.substr(0, 147) + "..."
	bubble_text = clean
	bubble_start = now
	bubble_until = now + clampf(4.0 + clean.length() / 22.0, 4.0, 12.0)
	talk_until = now + clampf(0.8 + clean.length() / 45.0, 0.8, 3.0)


func leave() -> void:
	if leaving:
		return
	leaving = true
	leave_at = _now()


func is_away() -> bool:
	if String(member.get("kind", "")) != "agent":
		return false
	var last := float(member.get("lastActive", 0)) / 1000.0
	return last > 0 and Time.get_unix_time_from_system() - last > AWAY_AFTER_S


func hit(world_point: Vector2) -> bool:
	var local := (world_point - position) / scale.x
	return Rect2(-56, -160, 112, 230).has_point(local)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	t += delta
	var now := _now()
	var k := minf(1.0, delta * 6.0)
	position = position.lerp(target_pos, k)
	var sc := lerpf(scale.x, target_scale, k)
	scale = Vector2(sc, sc)
	overlay.scale = Vector2.ONE / sc
	var alpha := clampf((now - appear_at) / 0.6, 0.0, 1.0)
	if leaving:
		alpha = clampf(1.0 - (now - leave_at) / 0.6, 0.0, 1.0)
		if alpha <= 0.0:
			queue_free()
			return
	var dim := 0.62 if is_away() else 1.0
	modulate = Color(dim, dim, dim * 1.05, alpha)
	if now > next_blink:
		blink_until = now + 0.13
		next_blink = now + 2.5 + randf() * 4.0
	glance = lerpf(glance, glance_target, minf(1.0, delta * 4.0))
	queue_redraw()
	front.queue_redraw()
	overlay.queue_redraw()


func _params() -> Dictionary:
	var now := _now()
	return {
		"t": t,
		"talk": now < talk_until,
		"blink": now < blink_until or is_away(),
		"glance": glance,
		"seed": seed,
		"skin": pal["skin"],
		"hair": pal["hair"],
	}


func _draw() -> void:
	HeroArt.draw_chair(self)
	var p := _params()
	var bob := sin(t * 1.6 + seed) * 1.5
	if p["talk"]:
		bob += sin(t * 16.0) * 1.3
	draw_set_transform(Vector2(0, bob))
	HeroArt.draw_hero(self, look, p)
	draw_set_transform(Vector2.ZERO)


func _draw_front() -> void:
	HeroArt.draw_hands(front, look, _params())
	_draw_mug(Vector2(66, 26))
	_draw_place_card()


func _draw_mug(at: Vector2) -> void:
	front.draw_rect(Rect2(at + Vector2(-9, -16), Vector2(18, 22)), Color("8a5a2b"))
	front.draw_rect(Rect2(at + Vector2(-9, -16), Vector2(18, 22)), Color("4a2c14"), false, 2.0)
	front.draw_line(at + Vector2(-9, -8), at + Vector2(9, -8), Color("c9a227"), 2.0)
	front.draw_arc(at + Vector2(10, -5), 6, -PI / 2, PI / 2, 8, Color("4a2c14"), 3.0)
	HeroArt.fill_ell(front, at + Vector2(0, -17), 10, 4, Color("fff4d6"))


func _draw_place_card() -> void:
	var label := String(member.get("name", "?"))
	var fs := 17
	var tw := serif.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w := tw + 34.0
	var r := Rect2(Vector2(-w / 2.0, 34), Vector2(w, 26))
	var paper := Color("efe0bd") if not hovered else Color("fff3d1")
	front.draw_rect(Rect2(r.position + Vector2(3, 3), r.size), Color(0, 0, 0, 0.35))
	front.draw_rect(r, paper)
	front.draw_rect(r, Color("f2c94c") if hovered or is_me else Color("8a6a3a"), false, 2.0)
	front.draw_string(serif, Vector2(r.position.x + 26, r.position.y + 19), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HeroArt.INK)
	_draw_sigil(Vector2(r.position.x + 14, r.position.y + 13))
	if not claims.is_empty():
		_draw_key(Vector2(r.end.x + 14, r.position.y + 13))


## A small brass key: this member holds at least one claim.
func _draw_key(c: Vector2) -> void:
	var brass := Color("e8b923")
	front.draw_circle(c + Vector2(1, 1), 7.5, Color(0, 0, 0, 0.35))
	front.draw_arc(c + Vector2(-6, 0), 5.0, 0, TAU, 14, brass, 3.0)
	front.draw_line(c + Vector2(-1, 0), c + Vector2(11, 0), brass, 3.0)
	front.draw_line(c + Vector2(7, 0), c + Vector2(7, 5), brass, 2.5)
	front.draw_line(c + Vector2(11, 0), c + Vector2(11, 6), brass, 2.5)
	if claims.size() > 1:
		front.draw_string(serif, c + Vector2(14, 6), "x%d" % claims.size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, brass)


func _draw_sigil(c: Vector2) -> void:
	var vendor := String(member.get("vendor", "other"))
	var col: Color = VENDOR_COLORS.get(vendor, Color("888888"))
	match vendor:
		"claude":
			for i in 8:
				var a := i * TAU / 8
				front.draw_line(c, c + Vector2(cos(a), sin(a)) * 7.0, col, 2.4)
		"codex":
			var hex := PackedVector2Array()
			for i in 7:
				var a := PI / 6 + i * TAU / 6
				hex.append(c + Vector2(cos(a), sin(a)) * 6.5)
			front.draw_polyline(hex, col, 2.4)
		"human":
			HeroArt.poly(front, [Vector2(-7, 5), Vector2(-7, -4), Vector2(-3.5, 0), Vector2(0, -6), Vector2(3.5, 0), Vector2(7, -4), Vector2(7, 5)], col, c)
		_:
			front.draw_circle(c, 4.5, col)


func _draw_overlay() -> void:
	var now := _now()
	var hs := scale.x
	var top := Vector2(0, HeroArt.top_y(look) * hs)
	if now - appear_at < 1.2:
		var k := (now - appear_at) / 1.2
		for i in 10:
			var a := i * TAU / 10 + k * 1.5
			var c := Vector2(0, -90 * hs) + Vector2(cos(a), sin(a)) * (30.0 + 70.0 * k) * hs
			HeroArt.star(overlay, c, 6.0 * (1.0 - k) + 1.0, Color(1.0, 0.9, 0.5, 1.0 - k))
	if now < bubble_until and bubble_text != "":
		_draw_bubble(top + Vector2(0, -10), now)
	elif has_turn():
		_draw_thinking(top + Vector2(0, -12))
	elif turn_state == "passed" and Time.get_unix_time_from_system() - turn_since < 6.0:
		_draw_pill("passes", top, Color(0.75, 0.72, 0.68))
	else:
		var status := String(member.get("status", ""))
		if status != "" and not leaving:
			if status.length() > 34:
				status = status.substr(0, 32) + "..."
			var fs := roundi(13 * text_scale)
			var tw := font.get_string_size(status, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var ph := fs + 9.0
			var r := Rect2(Vector2(-tw / 2.0 - 10, top.y - 8 - ph), Vector2(tw + 20, ph))
			overlay.draw_style_box(pill_box, r)
			overlay.draw_string(font, Vector2(r.position.x + 10, r.position.y + 4.5 + font.get_ascent(fs)), status, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color("e8dcc4"))
	if is_away():
		for i in 3:
			var ph := fmod(t * 0.6 + i * 0.33, 1.0)
			var zc := Vector2(26 * hs + ph * 26.0, -120 * hs - ph * 34.0)
			overlay.draw_string(serif, zc, "z", HORIZONTAL_ALIGNMENT_LEFT, -1, int(12 + ph * 10), Color(0.9, 0.9, 1.0, 1.0 - ph))


const TURN_TIMEOUT_S := 600.0


func set_turn(state: String, at: float) -> void:
	if state != turn_state:
		turn_state = state
		turn_since = at


func has_turn() -> bool:
	return turn_state in ["waiting", "seen", "working"] and Time.get_unix_time_from_system() - turn_since < TURN_TIMEOUT_S


func _draw_pill(label: String, top: Vector2, col: Color) -> void:
	var fs := roundi(13 * text_scale)
	var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var ph := fs + 9.0
	var r := Rect2(Vector2(-tw / 2.0 - 10, top.y - 8 - ph), Vector2(tw + 20, ph))
	overlay.draw_style_box(pill_box, r)
	overlay.draw_string(font, Vector2(r.position.x + 10, r.position.y + 4.5 + font.get_ascent(fs)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


## "It's my turn to answer": a small thought bubble with animated dots.
func _draw_thinking(anchor: Vector2) -> void:
	var s := text_scale
	var r := Rect2(Vector2(-26 * s, anchor.y - 26 * s), Vector2(52 * s, 24 * s))
	bubble_box.bg_color = BUBBLE_BG
	bubble_box.border_color = BUBBLE_EDGE
	bubble_box.shadow_color = Color(0, 0, 0, 0.35)
	overlay.draw_style_box(bubble_box, r)
	overlay.draw_circle(Vector2(-6 * s, r.end.y + 5 * s), 3.5 * s, BUBBLE_BG)
	overlay.draw_circle(Vector2(-2 * s, r.end.y + 11 * s), 2.2 * s, BUBBLE_BG)
	# waiting: still dots; seen: a slow pulse; working: quick typing dots.
	var speed := {"waiting": 0.0, "seen": 0.8, "working": 2.6}.get(turn_state, 0.0) as float
	for i in 3:
		var a := 0.3
		if speed > 0.0:
			var ph := fmod(t * speed - i * 0.25, 1.0)
			a = 0.35 + 0.65 * (1.0 - absf(ph * 2.0 - 1.0))
		overlay.draw_circle(r.get_center() + Vector2((i - 1) * 12 * s, 0), 3.6 * s, Color(HeroArt.INK, a))


func _draw_bubble(anchor: Vector2, now: float) -> void:
	var fs := roundi(15 * text_scale)
	var max_w := 270.0 * text_scale
	var size := font.get_multiline_string_size(bubble_text, HORIZONTAL_ALIGNMENT_LEFT, max_w, fs, 3)
	var pad := Vector2(12, 9)
	var w := size.x + pad.x * 2
	var h := size.y + pad.y * 2
	var fade := clampf(minf((now - bubble_start) / 0.15, (bubble_until - now) / 0.4), 0.0, 1.0)
	var x := -w / 2.0
	# Keep the bubble inside the visible room horizontally.
	var view := get_viewport_rect().size
	var gx := overlay.get_global_transform_with_canvas().origin.x
	x = clampf(x, -gx + 6.0, view.x - gx - w - 6.0)
	var r := Rect2(Vector2(x, anchor.y - h - 12), Vector2(w, h))
	# Never let the bubble leave the top of the window.
	var gy := overlay.get_global_transform_with_canvas().origin.y
	var push := maxf(0.0, 4.0 - (gy + r.position.y))
	r.position.y += push
	anchor.y = maxf(anchor.y, r.end.y + 4.0)
	bubble_box.bg_color = Color(BUBBLE_BG, fade)
	bubble_box.border_color = Color(BUBBLE_EDGE, fade)
	bubble_box.shadow_color = Color(0, 0, 0, 0.35 * fade)
	var tail := PackedVector2Array([Vector2(-9, r.end.y - 2), Vector2(9, r.end.y - 2), Vector2(0, anchor.y)])
	overlay.draw_style_box(bubble_box, r)
	overlay.draw_colored_polygon(tail, bubble_box.bg_color)
	overlay.draw_line(tail[1], tail[2], bubble_box.border_color, 2.0)
	overlay.draw_line(tail[0], tail[2], bubble_box.border_color, 2.0)
	overlay.draw_multiline_string(font, r.position + pad + Vector2(0, font.get_ascent(fs)), bubble_text, HORIZONTAL_ALIGNMENT_LEFT, max_w, fs, 3, Color(HeroArt.INK, fade))
