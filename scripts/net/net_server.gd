extends Node
## NetServer — the M3 transport: a real RFC 6455 WebSocket server built on
## TCPServer + WebSocketPeer.accept_stream (NOT WebSocketMultiplayerPeer, so
## the browser's plain `new WebSocket()` can talk to it), plus a tiny static
## HTTP host for the phone PWA on an adjacent port. Zero external runtimes:
## a phone opens http://<LAN-IP>:8788 and plays.
##
## Responsibilities:
##  - seats: a JOIN command claims a seat (or resumes it with the token saved
##    in the phone's localStorage) and returns a rotated reconnect_token;
##  - identity: the seat, not the message, decides player_id. A client cannot
##    act for another seat even if it forges the field;
##  - delivery: per-viewer STATE_SNAPSHOT (each phone gets its own hand and
##    only counts for the others), targeted requests/death prompts, filtered
##    domain events;
##  - reconnect: a dropped phone reconnects with its token and immediately
##    receives the snapshot PLUS the request it still owes an answer to.
##
## The engine and the rules are untouched: this node only moves protocol
## dictionaries between MatchSession and the sockets.

const Protocol := preload("res://scripts/core/match_protocol.gd")

signal log_line(text: String)
signal seats_changed()

const WEB_ROOT := "res://web_client/"
const SEATS_PATH := "user://seats.json"
const DEFAULT_WS_PORT := 8787
const DEFAULT_HTTP_PORT := 8788
const MAX_HTTP_HEADER := 8192

const MIME := {
	"html": "text/html; charset=utf-8",
	"js": "text/javascript; charset=utf-8",
	"css": "text/css; charset=utf-8",
	"json": "application/json; charset=utf-8",
	"webmanifest": "application/manifest+json",
	"svg": "image/svg+xml",
	"png": "image/png",
	"ico": "image/x-icon",
	"txt": "text/plain; charset=utf-8",
}

## One connected phone (or the tablet/simulator in the network test).
class Client:
	var peer: WebSocketPeer
	var player_id: int = -1
	var joined: bool = false
	var connected: bool = true

	func _init(p_peer: WebSocketPeer) -> void:
		peer = p_peer

var session = null
var ws_server := TCPServer.new()
var http_server := TCPServer.new()
var ws_port: int = 0
var http_port: int = 0
var clients: Array = []            # Array[Client]
## player_id -> {token: String, connected: bool}
var seats: Dictionary = {}
var _http_pending: Array = []      # [{tcp, buffer: PackedByteArray}]

# --- Lifecycle ----------------------------------------------------------------

func configure(p_session) -> void:
	session = p_session
	if not session.changed.is_connected(_on_session_changed):
		session.changed.connect(_on_session_changed)
	if not session.message.is_connected(_on_session_message):
		session.message.connect(_on_session_message)

## `desired_*` of 0 asks the OS for a free port (used by the network test).
func start(desired_ws: int = DEFAULT_WS_PORT, desired_http: int = DEFAULT_HTTP_PORT) -> bool:
	if session == null:
		Log.error("NetServer: configure() a session before start()")
		return false
	if ws_server.listen(desired_ws, "*") != OK:
		Log.error("NetServer: cannot listen on ws port %d" % desired_ws)
		return false
	ws_port = ws_server.get_local_port()
	if http_server.listen(desired_http, "*") != OK:
		Log.error("NetServer: cannot listen on http port %d" % desired_http)
		ws_server.stop()
		return false
	http_port = http_server.get_local_port()
	_reset_seats()
	_load_tokens()
	_log("network: phones → %s" % web_url())
	_log("network: websocket on ws://%s:%d" % [_ip(), ws_port])
	return true

func stop() -> void:
	for client in clients:
		client.peer.close()
	clients.clear()
	ws_server.stop()
	http_server.stop()
	_http_pending.clear()
	if session != null:
		if session.changed.is_connected(_on_session_changed):
			session.changed.disconnect(_on_session_changed)
		if session.message.is_connected(_on_session_message):
			session.message.disconnect(_on_session_message)

func _process(_delta: float) -> void:
	_accept_sockets()
	_poll_clients()
	_poll_http()

# --- Info for the table screen -------------------------------------------------

func lan_ip() -> String:
	return _ip()

func web_url() -> String:
	return "http://%s:%d" % [_ip(), http_port]

func ws_url() -> String:
	return "ws://%s:%d" % [_ip(), ws_port]

func seat_status() -> Array:
	var status: Array = []
	for player_id in seats.keys():
		var seat: Dictionary = seats[player_id]
		status.append({
			"seat": int(player_id),
			"connected": bool(seat.get("connected", false)),
			"has_token": String(seat.get("token", "")) != "",
		})
	status.sort_custom(func(a, b): return int(a["seat"]) < int(b["seat"]))
	return status

func _ip() -> String:
	for address in IP.get_local_addresses():
		if address.count(".") == 3 and not address.begins_with("127.") and not address.begins_with("169.254."):
			return address
	return "127.0.0.1"

# --- WebSocket accept / poll ---------------------------------------------------

func _accept_sockets() -> void:
	while ws_server.is_connection_available():
		var tcp: StreamPeerTCP = ws_server.take_connection()
		var peer := WebSocketPeer.new()
		if peer.accept_stream(tcp) != OK:
			Log.warn("NetServer: websocket handshake failed")
			continue
		clients.append(Client.new(peer))
		_log("network: incoming websocket connection")

func _poll_clients() -> void:
	for i in range(clients.size() - 1, -1, -1):
		var client: Client = clients[i]
		client.peer.poll()
		if client.peer.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_drop_client(client)
			clients.remove_at(i)
			continue
		if client.peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			continue
		while client.peer.get_available_packet_count() > 0:
			var text: String = client.peer.get_packet().get_string_from_utf8()
			_handle_text(client, text)

func _drop_client(client: Client) -> void:
	client.connected = false
	if client.joined and seats.has(client.player_id):
		seats[client.player_id]["connected"] = false
		_log("network: P%d disconnected — state kept, token still valid" % (client.player_id + 1))
		_save_tokens()
		seats_changed.emit()

# --- Protocol handling ---------------------------------------------------------

func _handle_text(client: Client, text: String) -> void:
	var msg: Dictionary = Protocol.from_wire(text)
	if msg.is_empty():
		_send(client, Protocol.error_message("bad_json", "", "not a JSON object"))
		return
	var type: String = String(msg.get("type", ""))
	if type == Protocol.CMD_JOIN:
		_handle_join(client, msg)
		return
	if not client.joined:
		_send(client, Protocol.error_message("not_joined", type, "send JOIN first"))
		return
	# THE SEAT DECIDES WHO ACTS. A forged player_id is overwritten here, and
	# the engine validates the identity again for window answers.
	msg["player_id"] = client.player_id
	var result: Dictionary = await session.submit_command(msg)
	if not result.get("ok", false):
		_send(client, Protocol.error_message(
			String(result.get("error", "refused")), type, "command refused by the server"))

func _handle_join(client: Client, msg: Dictionary) -> void:
	if client.joined:
		_send(client, Protocol.join_rejected("already_joined"))
		return
	var payload: Dictionary = msg.get("payload", {})
	var requested_seat: int = int(payload.get("seat", -1))
	var token: String = String(payload.get("token", ""))
	var player_id: int = _resolve_seat(requested_seat, token)
	if player_id < 0:
		_send(client, Protocol.join_rejected("seat_taken"))
		_log("network: join refused (seat %d)" % requested_seat)
		return
	var fresh_token: String = _token_for(player_id, true)
	client.joined = true
	client.player_id = player_id
	client.connected = true
	if seats.has(player_id):
		seats[player_id]["connected"] = true
	_save_tokens()
	_send(client, Protocol.join_ok(player_id, player_id, fresh_token, session.player_count()))
	_send(client, session.snapshot_message(player_id))
	var prompt: Dictionary = session.pending_prompt(player_id)
	if not prompt.is_empty():
		_send(client, prompt)
	_log("network: P%d joined%s" % [player_id + 1, " (reconnected)" if token != "" else ""])
	seats_changed.emit()

## Token first, then the requested seat, then the first free one.
func _resolve_seat(requested_seat: int, token: String) -> int:
	if token != "":
		for player_id in seats.keys():
			if String(seats[player_id].get("token", "")) == token:
				return int(player_id)
	if requested_seat >= 0 and requested_seat < session.player_count():
		if not bool(seats.get(requested_seat, {}).get("connected", false)):
			return requested_seat
		return -1
	for player_id in range(session.player_count()):
		if not bool(seats.get(player_id, {}).get("connected", false)):
			return player_id
	return -1

func _token_for(player_id: int, rotate: bool) -> String:
	var existing: String = String(seats.get(player_id, {}).get("token", ""))
	if existing != "" and not rotate:
		return existing
	var token: String = Crypto.new().generate_random_bytes(24).hex_encode()
	seats[player_id] = {"token": token, "connected": bool(seats.get(player_id, {}).get("connected", true))}
	return token

# --- Delivery ------------------------------------------------------------------

func _on_session_changed() -> void:
	for client in clients:
		if not client.joined:
			continue
		_send(client, session.snapshot_message(client.player_id))

func _on_session_message(msg: Dictionary) -> void:
	var type: String = String(msg.get("type", ""))
	var payload: Dictionary = msg.get("payload", {})
	if type == Protocol.MSG_STATE_SNAPSHOT:
		return   # the network layer builds one snapshot per viewer
	if type == Protocol.MSG_PRIORITY_REQUEST or type == Protocol.MSG_TARGET_REQUEST \
			or type == Protocol.MSG_DEATH_PENALTY_REQUEST:
		_send_to_player(int(payload.get("player_id", -1)), msg)
		return
	if type == Protocol.MSG_DOMAIN_EVENT:
		var private_to: int = int(payload.get("private_to", -1))
		for client in clients:
			if not client.joined:
				continue
			if private_to >= 0 and private_to != client.player_id:
				continue   # another player's private draw: not this phone's business
			_send(client, msg)

func _send_to_player(player_id: int, msg: Dictionary) -> void:
	for client in clients:
		if client.joined and client.player_id == player_id:
			_send(client, msg)

func _send(client: Client, msg: Dictionary) -> void:
	if msg.is_empty():
		return
	if client.peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	client.peer.send_text(Protocol.to_wire(msg))

func _log(text: String) -> void:
	print("  [net] %s" % text)
	log_line.emit(text)

# --- Tiny static HTTP server (the PWA) ----------------------------------------

func _poll_http() -> void:
	while http_server.is_connection_available():
		_http_pending.append({"tcp": http_server.take_connection(), "buffer": PackedByteArray()})
	for i in range(_http_pending.size() - 1, -1, -1):
		var entry: Dictionary = _http_pending[i]
		var tcp: StreamPeerTCP = entry["tcp"]
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_http_pending.remove_at(i)
			continue
		var available: int = tcp.get_available_bytes()
		if available > 0:
			var chunk: Array = tcp.get_data(available)
			if int(chunk[0]) == OK:
				entry["buffer"] = (entry["buffer"] as PackedByteArray) + (chunk[1] as PackedByteArray)
		var buffer: PackedByteArray = entry["buffer"]
		if buffer.size() > MAX_HTTP_HEADER:
			_http_reply(tcp, 413, "text/plain; charset=utf-8", "request too large".to_utf8_buffer())
			_http_pending.remove_at(i)
			continue
		if buffer.get_string_from_utf8().find("\r\n\r\n") < 0:
			continue
		_serve_http(tcp, buffer.get_string_from_utf8())
		_http_pending.remove_at(i)

func _serve_http(tcp: StreamPeerTCP, request: String) -> void:
	var first_line: String = request.split("\r\n")[0]
	var parts: PackedStringArray = first_line.split(" ")
	if parts.size() < 2 or parts[0] != "GET":
		_http_reply(tcp, 405, "text/plain; charset=utf-8", "GET only".to_utf8_buffer())
		return
	var path: String = parts[1].split("?")[0]
	if path == "/" or path == "":
		path = "/index.html"
	if path == "/config.json":
		var config := {
			"ws_port": ws_port, "http_port": http_port,
			"player_count": session.player_count() if session != null else 0,
			"seats": seat_status(),
		}
		_http_reply(tcp, 200, MIME["json"], JSON.stringify(config).to_utf8_buffer())
		return
	if path.contains(".."):
		_http_reply(tcp, 403, "text/plain; charset=utf-8", "forbidden".to_utf8_buffer())
		return
	var file_path: String = WEB_ROOT + path.trim_prefix("/")
	if not FileAccess.file_exists(file_path):
		_http_reply(tcp, 404, "text/plain; charset=utf-8", "not found".to_utf8_buffer())
		return
	var extension: String = path.get_extension().to_lower()
	var mime: String = String(MIME.get(extension, "application/octet-stream"))
	_http_reply(tcp, 200, mime, FileAccess.get_file_as_bytes(file_path))

func _http_reply(tcp: StreamPeerTCP, status: int, mime: String, body: PackedByteArray) -> void:
	var head := "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" % [
		status, "OK" if status == 200 else "ERROR", mime, body.size()]
	tcp.put_data(head.to_utf8_buffer())
	if not body.is_empty():
		tcp.put_data(body)
	tcp.disconnect_from_host()

# --- Seat tokens (survive a restart of the PC server) --------------------------

func _reset_seats() -> void:
	seats.clear()
	if session == null:
		return
	for player_id in range(session.player_count()):
		seats[player_id] = {"token": "", "connected": false}

func _load_tokens() -> void:
	if not FileAccess.file_exists(SEATS_PATH):
		return
	var file := FileAccess.open(SEATS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for key in (parsed as Dictionary).keys():
		var player_id: int = int(key)
		if seats.has(player_id):
			seats[player_id]["token"] = String(parsed[key])

func _save_tokens() -> void:
	var tokens: Dictionary = {}
	for player_id in seats.keys():
		tokens[str(player_id)] = String(seats[player_id].get("token", ""))
	var file := FileAccess.open(SEATS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(tokens))
	file.close()
