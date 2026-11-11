extends Node
## M3 GATE — end-to-end network test, headless, no browser needed.
##
## Starts the REAL WebSocket + HTTP server on 127.0.0.1 (ephemeral ports) and
## drives TWO WebSocketPeer clients exactly like two phones:
##  1. HTTP: the PWA shell and /config.json are actually served;
##  2. JOIN on both seats, reconnect tokens issued;
##  3. privacy over the wire: P1 never receives P2's hand contents, only the
##     count (and P2 does see its own);
##  4. a loot play with no target: the SERVER replies TARGET_REQUEST, the phone
##     answers SELECT_TARGET, the play becomes a stack entry;
##  5. the priority window reaches the phone that can answer, with the server's
##     legal actions, and its PASS closes it (then the Bomb resolves);
##  6. a forged player_id cannot act for another seat;
##  7. reconnect with the saved token resumes the seat and gets a snapshot.
##
## Run: run_net_test.bat (exit code = result).

const Protocol := preload("res://scripts/core/match_protocol.gd")
const SessionScript := preload("res://scripts/core/match_session.gd")
const NetServerScript := preload("res://scripts/net/net_server.gd")
const CARD_DIR := "res://resources/cards/base_set/"

## A phone stand-in: raw WebSocketPeer + an inbox of parsed protocol messages.
class TestClient extends RefCounted:
	var ws := WebSocketPeer.new()
	var inbox: Array = []
	var label := ""

	func _init(p_label: String) -> void:
		label = p_label

	func open(port: int) -> void:
		ws.connect_to_url("ws://127.0.0.1:%d" % port)

	func poll() -> void:
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var parsed = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				inbox.append(parsed)

	func send(msg: Dictionary) -> void:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(JSON.stringify(msg))

	func close() -> void:
		ws.close()

	func is_open() -> bool:
		return ws.get_ready_state() == WebSocketPeer.STATE_OPEN

var _session
var _net
var _clients: Array = []
var _checks: Array = []

func _ready() -> void:
	_run()

func _run() -> void:
	print("\n== NETWORK TEST (M3) ==")
	_session = SessionScript.new()
	_net = NetServerScript.new()
	add_child(_net)
	_net.configure(_session)
	_session.start(2, 8)
	if not _net.start(0, 0):
		_check("server started", false)
		_finish()
		return
	_check("server started", _net.ws_port > 0 and _net.http_port > 0,
		"ws %d · http %d" % [_net.ws_port, _net.http_port])

	# --- 1. static hosting -----------------------------------------------------
	var index_page: String = await _http_get("/")
	_check("HTTP serves the PWA shell", index_page.begins_with("HTTP/1.1 200")
		and index_page.contains("text/html") and index_page.contains("app.js"))
	var config_page: String = await _http_get("/config.json")
	_check("HTTP /config.json advertises the ws port",
		config_page.begins_with("HTTP/1.1 200") and config_page.contains("\"ws_port\":%d" % _net.ws_port))

	# --- 2. join ----------------------------------------------------------------
	var p1 := TestClient.new("P1")
	var p2 := TestClient.new("P2")
	_clients = [p1, p2]
	p1.open(_net.ws_port)
	p2.open(_net.ws_port)
	await _pump(40)
	_check("both sockets open", p1.is_open() and p2.is_open())
	p1.send(Protocol.command(Protocol.CMD_JOIN, 0, {"seat": 0, "token": ""}))
	p2.send(Protocol.command(Protocol.CMD_JOIN, 0, {"seat": 1, "token": ""}))
	var join_p1: Dictionary = await _wait_for(p1, Protocol.MSG_JOIN_OK)
	var join_p2: Dictionary = await _wait_for(p2, Protocol.MSG_JOIN_OK)
	var join_p1_payload: Dictionary = join_p1.get("payload", {})
	var join_p2_payload: Dictionary = join_p2.get("payload", {})
	_check("P1 joined seat 1", int(join_p1_payload.get("player_id", -1)) == 0)
	_check("P2 joined seat 2", int(join_p2_payload.get("player_id", -1)) == 1)
	var token_p2: String = String(join_p2_payload.get("reconnect_token", ""))
	_check("reconnect token issued", token_p2.length() >= 16)
	var first_snapshot: Dictionary = await _wait_for(p1, Protocol.MSG_STATE_SNAPSHOT)
	_check("join delivers a snapshot immediately", not first_snapshot.is_empty())

	# --- 3. privacy over the socket --------------------------------------------
	_session.controller.state.players[1]["hand"] = ["loot_bomb", "loot_dinner"]
	_session.emit_snapshot()
	await _pump(5)
	var snapshot_p1: Dictionary = _latest(p1, Protocol.MSG_STATE_SNAPSHOT).get("payload", {}).get("snapshot", {})
	var snapshot_p2: Dictionary = _latest(p2, Protocol.MSG_STATE_SNAPSHOT).get("payload", {}).get("snapshot", {})
	var players_p1: Array = snapshot_p1.get("players", [])
	var players_p2: Array = snapshot_p2.get("players", [])
	_check("P1 receives only P2's hand COUNT", players_p1.size() == 2
		and (players_p1[1]["hand"] as Array).is_empty() and int(players_p1[1]["hand_count"]) == 2)
	_check("P2 receives its own hand over the socket",
		(players_p2[1]["hand"] as Array) == ["loot_bomb", "loot_dinner"])

	# --- 4/5. target request + priority window over the socket -----------------
	var game_state = _session.controller.state
	game_state.players[0]["hand"] = ["loot_bomb"]
	game_state.players[0]["loot_played"] = 0
	game_state.players[0]["character_tapped"] = false
	game_state.players[0]["eternal_item_id"] = "eternal_d6"   # only answers ROLL windows
	var gaper: CardResource = load(CARD_DIR + "monster_gaper.tres")
	_session.controller.table_monsters.clear()
	_session.controller.table_monsters.append({"instance_id": "monster_gaper#net", "card": gaper, "hp": 5})
	_session.emit_snapshot()
	await _pump(3)
	p1.send(Protocol.command(Protocol.CMD_PLAY_LOOT, 0, {"card_id": "loot_bomb"}))
	var target_request: Dictionary = await _wait_for(p1, Protocol.MSG_TARGET_REQUEST)
	var target_payload: Dictionary = target_request.get("payload", {})
	var options: Array = target_payload.get("options", [])
	_check("server asks the PHONE for the target", not target_request.is_empty() and not options.is_empty())
	var target_id: String = String((options[0] as Dictionary).get("instance_id", ""))
	p1.send(Protocol.command(Protocol.CMD_SELECT_TARGET, 0, {"target_id": target_id},
		String(target_payload.get("request_id", ""))))
	var priority: Dictionary = await _wait_for(p2, Protocol.MSG_PRIORITY_REQUEST)
	var priority_payload: Dictionary = priority.get("payload", {})
	var legal_actions: Array = priority_payload.get("legal_actions", [])
	var has_loot_action: bool = false
	for raw_action in legal_actions:
		if String((raw_action as Dictionary).get("action", "")) == "loot":
			has_loot_action = true
	_check("priority window reaches P2 with server legal actions",
		not priority.is_empty() and String(priority_payload.get("stack_type", "")) == "pending_effect"
		and has_loot_action)
	_check("P1 is not asked for a window it cannot answer",
		_count_for_player(p1, Protocol.MSG_PRIORITY_REQUEST, 0) == 0)
	p2.send(Protocol.command(Protocol.CMD_PASS_PRIORITY, 1, {},
		String(priority_payload.get("request_id", ""))))
	await _pump(12)
	var hp_after: int = -1
	for monster in _session.controller.table_monsters:
		if String(monster["instance_id"]) == "monster_gaper#net":
			hp_after = int(monster["hp"])
	_check("the Bomb resolved after the pass", hp_after == 3, "hp 5 -> %d" % hp_after)
	_check("the played card left the hand in the engine",
		not (game_state.players[0]["hand"] as Array).has("loot_bomb"))

	# --- 6. identity is the SEAT, not the message ------------------------------
	p2.send(Protocol.command(Protocol.CMD_DECLARE_ATTACK, 0, {"target_id": "monster_gaper#net"}))
	var error: Dictionary = await _wait_for(p2, Protocol.MSG_ERROR)
	var error_payload: Dictionary = error.get("payload", {})
	_check("a forged player_id is refused", not error.is_empty()
		and String(error_payload.get("code", "")) == "not_your_turn")

	# --- 7. reconnect with the token -------------------------------------------
	p2.close()
	await _pump(20)
	var p2b := TestClient.new("P2-reconnect")
	_clients = [p1, p2b]
	p2b.open(_net.ws_port)
	await _pump(40)
	p2b.send(Protocol.command(Protocol.CMD_JOIN, 1, {"seat": 1, "token": token_p2}))
	var rejoin: Dictionary = await _wait_for(p2b, Protocol.MSG_JOIN_OK)
	var rejoin_payload: Dictionary = rejoin.get("payload", {})
	_check("reconnect with the token resumes P2", int(rejoin_payload.get("player_id", -1)) == 1)
	var resumed: Dictionary = await _wait_for(p2b, Protocol.MSG_STATE_SNAPSHOT)
	_check("reconnect sends the snapshot immediately", not resumed.is_empty())

	_net.stop()
	_finish()

# --- Helpers -------------------------------------------------------------------

func _pump(frames: int = 1) -> void:
	for i in range(frames):
		await get_tree().process_frame
		for client in _clients:
			client.poll()

func _wait_for(client: TestClient, type: String, max_frames: int = 300) -> Dictionary:
	for i in range(max_frames):
		for raw in client.inbox:
			if String((raw as Dictionary).get("type", "")) == type:
				client.inbox.erase(raw)
				return raw
		await _pump(1)
	return {}

func _latest(client: TestClient, type: String) -> Dictionary:
	for i in range(client.inbox.size() - 1, -1, -1):
		if String((client.inbox[i] as Dictionary).get("type", "")) == type:
			return client.inbox[i]
	return {}

func _count_for_player(client: TestClient, type: String, player_id: int) -> int:
	var count: int = 0
	for raw in client.inbox:
		var msg: Dictionary = raw
		if String(msg.get("type", "")) == type \
				and int((msg.get("payload", {}) as Dictionary).get("player_id", -1)) == player_id:
			count += 1
	return count

func _http_get(path: String) -> String:
	var tcp := StreamPeerTCP.new()
	if tcp.connect_to_host("127.0.0.1", _net.http_port) != OK:
		return ""
	for i in range(240):
		tcp.poll()
		if tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		if tcp.get_status() == StreamPeerTCP.STATUS_ERROR:
			return ""
		await get_tree().process_frame
	tcp.put_data(("GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" % path).to_utf8_buffer())
	var raw := ""
	for i in range(240):
		tcp.poll()
		var available: int = tcp.get_available_bytes()
		if available > 0:
			var chunk: Array = tcp.get_data(available)
			if int(chunk[0]) == OK:
				raw += (chunk[1] as PackedByteArray).get_string_from_utf8()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			break
		await get_tree().process_frame
	tcp.disconnect_from_host()
	return raw

func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks.append({"label": label, "ok": ok})
	print("  [net-test] %s: %s%s" % ["PASS" if ok else "FAIL", label,
		(" (" + detail + ")") if detail != "" else ""])

func _finish() -> void:
	var passed: int = 0
	for check in _checks:
		if check["ok"]:
			passed += 1
	print("\n  self-checks: %d/%d PASS" % [passed, _checks.size()])
	for check in _checks:
		if not check["ok"]:
			print("    - FAIL: %s" % check["label"])
	get_tree().quit(0 if passed == _checks.size() else 1)
