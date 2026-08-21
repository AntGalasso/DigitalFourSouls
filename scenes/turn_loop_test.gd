extends Node
## STEP 3 — self-play harness (console proof, no UI), updated by MP07.
##
## Two players, three full rounds of free-order actions per player (buy /
## loot / attack in any order, 1 buy, 1 loot +1 with the character effect, 1
## attack per turn). Drives the shared MatchController — game rules live
## there; this scene only decides WHAT the robot does and prints the story.
##
## Architecture self-checks (fail-fast, exit 1):
##  - STEP A: duplicate copies of the same passive card coexist (instance ids)
##  - STEP C: played loot does not accumulate CardEffect instances
##  - STEP F: scripted + data roll bonuses aggregate through the registry
##  - STEP G: death is a penalty (1 loot / 1 item / 1 cent), never match over
##  - STEP H: eternal items (D6 reroll, Belial Book adjust) work on the
##            pending attack roll, even across players; recharge at turn end
##  - STEP I: action limits (1 buy, 1 attack, 1 loot + character effect)
##  - STEP J: healing at full HP permanently increases max HP
##  - STEP K (MP07 A): active player alternates P1->P2->P1->P2 over 4 turns
##  - STEP L (MP07 C): every player starts with exactly 3¢
##  - STEP M (MP07 D): STOP attack is not a rule — the attack continues
##  - STEP N (MP07 E): the shop has exactly 2 slots, refilled after a buy
##  - STEP O (MP07 B): roll timing — eternal modifiers only while the roll is
##            PENDING (after the roll, before it resolves; refused before/after)
##  - STEP P (MP07 F): priority window — every player is asked starting from
##            the active player; a non-active player responds with loot and
##            eternal items during the active player's turn
##  - STEP Q (MP07 G): hit damage = character base (1) + item bonuses, never
##            a hardcoded resolver value
##  - STEP R (MP07 H): every item has description + activation_type/cost
##  - STEP S (MP07 I): every monster declares effect_trigger/effect_description
##  - STEP T (MP07 J): boss kills become ONE named soul card counting
##            soul_value (2 counts double); win is declared at 4 soul value
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
var _run_seed := 8

## Keep in sync with PROJECT_STATUS.md §4.
const PLAYABLE_BY_HUMAN := true

# scratch vars for the async self-checks (lambdas capture members, not locals)
var _check_roll_before := -1
var _check_roll_after := -1
var _check_d6_ok := false
var _check_d6_new := -1
var _check_belial_ok := false
var _check_first_attacked_roll := -1
var _check_second_attacked_roll := -1
var _priority_et_ok := false
var _check_win_pid := -1
var _check_boss_seen := false
# member guard flags: captured SCALAR locals do NOT persist across lambda
# calls in Godot 4.7 (each call re-reads the original captured value), so
# every "run this branch only once" flag must live on the test node.
var _check_roll_checked := false
var _o_saw_roll := false
var _o_saw_damage := false
var _p_roll_seen := false
var _p1_roll_asks := 0
var _g_game_over_seen := false

func _ready() -> void:
	print("== TEST START ==")
	var user_args := OS.get_cmdline_user_args()
	if user_args.size() > 0:
		_run_seed = int(user_args[0])
	print("seed: %d" % _run_seed)
	EventBus.cents_changed.connect(_on_cents_changed)
	_run_all()

func _run_all() -> void:
	_controller = MatchControllerScript.new()
	_controller.setup(2, _run_seed)
	## Robot response policies: auto-resolve every priority window (pass for
	## everything except "roll", which the active player resolves), auto-pick
	## the first item on death. Both stay connected for the whole run except
	## while a self-check installs its own intercepting handler.
	EventBus.priority_pending.connect(_robot_auto_priority)
	EventBus.player_died.connect(_robot_auto_death)

	_check_starting_cents()
	_check_shop_slots()
	_check_duplicate_copies()

	for round in range(1, ROUNDS + 1):
		print("\n============== ROUND %d ==============" % round)
		for player in GameState.players:
			await _run_robot_turn(player["id"])
		_print_state("end of round %d" % round)

	print("\n============== TEST COMPLETE ==============")
	_print_state("final")
	_check_effect_lifecycle()
	_check_roll_bonus()
	_check_turn_alternation()
	await _check_death_penalty()
	await _check_eternal_items()
	await _check_action_limits()
	_check_heal_at_max()
	await _check_no_stop_attack()
	await _check_roll_timing()
	await _check_priority_window()
	await _check_attack_damage()
	_check_item_descriptions()
	_check_monster_effects()
	_check_boss_souls()
	_print_summary()

func _run_robot_turn(player_id: int) -> void:
	print("\n--- P%d turn ---" % (player_id + 1))
	_controller.begin_turn(player_id)
	_robot_buy(player_id)
	_robot_loot(player_id)
	var attack_result: Dictionary = await _robot_attack(player_id)
	if attack_result.get("outcome", "") != "player_died":
		_controller.end_turn()
	print("--- P%d turn end ---" % (player_id + 1))

func _robot_auto_priority(player_id: int, stack_type: String, _payload: Dictionary) -> void:
	var action := "resolve" if stack_type == "roll" else "pass"
	EventBus.priority_given.emit.call_deferred(player_id, {"action": action})

func _robot_auto_death(_player_id: int, penalty: Dictionary) -> void:
	var options: Array = penalty.get("item_options", [])
	var choice: String = options[0] if not options.is_empty() else ""
	EventBus.player_death_resolved.emit.call_deferred(GameState.current_player_index, choice)

func _robot_buy(player_id: int) -> void:
	print("  [buy]")
	var bought_any := false
	for i in range(_controller.shop_slots.size()):
		var treasure: CardResource = _controller.get_shop_card(i)
		if treasure != null and _controller.buy(i, player_id):
			print("  buy: bought %s for %dc (now %dc)" % [treasure.display_name, treasure.cost_cents, GameState.players[player_id]["cents"]])
			bought_any = true
			break  # one purchase per turn
	if not bought_any:
		print("  buy: nothing affordable or left to buy")

func _robot_loot(player_id: int) -> void:
	print("  [loot]")
	var hand: Array = GameState.players[player_id]["hand"]
	if hand.is_empty():
		print("  loot: hand empty")
		return
	var played_any := false
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
		if _controller.play_loot(card, player_id, payload):
			print("  loot: played %s" % card.display_name)
			GameState.players[player_id]["hand"].erase(card_id)
			played_any = true
		else:
			print("  loot: can't play %s (loot limit reached)" % card.display_name)
	if not played_any:
		print("  loot: nothing playable in hand")

func _robot_attack(player_id: int) -> Dictionary:
	print("  [attack]")
	if _controller.table_monsters.is_empty():
		print("  attack: no monsters on the table — skipping")
		return {"outcome": "skipped"}
	var monster: Dictionary = _controller.table_monsters[0]  # robot heuristic: first slot
	var monster_card: CardResource = monster["card"]
	print("  attack: %s (die %d, hp %d)" % [monster_card.display_name, monster_card.die_value, monster["hp"]])
	var result: Dictionary = await _controller.attack(monster["instance_id"], player_id)
	match result.get("outcome", ""):
		"killed":
			print("  attack: %s killed after %d rolls" % [monster_card.display_name, result["steps"]])
		"player_died":
			print("  attack: P%d died after %d rolls" % [player_id + 1, result["steps"]])
	return result

func _on_cents_changed(player_id: int, delta: int, new_total: int) -> void:
	print("  cents: P%d %+d -> %d" % [player_id + 1, delta, new_total])

# --- Architecture checks (Metaprompt 03 + MP06 + MP07) -------------------------

## STEP L (MP07 C): right after setup every player must have exactly 3¢.
func _check_starting_cents() -> void:
	print("\n-- CHECK: starting cents (MP07 C) --")
	var ok: bool = GameState.players[0]["cents"] == 3 and GameState.players[1]["cents"] == 3
	print("  STEP L starting-cents check: %s (P1=%d¢ P2=%d¢)" % ["PASS" if ok else "FAIL", GameState.players[0]["cents"], GameState.players[1]["cents"]])
	_record_check("STEP L starting cents = 3 (C)", ok)

## STEP N (MP07 E): the shop shows exactly 2 slots; a purchase refills the
## slot from the treasure deck and the bought card never comes back.
func _check_shop_slots() -> void:
	print("\n-- CHECK: shop 2 slots (MP07 E) --")
	var ok: bool = _controller.shop_slots.size() == 2
	var first_card: CardResource = _controller.get_shop_card(0)
	var first_id: String = first_card.id if first_card != null else ""
	GameState.players[0]["cents"] = 30
	var bought: bool = _controller.buy(0, 0)
	ok = ok and bought
	ok = ok and _controller.shop_slots.size() == 2  # refilled back to 2
	var still_visible := false
	for slot in _controller.shop_slots:
		if slot["card"].id == first_id:
			still_visible = true
	ok = ok and not still_visible                  # bought card left the shop for good
	print("  STEP N shop-slot check: %s (2 slots; '%s' bought and gone, deck refilled)" % ["PASS" if ok else "FAIL", first_id])
	_record_check("STEP N shop 2 slots + refill (E)", ok)

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
## scripted effect must add +2, and Steven +1 — self-contained since the
## demo economy starts at 3¢ and treasures cost 10¢.
func _check_roll_bonus() -> void:
	var p: Dictionary = GameState.players[0]
	_clear_player_items(0)  # drop demo purchases so the check is self-contained
	var steven: CardResource = load(CARD_DIR + "treasure_steven.tres")
	var mp: CardResource = load(CARD_DIR + "treasure_money_is_power.tres")
	if steven == null or mp == null:
		Log.error("turn_loop_test: treasure_steven / treasure_money_is_power missing (run the import)")
		get_tree().quit(1)
		return
	p["cents"] = 10
	CardEffectRegistry.register_card(steven, 0, "treasure_steven#check")
	CardEffectRegistry.register_card(mp, 0, "treasure_money_is_power#check")
	var bonus: int = CardEffectRegistry.get_roll_bonus(0)
	CardEffectRegistry.unregister_card(0, "treasure_steven#check")
	CardEffectRegistry.unregister_card(0, "treasure_money_is_power#check")
	var ok := bonus == 3  # Steven(+1) + Money=Power at 10c(+2)
	print("  STEP F roll-bonus check: %s (steven +1 + money_is_power 10c/4 +2 = %d)" % ["PASS" if ok else "FAIL", bonus])
	_record_check("STEP F roll-bonus aggregation", ok)

## STEP K (MP07 A): four consecutive end_turn/begin_turn cycles must alternate
## P1 -> P2 -> P1 -> P2 (the human scene previously re-started the SAME player
## because the overlay re-began the current turn — fixed in game_scene.gd).
func _check_turn_alternation() -> void:
	print("\n-- CHECK: turn alternation (MP07 A) --")
	_controller.begin_turn(0)  # the demo rounds left P2 active; start from P1
	var sequence: Array = []
	for i in range(4):
		var next: int = _controller.end_turn()
		sequence.append(next)
		_controller.begin_turn(next)
	var ok: bool = sequence == [1, 0, 1, 0]
	ok = ok and GameState.current_player_index == 0
	print("  STEP K turn-alternation check: %s (next players over 4 turns: %s)" % ["PASS" if ok else "FAIL", str(sequence)])
	_record_check("STEP K turn alternation P1->P2 x4 (A)", ok)

## STEP G (MP06 f): death is a PENALTY — lose 1¢, 1 loot, 1 item, then the
## turn resolves (full HP restore) — it is never match over. The robot
## auto-picks the first item option, exactly like the human overlay will.
func _check_death_penalty() -> void:
	print("\n-- CHECK: death penalty (STEP G) --")
	var p: Dictionary = GameState.players[1]
	GameState.players[0]["cents"] = 10
	p["cents"] = 2
	p["hand"] = ["loot_bomb", "loot_dinner"]
	_clear_player_items(1)
	p["items_passive"].append("treasure_steven")
	_g_game_over_seen = false
	var on_won := func(_pid: int): _g_game_over_seen = true
	EventBus.game_won.connect(on_won)
	GameState.damage_player(1, 99, "death_check")
	await _controller.die(1)
	EventBus.game_won.disconnect(on_won)
	var ok: bool = p["cents"] == 1
	ok = ok and p["hand"] == ["loot_dinner"]                    # first loot lost
	ok = ok and not p["items_passive"].has("treasure_steven")   # item lost to the penalty
	ok = ok and p["hp"] == p["max_hp"]                          # turn resolved: full restore
	ok = ok and not _g_game_over_seen
	print("  STEP G death-penalty check: %s (lost 1¢, 1 loot, 1 item; hp restored; match continues)" % ["PASS" if ok else "FAIL"])
	_record_check("STEP G death penalty, never match over", ok)

## STEP H: eternal items work on the PENDING attack roll (MP07 B) — D6 rerolls
## and Belial Book adjusts by -1; the FINAL roll (what the attack resolves and
## monster_attacked carries) is the modified one. Recharge at end of the
## owner's turn and at the owner's next turn start. Two attacks, one modifier
## each: +5 bonus vs die 5 on an hp-1 monster guarantees the first roll kills,
## so final_roll IS the modified roll — no dice luck involved.
func _check_eternal_items() -> void:
	print("\n-- CHECK: eternal items on the pending roll (STEP H) --")
	var p0: Dictionary = GameState.players[0]
	var p1: Dictionary = GameState.players[1]
	p0["character_id"] = "character_isaac"
	p0["eternal_item_id"] = "eternal_d6"
	p0["eternal_used"] = false
	p1["character_id"] = "character_judas"
	p1["eternal_item_id"] = "eternal_belial_book"
	p1["eternal_used"] = false
	var fly: CardResource = load(CARD_DIR + "monster_fly.tres")
	var steven: CardResource = load(CARD_DIR + "treasure_steven.tres")
	if fly == null or steven == null:
		Log.error("turn_loop_test: monster_fly / treasure_steven missing (run the import)")
		get_tree().quit(1)
		return
	for i in range(5):
		CardEffectRegistry.register_card(steven, 0, "treasure_steven#h%d" % i)
	_controller.begin_turn(0)
	## Attack 1: Belial Book -1 only — roll_after is roll_before - 1, always.
	_check_roll_before = -1
	_check_roll_after = -1
	_check_belial_ok = false
	_check_first_attacked_roll = -1
	_check_roll_checked = false
	var handler_belial := func(pid: int, stack_type: String, _payload: Dictionary):
		if stack_type == "roll" and not _check_roll_checked:
			_check_roll_checked = true
			_check_roll_before = _controller.get_pending_roll().get("roll", -1)
			_check_belial_ok = _controller.use_eternal_item(1, {"delta": -1}).get("ok", false)
			_check_roll_after = _controller.get_pending_roll().get("roll", -1)
		EventBus.priority_given.emit.call_deferred(pid, {"action": "resolve" if stack_type == "roll" else "pass"})
	var on_attacked := func(_pid: int, _iid: String, roll: int, _bonus: int, _die: int):
		if _check_first_attacked_roll == -1:
			_check_first_attacked_roll = roll  # FIRST emission = the modified roll
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_fly#h1", "card": fly, "hp": 1})
	EventBus.priority_pending.disconnect(_robot_auto_priority)
	EventBus.priority_pending.connect(handler_belial)
	EventBus.monster_attacked.connect(on_attacked)
	var result_a: Dictionary = await _controller.attack("monster_fly#h1", 0)
	EventBus.priority_pending.disconnect(handler_belial)
	EventBus.priority_pending.connect(_robot_auto_priority)
	EventBus.monster_attacked.disconnect(on_attacked)
	var ok: bool = _check_belial_ok
	ok = ok and _check_roll_after == _check_roll_before - 1   # Belial -1 applied while pending
	ok = ok and _check_first_attacked_roll == _check_roll_after
	ok = ok and result_a.get("final_roll", -1) == _check_roll_after
	## Attack 2: D6 reroll only — attacked/final roll equal the reroll value.
	_check_d6_ok = false
	_check_d6_new = -1
	_check_second_attacked_roll = -1
	_check_roll_checked = false
	var handler_d6 := func(pid: int, stack_type: String, _payload: Dictionary):
		if stack_type == "roll" and not _check_roll_checked:
			_check_roll_checked = true
			var res: Dictionary = _controller.use_eternal_item(0, {})
			_check_d6_ok = res.get("ok", false)
			_check_d6_new = res.get("new_roll", -1)
		EventBus.priority_given.emit.call_deferred(pid, {"action": "resolve" if stack_type == "roll" else "pass"})
	var on_attacked2 := func(_pid: int, _iid: String, roll: int, _bonus: int, _die: int):
		if _check_second_attacked_roll == -1:
			_check_second_attacked_roll = roll  # FIRST emission = the reroll
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_fly#h2", "card": fly, "hp": 1})
	_controller.begin_turn(0)  # the attack limit is 1 per turn; fresh turn for the 2nd attack
	EventBus.priority_pending.disconnect(_robot_auto_priority)
	EventBus.priority_pending.connect(handler_d6)
	EventBus.monster_attacked.connect(on_attacked2)
	var result_b: Dictionary = await _controller.attack("monster_fly#h2", 0)
	EventBus.priority_pending.disconnect(handler_d6)
	EventBus.priority_pending.connect(_robot_auto_priority)
	EventBus.monster_attacked.disconnect(on_attacked2)
	for i in range(5):
		CardEffectRegistry.unregister_card(0, "treasure_steven#h%d" % i)
	ok = ok and _check_d6_ok and _check_d6_new > 0
	ok = ok and _check_second_attacked_roll == _check_d6_new
	ok = ok and result_b.get("final_roll", -1) == _check_d6_new
	_controller.end_turn()  # D6/Belial recharge at end of the owner's turn
	ok = ok and not p0["eternal_used"]
	p1["eternal_used"] = true
	_controller.begin_turn(1)  # ...and at the owner's turn start
	ok = ok and not p1["eternal_used"]
	_controller.end_turn()
	print("  STEP H eternal-item check: %s (Belial -1: roll %d -> %d; D6 reroll -> %d)" % [
		"PASS" if ok else "FAIL", _check_roll_before, _check_roll_after, _check_d6_new])
	_record_check("STEP H eternal items on the pending roll (B)", ok)

## STEP I (MP06 c): per-turn action limits — 1 buy, 1 loot +1 via the
## character effect, 1 attack; the second buy / third loot / second attack
## must be refused.
func _check_action_limits() -> void:
	print("\n-- CHECK: action limits (STEP I) --")
	_controller.begin_turn(0)
	var p: Dictionary = GameState.players[0]
	p["cents"] = 30
	var bought_1: bool = _controller.buy(0, 0)
	var bought_2: bool = _controller.buy(1, 0)                                       # refused: 1 buy per turn
	var loot_1: bool = _controller.play_loot(load(CARD_DIR + "loot_dinner.tres"), 0, {})
	var loot_2: bool = _controller.play_loot(load(CARD_DIR + "loot_pennies.tres"), 0, {})  # character effect
	var loot_3: bool = _controller.play_loot(load(CARD_DIR + "loot_bomb.tres"), 0, {})     # refused: limit
	var target_id: String = _controller.table_monsters[0]["instance_id"]
	var attack_1: Dictionary = await _controller.attack(target_id, 0)
	var attack_2: Dictionary = await _controller.attack(target_id, 0)               # refused: 1 attack per turn
	var ok: bool = bought_1 and not bought_2 and loot_1 and loot_2 and not loot_3
	ok = ok and attack_1.get("valid", false) and not attack_2.get("valid", false)
	_controller.end_turn()
	print("  STEP I action-limit check: %s (buy %s/%s, loot %s/%s/%s, attack %s/%s)" % [
		"PASS" if ok else "FAIL", bought_1, bought_2, loot_1, loot_2, loot_3,
		attack_1.get("valid", false), attack_2.get("valid", false)])
	_record_check("STEP I action limits", ok)

## STEP J (MP06 g): healing at full HP permanently raises max HP (Yum Heart
## rule) — a heal at full still nets +1 HP.
func _check_heal_at_max() -> void:
	print("\n-- CHECK: heal at max HP (STEP J) --")
	var p: Dictionary = GameState.players[1]
	var max_before: int = p["max_hp"]
	GameState.restore_hp(1)  # guarantee "full" before the heal
	GameState.heal(1, 1)
	var ok: bool = p["max_hp"] == max_before + 1 and p["hp"] == p["max_hp"]
	print("  STEP J heal-at-max check: %s (max_hp %d -> %d)" % ["PASS" if ok else "FAIL", max_before, p["max_hp"]])
	_record_check("STEP J heal at full max", ok)

## STEP M (MP07 D): STOP attack is NOT a rule. Even when a player answers the
## priority window with "stop", the attack continues until the monster or the
## player dies — no "stopped" outcome exists.
func _check_no_stop_attack() -> void:
	print("\n-- CHECK: STOP attack is not a rule (MP07 D) --")
	_controller.begin_turn(0)
	GameState.players[0]["max_hp"] = 99
	GameState.players[0]["hp"] = 99  # keep the loop bounded if the dice go cold
	if _controller.table_monsters.is_empty():
		Log.error("turn_loop_test: no monster to attack in STEP M")
		get_tree().quit(1)
		return
	var target_id: String = _controller.table_monsters[0]["instance_id"]
	var monster_card: CardResource = _controller.table_monsters[0]["card"]
	var handler := func(pid: int, stack_type: String, _payload: Dictionary):
		var action := "stop" if stack_type == "attack_declared" else ("resolve" if stack_type == "roll" else "pass")
		EventBus.priority_given.emit.call_deferred(pid, {"action": action})
	EventBus.priority_pending.disconnect(_robot_auto_priority)
	EventBus.priority_pending.connect(handler)
	var result: Dictionary = await _controller.attack(target_id, 0)
	EventBus.priority_pending.disconnect(handler)
	EventBus.priority_pending.connect(_robot_auto_priority)
	var outcome: String = result.get("outcome", "")
	var ok: bool = outcome in ["killed", "player_died"]
	print("  STEP M no-stop check: %s ('stop' on attack_declared ignored; outcome '%s' after %d rolls)" % [
		"PASS" if ok else "FAIL", outcome, result.get("steps", -1)])
	_record_check("STEP M no STOP attack (D)", ok)
	_controller.end_turn()

## STEP O (MP07 B): roll timing. The eternal modifier is ONLY valid while the
## roll is PENDING: refused with "no_pending_roll" during attack_declared and
## in the damage windows (the roll already resolved), accepted in the roll
## window, and refused again after the whole attack.
func _check_roll_timing() -> void:
	print("\n-- CHECK: roll pending timing (MP07 B) --")
	_controller.begin_turn(0)
	var p: Dictionary = GameState.players[0]
	p["character_id"] = "character_isaac"
	p["eternal_item_id"] = "eternal_d6"
	p["eternal_used"] = false
	var checks := {"declared": true, "roll": false, "after": true, "second": true, "roll_reason": ""}
	_o_saw_roll = false
	_o_saw_damage = false
	var handler := func(pid: int, stack_type: String, _payload: Dictionary):
		match stack_type:
			"attack_declared":
				var res: Dictionary = _controller.use_eternal_item(0, {})
				checks["declared"] = not res.get("ok", true) and res.get("reason", "") == "no_pending_roll"
			"roll":
				if not _o_saw_roll:
					_o_saw_roll = true
					var rres: Dictionary = _controller.use_eternal_item(0, {})
					checks["roll"] = rres.get("ok", false)
					checks["roll_reason"] = rres.get("reason", "")
			"monster_damage", "player_damage":
				if not _o_saw_damage:
					_o_saw_damage = true
					p["eternal_used"] = false  # isolate the timing rule from the once-per-turn rule
					var res: Dictionary = _controller.use_eternal_item(0, {})
					checks["after"] = not res.get("ok", true) and res.get("reason", "") == "no_pending_roll"
		EventBus.priority_given.emit.call_deferred(pid, {"action": "resolve" if stack_type == "roll" else "pass"})
	EventBus.priority_pending.disconnect(_robot_auto_priority)
	EventBus.priority_pending.connect(handler)
	await _controller.attack(_controller.table_monsters[0]["instance_id"], 0)
	EventBus.priority_pending.disconnect(handler)
	EventBus.priority_pending.connect(_robot_auto_priority)
	p["eternal_used"] = false
	var res2: Dictionary = _controller.use_eternal_item(0, {})
	checks["second"] = not res2.get("ok", true) and res2.get("reason", "") == "no_pending_roll"
	var ok: bool = checks["declared"] and checks["roll"] and checks["after"] and checks["second"]
	print("  STEP O roll-timing check: %s (declared:%s roll:%s[%s] damage:%s after:%s)" % [
		"PASS" if ok else "FAIL", checks["declared"], checks["roll"], checks["roll_reason"], checks["after"], checks["second"]])
	_record_check("STEP O roll pending timing (B)", ok)
	_controller.end_turn()

# scratch vars for STEP P (priority window)
var _priority_first_ask := -1
var _priority_roll_before := -1
var _priority_attacked_roll := -1
var _priority_p1_hp_before := -1

## STEP P (MP07 F): priority window. The window asks the ACTIVE player first;
## the NON-active player responds during the active player's turn — playing a
## loot card (character effect) AND its eternal item — and the attack roll
## resolves with the modified value.
func _check_priority_window() -> void:
	print("\n-- CHECK: priority window (MP07 F) --")
	var p0: Dictionary = GameState.players[0]
	var p1: Dictionary = GameState.players[1]
	p0["character_id"] = "character_isaac"
	p0["eternal_item_id"] = "eternal_d6"
	p0["eternal_used"] = false
	p1["character_id"] = "character_judas"
	p1["eternal_item_id"] = "eternal_belial_book"
	p1["eternal_used"] = false
	p1["character_effect_used"] = false
	p1["hand"] = ["loot_dinner"]
	_controller.begin_turn(0)
	if _controller.table_monsters.is_empty():
		Log.error("turn_loop_test: no monster to attack in STEP P")
		get_tree().quit(1)
		return
	var target_id: String = _controller.table_monsters[0]["instance_id"]
	_priority_first_ask = -1
	_priority_roll_before = -1
	_priority_attacked_roll = -1
	_priority_p1_hp_before = p1["hp"]
	_p_roll_seen = false
	_p1_roll_asks = 0
	var handler := func(pid: int, stack_type: String, _payload: Dictionary):
		if stack_type == "roll":
			if not _p_roll_seen:
				_p_roll_seen = true
				_priority_first_ask = pid
				_priority_roll_before = _controller.get_pending_roll().get("roll", -1)
			if pid == 1:
				_p1_roll_asks += 1
				if _p1_roll_asks == 1:
					EventBus.priority_given.emit.call_deferred(pid, {"action": "loot", "card_id": "loot_dinner", "target_id": ""})
					return
				if _p1_roll_asks == 2:
					EventBus.priority_given.emit.call_deferred(pid, {"action": "eternal", "payload": {"delta": -1}})
					return
		EventBus.priority_given.emit.call_deferred(pid, {"action": "resolve" if stack_type == "roll" else "pass"})
	var on_attacked := func(_pid: int, _iid: String, roll: int, _bonus: int, _die: int):
		if _priority_attacked_roll == -1:
			_priority_attacked_roll = roll  # FIRST emission = the modified roll
	_priority_et_ok = false
	var on_eternal := func(_pid: int, _iid: String, res: Dictionary): _priority_et_ok = res.get("ok", false)
	EventBus.priority_pending.disconnect(_robot_auto_priority)
	EventBus.priority_pending.connect(handler)
	EventBus.monster_attacked.connect(on_attacked)
	EventBus.eternal_used.connect(on_eternal)
	var result: Dictionary = await _controller.attack(target_id, 0)
	EventBus.priority_pending.disconnect(handler)
	EventBus.priority_pending.connect(_robot_auto_priority)
	EventBus.monster_attacked.disconnect(on_attacked)
	EventBus.eternal_used.disconnect(on_eternal)
	var ok: bool = _priority_first_ask == 0                        # active player asked first
	ok = ok and _priority_et_ok                                   # P1's eternal succeeded
	ok = ok and p1["character_effect_used"]                       # P1's loot used the character effect
	ok = ok and not p1["hand"].has("loot_dinner")                 # loot response consumed the card
	ok = ok and p1["hp"] == _priority_p1_hp_before + 1            # Dinner healed P1
	ok = ok and _priority_attacked_roll == _priority_roll_before - 1  # Belial -1 applied
	ok = ok and result.get("valid", false)
	print("  STEP P priority-window check: %s (first ask P%d; P1 responded with Dinner + Belial -1: roll %d -> %d)" % [
		"PASS" if ok else "FAIL", _priority_first_ask + 1, _priority_roll_before, _priority_attacked_roll])
	_record_check("STEP P priority window, non-active player responds (F)", ok)
	_controller.end_turn()

## STEP Q (MP07 G): hit damage = character base damage + item damage bonuses —
## never a hardcoded resolver value. Baseline is 1; Blood Clot (+1) makes it 2.
func _check_attack_damage() -> void:
	print("\n-- CHECK: hit damage from attack value (MP07 G) --")
	_controller.begin_turn(0)
	var p: Dictionary = GameState.players[0]
	p["damage"] = 1
	_clear_player_items(0)
	var fly: CardResource = load(CARD_DIR + "monster_fly.tres")
	if fly == null:
		Log.error("turn_loop_test: monster_fly.tres missing (run the import)")
		get_tree().quit(1)
		return
	var steven: CardResource = load(CARD_DIR + "treasure_steven.tres")
	CardEffectRegistry.register_card(steven, 0, "treasure_steven#q")
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_fly#q", "card": fly, "hp": 2})
	var amounts: Array = []
	var on_damaged := func(_iid: String, amount: int): amounts.append(amount)
	EventBus.monster_damaged.connect(on_damaged)
	await _controller.attack("monster_fly#q", 0)
	EventBus.monster_damaged.disconnect(on_damaged)
	var baseline: int = amounts[0] if not amounts.is_empty() else -1
	var clot: CardResource = load(CARD_DIR + "treasure_blood_clot.tres")
	if clot == null:
		Log.error("turn_loop_test: treasure_blood_clot.tres missing (run the import)")
		get_tree().quit(1)
		return
	CardEffectRegistry.register_card(clot, 0, "treasure_blood_clot#q")
	_controller.begin_turn(0)  # the attack limit is 1 per turn; fresh turn for the 2nd attack
	amounts.clear()
	EventBus.monster_damaged.connect(on_damaged)
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_fly#q2", "card": fly, "hp": 2})
	await _controller.attack("monster_fly#q2", 0)
	EventBus.monster_damaged.disconnect(on_damaged)
	var with_clot: int = amounts[0] if not amounts.is_empty() else -1
	CardEffectRegistry.unregister_card(0, "treasure_steven#q")
	CardEffectRegistry.unregister_card(0, "treasure_blood_clot#q")
	var ok: bool = baseline == 1 and with_clot == 2
	print("  STEP Q damage check: %s (baseline %d, with Blood Clot %d)" % ["PASS" if ok else "FAIL", baseline, with_clot])
	_record_check("STEP Q damage from attack value (G)", ok)
	_controller.end_turn()

## STEP R (MP07 H): every item declares a description and an activation
## category (passive | activated_free | activated_paid).
func _check_item_descriptions() -> void:
	print("\n-- CHECK: item descriptions (MP07 H) --")
	var ids: Array = ["treasure_sack_of_pennies", "treasure_the_bible", "treasure_steven",
		"treasure_money_is_power", "treasure_change_purse", "treasure_crows_heart",
		"treasure_blood_clot", "eternal_d6", "eternal_belial_book", "eternal_yum_heart"]
	var ok := true
	var failures: Array = []
	for id in ids:
		var card: CardResource = load(CARD_DIR + id + ".tres")
		if card == null:
			ok = false
			failures.append("%s: missing (run the import)" % id)
			continue
		if card.description == "":
			ok = false
			failures.append("%s: empty description" % id)
		if not ["passive", "activated_free", "activated_paid"].has(card.activation_type):
			ok = false
			failures.append("%s: activation_type '%s'" % [id, card.activation_type])
		if card.activation_type != "passive" and card.activation_cost == "":
			ok = false
			failures.append("%s: non-passive without activation_cost" % id)
	print("  STEP R item-description check: %s%s" % ["PASS" if ok else "FAIL", "" if ok else " (" + ", ".join(failures) + ")"])
	_record_check("STEP R item descriptions (H)", ok)

## STEP S (MP07 I): every monster declares its effect trigger category
## (none | on_roll | on_death | on_miss) and an explicit effect_description.
func _check_monster_effects() -> void:
	print("\n-- CHECK: monster effect fields (MP07 I) --")
	var ids: Array = ["monster_gaper", "monster_pooter", "monster_fly", "monster_attack_fly",
		"monster_red_host", "monster_mauler", "monster_gusher", "monster_hive",
		"monster_rage_giant", "monster_dinga", "monster_dingling", "monster_globbin",
		"monster_gurdy", "monster_fistula", "monster_monstro"]
	var ok := true
	var failures: Array = []
	for id in ids:
		var card: CardResource = load(CARD_DIR + id + ".tres")
		if card == null:
			ok = false
			failures.append("%s: missing (run the import)" % id)
			continue
		if not ["none", "on_roll", "on_death", "on_miss"].has(card.effect_trigger):
			ok = false
			failures.append("%s: trigger '%s'" % [id, card.effect_trigger])
		if card.effect_description == "":
			ok = false
			failures.append("%s: empty effect_description" % id)
	print("  STEP S monster-effect check: %s%s" % ["PASS" if ok else "FAIL", "" if ok else " (" + ", ".join(failures) + ")"])
	_record_check("STEP S monster effect fields (I)", ok)

## STEP T (MP07 J): a boss kill becomes ONE named soul card counting its
## soul_value (Monstro 2 — one entry, double value); the win condition fires
## when the SUM of soul values reaches 4.
func _check_boss_souls() -> void:
	print("\n-- CHECK: boss souls (MP07 J) --")
	var p: Dictionary = GameState.players[0]
	var monstro: CardResource = load(CARD_DIR + "monster_monstro.tres")
	if monstro == null:
		Log.error("turn_loop_test: monster_monstro.tres missing (run the import)")
		get_tree().quit(1)
		return
	p["souls"] = []
	GameState.soul_values.clear()
	for m in _controller.table_monsters:
		CardEffectRegistry.unregister_monster(m["instance_id"])
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_monstro#t", "card": monstro, "hp": monstro.hp})
	_check_win_pid = -1
	_check_boss_seen = false
	var on_won := func(pid: int): _check_win_pid = pid
	var on_boss := func(_pid: int, _cid: String, _val: int): _check_boss_seen = true
	EventBus.game_won.connect(on_won)
	EventBus.boss_defeated.connect(on_boss)
	EventBus.monster_killed.emit(0, "monster_monstro#t", _controller._kill_rewards(monstro))
	EventBus.boss_defeated.disconnect(on_boss)
	var ok: bool = _check_boss_seen
	ok = ok and p["souls"] == ["monster_monstro"]     # ONE soul card for the boss
	ok = ok and GameState.soul_total(0) == 2          # ...that counts double
	ok = ok and _check_win_pid == -1                  # 2 < 4: no win yet
	GameState.gain_soul(0, "monster_mom", 2)          # fake a second boss kill
	ok = ok and GameState.soul_total(0) == 4
	ok = ok and _check_win_pid == 0                   # sum reached 4 -> win
	EventBus.game_won.disconnect(on_won)
	print("  STEP T boss-soul check: %s (Monstro -> %s soul value 2; +2 = %d -> winner P%d)" % [
		"PASS" if ok else "FAIL", str(p["souls"]), GameState.soul_total(0), _check_win_pid + 1])
	_record_check("STEP T boss souls count double, win at 4 (J)", ok)

## Unmounts every card copy a player owns, then empties items_passive — used
## to make the self-checks self-contained regardless of demo purchases.
func _clear_player_items(player_id: int) -> void:
	var p: Dictionary = GameState.players[player_id]
	var unique_ids: Array = []
	for card_id in p["items_passive"]:
		if not unique_ids.has(card_id):
			unique_ids.append(card_id)
	for card_id in unique_ids:
		while p["items_passive"].has(card_id):
			CardEffectRegistry.unregister_card_by_card_id(player_id, card_id)
			p["items_passive"].erase(card_id)

## Terminal "thermometer": a minimal extract of PROJECT_STATUS.md so a run of
## run_test.bat answers the key questions without opening any file.
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
		print("  P%d: hp=%d cents=%d souls=%s (value %d) hand=%s items=%s" % [
			p["id"] + 1, p["hp"], p["cents"], str(p["souls"]), GameState.soul_total(p["id"]), str(p["hand"]), str(p["items_passive"])])