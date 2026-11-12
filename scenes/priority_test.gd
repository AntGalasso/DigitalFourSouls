extends Node
## M4 GATE — reaction window, triggers, fizzling, 3–4 players.
##
## Everything here runs headless against the REAL session (MatchSession +
## CommandDriver): the countdown is the real SceneTree timer, not a mock.
##
##   T1  the 2 s window auto-resolves when nobody reacts (the stack empties
##       without a single PASS arriving);
##   T2  the countdown FREEZES while a player picks a target, and resumes as
##       soon as the target is chosen;
##   T3  triggers are collected in APNAP order (active player first, then
##       clockwise) and their conditions come from card DATA;
##   T4  a stack entry whose target is gone FIZZLES (applies nothing, says so);
##   T5  the engine plays 3 and 4 players, not just 2.
##
## Run: run_priority_test.bat

const Protocol := preload("res://scripts/core/match_protocol.gd")
const SessionScript := preload("res://scripts/core/match_session.gd")
const ControllerScript := preload("res://scripts/core/match_controller.gd")
const MatchStateScript := preload("res://scripts/core/match_state.gd")
const TriggerEngineScript := preload("res://scripts/core/trigger_engine.gd")
const CARD_DIR := "res://resources/cards/base_set/"

## A driver that never reacts: the countdown is the only thing that can close
## a window, which is exactly what T1 checks.
class PassDriver extends RefCounted:
	func is_interactive() -> bool:
		return false

	func decide_priority(_request: Dictionary) -> Dictionary:
		return {"action": "pass"}

	func decide_death(_request: Dictionary) -> Dictionary:
		return {}

var _checks: Array = []

func _ready() -> void:
	_run()

func _run() -> void:
	print("\n== PRIORITY / TRIGGER / MULTIPLAYER TEST (M4) ==")
	await _test_autoresolve()
	await _test_pause_on_target()
	_test_apnap()
	await _test_fizzling()
	_test_many_players()
	_finish()

# --- T1: the countdown closes the window on its own ---------------------------

func _test_autoresolve() -> void:
	var session = SessionScript.new()
	session.priority_window_ms = 120
	session.start(2, 11)
	var monster_id: String = String(session.controller.table_monsters[0]["instance_id"])
	session.controller.state.players[0]["hp"] = 50
	session.controller.state.players[0]["max_hp"] = 50
	var started: int = Time.get_ticks_msec()
	var result: Dictionary = await session.submit_command(
		Protocol.command(Protocol.CMD_DECLARE_ATTACK, 0, {"target_id": monster_id}))
	var elapsed: int = Time.get_ticks_msec() - started
	var ok: bool = bool(result.get("ok", false))
	ok = ok and elapsed >= 100                       # it really waited for the timer
	ok = ok and session.controller.stack != null and session.controller.stack.is_empty()
	ok = ok and session.window_kind() == ""          # no window left hanging
	_check("countdown auto-resolves the stack with no PASS", ok, "%d ms, stack empty" % elapsed)
	session.stop()

# --- T2: the countdown freezes while a target is chosen -----------------------

func _test_pause_on_target() -> void:
	var session = SessionScript.new()
	session.priority_window_ms = 100
	session.target_timeout_ms = 5000
	session.start(2, 12)
	var controller = session.controller
	var state = controller.state
	var monster_id: String = String(controller.table_monsters[0]["instance_id"])
	var monsters_before: int = controller.table_monsters.size()
	var monster_hp_before: int = int(controller.table_monsters[0]["hp"])
	state.players[0]["hp"] = 50
	state.players[0]["max_hp"] = 50
	state.players[1]["hand"] = ["loot_bomb"]
	state.players[1]["loot_played"] = 0
	state.players[1]["character_tapped"] = false
	state.players[1]["eternal_item_id"] = "eternal_d6"
	state.players[0]["eternal_item_id"] = "eternal_d6"

	# Catch P2's PRIORITY_REQUEST while P1 attacks.
	var captured: Dictionary = {}
	var on_message := func(msg: Dictionary) -> void:
		if String(msg.get("type", "")) != Protocol.MSG_PRIORITY_REQUEST or not captured.is_empty():
			return
		var payload: Dictionary = msg.get("payload", {})
		if int(payload.get("player_id", -1)) == 1:
			captured.merge(payload, true)
	session.message.connect(on_message)

	controller.state.players[0]["attacks_used"] = 0
	var attack_holder: Dictionary = {"done": false, "result": {}}
	_run_attack(session, monster_id, attack_holder)
	for i in range(80):
		if not captured.is_empty():
			break
		await get_tree().create_timer(0.02).timeout
	_check("P2 receives a live priority request during the attack", not captured.is_empty())

	var play: Dictionary = await session.submit_command(Protocol.command(
		Protocol.CMD_PLAY_LOOT, 1, {"card_id": "loot_bomb"},
		String(captured.get("request_id", ""))))
	_check("a response that needs a target asks for it instead of acting",
		play.get("pending", "") == "target")
	# Three times the window: if the countdown were running, it would have
	# expired and auto-resolved long ago.
	await get_tree().create_timer(0.35).timeout
	var prompt: Dictionary = session.pending_prompt(1)
	var still_paused: bool = String(prompt.get("type", "")) == Protocol.MSG_TARGET_REQUEST
	still_paused = still_paused and session.controller.stack != null \
		and not session.controller.stack.is_empty()
	_check("the countdown is PAUSED while the target is being chosen", still_paused)

	var chosen: Dictionary = await session.submit_command(Protocol.command(
		Protocol.CMD_SELECT_TARGET, 1, {"target_id": monster_id},
		String(prompt.get("payload", {}).get("request_id", ""))))
	_check("choosing the target is accepted", bool(chosen.get("ok", false)))
	for i in range(150):
		if attack_holder["done"]:
			break
		await get_tree().create_timer(0.02).timeout
	# Track the TARGET by instance id: the attack may have killed it and the
	# slot refilled, so counting cards is not enough.
	var target_hp: int = -1
	for monster in controller.table_monsters:
		if String(monster.get("instance_id", "")) == monster_id:
			target_hp = int(monster["hp"])
	var damaged: bool = target_hp < 0 or target_hp < monster_hp_before
	_check("after the pause the play resolves (the Bomb hurt the target)", damaged,
		"target %s: hp %d -> %s" % [monster_id, monster_hp_before,
			"gone" if target_hp < 0 else str(target_hp)])
	session.message.disconnect(on_message)
	session.stop()

func _run_attack(session, monster_id: String, holder: Dictionary) -> void:
	holder["result"] = await session.submit_command(
		Protocol.command(Protocol.CMD_DECLARE_ATTACK, 0, {"target_id": monster_id}))
	holder["done"] = true

# --- T3: APNAP + data conditions ---------------------------------------------

func _test_apnap() -> void:
	var state = MatchStateScript.new()
	state.reset(3)
	for pid in range(3):
		state.players[pid]["items_passive"] = ["treasure_crows_heart"]
	state.current_player_index = 1
	var engine = TriggerEngineScript.new()
	var entries: Array = engine.collect("on_monster_killed",
		{"active_player": 1, "attacker": 0}, state)
	var owners: Array = []
	for entry in entries:
		owners.append(int((entry as Dictionary).get("owner", -1)))
	_check("triggers are collected APNAP (active first, then clockwise)",
		owners == [1, 2, 0], str(owners))
	var gurdy: CardResource = load(CARD_DIR + "monster_gurdy.tres")
	var damage_effect: String = gurdy.trigger_effect if gurdy != null else ""
	_check("Gurdy's effect comes from card data", damage_effect == "damage_attacker")
	var condition_ok: bool = engine.condition_ok("roll == 1", {"roll": 1}) \
		and not engine.condition_ok("roll == 1", {"roll": 2})
	var typo_closed: bool = not engine.condition_ok("roll = ", {"roll": 1})
	_check("effect_condition is parsed (and a typo fails closed)", condition_ok and typo_closed)

# --- T4: fizzling -------------------------------------------------------------

func _test_fizzling() -> void:
	var controller = ControllerScript.new()
	controller.setup(2, 13, PassDriver.new())
	var fizzled: Array = []
	var on_fizzle := func(owner_id: int, card_id: String, reason: String) -> void:
		fizzled.append([owner_id, card_id, reason])
	EventBus.effect_fizzled.connect(on_fizzle)
	var monsters_before: int = controller.table_monsters.size()
	controller.stack.push({
		"type": "pending_effect", "owner": 0, "card_id": "loot_bomb",
		"payload": {"target_id": "monster_gone#999"},
	})
	await controller._resolve_stack()
	EventBus.effect_fizzled.disconnect(on_fizzle)
	var ok: bool = fizzled.size() == 1
	ok = ok and String(fizzled[0][2]) == "target_gone"
	ok = ok and controller.table_monsters.size() == monsters_before
	ok = ok and controller.stack.is_empty()
	_check("a dead target makes the effect FIZZLE (nothing applied)", ok)
	controller.teardown()

# --- T5: 3 and 4 players ------------------------------------------------------

func _test_many_players() -> void:
	for count in [3, 4]:
		var controller = ControllerScript.new()
		controller.setup(count, 20 + count, PassDriver.new())
		var ok: bool = controller.state.players.size() == count
		for pid in range(count):
			ok = ok and int(controller.state.players[pid]["cents"]) == 3
			controller.begin_turn(pid)
			ok = ok and int(controller.state.current_player_index) == pid
		var table_snapshot: Dictionary = controller.snapshot_for(-1)
		var players: Array = table_snapshot.get("players", [])
		ok = ok and players.size() == count
		ok = ok and int(players[count - 1]["hand_count"]) >= 1
		ok = ok and (players[count - 1]["hand"] as Array).is_empty()   # table sees no hand
		controller.end_turn()
		ok = ok and int(controller.state.current_player_index) == 0     # wraps around
		var legal: Dictionary = controller.ui_actions(count - 1)
		ok = ok and String(legal.get("phase", "")) != ""
		_check("%d players: turn order, starts at 3¢, snapshot and wrap" % count, ok)
		controller.teardown()

# --- Reporting ----------------------------------------------------------------

func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks.append({"label": label, "ok": ok})
	print("  [priority-test] %s: %s%s" % ["PASS" if ok else "FAIL", label,
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
