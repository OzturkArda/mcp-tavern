class_name HubClient
extends Node
## Talks to hub/hub.ts: HTTP for writes, a WebSocket for the live event stream.

signal connection_changed(online: bool)
signal snapshot(members: Array, messages: Array)
signal message_received(message: Dictionary)
signal member_updated(member: Dictionary)
signal member_left(id: String)
signal join_failed(reason: String)

var base_url := "http://127.0.0.1:4777"
var token := ""
var me: Dictionary = {}
var my_name := ""
var _ws := WebSocketPeer.new()
var _online := false
var _retry_at := 0.0
var _ping_at := 0.0
var _joining := false
var _started_hub := false


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Join (or resume) as a human member, starting the hub if nothing answers.
func join(member_name: String, resume_token: String = "") -> void:
	my_name = member_name
	_joining = true
	for attempt in 30:
		var res := await request(HTTPClient.METHOD_POST, "/api/join", {
			"name": member_name, "kind": "human", "client": "tavern-ui", "resume": resume_token,
		})
		if res["ok"]:
			token = res["token"]
			me = res["member"]
			_joining = false
			_open_socket()
			return
		if int(res["status"]) == 0:
			if not _started_hub:
				_started_hub = true
				_start_hub()
			await get_tree().create_timer(0.5).timeout
			continue
		_joining = false
		join_failed.emit(String(res.get("error", "could not join")))
		return
	_joining = false
	join_failed.emit("the hub isn't answering on %s" % base_url)


func _start_hub() -> void:
	var hub := ProjectSettings.globalize_path("res://").path_join("../hub/hub.ts").simplify_path()
	var home := OS.get_environment("HOME")
	for bun in ["/opt/homebrew/bin/bun", "/usr/local/bin/bun", home.path_join(".bun/bin/bun")]:
		if FileAccess.file_exists(bun) and FileAccess.file_exists(hub):
			OS.create_process(bun, [hub])
			return
	push_warning("Couldn't find bun or %s to start the hub" % hub)


func _open_socket() -> void:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 32 * 1024 * 1024
	_ws.outbound_buffer_size = 1024 * 1024
	_ws.max_queued_packets = 8192
	var url := base_url.replace("http://", "ws://") + "/ws?token=" + token.uri_encode()
	if _ws.connect_to_url(url) != OK:
		_retry_at = _now() + 2.0


func _process(_delta: float) -> void:
	if token == "":
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _online:
			_online = true
			connection_changed.emit(true)
		while _ws.get_available_packet_count() > 0:
			var data = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
			if typeof(data) == TYPE_DICTIONARY:
				_handle(data)
		if _now() > _ping_at:
			_ping_at = _now() + 20.0
			_ws.send_text("ping")
	elif state == WebSocketPeer.STATE_CLOSED:
		if _online:
			_online = false
			connection_changed.emit(false)
			_retry_at = _now() + 1.0
		if not _joining and _now() >= _retry_at:
			_retry_at = _now() + 3.0
			# Resume our membership, or rejoin if the hub restarted and forgot us.
			join(my_name, token)


func _handle(ev: Dictionary) -> void:
	match String(ev.get("type", "")):
		"snapshot":
			if ev.get("you") == null:
				# Our token is stale (hub restarted): rejoin under the same name.
				_ws.close()
				token = ""
				join(my_name)
				return
			me = ev["you"]
			snapshot.emit(ev.get("members", []), ev.get("messages", []))
		"message":
			message_received.emit(ev["message"])
		"member":
			if ev["member"]["id"] == me.get("id"):
				me = ev["member"]
			member_updated.emit(ev["member"])
		"left":
			member_left.emit(String(ev["id"]))


func send_message(text: String, image_file: String = "") -> Dictionary:
	var body := {"text": text}
	if image_file != "":
		body["image"] = image_file
	return await request(HTTPClient.METHOD_POST, "/api/messages", body)


## Uploads raw image bytes; returns the stored file name or "" on failure.
func upload_image(bytes: PackedByteArray) -> Dictionary:
	return await request(HTTPClient.METHOD_POST, "/api/images", null, bytes)


func set_look(member_name: String, look: String) -> void:
	await request(HTTPClient.METHOD_POST, "/api/look", {"name": member_name, "look": look})


func request(method: int, path: String, body = null, raw: PackedByteArray = PackedByteArray()) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = 30.0
	add_child(http)
	var headers := PackedStringArray()
	if token != "":
		headers.append("Authorization: Bearer " + token)
	var err: int
	if raw.size() > 0:
		headers.append("Content-Type: application/octet-stream")
		err = http.request_raw(base_url + path, headers, method, raw)
	else:
		headers.append("Content-Type: application/json")
		err = http.request(base_url + path, headers, method, "" if body == null else JSON.stringify(body))
	if err != OK:
		http.queue_free()
		return {"ok": false, "status": 0, "error": "request failed"}
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": 0, "error": "hub unreachable"}
	var code := int(res[1])
	var bytes: PackedByteArray = res[3]
	var data = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		data = {}
	data["ok"] = code >= 200 and code < 300
	data["status"] = code
	return data


func fetch_bytes(path: String) -> PackedByteArray:
	var http := HTTPRequest.new()
	http.timeout = 30.0
	add_child(http)
	if http.request(base_url + path) != OK:
		http.queue_free()
		return PackedByteArray()
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS or int(res[1]) != 200:
		return PackedByteArray()
	return res[3]
