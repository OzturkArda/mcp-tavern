class_name TavernView
extends Control
## The room: everyone in the chat sits around the table as a fantasy character.

signal hero_clicked(member_name: String, button: int)

const DESIGN := Vector2(1280, 510)
const HEADROOM := 40.0  # space above the ceiling beam for speech bubbles
const TABLE_C := Vector2(640, 330)
const TABLE_R := Vector2(420, 84)

var world: Node2D
var room: Node2D
var heroes_root: Node2D
var table: Node2D
var lights: Node2D
var shade: Node2D
var heroes := {}  # member id -> HeroNode
var my_id := ""
var t := 0.0
var x0 := 0.0
var x1 := DESIGN.x
var font: Font
var serif: Font
var glow_tex: GradientTexture2D
var vignette_tex: GradientTexture2D
var hovered: HeroNode = null
var _bubble_seq := 0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	font = get_theme_default_font()
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray(["Palatino", "Book Antiqua", "Georgia", "serif"])
	sf.font_weight = 600
	serif = sf
	glow_tex = _radial([Color(1, 1, 1, 1), Color(1, 1, 1, 0.35), Color(1, 1, 1, 0)], [0.0, 0.35, 1.0])
	vignette_tex = _radial([Color(0, 0, 0, 0), Color(0, 0, 0, 0.15), Color(0, 0, 0, 0.75)], [0.0, 0.55, 1.0])
	world = Node2D.new()
	add_child(world)
	room = _layer(0, _draw_room)
	heroes_root = Node2D.new()
	heroes_root.z_index = 1
	heroes_root.y_sort_enabled = true
	world.add_child(heroes_root)
	table = _layer(2, _draw_table)
	lights = _layer(8, _draw_lights)
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	lights.material = add
	shade = _layer(9, _draw_shade)


func _layer(z: int, painter: Callable) -> Node2D:
	var n := Node2D.new()
	n.z_index = z
	world.add_child(n)
	n.draw.connect(painter)
	return n


func _radial(colors: Array, offsets: Array) -> GradientTexture2D:
	var g := Gradient.new()
	g.colors = PackedColorArray(colors)
	g.offsets = PackedFloat32Array(offsets)
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	return tex


# ------------------------------------------------------------------ members

func set_members(list: Array, me_id: String) -> void:
	my_id = me_id
	var seen := {}
	for m in list:
		seen[m["id"]] = true
		upsert_member(m)
	for id in heroes.keys():
		if not seen.has(id):
			remove_member(id)
	_layout()


func upsert_member(m: Dictionary) -> void:
	var id: String = m["id"]
	if heroes.has(id):
		heroes[id].update_member(m)
	else:
		var h := HeroNode.new()
		h.setup(m, font, serif)
		h.is_me = id == my_id
		heroes_root.add_child(h)
		heroes[id] = h
		h.position = _entry_point()
		h.scale = Vector2(_hero_scale(heroes.size()), _hero_scale(heroes.size()))
	_layout()


func remove_member(id: String) -> void:
	if not heroes.has(id):
		return
	heroes[id].leave()
	heroes.erase(id)
	_layout()


func touch_member(id: String, at_ms: float) -> void:
	if heroes.has(id):
		heroes[id].member["lastActive"] = at_ms


func on_message(msg: Dictionary) -> void:
	if msg.get("kind", "") != "chat":
		return
	var from = msg.get("from")
	if typeof(from) != TYPE_DICTIONARY or not heroes.has(from["id"]):
		return
	var speaker: HeroNode = heroes[from["id"]]
	var text := String(msg.get("text", ""))
	if msg.get("image") != null:
		text = (text + " [image]").strip_edges()
	speaker.say(text)
	_bubble_seq += 1
	speaker.overlay.z_index = 12 + _bubble_seq % 40
	for h in heroes.values():
		if h != speaker and absf(h.position.x - speaker.position.x) < 300.0:
			h.bubble_until = minf(h.bubble_until, Time.get_ticks_msec() / 1000.0 + 1.2)
	speaker.member["lastActive"] = Time.get_unix_time_from_system() * 1000.0
	for h in heroes.values():
		if h != speaker:
			h.glance_target = clampf((speaker.position.x - h.position.x) / 180.0, -1.0, 1.0)


func _entry_point() -> Vector2:
	return Vector2(x1 - 60, TABLE_C.y - 60)


func _hero_scale(n: int) -> float:
	if n <= 6:
		return 1.0
	if n <= 9:
		return 0.86
	if n <= 12:
		return 0.74
	return 0.62


func _sorted() -> Array:
	var list: Array = heroes.values()
	list.sort_custom(func(a: HeroNode, b: HeroNode) -> bool:
		var ah := 0 if a.member.get("kind") == "human" else 1
		var bh := 0 if b.member.get("kind") == "human" else 1
		if ah != bh:
			return ah < bh
		return float(a.member.get("joinedAt", 0)) < float(b.member.get("joinedAt", 0)))
	return list


func _layout() -> void:
	var list := _sorted()
	var n := list.size()
	if n == 0:
		return
	var hs := _hero_scale(n)
	var a0 := PI + 0.42
	var a1 := TAU - 0.42
	if n > 6:
		a0 = PI + 0.1
		a1 = TAU - 0.1
	for i in n:
		var a := (a0 + a1) / 2.0 if n == 1 else lerpf(a0, a1, float(i) / (n - 1))
		var h: HeroNode = list[i]
		h.target_pos = TABLE_C + Vector2(cos(a) * TABLE_R.x * 0.88, sin(a) * TABLE_R.y * 0.9 - 4)
		h.target_scale = hs


# ------------------------------------------------------------------ frame

func _process(delta: float) -> void:
	t += delta
	var k := size.y / DESIGN.y
	world.scale = Vector2(k, k)
	world.position = Vector2((size.x - DESIGN.x * k) / 2.0, HEADROOM * k)
	x0 = -world.position.x / k
	x1 = x0 + size.x / k
	room.queue_redraw()
	table.queue_redraw()
	lights.queue_redraw()
	shade.queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_hovered(_hero_at(event.position))
	elif event is InputEventMouseButton and event.pressed:
		var h := _hero_at(event.position)
		if h:
			hero_clicked.emit(String(h.member.get("name", "")), event.button_index)
			accept_event()


func _hero_at(local: Vector2) -> HeroNode:
	var wp: Vector2 = world.transform.affine_inverse() * local
	var best: HeroNode = null
	for h in heroes.values():
		if h.hit(wp) and (best == null or h.position.y > best.position.y):
			best = h
	return best


func _set_hovered(h: HeroNode) -> void:
	if hovered == h:
		return
	if is_instance_valid(hovered):
		hovered.hovered = false
	hovered = h
	if h:
		h.hovered = true
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h else Control.CURSOR_ARROW


func _get_tooltip(at: Vector2) -> String:
	var h := _hero_at(at)
	if not h:
		return ""
	var m := h.member
	var who := "you" if m.get("id") == my_id else String(m.get("vendor", ""))
	if who == "claude":
		who = "Claude"
	elif who == "codex":
		who = "Codex"
	var lines := ["%s  (%s)" % [m.get("name", ""), who]]
	if String(m.get("status", "")) != "":
		lines.append(String(m["status"]))
	var idle := int((Time.get_unix_time_from_system() * 1000.0 - float(m.get("lastActive", 0))) / 60000.0)
	lines.append("active just now" if idle < 1 else "last active %d min ago" % idle)
	lines.append("click: @mention   right-click: change look")
	return "\n".join(lines)


# ------------------------------------------------------------------ painting

func _hash01(a: int, b: int) -> float:
	return float(hash(Vector2i(a, b)) % 1000) / 1000.0


func _draw_room() -> void:
	var r := room
	var w := x1 - x0
	r.draw_rect(Rect2(x0, -HEADROOM - 2, w, HEADROOM + 4), Color("22140b"))
	var b0 := int(floor(x0 / 120.0))
	for i in range(b0, int(ceil(x1 / 120.0)) + 1):
		r.draw_rect(Rect2(i * 120, -HEADROOM - 2, 10, HEADROOM + 4), Color("2e1b10"))
	r.draw_rect(Rect2(x0, 0, w, 300), Color("2b221d"))
	var stone := Color("3a2f28")
	var stone2 := Color("4a3d33")
	for row in 11:
		var y := 24 + row * 20
		var off := 30 if row % 2 else 0
		var c0 := int(floor((x0 - off) / 60.0)) - 1
		var c1 := int(ceil((x1 - off) / 60.0)) + 1
		for col in range(c0, c1):
			var x := col * 60 + off
			r.draw_rect(Rect2(x + 2, y + 2, 56, 17), stone.lerp(stone2, _hash01(col, row)))
	r.draw_rect(Rect2(x0, 232, w, 68), Color("3d2616"))
	r.draw_rect(Rect2(x0, 228, w, 8), Color("5a3820"))
	var p0 := int(floor(x0 / 90.0))
	for i in range(p0, int(ceil(x1 / 90.0)) + 1):
		r.draw_rect(Rect2(i * 90 + 8, 244, 74, 46), Color("442a18"))
	r.draw_rect(Rect2(x0, 300, w, DESIGN.y - HEADROOM - 300 + 2), Color("4a2e1b"))
	for row in 8:
		var y := 300 + row * 22
		r.draw_line(Vector2(x0, y), Vector2(x1, y), Color("3a2314"), 2.0)
		var off := (row * 137) % 160
		var s0 := int(floor((x0 - off) / 160.0))
		for i in range(s0, int(ceil((x1 - off) / 160.0)) + 1):
			r.draw_line(Vector2(i * 160 + off, y), Vector2(i * 160 + off, y + 22), Color("3a2314"), 2.0)
	r.draw_rect(Rect2(x0, 0, w, 22), Color("2a170c"))
	r.draw_rect(Rect2(x0, 20, w, 4), Color("1a0e07"))
	for px in [290.0, 990.0]:
		r.draw_rect(Rect2(px - 11, 22, 22, 278), Color("3a2212"))
		r.draw_rect(Rect2(px - 11, 22, 4, 278), Color("4e2f19"))
	_draw_fireplace(r, 130.0)
	_draw_banner(r, 440.0, Color("7a1f24"), 0)
	_draw_banner(r, 840.0, Color("1f5a3a"), 1)
	_draw_shelf(r, 1080.0)
	_draw_barrels(r, 1180.0)
	for lx in [400.0, 640.0, 880.0]:
		_draw_lantern(r, Vector2(lx, 22))
	_draw_cat(r, Vector2(150, 340))


func _draw_fireplace(r: Node2D, cx: float) -> void:
	r.draw_rect(Rect2(cx - 100, 108, 200, 192), Color("5b4f47"))
	for row in 9:
		for col in 5:
			var off := 20 if row % 2 else 0
			var x := cx - 100 + col * 40 + off
			if x + 38 > cx + 100:
				continue
			r.draw_rect(Rect2(x + 1, 110 + row * 21, 38, 19), Color("6b5e55").lerp(Color("5a4d45"), _hash01(col, row + 40)))
	var arch := HeroArt.arc_pts(Vector2(cx, 200), 66, 50, PI, TAU, 16)
	arch.append(Vector2(cx + 66, 300))
	arch.append(Vector2(cx - 66, 300))
	r.draw_colored_polygon(arch, Color("140d0a"))
	r.draw_rect(Rect2(cx - 116, 96, 232, 16), Color("5a3820"))
	r.draw_rect(Rect2(cx - 116, 108, 232, 4), Color("3a2212"))
	r.draw_line(Vector2(cx - 46, 292), Vector2(cx + 40, 282), Color("4a2a14"), 12.0)
	r.draw_line(Vector2(cx - 40, 282), Vector2(cx + 46, 292), Color("5a3418"), 12.0)
	var layers := [[Color("c0391b"), 1.0, 0.0], [Color("f07f1c"), 0.72, 1.3], [Color("ffd166"), 0.42, 2.6]]
	for layer in layers:
		var col: Color = layer[0]
		var sc: float = layer[1]
		var ph: float = layer[2]
		var pts := PackedVector2Array([Vector2(cx - 50 * sc, 288)])
		for i in 7:
			var x := cx - 50 * sc + (i + 0.5) * (100.0 * sc / 7.0)
			var hgt := (60.0 + 26.0 * sin(t * 7.0 + i * 1.9 + ph) + 14.0 * sin(t * 13.0 + i)) * sc * (1.0 - absf(i - 3) * 0.12)
			pts.append(Vector2(x - 5 * sc, 286 - hgt * 0.45))
			pts.append(Vector2(x, 286 - hgt))
		pts.append(Vector2(cx + 50 * sc, 288))
		r.draw_colored_polygon(pts, col)
	for i in 4:
		var ph := fmod(t * 0.7 + i * 0.27, 1.0)
		r.draw_circle(Vector2(cx - 20 + i * 14 + sin(t * 3 + i) * 6, 270 - ph * 120), 1.8 * (1.0 - ph), Color(1.0, 0.7, 0.3, 1.0 - ph))
	_draw_candle(r, Vector2(cx - 80, 96), 0.0)
	_draw_candle(r, Vector2(cx + 84, 96), 1.0)
	r.draw_rect(Rect2(cx - 20, 72, 16, 24), Color("6d2b8c"))
	r.draw_rect(Rect2(cx - 16, 64, 8, 8), Color("6d2b8c"))
	r.draw_rect(Rect2(cx + 4, 80, 26, 16), Color("8a6a3a"))


func _draw_candle(r: CanvasItem, base: Vector2, ph: float) -> void:
	r.draw_rect(Rect2(base + Vector2(-4, -20), Vector2(8, 20)), Color("efe6cf"))
	var fl := 1.0 + 0.15 * sin(t * 11.0 + ph * 5.0)
	HeroArt.fill_ell(r, base + Vector2(0, -27), 3.5 * fl, 7.0 * fl, Color("ffcf5a"))
	HeroArt.fill_ell(r, base + Vector2(0, -25), 1.6, 3.5, Color("fff6d0"))


func _draw_banner(r: Node2D, cx: float, col: Color, emblem: int) -> void:
	var sway := sin(t * 0.8 + cx) * 2.0
	r.draw_line(Vector2(cx - 44, 30), Vector2(cx + 44, 30), Color("6b4128"), 5.0)
	var pts := PackedVector2Array([Vector2(cx - 36, 30), Vector2(cx + 36, 30), Vector2(cx + 36 + sway, 150), Vector2(cx + sway, 132), Vector2(cx - 36 + sway, 150)])
	r.draw_colored_polygon(pts, col)
	r.draw_polyline(PackedVector2Array([pts[0], pts[4], pts[3], pts[2], pts[1]]), Color("c9a227"), 2.0)
	var c := Vector2(cx + sway * 0.6, 80)
	if emblem == 0:
		HeroArt.poly(r, [Vector2(-16, -18), Vector2(16, -18), Vector2(16, 4), Vector2(0, 20), Vector2(-16, 4)], Color("c9a227"), c)
		HeroArt.poly(r, [Vector2(-11, -13), Vector2(11, -13), Vector2(11, 2), Vector2(0, 14), Vector2(-11, 2)], col.darkened(0.2), c)
		r.draw_line(c + Vector2(0, -10), c + Vector2(0, 10), Color("c9a227"), 3.0)
		r.draw_line(c + Vector2(-7, -3), c + Vector2(7, -3), Color("c9a227"), 3.0)
	else:
		r.draw_line(c + Vector2(0, 18), c + Vector2(0, -2), Color("c9a227"), 4.0)
		HeroArt.fill_ell(r, c + Vector2(0, -8), 16, 13, Color("c9a227"))
		HeroArt.fill_ell(r, c + Vector2(0, -8), 11, 8, col.darkened(0.15))


func _draw_shelf(r: Node2D, x: float) -> void:
	var cols := [Color("2e7d32"), Color("6a1b9a"), Color("c77d16"), Color("1565c0"), Color("b71c1c"), Color("00838f")]
	for row in 2:
		var y := 130.0 + row * 62.0
		r.draw_rect(Rect2(x - 10, y, 190, 8), Color("5a3820"))
		r.draw_rect(Rect2(x - 10, y + 8, 190, 3), Color("2a170c"))
		var bx := x
		for i in 7:
			var h := 26.0 + _hash01(i, row) * 20.0
			var bw := 14.0 + _hash01(row, i) * 8.0
			var col: Color = cols[(i + row * 3) % cols.size()]
			if (i + row) % 3 == 2:
				r.draw_rect(Rect2(bx, y - h - 4, bw * 0.8, h + 4), col.darkened(0.35))
				r.draw_rect(Rect2(bx + 2, y - h + 4, bw * 0.8 - 4, 3), Color("c9a227"))
			else:
				r.draw_rect(Rect2(bx, y - h * 0.7, bw, h * 0.7), col)
				r.draw_rect(Rect2(bx + bw * 0.3, y - h, bw * 0.4, h * 0.3), col.darkened(0.2))
				r.draw_rect(Rect2(bx + 2, y - h * 0.6, 3, h * 0.4), Color(1, 1, 1, 0.3))
			bx += bw + 6.0


func _draw_barrels(r: Node2D, cx: float) -> void:
	for i in 2:
		var c := Vector2(cx - 30 + i * 70, 340 + i * 20)
		r.draw_rect(Rect2(c + Vector2(-32, -50), Vector2(64, 90)), Color("6b4128"))
		HeroArt.fill_ell(r, c + Vector2(0, 40), 32, 9, Color("6b4128"))
		HeroArt.fill_ell(r, c + Vector2(0, -50), 32, 9, Color("8a5a34"))
		HeroArt.fill_ell(r, c + Vector2(0, -50), 24, 6, Color("5a3418"))
		for yy in [-34.0, 22.0]:
			r.draw_line(c + Vector2(-32, yy), c + Vector2(32, yy), Color("2f2f33"), 5.0)
		r.draw_rect(Rect2(c + Vector2(10, -50), Vector2(10, 90)), Color(0, 0, 0, 0.15))


func _draw_lantern(r: Node2D, top: Vector2) -> void:
	var sway := sin(t * 0.9 + top.x) * 2.0
	var c := top + Vector2(sway, 46)
	r.draw_line(top, c + Vector2(0, -14), Color("222"), 2.0)
	r.draw_rect(Rect2(c + Vector2(-10, -14), Vector2(20, 4)), Color("222"))
	r.draw_rect(Rect2(c + Vector2(-8, -10), Vector2(16, 20)), Color("ffcf6a"))
	r.draw_rect(Rect2(c + Vector2(-8, -10), Vector2(16, 20)), Color("222"), false, 2.0)
	r.draw_line(c + Vector2(0, -10), c + Vector2(0, 10), Color("222"), 1.5)
	r.draw_rect(Rect2(c + Vector2(-10, 10), Vector2(20, 4)), Color("222"))


func _draw_cat(r: Node2D, c: Vector2) -> void:
	var breathe := 1.0 + 0.04 * sin(t * 1.5)
	HeroArt.fill_ell(r, c + Vector2(0, 6), 34, 6, Color(0, 0, 0, 0.3))
	HeroArt.fill_ell(r, c, 30 * breathe, 14 * breathe, Color("4b4b52"))
	HeroArt.fill_ell(r, c + Vector2(-24, -4), 14, 12, Color("55555c"))
	HeroArt.poly(r, [Vector2(-34, -10), Vector2(-32, -24), Vector2(-26, -14)], Color("55555c"), c)
	HeroArt.poly(r, [Vector2(-22, -14), Vector2(-16, -24), Vector2(-14, -10)], Color("55555c"), c)
	r.draw_line(c + Vector2(-30, -4), c + Vector2(-26, -3), Color("222"), 1.5)
	r.draw_line(c + Vector2(-21, -4), c + Vector2(-17, -3), Color("222"), 1.5)
	r.draw_polyline(HeroArt.arc_pts(c + Vector2(14, 2), 20, 10, -0.3, 1.9, 10), Color("4b4b52"), 6.0)


func _draw_table() -> void:
	var r := table
	var c := TABLE_C
	var rx := TABLE_R.x
	var ry := TABLE_R.y
	var th := 26.0
	HeroArt.fill_ell(r, c + Vector2(0, th + 70), rx * 1.0, ry * 0.75, Color(0, 0, 0, 0.35))
	for lx in [-300.0, -110.0, 110.0, 300.0]:
		r.draw_rect(Rect2(c.x + lx - 13, c.y + 30, 26, DESIGN.y - HEADROOM - c.y - 30), Color("3b2414"))
	var side := HeroArt.arc_pts(c + Vector2(0, th), rx, ry, 0, PI, 40)
	side.append_array(HeroArt.arc_pts(c, rx, ry, PI, 0, 40))
	r.draw_colored_polygon(side, Color("5a3520"))
	r.draw_colored_polygon(HeroArt.ell(c, rx, ry, 72), Color("8a5a34"))
	for yoff in [-52.0, -24.0, 4.0, 32.0, 60.0]:
		var hw := rx * sqrt(maxf(0.0, 1.0 - pow(yoff / ry, 2)))
		r.draw_line(c + Vector2(-hw + 6, yoff), c + Vector2(hw - 6, yoff), Color(0, 0, 0, 0.13), 2.0)
	r.draw_polyline(HeroArt.arc_pts(c, rx, ry, PI, TAU, 48), Color("a8744a"), 3.0)
	r.draw_polyline(HeroArt.arc_pts(c, rx - 3, ry - 2, 0, PI, 48), Color("6b4026"), 2.0)
	# Center pieces: a map, a die and candles.
	var m := c + Vector2(70, 18)
	HeroArt.poly(r, [Vector2(-50, -16), Vector2(46, -22), Vector2(54, 14), Vector2(-44, 20)], Color("e3cf9f"), m)
	r.draw_polyline(PackedVector2Array([m + Vector2(-34, 6), m + Vector2(-12, -6), m + Vector2(8, 4), m + Vector2(32, -10)]), Color("9b2c2c"), 2.0)
	r.draw_circle(m + Vector2(32, -10), 3, Color("9b2c2c"))
	var d := c + Vector2(-120, 30)
	var hexa := PackedVector2Array()
	for i in 6:
		hexa.append(d + Vector2(cos(i * TAU / 6 + PI / 6), sin(i * TAU / 6 + PI / 6)) * 13.0)
	r.draw_colored_polygon(hexa, Color("b3262e"))
	r.draw_polyline(PackedVector2Array([hexa[1], hexa[3], hexa[5], hexa[1]]), Color("7a1a20"), 1.5)
	for i in 3:
		_draw_candle(r, c + Vector2(-46 + i * 26, -6 + (i % 2) * 10), float(i))
	if heroes.is_empty():
		var msg := "The tavern is quiet... waiting for company"
		var fs := 22
		var tw := serif.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		r.draw_string(serif, c + Vector2(-tw / 2.0, -40), msg, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.95, 0.85, 0.85))


func _draw_lights() -> void:
	var l := lights
	var f := 0.85 + 0.15 * sin(t * 9.0) * sin(t * 5.3)
	_glow(l, Vector2(130, 250), 300.0 * f, Color(1.0, 0.45, 0.12, 0.30))
	for lx in [400.0, 640.0, 880.0]:
		_glow(l, Vector2(lx + sin(t * 0.9 + lx) * 2.0, 68), 150.0, Color(1.0, 0.75, 0.35, 0.16))
	_glow(l, TABLE_C + Vector2(-20, -30), 380.0 * (0.95 + 0.05 * sin(t * 7.0)), Color(1.0, 0.7, 0.35, 0.12))


func _glow(ci: CanvasItem, c: Vector2, radius: float, col: Color) -> void:
	ci.draw_texture_rect(glow_tex, Rect2(c - Vector2(radius, radius), Vector2(radius, radius) * 2.0), false, col)


func _draw_shade() -> void:
	var w := x1 - x0
	shade.draw_texture_rect(vignette_tex, Rect2(x0 - w * 0.1, -HEADROOM - DESIGN.y * 0.25, w * 1.2, DESIGN.y * 1.5), false, Color(1, 1, 1, 0.9))
