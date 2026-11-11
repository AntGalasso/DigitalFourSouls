extends Node
## UI CANARY (M2) — drives the REAL passive scene through its own handlers,
## exactly like a human clicking, and asserts what the user would see.
##
## Covered:
##  1. P1 turn: buy, play a hand card (the SERVER asks for the target, the
##     driver answers TARGET_REQUEST by clicking a monster), attack.
##  2. Every priority window is answered by pressing the overlay's PASS button.
##  3. END TURN -> "pass the device" overlay -> P2 starts.
##  4. DEATH: P2 is left at 1 HP, a fixed die makes the attack a miss, and the
##     driver completes the TWO-STEP penalty overlay (choose the loot, then the
##     item) through the real buttons. The engine must apply the penalty and
##     start the next turn.
##  5. No stall: _settle() must return without hitting its frame cap (this is
##     the old "still busy" targeting warning, now a hard failure).
##
## Exits 0 only if every expectation passed.

const CARD_DIR := "res://resources/cards/base_set/"

var ui
var _failures: Array = []
var _real_rng = null

## Deterministic die: always 1, so an attack against die >= 2 always misses.
class FixedRng extends RefCounted:
	func randi_range(_from: int, _to: int) -> int:
		return 1

func _ready() -> void:
	ui = load("res://scenes/game_scene.tscn").instantiate()
	add_child(ui)
	_run()

func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	print("\n########## TURN OF P1 ##########")
	GameState.players[0]["max_hp"] = 99
	GameState.players[0]["hp"] = 99
	ui._session.emit_snapshot()
	await get_tree().process_frame
	await _step("P1 buys shop slot 0", func(): ui._on_shop_pressed(0))
	await _step("P1 plays the first hand card", func(): ui._on_hand_pressed(_first_hand_card()))
	await _step("P1 attacks slot 0", func(): ui._on_monster_pressed(0))
	_expect(not ui._session.controller.is_combat_in_progress(), "combat closed after the attack")

	print("\n[driver] P1 presses END TURN")
	await _step("P1 ends the turn", func(): ui._on_end_turn())
	_expect(ui._awaiting_device, "device overlay shown after END TURN")
	print("[driver] overlay='%s' button='%s'" % [ui._overlay_label.text, ui._overlay_button.text])
	ui._on_overlay_button()
	await _settle()
	_expect(GameState.current_player_index == 1, "P2 is the active player after the handover")

	print("\n########## TURN OF P2 (death path) ##########")
	await _step("P2 buys shop slot 0", func(): ui._on_shop_pressed(0))
	var p2: Dictionary = GameState.players[1]
	# Fixture: one non-eternal item so the penalty's item choice is reachable.
	if not p2["items_passive"].has("treasure_the_bible"):
		p2["items_passive"].append("treasure_the_bible")
		CardEffectRegistry.register_card(load(CARD_DIR + "treasure_the_bible.tres"), 1, "treasure_the_bible#canary")
	p2["max_hp"] = 1
	p2["hp"] = 1
	p2["hand"] = ["loot_bomb", "loot_dinner"]
	p2["character_tapped"] = false
	p2["loot_played"] = 0
	# One high-die monster + a die that always rolls 1 => guaranteed miss.
	var controller = ui._session.controller
	controller.table_monsters.clear()
	var fly: CardResource = load(CARD_DIR + "monster_attack_fly.tres")
	controller.table_monsters.append({"instance_id": "monster_attack_fly#canary", "card": fly, "hp": 5})
	CardEffectRegistry.register_monster(fly, "monster_attack_fly#canary")
	ui._session.emit_snapshot()
	await get_tree().process_frame
	_real_rng = Rng.rng
	Rng.rng = FixedRng.new()
	var cents_before: int = int(p2["cents"])
	var hand_before: Array = (p2["hand"] as Array).duplicate()
	print("[driver] P2 attacks at 1 HP with a forced miss (roll 1 vs die %d)" % fly.die_value)
	await _step("P2 attacks slot 0", func(): ui._on_monster_pressed(0))
	Rng.rng = _real_rng
	_real_rng = null

	_expect(int(p2["cents"]) == cents_before - 1, "death cost 1 cent")
	_expect((p2["hand"] as Array).size() == hand_before.size() - 1, "death discarded exactly one loot card")
	_expect(not (p2["hand"] as Array).has("loot_bomb"), "the chosen loot (Bomb) is the discarded one")
	_expect((p2["items_passive"] as Array).is_empty(), "the chosen item was lost")
	_expect(bool(p2["character_tapped"]), "character tapped by the penalty")
	_expect(int(GameState.current_player_index) == 0, "turn advanced to P1 after the death")
	_expect(ui._awaiting_device, "device overlay after the death handover")

	print("\n[driver] continuing to P1's next turn")
	ui._on_overlay_button()
	await _settle()
	_expect(not ui._awaiting_device and int(GameState.current_player_index) == 0, "P1 is active and the overlay is gone")

	var passed: int = 7 - _failures.size()
	print("\n[driver] canary: %d/7 PASS" % passed)
	for failure in _failures:
		print("  [driver] FAIL: %s" % failure)
	print("[driver] DONE")
	get_tree().quit(0 if _failures.is_empty() else 1)

# --- Driving ------------------------------------------------------------------

func _step(label: String, fn: Callable) -> void:
	print("\n[driver] %s (current=P%d)" % [label, GameState.current_player_index + 1])
	fn.call()
	await _settle()

## Waits until the UI has nothing pending, answering what a human would answer:
## a target request by clicking monster 0, a window with PASS, a death penalty
## with the first offered choice (loot, then item).
func _settle(max_frames := 240) -> void:
	var frames: int = 0
	while frames < max_frames:
		await get_tree().process_frame
		frames += 1
		if not ui._death.is_empty():
			if ui._death_stage == "done":
				continue
			_press_first_choice()
			continue
		if ui._target.is_empty() == false:
			ui._on_monster_pressed(0)
			continue
		if not ui._window.is_empty():
			_press_overlay_button("PASS")
			continue
		if ui._awaiting_device:
			return
		var controller = ui._session.controller
		if controller.is_combat_in_progress() or not controller.stack.is_empty():
			continue
		return
	_failures.append("still busy after %d frames (window=%s target=%s death=%s)" % [
		max_frames, not ui._window.is_empty(), not ui._target.is_empty(), not ui._death.is_empty()])
	print("  [driver] WARNING: still busy after %d frames (priority_open=%s target=%s death=%s combat=%s stack=%d)" % [
		frames, not ui._window.is_empty(), not ui._target.is_empty(), not ui._death.is_empty(),
		ui._session.controller.is_combat_in_progress(), ui._session.controller.stack.size()])

func _press_overlay_button(prefix: String) -> bool:
	for child in ui._overlay_box.get_children():
		if child is Button and String(child.text).begins_with(prefix):
			print("  [driver] presses '%s'" % String(child.text))
			child.pressed.emit()
			return true
	return false

func _press_first_choice() -> void:
	for child in ui._overlay_box.get_children():
		if child is Button:
			print("  [driver] chooses '%s'" % String(child.text))
			child.pressed.emit()
			return

func _first_hand_card() -> String:
	var players: Array = ui._snapshot.get("players", [])
	var viewer: int = int(ui._snapshot.get("viewer_player_id", 0))
	if viewer < players.size():
		var hand: Array = (players[viewer] as Dictionary).get("hand", [])
		if not hand.is_empty():
			return String(hand[0])
	return ""

func _expect(condition: bool, label: String) -> void:
	var ok: bool = condition
	print("  [driver] %s: %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		_failures.append(label)
