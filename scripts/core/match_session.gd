extends RefCounted
## MatchSession — the authoritative "server" in one process (M2).
##
## Layering (ratifica #1/#2):
##   client (PWA later, game_scene.gd today)
##     -- COMMAND (pure Dictionary, JSON-ready) -->   MatchSession
##                                                        |
##                                                        v
##                                                   MatchController (rules)
##                                                        |
##     <-- MESSAGE (snapshot / requests / events) --   MatchSession
##
## Responsibilities:
##  - owns the controller and a CommandDriver (the engine's input transport);
##  - validates every command with MatchProtocol (shape only);
##  - decides who may act and when (the engine does the actual rule checks);
##  - answers "which target?" with a TARGET_REQUEST instead of guessing;
##  - server-owned legality: every snapshot carries ui_actions() so a client
##    never recomputes a buy limit, a cost or a tap state;
##  - filters DOMAIN_EVENT payloads that reveal private hands.
##
## There is NO networking here on purpose: in M3 the socket replaces `_emit`
## and `submit_command`'s entry point. Rules, protocol and client stay as-is.
##
## Not a class_name on purpose (headless CLI): preload it.

const Protocol := preload("res://scripts/core/match_protocol.gd")
const ControllerScript := preload("res://scripts/core/match_controller.gd")
const CommandDriverScript := preload("res://scripts/core/drivers/command_driver.gd")

## A protocol message for the local viewer.
signal message(msg: Dictionary)
## Convenience for the UI: something changed and the snapshot was re-emitted.
signal changed()

var controller = null
var driver = null

## M4: the reaction window handed to the transport. 2000 ms in the phone game;
## 0 disables the countdown (hotseat: a human must not be auto-passed).
var priority_window_ms: int = 2000
## Safety net while a phone picks a target: the countdown is paused, but the
## game must not hang forever if that phone walks away.
var target_timeout_ms: int = 30000
var _target_timer_generation: int = 0

## A command that needs a target: {command, request_id, card_id, command_type}.
var _pending_target: Dictionary = {}
var _domain_connected: bool = false

# --- Lifecycle ----------------------------------------------------------------

func start(player_count: int, seed_value: int) -> void:
	stop()
	controller = ControllerScript.new()
	driver = CommandDriverScript.new()
	driver.message_sink = _on_driver_message
	controller.priority_window_ms = priority_window_ms
	controller.setup(player_count, seed_value, driver)
	if driver != null:
		driver.window_ms = priority_window_ms
	_connect_domain()
	controller.begin_turn(0)
	# The first turn is announced like every other one, so a client never has to
	# special-case "turn 0" (and the device overlay logic stays uniform).
	_emit_domain("turn_started", {"player_id": 0})
	emit_snapshot()

func stop() -> void:
	_disconnect_domain()
	_pending_target.clear()
	if controller != null:
		controller.teardown()
	controller = null
	driver = null

# --- Client entry point -------------------------------------------------------

## Handles one client command. Returns {ok: bool, error?: String, ...}; it is
## awaitable because the engine may wait for a human answer deeper down.
func submit_command(cmd: Dictionary) -> Dictionary:
	if controller == null:
		return {"ok": false, "error": "no_session"}
	var err: String = Protocol.validation_error(cmd)
	if err != "":
		return {"ok": false, "error": err}
	var type: String = String(cmd.get("type", ""))
	var pid: int = int(cmd.get("player_id", -1))
	var payload: Dictionary = cmd.get("payload", {})

	# 1. A target answer completes the command waiting for it.
	if type == Protocol.CMD_SELECT_TARGET:
		return await _complete_target(cmd)

	# 2. Answers to an open window go straight to the driver (the engine is
	#    waiting there). A loot that needs a target is intercepted first.
	if driver.has_window():
		if type == Protocol.CMD_PLAY_LOOT and driver.window_kind() == "priority":
			var window_card: CardResource = controller.card_resource(String(payload.get("card_id", "")))
			if window_card != null and window_card.needs_target and String(payload.get("target_id", "")) == "":
				_request_target(cmd, window_card.id)
				return {"ok": true, "pending": "target"}
		if driver.receive_command(cmd):
			return {"ok": true}
		return {"ok": false, "error": "no_window_for_answer"}

	# 3. Free actions belong to the active player, in the engine's own terms.
	if type == Protocol.CMD_PASS_PRIORITY:
		return {"ok": false, "error": "no_window"}
	if pid != int(controller.state.current_player_index):
		return {"ok": false, "error": "not_your_turn"}

	if type == Protocol.CMD_BUY_SHOP:
		var bought: bool = controller.buy(int(payload.get("slot", -1)), pid)
		emit_snapshot()
		return {"ok": bought, "error": "" if bought else "buy_refused"}

	if type == Protocol.CMD_DECLARE_ATTACK:
		var attack_target: String = String(payload.get("target_id", ""))
		if attack_target == "":
			_request_target(cmd, "")
			return {"ok": true, "pending": "target"}
		return await _run_attack(pid, attack_target)

	if type == Protocol.CMD_PLAY_LOOT:
		var card: CardResource = controller.card_resource(String(payload.get("card_id", "")))
		if card == null:
			return {"ok": false, "error": "unknown_card"}
		if not (controller.state.players[pid]["hand"] as Array).has(card.id):
			return {"ok": false, "error": "not_in_hand"}
		if card.needs_target and String(payload.get("target_id", "")) == "":
			_request_target(cmd, card.id)
			return {"ok": true, "pending": "target"}
		var card_payload: Dictionary = {}
		if String(payload.get("target_id", "")) != "":
			card_payload["target_id"] = String(payload["target_id"])
		var played: bool = await controller.play_loot(card, pid, card_payload)
		emit_snapshot()
		return {"ok": played, "error": "" if played else "play_refused"}

	if type == Protocol.CMD_ACTIVATE_ITEM:
		var item_payload: Dictionary = {}
		if payload.has("delta"):
			item_payload["delta"] = int(payload["delta"])
		if payload.has("target_id"):
			item_payload["target_id"] = payload["target_id"]
		var used: Dictionary = controller.use_eternal_item(pid, item_payload)
		emit_snapshot()
		return {"ok": used.get("ok", false), "result": used, "error": "" if used.get("ok", false) else String(used.get("reason", "item_refused"))}

	if type == Protocol.CMD_END_TURN:
		var next_player: int = controller.end_turn()
		var turn_started: bool = false
		if controller.state.has_winner() < 0:
			controller.begin_turn(next_player)
			turn_started = true
			_emit_domain("turn_started", {"player_id": next_player})
		emit_snapshot()
		return {"ok": true, "next_player": next_player, "turn_started": turn_started}

	return {"ok": false, "error": "not_implemented"}

func _run_attack(pid: int, target_id: String) -> Dictionary:
	var result: Dictionary = await controller.attack(target_id, pid)
	var outcome: String = String(result.get("outcome", ""))
	var next_player: int = int(controller.state.current_player_index)
	if outcome == "player_died" and controller.state.has_winner() < 0:
		# The death penalty already ran the ending phase: start the next turn
		# exactly like END_TURN does, so no client has to know the rule.
		controller.begin_turn(next_player)
		_emit_domain("turn_started", {"player_id": next_player})
	emit_snapshot()
	return {"ok": result.get("valid", false), "result": result, "next_player": next_player}

## The server asks WHICH target instead of picking one for the player.
func _request_target(cmd: Dictionary, card_id: String) -> void:
	var options: Array = []
	for monster in controller.state.table_monsters:
		var card: CardResource = monster.get("card")
		if card == null:
			continue
		options.append({
			"instance_id": String(monster["instance_id"]),
			"card_id": card.id,
			"display_name": card.display_name,
			"die_value": card.die_value,
			"hp": int(monster["hp"]),
		})
	var request_id: String = String(cmd.get("request_id", ""))
	_pending_target = {
		"command": cmd.duplicate(true),
		"request_id": request_id,
		"card_id": card_id,
		"command_type": String(cmd.get("type", "")),
		"options": options.duplicate(true),
	}
	# M4: freeze the reaction countdown while the target is being chosen — no
	# auto-pass may fire while a human is looking at the table.
	if driver != null:
		driver.pause_window()
	_start_target_timeout()
	_emit(Protocol.target_request(request_id, int(cmd.get("player_id", -1)),
		String(cmd.get("type", "")), card_id, options))

func _complete_target(cmd: Dictionary) -> Dictionary:
	if _pending_target.is_empty():
		return {"ok": false, "error": "no_pending_target"}
	var stored: Dictionary = _pending_target
	var wanted_id: String = String(stored.get("request_id", ""))
	if wanted_id != String(cmd.get("request_id", "")):
		return {"ok": false, "error": "stale_target_request"}
	_pending_target = {}
	_target_timer_generation += 1
	if driver != null:
		driver.resume_window()
	var target_id: String = String(cmd.get("payload", {}).get("target_id", ""))
	if target_id == "":
		# empty target = the player cancelled the selection
		emit_snapshot()
		return {"ok": true, "cancelled": true}
	var original: Dictionary = (stored.get("command", {}) as Dictionary).duplicate(true)
	original["payload"]["target_id"] = target_id
	return await submit_command(original)

# --- Messages ----------------------------------------------------------------

## The snapshot for whoever is looking right now (hotseat: the player being
## asked if a window is open, otherwise the active player).
func emit_snapshot() -> void:
	if controller == null:
		return
	var viewer: int = _viewer()
	_emit(Protocol.state_snapshot(
		controller.snapshot_for(viewer), controller.ui_actions(viewer), driver.window_kind(),
		window_remaining_ms(), window_total_ms()))
	changed.emit()

## M4: the countdown the clients animate. The server is the only clock.
func window_remaining_ms() -> int:
	return driver.window_remaining_ms() if driver != null else 0

func window_total_ms() -> int:
	return driver.window_total_ms() if driver != null else 0

func _viewer() -> int:
	if driver != null and driver.has_window():
		return int(driver.pending_player_id())
	if controller != null:
		return int(controller.state.current_player_index)
	return 0

func window_kind() -> String:
	return driver.window_kind() if driver != null else ""

func player_count() -> int:
	return controller.state.players.size() if controller != null else 0

## A STATE_SNAPSHOT for one specific viewer; `-1` is the table (no hands).
## This is what the network layer sends, one per connected phone.
func snapshot_message(viewer: int) -> Dictionary:
	if controller == null:
		return {}
	return Protocol.state_snapshot(
		controller.snapshot_for(viewer), controller.ui_actions(viewer), window_kind(),
		window_remaining_ms(), window_total_ms())

## The request this player owes an answer to RIGHT NOW ({} if none). A phone
## that reloads the page gets its pending prompt back instead of a dead screen.
func pending_prompt(player_id: int) -> Dictionary:
	if driver == null:
		return {}
	# M4: a pending TARGET comes first — while the player is choosing, that is
	# the prompt they owe (the window behind it is paused, not answerable).
	if not _pending_target.is_empty():
		var pending_command: Dictionary = _pending_target.get("command", {})
		if int(pending_command.get("player_id", -1)) == player_id:
			return Protocol.target_request(
				String(_pending_target.get("request_id", "")), player_id,
				String(_pending_target.get("command_type", "")),
				String(_pending_target.get("card_id", "")),
				_pending_target.get("options", []))
	if driver.window_kind() == "priority":
		# M4: the round is per player — give this phone ITS request back, with
		# the countdown that is actually left.
		var request: Dictionary = driver.pending_request_for(player_id)
		if request.is_empty():
			return {}
		request["window_total_ms"] = window_total_ms()
		request["window_remaining_ms"] = window_remaining_ms()
		return Protocol.priority_request(request)
	if driver.window_kind() == "death":
		var death: Dictionary = driver.pending_request()
		if int(death.get("player_id", -1)) != player_id:
			return {}
		return Protocol.death_request(death)
	return {}

## The target picker went silent past the safety timeout: cancel the choice,
## restart the countdown and let the engine continue as if the play was passed.
func _start_target_timeout() -> void:
	_target_timer_generation += 1
	var generation: int = _target_timer_generation
	if target_timeout_ms <= 0:
		return
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var timer := tree.create_timer(float(target_timeout_ms) / 1000.0, true, false, true)
	timer.timeout.connect(func() -> void:
		if generation != _target_timer_generation or _pending_target.is_empty():
			return
		_pending_target = {}
		if driver != null:
			driver.resume_window()
		_emit_domain("target_expired", {})
		emit_snapshot())

func _on_driver_message(msg: Dictionary) -> void:
	_emit(msg)
	emit_snapshot()

func _emit(msg: Dictionary) -> void:
	message.emit(msg)

## Domain events leave the session UNFILTERED, with `private_to` on the
## envelope: each consumer (hotseat screen, table, socket) hides the contents
## for viewers that are not allowed to see them. The transport must never be
## the place where privacy is decided.
func _emit_domain(event_name: String, data: Dictionary, private_to: int = -1) -> void:
	_emit(Protocol.domain_event(event_name, data.duplicate(true), private_to))

# --- Domain event bridge -----------------------------------------------------

func _connect_domain() -> void:
	if _domain_connected:
		return
	EventBus.card_drawn.connect(_on_card_drawn)
	EventBus.card_played.connect(_on_card_played)
	EventBus.card_discarded.connect(_on_card_discarded)
	EventBus.item_bought.connect(_on_item_bought)
	EventBus.monster_attacked.connect(_on_monster_attacked)
	EventBus.monster_killed.connect(_on_monster_killed)
	EventBus.eternal_used.connect(_on_eternal_used)
	EventBus.souls_changed.connect(_on_souls_changed)
	EventBus.game_won.connect(_on_game_won)
	EventBus.effect_fizzled.connect(_on_effect_fizzled)
	EventBus.trigger_pushed.connect(_on_trigger_pushed)
	_domain_connected = true

func _disconnect_domain() -> void:
	if not _domain_connected:
		return
	EventBus.card_drawn.disconnect(_on_card_drawn)
	EventBus.card_played.disconnect(_on_card_played)
	EventBus.card_discarded.disconnect(_on_card_discarded)
	EventBus.item_bought.disconnect(_on_item_bought)
	EventBus.monster_attacked.disconnect(_on_monster_attacked)
	EventBus.monster_killed.disconnect(_on_monster_killed)
	EventBus.eternal_used.disconnect(_on_eternal_used)
	EventBus.souls_changed.disconnect(_on_souls_changed)
	EventBus.game_won.disconnect(_on_game_won)
	EventBus.effect_fizzled.disconnect(_on_effect_fizzled)
	EventBus.trigger_pushed.disconnect(_on_trigger_pushed)
	_domain_connected = false

func _on_card_drawn(player_id: int, card_id: String, deck: String) -> void:
	_emit_domain("card_drawn", {"player_id": player_id, "card_id": card_id, "deck": deck}, player_id)

func _on_card_played(player_id: int, card_id: String) -> void:
	_emit_domain("card_played", {"player_id": player_id, "card_id": card_id})

func _on_card_discarded(player_id: int, card_id: String) -> void:
	_emit_domain("card_discarded", {"player_id": player_id, "card_id": card_id})

func _on_item_bought(player_id: int, card_id: String) -> void:
	_emit_domain("item_bought", {"player_id": player_id, "card_id": card_id})

func _on_monster_attacked(player_id: int, instance_id: String, roll: int, bonus: int, die_value: int) -> void:
	_emit_domain("monster_attacked", {
		"player_id": player_id, "instance_id": instance_id,
		"roll": roll, "bonus": bonus, "die_value": die_value})

func _on_monster_killed(player_id: int, instance_id: String, rewards: Dictionary) -> void:
	_emit_domain("monster_killed", {
		"player_id": player_id, "instance_id": instance_id, "rewards": rewards})

func _on_eternal_used(player_id: int, item_id: String, result: Dictionary) -> void:
	_emit_domain("eternal_used", {"player_id": player_id, "item_id": item_id, "result": result})

func _on_souls_changed(player_id: int, souls: Array, total_value: int) -> void:
	_emit_domain("souls_changed", {"player_id": player_id, "souls": souls, "total_value": total_value})

func _on_game_won(player_id: int) -> void:
	_emit_domain("game_won", {"player_id": player_id})

## M4: a stack entry lost its target and applied nothing (auditable trace).
func _on_effect_fizzled(owner_id: int, card_id: String, reason: String) -> void:
	_emit_domain("effect_fizzled", {"player_id": owner_id, "card_id": card_id, "reason": reason})

func _on_trigger_pushed(entry: Dictionary) -> void:
	_emit_domain("trigger_pushed", {
		"player_id": int(entry.get("owner", 0)),
		"card_id": String(entry.get("card_id", "")),
		"trigger": String(entry.get("trigger", "")),
		"effect": String(entry.get("effect", "")),
	})
