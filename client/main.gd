extends Control
## MCP Tavern client: the tavern scene on top, the chat underneath.
## Command-line (after `--`): --name=<you> --hub=<url> --text-scale=<x>
##   --screenshot=<png path> --wait=<s>

const CFG_PATH := "user://tavern.cfg"
const MAX_LOG := 300
const MAX_UPLOAD := 15 * 1024 * 1024
const BG := Color("17110d")
const PANEL := Color("1f1711")
const FIELD := Color("2a2019")
const EDGE := Color("5c4329")
const TEXT := Color("eadfc8")
const DIM := Color("8f7f68")
const GOLD := Color("f2c94c")
const BASE_FONT := 15
const MAX_CHAT_WIDTH := 1100.0

var hub: HubClient
var tavern: TavernView
var log_view: RichTextLabel
var input: TextEdit
var send_btn: Button
var attach_btn: Button
var attach_row: HBoxContainer
var attach_thumb: TextureRect
var attach_label: Label
var status_label: Label
var viewer: Control
var viewer_tex: TextureRect
var name_layer: Control
var name_edit: LineEdit
var name_error: Label
var file_dialog: FileDialog
var chat_margin: MarginContainer
var fullscreen_btn: Button

var messages: Array = []
var members := {}
var textures := {}
var loading := {}
var log_dirty := false
var pending_image := PackedByteArray()
var sending := false
var cfg := ConfigFile.new()
var args := {}
var text_scale := 1.0
var _window_state := ""
var _window_check_at := 0.0
var _last_from := ""
var _last_ts := 0
var _re_codeblock := RegEx.create_from_string("```(?:[A-Za-z0-9_+\\-]*\\n)?([\\s\\S]*?)```")
var _re_code := RegEx.create_from_string("`([^`\\n]+)`")
var _re_bold := RegEx.create_from_string("\\*\\*([^*\\n]+)\\*\\*")
var _re_url := RegEx.create_from_string("(https?://[^\\s\\[\\]]+)")
var _re_mention := RegEx.create_from_string("(?<![\\w/])@([A-Za-z0-9_\\-]+(?:\\.[A-Za-z0-9_\\-]+)*)")


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := String(a).trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else "true"
	get_window().title = "MCP Tavern"
	cfg.load(CFG_PATH)
	text_scale = float(args.get("text-scale", cfg.get_value("ui", "text_scale", 1.0)))
	theme = _make_theme()
	_build_ui()
	_setup_window()
	_apply_text_scale()
	resized.connect(_fit_chat_width)
	hub = HubClient.new()
	add_child(hub)
	if args.has("hub"):
		hub.base_url = String(args["hub"])
	hub.connection_changed.connect(_on_connection)
	hub.snapshot.connect(_on_snapshot)
	hub.message_received.connect(_on_message)
	hub.member_updated.connect(_on_member)
	hub.member_left.connect(_on_left)
	hub.join_failed.connect(_on_join_failed)
	hub.claims_changed.connect(func(list: Array) -> void: tavern.set_claims(list))
	get_window().files_dropped.connect(_on_files_dropped)
	var saved := String(args.get("name", cfg.get_value("user", "name", "")))
	if saved != "":
		_join(saved)
	else:
		_ask_name("")
	if args.has("screenshot"):
		_take_screenshot(String(args["screenshot"]), float(args.get("wait", "4")))


# ------------------------------------------------------------------ UI

func _box(bg: Color, border: Color = Color.TRANSPARENT, radius: int = 6, margin: float = 8.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	if border.a > 0:
		sb.border_color = border
		sb.set_border_width_all(1)
	return sb


func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font_size = 15
	th.set_color("font_color", "Label", TEXT)
	th.set_color("default_color", "RichTextLabel", TEXT)
	th.set_stylebox("normal", "RichTextLabel", _box(Color.TRANSPARENT, Color.TRANSPARENT, 0, 2))
	th.set_stylebox("panel", "PanelContainer", _box(PANEL, Color.TRANSPARENT, 0, 0))
	for cls in ["TextEdit", "LineEdit"]:
		th.set_stylebox("normal", cls, _box(FIELD, EDGE, 8, 10))
		th.set_stylebox("focus", cls, _box(FIELD, GOLD.darkened(0.3), 8, 10))
		th.set_color("font_color", cls, TEXT)
		th.set_color("font_placeholder_color", cls, DIM)
		th.set_color("caret_color", cls, GOLD)
	th.set_color("background_color", "TextEdit", FIELD)
	th.set_stylebox("normal", "Button", _box(Color("4a3020"), EDGE, 8, 10))
	th.set_stylebox("hover", "Button", _box(Color("5c3c27"), GOLD.darkened(0.4), 8, 10))
	th.set_stylebox("pressed", "Button", _box(Color("3a2416"), GOLD.darkened(0.4), 8, 10))
	th.set_stylebox("disabled", "Button", _box(Color("2e221a"), EDGE, 8, 10))
	th.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	th.set_color("font_color", "Button", TEXT)
	th.set_color("font_hover_color", "Button", GOLD)
	th.set_stylebox("panel", "TooltipPanel", _box(Color(0.1, 0.07, 0.05, 0.95), EDGE, 6, 8))
	th.set_color("font_color", "TooltipLabel", TEXT)
	return th


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	tavern = TavernView.new()
	tavern.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tavern.size_flags_stretch_ratio = 1.15
	tavern.hero_clicked.connect(_on_hero_clicked)
	root.add_child(tavern)
	status_label = Label.new()
	status_label.position = Vector2(14, 8)
	status_label.z_index = 20
	status_label.add_theme_font_size_override("font_size", 13)
	status_label.add_theme_color_override("font_color", Color(1, 0.93, 0.8, 0.8))
	status_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	tavern.add_child(status_label)
	_build_toolbar()

	var beam := ColorRect.new()
	beam.color = Color("2a170c")
	beam.custom_minimum_size = Vector2(0, 6)
	root.add_child(beam)

	var chat := PanelContainer.new()
	chat.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(chat)
	var margin := MarginContainer.new()
	chat_margin = margin
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 12)
	chat.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	log_view = RichTextLabel.new()
	log_view.bbcode_enabled = true
	log_view.scroll_following = true
	log_view.selection_enabled = true
	log_view.context_menu_enabled = true
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.add_theme_constant_override("line_separation", 3)
	log_view.add_theme_font_size_override("mono_font_size", 14)
	log_view.meta_clicked.connect(_on_meta)
	col.add_child(log_view)

	attach_row = HBoxContainer.new()
	attach_row.visible = false
	attach_row.add_theme_constant_override("separation", 10)
	attach_thumb = TextureRect.new()
	attach_thumb.custom_minimum_size = Vector2(56, 40)
	attach_thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	attach_thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	attach_row.add_child(attach_thumb)
	attach_label = Label.new()
	attach_label.add_theme_color_override("font_color", DIM)
	attach_row.add_child(attach_label)
	var remove := Button.new()
	remove.text = "Remove"
	remove.pressed.connect(_clear_attachment)
	attach_row.add_child(remove)
	col.add_child(attach_row)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	attach_btn = Button.new()
	attach_btn.text = "+ Image"
	attach_btn.tooltip_text = "Attach an image (you can also paste or drop one)"
	attach_btn.pressed.connect(_pick_file)
	row.add_child(attach_btn)
	input = TextEdit.new()
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size = Vector2(0, 46)
	input.placeholder_text = "Say something to the table...   (Enter sends, Shift+Enter for a new line, paste or drop images)"
	input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	input.scroll_fit_content_height = true
	input.gui_input.connect(_on_input_key)
	row.add_child(input)
	send_btn = Button.new()
	send_btn.text = "Send"
	send_btn.custom_minimum_size = Vector2(84, 0)
	send_btn.pressed.connect(_send)
	row.add_child(send_btn)

	file_dialog = FileDialog.new()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.use_native_dialog = true
	file_dialog.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp, *.gif ; Images"])
	file_dialog.file_selected.connect(_attach_file)
	add_child(file_dialog)

	_build_viewer()
	_build_name_prompt()


func _build_toolbar() -> void:
	var bar := HBoxContainer.new()
	bar.z_index = 20
	bar.add_theme_constant_override("separation", 6)
	tavern.add_child(bar)
	bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	bar.offset_left = -12
	bar.offset_right = -12
	bar.offset_top = 6
	var small := _box(Color(0.1, 0.06, 0.04, 0.75), EDGE, 6, 6)
	small.content_margin_top = 2
	small.content_margin_bottom = 2
	var specs := [
		["A-", "Smaller text  (Cmd -)", func() -> void: _set_text_scale(text_scale - 0.1)],
		["A+", "Larger text  (Cmd +)", func() -> void: _set_text_scale(text_scale + 0.1)],
		["Full screen", "Toggle full screen  (Ctrl Cmd F or F11)", _toggle_fullscreen],
	]
	for spec in specs:
		var b := Button.new()
		b.text = spec[0]
		b.tooltip_text = spec[1]
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_stylebox_override("normal", small)
		b.pressed.connect(spec[2])
		bar.add_child(b)
		if spec[0] == "Full screen":
			fullscreen_btn = b


# ------------------------------------------------------------------ window & text size

func _setup_window() -> void:
	var win := get_window()
	var screen := DisplayServer.window_get_current_screen()
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var dpi := DisplayServer.screen_get_scale(screen)
	win.min_size = Vector2i(Vector2(720, 520) * dpi)
	var saved_size: Vector2i = cfg.get_value("window", "size", Vector2i.ZERO)
	var saved_pos: Vector2i = cfg.get_value("window", "position", Vector2i.ZERO)
	if saved_size.x > 0 and _on_some_screen(saved_pos):
		win.size = saved_size
		win.position = saved_pos
	else:
		var h := int(usable.size.y * 0.82)
		var w := mini(int(usable.size.x * 0.75), int(h * 1.6))
		win.size = Vector2i(w, h)
		win.position = usable.position + (usable.size - win.size) / 2
	if cfg.get_value("window", "fullscreen", false):
		_set_fullscreen(true)
	_window_state = _describe_window()


func _on_some_screen(pos: Vector2i) -> bool:
	for i in DisplayServer.get_screen_count():
		if DisplayServer.screen_get_usable_rect(i).has_point(pos + Vector2i(40, 40)):
			return true
	return false


func _is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


func _toggle_fullscreen() -> void:
	_set_fullscreen(not _is_fullscreen())


func _set_fullscreen(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)


func _describe_window() -> String:
	var win := get_window()
	return "%s|%s|%s" % [_is_fullscreen(), win.size, win.position]


## Remembers size, position and full screen across launches.
func _track_window() -> void:
	if args.has("screenshot"):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _window_check_at:
		return
	_window_check_at = now + 1.0
	fullscreen_btn.text = "Exit full screen" if _is_fullscreen() else "Full screen"
	var state := _describe_window()
	if state == _window_state:
		return
	_window_state = state
	cfg.set_value("window", "fullscreen", _is_fullscreen())
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED:
		cfg.set_value("window", "size", get_window().size)
		cfg.set_value("window", "position", get_window().position)
	cfg.save(CFG_PATH)


func _set_text_scale(value: float) -> void:
	text_scale = clampf(snappedf(value, 0.05), 0.7, 2.5)
	if not args.has("screenshot"):
		cfg.set_value("ui", "text_scale", text_scale)
		cfg.save(CFG_PATH)
	_apply_text_scale()
	_flash("Text size %d%%" % roundi(text_scale * 100))


func _apply_text_scale() -> void:
	theme.default_font_size = roundi(BASE_FONT * text_scale)
	log_view.add_theme_font_size_override("mono_font_size", roundi(14 * text_scale))
	input.custom_minimum_size.y = roundi(46 * text_scale)
	HeroNode.text_scale = text_scale
	_fit_chat_width()
	log_dirty = true


func _fs(base: int) -> int:
	return roundi(base * text_scale)


## Keeps chat lines a readable length on wide windows.
func _fit_chat_width() -> void:
	if not chat_margin:
		return
	var side := maxi(16, int((size.x - MAX_CHAT_WIDTH * text_scale) / 2.0))
	chat_margin.add_theme_constant_override("margin_left", side)
	chat_margin.add_theme_constant_override("margin_right", side)


func _input(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed):
		return
	var k := e as InputEventKey
	if k.keycode == KEY_F11 or (k.keycode == KEY_F and k.ctrl_pressed and k.meta_pressed):
		if not k.echo:
			_toggle_fullscreen()
		get_viewport().set_input_as_handled()
		return
	if not k.is_command_or_control_pressed():
		return
	match k.keycode:
		KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
			_set_text_scale(text_scale + 0.1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_set_text_scale(text_scale - 0.1)
		KEY_0, KEY_KP_0:
			_set_text_scale(1.0)
		_:
			return
	get_viewport().set_input_as_handled()


func _build_viewer() -> void:
	viewer = Control.new()
	viewer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer.z_index = 100
	viewer.visible = false
	viewer.mouse_filter = Control.MOUSE_FILTER_STOP
	viewer.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed:
			viewer.visible = false)
	add_child(viewer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.88)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewer.add_child(dim)
	viewer_tex = TextureRect.new()
	viewer_tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewer_tex.offset_left = 40
	viewer_tex.offset_top = 40
	viewer_tex.offset_right = -40
	viewer_tex.offset_bottom = -40
	viewer_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	viewer_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	viewer_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewer.add_child(viewer_tex)


func _build_name_prompt() -> void:
	name_layer = Control.new()
	name_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_layer.z_index = 110
	name_layer.visible = false
	add_child(name_layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	name_layer.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color("2a1e15"), GOLD.darkened(0.45), 10, 22))
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(380, 0)
	panel.add_child(col)
	var title := Label.new()
	title.text = "What should the table call you?"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_font_override("font", tavern.serif)
	col.add_child(title)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Your name"
	name_edit.max_length = 32
	name_edit.text_submitted.connect(func(_t: String) -> void: _submit_name())
	col.add_child(name_edit)
	name_error = Label.new()
	name_error.add_theme_color_override("font_color", Color("ff8a80"))
	name_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(name_error)
	var go := Button.new()
	go.text = "Take a seat"
	go.pressed.connect(_submit_name)
	col.add_child(go)


# ------------------------------------------------------------------ joining

func _ask_name(error: String) -> void:
	name_layer.visible = true
	name_error.text = error
	name_error.visible = error != ""
	if name_edit.text == "":
		name_edit.text = String(cfg.get_value("user", "name", OS.get_environment("USER").capitalize().replace(" ", "")))
	name_edit.grab_focus()
	name_edit.select_all()


func _submit_name() -> void:
	var n := name_edit.text.strip_edges().replace(" ", "-")
	if not RegEx.create_from_string("^[A-Za-z0-9_.\\-]{1,32}$").search(n):
		_ask_name("Use 1-32 letters, digits, _ . or -")
		return
	name_layer.visible = false
	cfg.set_value("user", "name", n)
	cfg.save(CFG_PATH)
	_join(n)


func _join(n: String) -> void:
	status_label.text = "Connecting as %s..." % n
	await hub.join(n, String(cfg.get_value("user", "token", "")))
	if hub.token != "" and not args.has("screenshot"):
		cfg.set_value("user", "token", hub.token)
		cfg.save(CFG_PATH)


func _on_join_failed(reason: String) -> void:
	status_label.text = "Not connected"
	_ask_name("Couldn't join: %s" % reason)


func _on_connection(online: bool) -> void:
	if online:
		status_label.text = "Seated as %s" % hub.my_name
	else:
		status_label.text = "Lost the connection, reconnecting..."


# ------------------------------------------------------------------ events

func _on_snapshot(list: Array, history: Array) -> void:
	members.clear()
	for m in list:
		members[m["id"]] = m
	tavern.set_members(list, String(hub.me.get("id", "")))
	messages = history
	log_dirty = true


func _on_message(m: Dictionary) -> void:
	messages.append(m)
	if messages.size() > MAX_LOG * 2:
		messages = messages.slice(messages.size() - MAX_LOG)
	if not log_dirty:
		_append(m)
	tavern.on_message(m)
	var mentions: Array = m.get("mentions", [])
	if m.get("kind") == "chat" and (hub.my_name in mentions or "all" in mentions):
		if not get_window().has_focus():
			DisplayServer.window_request_attention()


func _on_member(m: Dictionary) -> void:
	var known := members.has(m["id"])
	var look_changed: bool = known and members[m["id"]].get("look") != m.get("look")
	members[m["id"]] = m
	tavern.upsert_member(m)
	if look_changed:
		log_dirty = true


func _on_left(id: String) -> void:
	members.erase(id)
	tavern.remove_member(id)


func _on_hero_clicked(member_name: String, button: int) -> void:
	if button == MOUSE_BUTTON_LEFT:
		if member_name != hub.my_name:
			input.insert_text_at_caret("@%s " % member_name)
		input.grab_focus()
	elif button == MOUSE_BUTTON_RIGHT:
		var looks: Array = HeroArt.STYLES.keys()
		for m in members.values():
			if m["name"] == member_name:
				var i := looks.find(m.get("look", ""))
				hub.set_look(member_name, looks[(i + 1) % looks.size()])


# ------------------------------------------------------------------ chat log

func _process(_delta: float) -> void:
	_track_window()
	if log_dirty:
		log_dirty = false
		_render_log()


func _render_log() -> void:
	log_view.clear()
	_last_from = ""
	_last_ts = 0
	for i in range(maxi(0, messages.size() - MAX_LOG), messages.size()):
		_append(messages[i])


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _format(text: String) -> String:
	var s := _esc(text)
	s = _re_codeblock.sub(s, "[bgcolor=#2b2019][code]$1[/code][/bgcolor]", true)
	s = _re_code.sub(s, "[bgcolor=#2b2019][color=#f0c674][code]$1[/code][/color][/bgcolor]", true)
	s = _re_bold.sub(s, "[b]$1[/b]", true)
	s = _re_url.sub(s, "[url]$1[/url]", true)
	s = _re_mention.sub(s, "[color=#ffd43b][b]@$1[/b][/color]", true)
	return s


func _unix(ts: String) -> int:
	return Time.get_unix_time_from_datetime_string(ts.substr(0, 19))


func _clock(unix: int) -> String:
	var local := unix + int(Time.get_time_zone_from_system()["bias"]) * 60
	var d := Time.get_datetime_dict_from_unix_time(local)
	return "%02d:%02d" % [d["hour"], d["minute"]]


func _append(m: Dictionary) -> void:
	var from = m.get("from")
	if m.get("kind") == "system":
		var who := _esc(String(from["name"])) if typeof(from) == TYPE_DICTIONARY else "someone"
		var line := ""
		match String(m.get("event", "")):
			"join":
				line = "%s pulls up a chair" % who
			"leave":
				line = "%s heads out into the night" % who
			_:
				line = _esc(String(m.get("text", ""))).replace(" claimed ", " takes the key to ").replace(" released ", " hands back the key to ")
		log_view.append_text("[center][color=#7d6d57][i]~ %s ~[/i][/color][/center]\n" % line)
		_last_from = ""
		return
	if typeof(from) != TYPE_DICTIONARY:
		return
	var ts := _unix(String(m.get("ts", "")))
	var fid := String(from["id"])
	if fid != _last_from or ts - _last_ts > 180:
		var current: Dictionary = members.get(fid, from)
		var col := HeroArt.label_color(String(current.get("look", from.get("look", ""))))
		var tag := String(from.get("vendor", ""))
		match tag:
			"claude":
				tag = "Claude"
			"codex":
				tag = "Codex"
			"human":
				tag = "you" if fid == String(hub.me.get("id", "")) else "human"
		if _last_from != "" or log_view.get_paragraph_count() > 1:
			log_view.append_text("[font_size=%d] [/font_size]\n" % _fs(6))
		log_view.append_text("[color=#%s][b]%s[/b][/color]  [color=#6f604d][font_size=%d]%s · %s[/font_size][/color]\n" % [col.to_html(false), _esc(String(from["name"])), _fs(12), tag, _clock(ts)])
	_last_from = fid
	_last_ts = ts
	var text := String(m.get("text", ""))
	var mentions: Array = m.get("mentions", [])
	if text != "":
		var body := _format(text)
		if hub.my_name in mentions:
			body = "[bgcolor=#3a2a12]%s[/bgcolor]" % body
		log_view.append_text(body + "\n")
	var image = m.get("image")
	if typeof(image) == TYPE_DICTIONARY:
		var file := String(image["file"])
		if textures.has(file) and textures[file] != null:
			var tex: Texture2D = textures[file]
			var scale := minf(1.0, minf(360.0 * text_scale / tex.get_width(), 240.0 * text_scale / tex.get_height()))
			log_view.push_meta("img:" + file)
			log_view.add_image(tex, int(tex.get_width() * scale), int(tex.get_height() * scale))
			log_view.pop()
			log_view.append_text("\n")
		elif textures.has(file):
			log_view.push_meta("file:" + String(image.get("path", "")))
			log_view.append_text("[color=#8f7f68][i][u](image: %s - click to open)[/u][/i][/color]" % _esc(file))
			log_view.pop()
			log_view.append_text("\n")
		else:
			log_view.append_text("[color=#6f604d][i](loading image...)[/i][/color]\n")
			_load_image(file, String(image.get("url", "/images/" + file)))


func _load_image(file: String, url: String) -> void:
	if textures.has(file) or loading.has(file):
		return
	loading[file] = true
	var bytes := await hub.fetch_bytes(url)
	var img := _image_from_bytes(bytes)
	textures[file] = ImageTexture.create_from_image(img) if img else null
	loading.erase(file)
	log_dirty = true


func _image_from_bytes(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes[0] == 0x52 and bytes[8] == 0x57:
		err = img.load_webp_from_buffer(bytes)
	return img if err == OK else null


func _on_meta(meta: Variant) -> void:
	var s := String(meta)
	if s.begins_with("img:"):
		var tex = textures.get(s.substr(4))
		if tex:
			viewer_tex.texture = tex
			viewer.visible = true
	elif s.begins_with("file:"):
		OS.shell_open(s.substr(5))
	else:
		OS.shell_open(s)


# ------------------------------------------------------------------ sending

func _on_input_key(e: InputEvent) -> void:
	if not (e is InputEventKey and e.pressed):
		return
	var k := e as InputEventKey
	if (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER) and not k.shift_pressed:
		input.accept_event()
		_send()
	elif k.keycode == KEY_V and (k.meta_pressed or k.ctrl_pressed) and DisplayServer.clipboard_has_image():
		var img := DisplayServer.clipboard_get_image()
		if img:
			input.accept_event()
			_attach_bytes(img.save_png_to_buffer(), "pasted image", img)


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE and viewer.visible:
		viewer.visible = false


func _pick_file() -> void:
	file_dialog.popup_centered_ratio(0.6)


func _on_files_dropped(files: PackedStringArray) -> void:
	if files.size() > 0:
		_attach_file(files[0])


func _attach_file(path: String) -> void:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		_flash("Couldn't read %s" % path.get_file())
		return
	_attach_bytes(bytes, path.get_file(), _image_from_bytes(bytes))


func _attach_bytes(bytes: PackedByteArray, label: String, preview: Image) -> void:
	if bytes.size() > MAX_UPLOAD:
		_flash("Images must be under 15 MB")
		return
	pending_image = bytes
	attach_label.text = label
	attach_thumb.texture = ImageTexture.create_from_image(preview) if preview else null
	attach_row.visible = true
	input.grab_focus()


func _clear_attachment() -> void:
	pending_image = PackedByteArray()
	attach_row.visible = false
	attach_thumb.texture = null


func _flash(text: String) -> void:
	status_label.text = text
	get_tree().create_timer(4.0).timeout.connect(func() -> void:
		if status_label.text == text:
			status_label.text = "Seated as %s" % hub.my_name if hub.token != "" else "")


func _send() -> void:
	if sending:
		return
	var text := input.text.strip_edges()
	if text == "" and pending_image.is_empty():
		return
	if hub.token == "":
		_flash("Not connected yet")
		return
	sending = true
	send_btn.disabled = true
	var image_file := ""
	if not pending_image.is_empty():
		var up := await hub.upload_image(pending_image)
		if not up["ok"]:
			_flash("Upload failed: %s" % up.get("error", "unknown error"))
			sending = false
			send_btn.disabled = false
			return
		image_file = String(up["image"]["file"])
	var res := await hub.send_message(text, image_file)
	sending = false
	send_btn.disabled = false
	if res["ok"]:
		input.text = ""
		_clear_attachment()
	else:
		_flash("Couldn't send: %s" % res.get("error", "unknown error"))


# ------------------------------------------------------------------ testing aid

func _take_screenshot(path: String, wait: float) -> void:
	if args.has("click"):
		await get_tree().create_timer(maxf(0.0, wait - 1.5)).timeout
		var cxy := String(args["click"]).split(",")
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = pressed
			click.position = Vector2(float(cxy[0]), float(cxy[1]))
			click.global_position = click.position
			Input.parse_input_event(click)
	if args.has("hover"):
		await get_tree().create_timer(maxf(0.0, wait - 1.0)).timeout
		var xy := String(args["hover"]).split(",")
		var ev := InputEventMouseMotion.new()
		ev.position = Vector2(float(xy[0]), float(xy[1]))
		ev.global_position = ev.position
		Input.parse_input_event(ev)
		await get_tree().create_timer(1.0).timeout
	else:
		await get_tree().create_timer(wait).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()
