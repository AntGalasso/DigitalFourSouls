extends Node
## STEP 3 — self-play harness (console proof, no UI).
##
## Two players, three full rounds of buy -> attack -> loot per player. Drives
## the shared MatchController with robot heuristics (buy the cheapest
## affordable treasure, attack the first occupied monster slot, play any
## behavior loot drawn). Game rules live in the controller — this scene only
## decides WHAT the robot does and prints the story.
##
## Architecture self-checks (fail-fast, exit 1):
##  - STEP A: duplicate copies of the same passive card coexist (instance ids)
##  - STEP C: played loot does not accumulate CardEffect instances
##  - STEP F: scripted + data roll bonuses aggregate through the registry
## And a final PROJECT_STATUS thermometer (card count, checks, playability).
##
## HOW TO RUN: run_test.bat, or
##   godot --headless --path . res://scenes/turn_loop_test.tscn [-- seed]

const ROUNDS := 3
const CARD_DIR := "res://resources/cards/base_set/"
## Preload (not class_name): the global class cache is only refreshed by the
## editor, so headless CLI runs resolve this via preload instead.
const MatchControllerScript := preload("res://scripts/core/match_controller.gd")

var _controller
var _self_checks: Array = []        # [{name, ok}] — reported by _print_summary

## Keep in sync with PROJECT_STATUS.md §4.
const PLAYABLE_BY_HUMAN := false

func _ready() -> void:
	print("== TEST START ==")
	var run_seed := 8
	var user_args := OS.get_cmdline_user_args()
	if user_args.size() > 0:
		run_seed = int(user_args[0])
	print("seed: %d" % run_seed)
	EventBus.cents_changed.connect(_on_cents_changed)
	_controller = MatchControllerScript.new()
	_controller.setup(2, run_seed)
	_check_duplicate_copies()

	var match_over := false
	for round in range(1, ROUNDS + 1):
		print("\n============== ROUND %d ==============" % round)
		for player in GameState.players:
			_run_robot_turn(player["id"])
			if GameState.players[player["id"]]["hp"] <= 0:
				print("  >>> P%d has died — match over" % (player["id"] + 1))
				match_over = true
				break
		if match_over:
			break
		_print_state("end of round %d" % round)

	print("\n============== TEST COMPLETE ==============")
	_print_state("final")
	_check_effect_lifecycle()
	_check_roll_bonus()
	_print_summary()

func _run_robot_turn(player_id: int) -> void:
	print("\n--- P%d turn ---" % (player_id + 1))
	_controller.begin_turn(player_id)
	_robot_buy(player_id)
	_robot_attack(player_id)
	_robot_loot(player_id)
	EventBus.turn_ended.emit(player_id)
	print("--- P%d turn end ---" % (player_id + 1))

func _robot_buy(player_id: int) -> void:
	EventBus.phase_changed.emit(player_id, "buy")
	print("  [buy phase]")
	var bought_any := false
	for treasure in _controller.shop:
		if _controller.buy(treasure, player_id):
			print("  buy: bought %s for %dc (now %dc)" % [treasure.display_name, treasure.cost_cents, GameState.players[player_id]["cents"]])
			bought_any = true
	if not bought_any:
		print("  buy: nothing affordable or left to buy")

func _robot_attack(player_id: int) -> void:
	EventBus.phase_changed.emit(player_id, "attack")
	print("  [attack phase]")
	if _controller.table_monsters.is_empty():
		print("  attack: no monsters on the table — skipping")
		return
	var monster: Dictionary = _controller.table_monsters[0]  # robot heuristic: first slot
	var monster_card: CardResource = monster["card"]
	var result: Dictionary = _controller.attack(monster["instance_id"], player_id)
	if result["bonus"] != 0:
		print("  attack: %s (die %d, hp %d) — roll %d (+%d bonus) vs die %d" % [monster_card.display_name, monster_card.die_value, monster["hp"], result["roll"], result["bonus"], monster_card.die_value])
	else:
		print("  attack: %s (die %d, hp %d) — roll %d vs die %d" % [monster_card.display_name, monster_card.die_value, monster["hp"], result["roll"], monster_card.die_value])
	if result["hit"]:
		print("  attack: HIT")
	else:
		print("  attack: MISS — %s deals 1 damage" % monster_card.display_name)

func _robot_loot(player_id: int) -> void:
	EventBus.phase_changed.emit(player_id, "loot")
	print("  [loot phase]")
	var hand: Array = GameState.players[player_id]["hand"]
	if hand.is_empty():
		print("  loot: hand empty")
		return
	for card_id in hand.duplicate():
		var card: CardResource = _controller.card_resource(card_id)
		if card == null:
			continue
		if card.effect_script_path == "" and card.simple_effect == "":
			print("  loot: drew %s (vanilla) — kept in hand" % card.display_name)
			continue
		var payload := {}
		if not _controller.table_monsters.is_empty():
			payload = {"target_id": _controller.table_monsters[0]["instance_id"]}
		print("  loot: played %s" % card.display_name)
		_controller.play_loot(card, player_id, payload)
		GameState.players[player_id]["hand"].erase(card_id)

func _on_cents_changed(player_id: int, delta: int, new_total: int) -> void:
	print("  cents: P%d %+d -> %d" % [player_id + 1, delta, new_total])

# --- Architecture checks (Metaprompt 03) --------------------------------------

## STEP A: two copies of the same passive card must coexist. Both copies of
## Sack of Pennies fire on turn_started -> P0 should gain 6c (not 3).
## Runs before the demo rounds so the table state stays untouched.
func _check_duplicate_copies() -> void:
	var p: Dictionary = GameState.players[0]
	var sack: CardResource = load(CARD_DIR + "treasure_sack_of_pennies.tres")
	if sack == null:
		Log.error("turn_loop_test: treasure_sack_of_pennies.tres missing (run the import)")
		get_tree().quit(1)
		return
	var cents_before: int = p["cents"]
	CardEffectRegistry.register_card(sack, 0, "treasure_sack_of_pennies#dupA")
	CardEffectRegistry.register_card(sack, 0, "treasure_sack_of_pennies#dupB")
	EventBus.turn_started.emit(0)
	var gained: int = p["cents"] - cents_before
	var ok := gained == 6
	print("  STEP A duplicate-copy check: %s (2 copies fired, +%d cents)" % ["PASS" if ok else "FAIL", gained])
	CardEffectRegistry.unregister_card(0, "treasure_sack_of_pennies#dupA")
	CardEffectRegistry.unregister_card(0, "treasure_sack_of_pennies#dupB")
	_record_check("STEP A duplicate-copy coexistence", ok)

## STEP C: played loot must not accumulate CardEffect instances. Playing 5
## single-use Bombs should leave _effects exactly as big as before.
func _check_effect_lifecycle() -> void:
	var before: int = CardEffectRegistry.effect_count()
	var bomb: CardResource = load(CARD_DIR + "loot_bomb.tres")
	if bomb == null:
		Log.error("turn_loop_test: loot_bomb.tres missing (run the import)")
		get_tree().quit(1)
		return
	for i in range(5):
		CardEffectRegistry.play_card(bomb, 0, {})
	var after: int = CardEffectRegistry.effect_count()
	var ok := after == before
	print("  STEP C lifecycle check: %s (effects %d -> %d after 5 loot plays)" % ["PASS" if ok else "FAIL", before, after])
	_record_check("STEP C effect lifecycle", ok)

## STEP F: scripted roll-bonus aggregation (The Money = Power). At 10c the
## scripted effect must add +2; Steven (owned from the demo) adds +1 — the
## registry must sum both paths into a single get_roll_bonus().
func _check_roll_bonus() -> void:
	var p: Dictionary = GameState.players[0]
	var mp: CardResource = load(CARD_DIR + "treasure_money_is_power.tres")
	if mp == null:
		Log.error("turn_loop_test: treasure_money_is_power.tres missing (run the import)")
		get_tree().quit(1)
		return
	p["cents"] = 10
	CardEffectRegistry.register_card(mp, 0, "treasure_money_is_power#check")
	var bonus: int = CardEffectRegistry.get_roll_bonus(0)
	CardEffectRegistry.unregister_card(0, "treasure_money_is_power#check")
	var ok := bonus == 3  # Steven(+1) + Money=Power at 10c(+2)
	print("  STEP F roll-bonus check: %s (steven +1 + money_is_power 10c/4 +2 = %d)" % ["PASS" if ok else "FAIL", bonus])
	_record_check("STEP F roll-bonus aggregation", ok)

## Terminal "thermometer": a minimal extract of PROJECT_STATUS.md so a run of
## run_test.bat answers the three key questions without opening any file.
func _print_summary() -> void:
	var passed := 0
	for check in _self_checks:
		if check["ok"]:
			passed += 1
	print("\n==== PROJECT STATUS (extract of PROJECT_STATUS.md) ====")
	print("  cards in catalogue: %d" % _controller.total_cards_at_setup)
	print("  self-checks: %d/%d PASS" % [passed, _self_checks.size()])
	for check in _self_checks:
		print("    - %s: %s" % [check["name"], "PASS" if check["ok"] else "FAIL"])
	print("  playable by a human today: %s" % ("YES" if PLAYABLE_BY_HUMAN else "NO — no UI, no input, self-play only"))
	get_tree().quit(0 if passed == _self_checks.size() else 1)

func _record_check(name: String, ok: bool) -> void:
	_self_checks.append({"name": name, "ok": ok})

func _print_state(label: String) -> void:
	print("\n-- STATE %s --" % label)
	var table: Array = []
	for monster in _controller.table_monsters:
		table.append("%s (hp %d)" % [monster["card"].id, monster["hp"]])
	print("  table: %s" % str(table))
	for p in GameState.players:
		print("  P%d: hp=%d cents=%d souls=%s hand=%s items=%s" % [
			p["id"] + 1, p["hp"], p["cents"], str(p["souls"]), str(p["hand"]), str(p["items_passive"])])
