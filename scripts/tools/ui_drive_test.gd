extends Node
## TEMPORARY diagnostic driver: instantiates the REAL hotseat scene and drives
## it through its own click handlers (like a human would), P1 full turn then
## P2 full turn, printing where actions get refused or stall.

var ui
var _frames_waiting := 0

func _ready() -> void:
	ui = load("res://scenes/game_scene.tscn").instantiate()
	add_child(ui)
	EventBus.priority_pending.connect(_on_asked)
	EventBus.player_died.connect(_on_died)
	_run()

## Mimic the death-choice overlay: first loot option, first item option
## (ratifica #5 — the death request now carries BOTH choices).
func _on_died(pid: int, penalty: Dictionary) -> void:
	var loot_options: Array = penalty.get("loot_options", [])
	var item_options: Array = penalty.get("item_options", [])
	var choice := {
		"loot_id": String(loot_options[0]) if not loot_options.is_empty() else "",
		"item_id": String(item_options[0]) if not item_options.is_empty() else "",
	}
	EventBus.player_death_resolved.emit.call_deferred(pid, choice)

func _on_asked(pid: int, _type: String, _payload: Dictionary) -> void:
	# mimic the human: whoever is asked answers (PASS) on a later frame,
	# through the scene's own _respond gate exactly like the buttons do.
	_do_respond.call_deferred(pid)

func _do_respond(pid: int) -> void:
	if not is_instance_valid(ui):
		return
	if ui._priority_open and ui._priority_player == pid:
		print("  [driver] P%d responds PASS (window=%s)" % [pid + 1, ui._priority_type])
		ui._respond({"action": "pass"})

func _settle(max_frames := 120) -> void:
	var f := 0
	while f < max_frames:
		await get_tree().process_frame
		f += 1
		var busy: bool = ui._priority_open or ui._pending_action != "" \
			or ui._controller.is_combat_in_progress() or not ui._controller.stack.is_empty()
		if not busy:
			return
	print("  [driver] WARNING: still busy after %d frames (priority_open=%s pending_action='%s' combat=%s stack=%d)" % [
		f, ui._priority_open, ui._pending_action, ui._controller.is_combat_in_progress(), ui._controller.stack.size()])

func _try(label: String, fn: Callable) -> void:
	print("\n[driver] %s (current=P%d)" % [label, GameState.current_player_index + 1])
	fn.call()
	await _settle()

func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	print("########## TURN OF P1 ##########")
	# keep P1 alive so we test the PLAIN handover (death path is exercised apart)
	GameState.players[0]["max_hp"] = 99
	GameState.players[0]["hp"] = 99
	await _try("P1 buys shop slot 0", func(): ui._on_shop_pressed(0))
	await _try("P1 plays hand card 0", func():
		ui._on_hand_pressed(0))
	if ui._pending_action.begins_with("target"):
		await _try("P1 picks monster target", func(): ui._on_monster_pressed(0))
	await _try("P1 attacks", func():
		ui._pending_action = "attack"
		ui._on_monster_pressed(0))

	print("\n[driver] P1 presses END TURN")
	ui._on_end_turn()
	await get_tree().process_frame
	print("[driver] overlay='%s' button='%s' | current player index=%d" % [
		ui._overlay_label.text, ui._overlay_button.text, GameState.current_player_index])

	print("\n[driver] device passed: pressing 'Start next turn'")
	ui._on_overlay_button()
	await get_tree().process_frame
	print("[driver] after start: current index=%d (expected 1 for P2)" % GameState.current_player_index)

	print("########## TURN OF P2 ##########")
	await _try("P2 buys shop slot 0", func(): ui._on_shop_pressed(0))
	await _try("P2 plays hand card 0", func(): ui._on_hand_pressed(0))
	if ui._pending_action.begins_with("target"):
		await _try("P2 picks monster target", func(): ui._on_monster_pressed(0))
	await _try("P2 attacks", func():
		ui._pending_action = "attack"
		ui._on_monster_pressed(0))

	print("\n[driver] button states on P2 turn (from _refresh):")
	print("  attack disabled=%s end disabled=%s priority_open=%s" % [
		ui._attack_button.disabled, ui._end_button.disabled, ui._priority_open])
	print("[driver] P1 hp=%d/%d cents=%d | P2 cents=%d hand=%s" % [
		GameState.players[0]["hp"], GameState.players[0]["max_hp"], GameState.players[0]["cents"],
		GameState.players[1]["cents"], str(GameState.players[1]["hand"])])
	print("[driver] DONE")
	get_tree().quit(0)
