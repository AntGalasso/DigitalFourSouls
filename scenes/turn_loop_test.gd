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
## The MP07 STACK BUILD reproduces the metaprompt examples as tests:
##  - STEP U (ESEMPIO 1): ending phase order + advance_active_player ALWAYS,
##            P1->P2->P1->P2 over 4 cycles, draw after the switch
##  - STEP V (ESEMPIO 2): raw roll 2 -> pending_roll r# -> priority to P1
##            then P2 -> D6 pushes a modifier -> reroll at resolution
##            (2 -> 5) -> cascade resolves r#: "5 vs die 3 -> HIT"
##  - STEP W (ESEMPIO 2b): Belial Book (+1) applies AT ACTIVATION on the
##            pending roll (3 -> 4), resolution logs "4 vs die 4 -> HIT"
##  - STEP X (ESEMPIO 3): kill closure (reward from card data, refill,
##            reset_combat_state with empty-stack verify) AND the player-
##            death path still resetting combat state
##  - STEP Y (ESEMPIO 4): Yum Heart = prevention shield (apply / consume /
##            expire unused at end of owner's turn + recharge)
##  - STEP Z (ESEMPIO 5): loot play becomes pending_effect; the NON-active
##            player gets a priority window before Bomb resolves
##  - STEP AE (Comprehensive Rules): a round of passes resolves ONLY the top of
##            the stack; loot in response is pushed (not atomic), the entry
##            underneath gets a FRESH window before it resolves
## And a final PROJECT_STATUS thermometer (card count, checks, playability).
##
## HOW TO RUN: run_test.bat, or
##   godot --headless --path . res://scenes/turn_loop_test.tscn [-- seed]

const ROUNDS := 3
const CARD_DIR := "res://resources/cards/base_set/"
## Preload (not class_name): the global class cache is only refreshed by the
## editor, so headless CLI runs resolve this via preload instead.
const MatchControllerScript := preload("res://scripts/core/match_controller.gd")
const MatchStateScript := preload("res://scripts/core/match_state.gd")
const Protocol := preload("res://scripts/core/match_protocol.gd")

var _controller
var _driver                       # ScriptedDriver — replaces the old global-signal hooks
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
	## The harness IS the driver now (ratifica #3): the engine asks this object
	## for every priority/death answer, bound to a request id. Checks swap
	## _driver.policy instead of connecting/disconnecting global signals.
	_driver = ScriptedDriver.new()
	_driver.policy = _robot_policy
	_driver.death_policy = _robot_death_policy
	_controller.setup(2, _run_seed, _driver)

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
	# MP07 stack build — the metaprompt examples as executable tests:
	await _check_ex1_turn_cycle()
	await _check_ex2_d6_reroll()
	await _check_ex2b_belial_adjust()
	await _check_ex3_combat_closure()
	await _check_ex4_yum_heart_shield()
	await _check_ex5_loot_stack()
	await _check_single_resolution()
	_check_protocol_purity()
	# M1 invariants (ratifiche #2, #3): identity-bound input, private snapshots,
	# serializable state, restartable engine.
	await _check_priority_identity()
	_check_state_snapshot()
	_check_state_roundtrip()
	_check_teardown()
	_print_summary()

func _run_robot_turn(player_id: int) -> void:
	print("\n--- P%d turn ---" % (player_id + 1))
	_controller.begin_turn(player_id)
	_robot_buy(player_id)
	await _robot_loot(player_id)   # loot plays open a stack window: MUST be awaited
	var attack_result: Dictionary = await _robot_attack(player_id)
	if attack_result.get("outcome", "") != "player_died":
		_controller.end_turn()
	print("--- P%d turn end ---" % (player_id + 1))

## Robot response policy: PASS everything. Consecutive passes close every
## priority window and resolve the top of the stack; self-checks swap this
## policy for one that answers with a specific action.
func _robot_policy(_player_id: int, _stack_type: String, _entry: Dictionary) -> Dictionary:
	return {"action": "pass"}

## Death policy: pick the first legal loot card and the first legal item.
func _robot_death_policy(_player_id: int, request: Dictionary) -> Dictionary:
	var penalty: Dictionary = request.get("penalty", {})
	var loot_options: Array = penalty.get("loot_options", [])
	var item_options: Array = penalty.get("item_options", [])
	return {
		"loot_id": String(loot_options[0]) if not loot_options.is_empty() else "",
		"item_id": String(item_options[0]) if not item_options.is_empty() else "",
	}

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
		if await _controller.play_loot(card, player_id, payload):
			print("  loot: played %s" % card.display_name)
			# the card already left the hand: play_loot() owns that now
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
	var handler_belial := func(_pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		if stack_type == "pending_roll" and not _check_roll_checked:
			_check_roll_checked = true
			_check_roll_before = _controller.get_pending_roll().get("roll", -1)
			_check_belial_ok = _controller.use_eternal_item(1, {"delta": -1}).get("ok", false)
			_check_roll_after = _controller.get_pending_roll().get("roll", -1)
		return {"action": "resolve" if stack_type == "pending_roll" else "pass"}
	var on_attacked := func(_pid: int, _iid: String, roll: int, _bonus: int, _die: int):
		if _check_first_attacked_roll == -1:
			_check_first_attacked_roll = roll  # FIRST emission = the modified roll
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_fly#h1", "card": fly, "hp": 1})
	_driver.policy = handler_belial
	EventBus.monster_attacked.connect(on_attacked)
	var result_a: Dictionary = await _controller.attack("monster_fly#h1", 0)
	_driver.policy = _robot_policy
	EventBus.monster_attacked.disconnect(on_attacked)
	var ok: bool = _check_belial_ok
	ok = ok and _check_roll_after == _check_roll_before - 1   # Belial -1 applied while pending
	ok = ok and _check_first_attacked_roll == _check_roll_after
	ok = ok and result_a.get("final_roll", -1) == _check_roll_after
	## Attack 2: D6 reroll only — the reroll is DEFERRED to modifier resolution,
	## so activation returns no value; the FINAL (rerolled) number is what the
	## roll resolves with and monster_attacked carries.
	_check_d6_ok = false
	_check_d6_new = -1
	_check_second_attacked_roll = -1
	_check_roll_checked = false
	var handler_d6 := func(_pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		if stack_type == "pending_roll" and not _check_roll_checked:
			_check_roll_checked = true
			var res: Dictionary = _controller.use_eternal_item(0, {})
			_check_d6_ok = res.get("ok", false) and res.get("reason", "") != "no_pending_roll"
		return {"action": "resolve" if stack_type == "pending_roll" else "pass"}
	var on_attacked2 := func(_pid: int, _iid: String, roll: int, _bonus: int, _die: int):
		if _check_second_attacked_roll == -1:
			_check_second_attacked_roll = roll  # FIRST emission = the rerolled value
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": "monster_fly#h2", "card": fly, "hp": 1})
	_controller.begin_turn(0)  # the attack limit is 1 per turn; fresh turn for the 2nd attack
	_driver.policy = handler_d6
	EventBus.monster_attacked.connect(on_attacked2)
	var result_b: Dictionary = await _controller.attack("monster_fly#h2", 0)
	_driver.policy = _robot_policy
	EventBus.monster_attacked.disconnect(on_attacked2)
	for i in range(5):
		CardEffectRegistry.unregister_card(0, "treasure_steven#h%d" % i)
	_check_d6_new = _check_second_attacked_roll
	ok = ok and _check_d6_ok and _check_d6_new > 0
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
	var loot_1: bool = await _controller.play_loot(load(CARD_DIR + "loot_dinner.tres"), 0, {})
	var loot_2: bool = await _controller.play_loot(load(CARD_DIR + "loot_pennies.tres"), 0, {})  # character effect
	var loot_3: bool = await _controller.play_loot(load(CARD_DIR + "loot_bomb.tres"), 0, {})     # refused: limit
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
## pending_roll priority window with "stop", the attack continues until the
## monster or the player dies — no "stopped" outcome exists.
func _check_no_stop_attack() -> void:
	print("\n-- CHECK: STOP attack is not a rule (MP07 D) --")
	_controller.begin_turn(0)
	GameState.players[0]["max_hp"] = 99
	GameState.players[0]["hp"] = 99  # keep the loop bounded if the dice go cold
	for m in _controller.table_monsters:
		CardEffectRegistry.unregister_monster(m["instance_id"])
	_controller.table_monsters.clear()
	var fly_m: CardResource = load(CARD_DIR + "monster_fly.tres")
	_controller.table_monsters.append({"instance_id": "monster_fly#m", "card": fly_m, "hp": 1})
	var handler := func(_pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		return {"action": "stop" if stack_type == "pending_roll" else "pass"}
	_driver.policy = handler
	var result: Dictionary = await _controller.attack("monster_fly#m", 0)
	_driver.policy = _robot_policy
	var outcome: String = result.get("outcome", "")
	var ok: bool = outcome == "killed"
	ok = ok and _controller.stack.is_empty() and not _controller.is_combat_in_progress()
	print("  STEP M no-stop check: %s ('stop' on pending_roll ignored; outcome '%s' after %d rolls; stack empty)" % [
		"PASS" if ok else "FAIL", outcome, result.get("steps", -1)])
	_record_check("STEP M no STOP attack (D)", ok)
	_controller.end_turn()

## STEP O (MP07 B / ESEMPIO 2): the eternal modifier answers an EXISTING
## pending_roll on the stack — refused with "no_pending_roll" when no window
## is open (before declaring / after resolving), accepted inside the
## pending_roll window, refused again once everything resolved.
func _check_roll_timing() -> void:
	print("\n-- CHECK: roll pending timing (MP07 B / ESEMPIO 2) --")
	_controller.begin_turn(0)
	var p: Dictionary = GameState.players[0]
	p["character_id"] = "character_isaac"
	p["eternal_item_id"] = "eternal_d6"
	p["eternal_used"] = false
	p["max_hp"] = 99
	p["hp"] = 99  # survive every miss while the dice warm up
	for m in _controller.table_monsters:
		CardEffectRegistry.unregister_monster(m["instance_id"])
	_controller.table_monsters.clear()
	var fly_o: CardResource = load(CARD_DIR + "monster_attack_fly.tres")
	_controller.table_monsters.append({"instance_id": "monster_attack_fly#o", "card": fly_o, "hp": 1})
	# 1) no stack entry at all -> refused
	var res_before: Dictionary = _controller.use_eternal_item(0, {})
	var ok: bool = not res_before.get("ok", true) and res_before.get("reason", "") == "no_pending_roll"
	p["eternal_used"] = false
	# 2) inside the pending_roll window -> accepted
	var in_window := {"ok": false}
	_o_saw_roll = false
	var handler := func(_pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		if stack_type == "pending_roll" and not _o_saw_roll:
			_o_saw_roll = true
			var rres: Dictionary = _controller.use_eternal_item(0, {})
			in_window["ok"] = rres.get("ok", false)
		return {"action": "pass"}
	_driver.policy = handler
	await _controller.attack("monster_attack_fly#o", 0)
	_driver.policy = _robot_policy
	ok = ok and in_window["ok"]
	# 3) attack fully resolved, stack empty -> refused again
	p["eternal_used"] = false
	var res_after: Dictionary = _controller.use_eternal_item(0, {})
	var refused_after: bool = not res_after.get("ok", true) and res_after.get("reason", "") == "no_pending_roll"
	ok = ok and refused_after
	p["max_hp"] = 2
	p["hp"] = 2  # leave a consistent state for later checks
	print("  STEP O roll-timing check: %s (before:%s in-window:%s after:%s)" % [
		"PASS" if ok else "FAIL",
		not res_before.get("ok", true) and res_before.get("reason", "") == "no_pending_roll",
		in_window["ok"], refused_after])
	_record_check("STEP O roll pending timing (B)", ok)

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
	p1["character_tapped"] = false
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
	var handler := func(pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		if stack_type == "pending_roll":
			if not _p_roll_seen:
				_p_roll_seen = true
				_priority_first_ask = pid
				_priority_roll_before = _controller.get_pending_roll().get("roll", -1)
			if pid == 1:
				_p1_roll_asks += 1
				if _p1_roll_asks == 1:
					return {"action": "loot", "card_id": "loot_dinner", "target_id": ""}
				if _p1_roll_asks == 2:
					return {"action": "eternal", "payload": {"delta": -1}}
		return {"action": "resolve" if stack_type == "pending_roll" else "pass"}
	var on_attacked := func(_pid: int, _iid: String, roll: int, _bonus: int, _die: int):
		if _priority_attacked_roll == -1:
			_priority_attacked_roll = roll  # FIRST emission = the modified roll
	_priority_et_ok = false
	var on_eternal := func(_pid: int, _iid: String, res: Dictionary): _priority_et_ok = res.get("ok", false)
	_driver.policy = handler
	EventBus.monster_attacked.connect(on_attacked)
	EventBus.eternal_used.connect(on_eternal)
	var result: Dictionary = await _controller.attack(target_id, 0)
	_driver.policy = _robot_policy
	EventBus.monster_attacked.disconnect(on_attacked)
	EventBus.eternal_used.disconnect(on_eternal)
	var ok: bool = _priority_first_ask == 0                        # active player asked first
	ok = ok and _priority_et_ok                                   # P1's eternal succeeded
	ok = ok and p1["character_tapped"]                            # P1's out-of-turn loot TAPPED the character
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
	p["max_hp"] = 99
	p["hp"] = 99  # survive the misses of a real-dice multi-roll sequence
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
	p["max_hp"] = 2
	p["hp"] = 2
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

# --- MP07 stack-build scratch vars (STEP U-Z / ESEMPI 1-5) ---------------------
# member vars, NOT captured locals: scalar lambda captures re-read the original
# value on every call in Godot 4.7, so anything mutated inside a handler lives here.
var _real_rng: RandomNumberGenerator = null
var _u_advanced: Array = []
var _u_tags: Array = []
var _u_draws: Array = []
var _v_pushed: Array = []
var _v_resolved: Array = []
var _v_asks: Array = []
var _v_reset: int = 0
var _v_seen: bool = false
var _w_seen: int = 0
var _w_value_after: int = -1
var _w_roll_id: String = ""
var _x_resets: int = 0
var _y_shield_events: Array = []
var _z_asks: Array = []
var _z_pushed: Array = []

## Duck-typed stand-in for Rng.rng: replays scripted die results in order
## (default 1 once dry) so the example sequences are byte-exact, not lucky.
class FakeRng extends RefCounted:
	var queue: Array = []
	func randi_range(_from: int, _to: int) -> int:
		if queue.is_empty():
			return 1
		return queue.pop_front()

## Test driver (MatchDriver contract): wraps a policy Callable and binds the
## request identity onto the answer — exactly what a transport layer does for
## a real client. The engine still validates both fields, so a policy that
## returns junk is treated as a pass.
class ScriptedDriver extends RefCounted:
	var policy: Callable = Callable()
	var death_policy: Callable = Callable()

	func is_interactive() -> bool:
		return false

	func decide_priority(request: Dictionary) -> Dictionary:
		var response: Dictionary = {"action": "pass"}
		if policy.is_valid():
			var raw = policy.call(request.get("player_id", -1), request.get("stack_type", ""), request.get("entry", {}))
			if typeof(raw) == TYPE_DICTIONARY:
				response = raw
		response["request_id"] = String(request.get("request_id", ""))
		response["player_id"] = int(request.get("player_id", -1))
		return response

	func decide_death(request: Dictionary) -> Dictionary:
		var choice: Dictionary = {}
		if death_policy.is_valid():
			var raw = death_policy.call(request.get("player_id", -1), request)
			if typeof(raw) == TYPE_DICTIONARY:
				choice = raw
		choice["request_id"] = String(request.get("request_id", ""))
		choice["player_id"] = int(request.get("player_id", -1))
		return choice

## Bad driver: answers with a STALE request id and/or the WRONG player id.
## Used to prove the engine rejects answers that do not belong to the request
## in flight (ratifica #3).
class StaleDriver extends RefCounted:
	var stale_request_id: bool = true
	var wrong_player: bool = false

	func is_interactive() -> bool:
		return false

	func decide_priority(request: Dictionary) -> Dictionary:
		return {
			"action": "loot",
			"card_id": "loot_bomb",
			"request_id": "pr-stale" if stale_request_id else String(request.get("request_id", "")),
			"player_id": (int(request.get("player_id", -1)) + 1) if wrong_player else int(request.get("player_id", -1)),
		}

func _install_fake_rng(queue: Array) -> void:
	if _real_rng == null:
		_real_rng = Rng.rng
	var fake := FakeRng.new()
	fake.queue = queue.duplicate()
	Rng.rng = fake

func _restore_rng() -> void:
	if _real_rng != null:
		Rng.rng = _real_rng
	_real_rng = null

## Replaces the whole table with ONE fresh monster instance.
func _set_single_monster(instance_id: String, card: CardResource, hp: int) -> void:
	for m in _controller.table_monsters:
		CardEffectRegistry.unregister_monster(m["instance_id"])
	_controller.table_monsters.clear()
	_controller.table_monsters.append({"instance_id": instance_id, "card": card, "hp": hp})

func _find_table_hp(instance_id: String) -> int:
	for m in _controller.table_monsters:
		if m["instance_id"] == instance_id:
			return m["hp"]
	return -999

## --- STEP U (ESEMPIO 1): full turn cycle with player switch --------------------

## The ENDING PHASE runs heal_all_players -> heal_all_monsters ->
## discard_to_hand_limit -> refill_empty_slots, then advance_active_player()
## ALWAYS fires (the step that must never be missing) and the NEXT turn draws
## for the new active player. Four cycles: P1->P2->P1->P2, never stuck on P1.
func _check_ex1_turn_cycle() -> void:
	print("\n-- CHECK: ESEMPIO 1 — full turn cycle with player switch --")
	_restock_loot(8)   # guarantee 4 draws despite hand-assignment leaks in earlier checks
	_controller.begin_turn(0)
	_u_advanced.clear()
	_u_tags.clear()
	_u_draws.clear()
	var on_adv := func(prev: int, nxt: int):
		_u_advanced.append([prev, nxt])
		_u_tags.append("advance")
	var on_hp := func(_pid: int, _total: int): _u_tags.append("heal_players")
	var on_mons := func(): _u_tags.append("heal_monsters")
	var on_draw := func(pid: int, _cid: String, _deck: String):
		_u_draws.append(pid)
		_u_tags.append("draw")
	EventBus.active_player_advanced.connect(on_adv)
	EventBus.hp_restored.connect(on_hp)
	EventBus.monsters_restored.connect(on_mons)
	EventBus.card_drawn.connect(on_draw)
	for i in range(4):
		_controller.end_turn()                        # ending phase + advance INSIDE
		_controller.begin_turn(GameState.current_player_index)
	EventBus.active_player_advanced.disconnect(on_adv)
	EventBus.hp_restored.disconnect(on_hp)
	EventBus.monsters_restored.disconnect(on_mons)
	EventBus.card_drawn.disconnect(on_draw)
	var ok: bool = _u_advanced == [[0, 1], [1, 0], [0, 1], [1, 0]]   # P1->P2->P1->P2
	# each cycle's draw belongs to the NEW active player (ESEMPIO 1 step 6):
	ok = ok and _u_draws == [1, 0, 1, 0]
	ok = ok and GameState.current_player_index == 0                  # back to P1 after 4 switches
	var pattern_ok: bool = _u_tags.size() == 20                      # 4 x [heal_players x2, heal_monsters, advance, draw]
	if pattern_ok:
		for c in range(4):
			if _u_tags.slice(c * 5, c * 5 + 5) != ["heal_players", "heal_players", "heal_monsters", "advance", "draw"]:
				pattern_ok = false
	ok = ok and pattern_ok
	print("  STEP U ESEMPIO-1 check: %s (advanced %s; draws %s; ending-phase order ok: %s)" % [
		"PASS" if ok else "FAIL", str(_u_advanced), str(_u_draws), pattern_ok])
	_record_check("STEP U ESEMPIO 1 turn cycle + advance_active_player", ok)

## --- STEP V (ESEMPIO 2): D6 answers the pending roll ----------------------------

## Raw roll 2 -> PUSH pending_roll r# -> priority asks P1 (active, passes)
## then P2 (Isaac): D6 pushes a GENERIC modifier on top -> round restarts
## from the active player -> both pass consecutively -> resolution cascades:
## the modifier rerolls first ("r# value changes from 2 to 5"), then r#
## resolves against die 3 -> HIT.
func _check_ex2_d6_reroll() -> void:
	print("\n-- CHECK: ESEMPIO 2 — D6 answers the pending roll through the stack --")
	var p0: Dictionary = GameState.players[0]
	var p1: Dictionary = GameState.players[1]
	_clear_player_items(0)
	_clear_player_items(1)
	p0["character_id"] = "character_judas"
	p0["eternal_item_id"] = "eternal_belial_book"
	p0["eternal_used"] = false
	p1["character_id"] = "character_isaac"
	p1["eternal_item_id"] = "eternal_d6"
	p1["eternal_used"] = false
	var fly: CardResource = load(CARD_DIR + "monster_attack_fly.tres")
	_set_single_monster("monster_attack_fly#v", fly, 1)
	_controller.begin_turn(0)                 # draw/shuffle randomness BEFORE scripting dice
	_install_fake_rng([2, 5])
	var cents_before: int = p0["cents"]
	_v_pushed.clear(); _v_resolved.clear(); _v_asks.clear(); _v_reset = 0; _v_seen = false
	var on_push := func(e: Dictionary): _v_pushed.append([e.get("type"), e.get("id"), e.get("value", -1)])
	var on_resolved := func(e: Dictionary, r: Dictionary): _v_resolved.append([e.get("type"), e.get("id"), r])
	var on_reset := func(): _v_reset += 1
	var handler := func(pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		_v_asks.append(pid)
		if stack_type == "pending_roll" and pid == 1 and not _v_seen:
			_v_seen = true                   # P2 (non-active!) answers with the D6
			return {"action": "eternal", "payload": {}}
		return {"action": "pass"}
	EventBus.stack_entry_pushed.connect(on_push)
	EventBus.stack_entry_resolved.connect(on_resolved)
	EventBus.combat_state_reset.connect(on_reset)
	_driver.policy = handler
	var result: Dictionary = await _controller.attack("monster_attack_fly#v", 0)
	_driver.policy = _robot_policy
	EventBus.stack_entry_pushed.disconnect(on_push)
	EventBus.stack_entry_resolved.disconnect(on_resolved)
	EventBus.combat_state_reset.disconnect(on_reset)
	_restore_rng()
	var roll_id: String = _v_pushed[0][1] if _v_pushed.size() > 0 else "?"
	var ok: bool = result.get("outcome", "") == "killed"
	ok = ok and _v_pushed.size() == 2
	ok = ok and _v_pushed[0][0] == "pending_roll" and _v_pushed[0][2] == 2   # raw roll 2, PENDING
	ok = ok and _v_pushed[1][0] == "modifier"                                # D6 answer ON TOP
	ok = ok and _v_asks == [0, 1, 0, 1, 0, 1]                              # active first; restart after response; NEW window on the roll after the modifier resolved
	ok = ok and result.get("final_roll", -1) == 5                            # reroll changed the value
	ok = ok and _v_resolved.size() == 2 and _v_resolved[0][0] == "modifier"  # LIFO: modifier first
	ok = ok and _v_resolved[1][0] == "pending_roll"
	ok = ok and _v_resolved[1][2].get("hit", false) \
		and _v_resolved[1][2].get("roll", -1) == 5 \
		and _v_resolved[1][2].get("die_value", -1) == 3                      # "5 vs die 3 -> HIT"
	ok = ok and p0["cents"] == cents_before + 1                              # reward FROM CARD DATA
	ok = ok and _v_reset == 1 and _controller.stack.is_empty()               # ESEMPIO 3 closure
	print("  STEP V ESEMPIO-2 check: %s (roll %s: 2 pending -> P2 D6 modifier -> reroll 2->5 -> 'HIT' vs die 3; asks %s)" % [
		"PASS" if ok else "FAIL", roll_id, str(_v_asks)])
	_record_check("STEP V ESEMPIO 2 D6 reroll via stack modifiers", ok)

## --- STEP W (ESEMPIO 2b): Belial Book on the OWN roll, after it -----------------

## The adjust button exists only AFTER the roll exists (no pending_roll, no
## action — no preventive modifying). Raw 3 -> activation applies +1
## IMMEDIATELY (logged "value 3 -> 4" while the window is still open) ->
## resolution reads 4 vs die 4 -> HIT.
func _check_ex2b_belial_adjust() -> void:
	print("\n-- CHECK: ESEMPIO 2b — Belial Book adjusts the pending roll (+1) --")
	var p0: Dictionary = GameState.players[0]
	_clear_player_items(0)
	_clear_player_items(1)
	p0["character_id"] = "character_judas"
	p0["eternal_item_id"] = "eternal_belial_book"
	p0["eternal_used"] = false
	GameState.players[1]["eternal_used"] = true       # keep P2 out of this window
	var gaper: CardResource = load(CARD_DIR + "monster_gaper.tres")
	_set_single_monster("monster_gaper#w", gaper, 1)
	_controller.begin_turn(0)
	_install_fake_rng([3])
	var cents_before: int = p0["cents"]
	_v_pushed.clear(); _v_resolved.clear(); _v_asks.clear()
	_w_seen = 0; _w_value_after = -1; _w_roll_id = ""
	var on_push := func(e: Dictionary):
		_v_pushed.append([e.get("type"), e.get("id"), e.get("value", -1)])
		if e.get("type") == "pending_roll":
			_w_roll_id = e["id"]
	var on_resolved := func(e: Dictionary, r: Dictionary): _v_resolved.append([e.get("type"), r])
	var handler := func(pid: int, stack_type: String, _payload: Dictionary) -> Dictionary:
		_v_asks.append(pid)
		if stack_type == "pending_roll" and pid == 0:
			_w_seen += 1
			if _w_seen == 1:
				return {"action": "eternal", "payload": {"delta": 1}}
			# asked AGAIN -> the +1 is ALREADY on the pending value (pre-resolution)
			_w_value_after = _controller.stack.find(_w_roll_id).get("value", -1)
		return {"action": "pass"}
	EventBus.stack_entry_pushed.connect(on_push)
	EventBus.stack_entry_resolved.connect(on_resolved)
	_driver.policy = handler
	var result: Dictionary = await _controller.attack("monster_gaper#w", 0)
	_driver.policy = _robot_policy
	EventBus.stack_entry_pushed.disconnect(on_push)
	EventBus.stack_entry_resolved.disconnect(on_resolved)
	_restore_rng()
	var ok: bool = result.get("outcome", "") == "killed"
	ok = ok and _v_pushed.size() == 2
	ok = ok and _v_pushed[0][0] == "pending_roll" and _v_pushed[0][2] == 3   # raw 3 pending
	ok = ok and _v_pushed[1][0] == "modifier"                                # Belial answer on top
	ok = ok and _w_value_after == 4                                          # applied AT ACTIVATION
	ok = ok and result.get("final_roll", -1) == 4
	ok = ok and _v_resolved.size() == 2 and _v_resolved[0][0] == "modifier" and _v_resolved[1][0] == "pending_roll"
	ok = ok and _v_resolved[1][1].get("hit", false) \
		and _v_resolved[1][1].get("roll", -1) == 4 \
		and _v_resolved[1][1].get("die_value", -1) == 4                      # "4 vs die 4 -> HIT"
	ok = ok and p0["cents"] == cents_before + 1                              # reward from card data
	ok = ok and _controller.stack.is_empty()
	print("  STEP W ESEMPIO-2b check: %s (raw 3 -> Belial +1 AT ACTIVATION (%d) -> resolution 4 vs die 4 -> 'HIT'; asks %s)" % [
		"PASS" if ok else "FAIL", _w_value_after, str(_v_asks)])
	_record_check("STEP W ESEMPIO 2b Belial Book +1 at activation", ok)

## --- STEP X (ESEMPIO 3): closure on EVERY exit path ------------------------------

## After a kill: reward from card data, slot refilled, reset_combat_state ran
## (stack VERIFIED empty) and ATTACK is declarable again the following turn.
## After the player dies INSTEAD of the monster: reset_combat_state STILL ran
## — the attack system is never left busy.
func _check_ex3_combat_closure() -> void:
	print("\n-- CHECK: ESEMPIO 3 — combat closure on kill AND death paths --")
	var p0: Dictionary = GameState.players[0]
	var p1: Dictionary = GameState.players[1]
	_clear_player_items(0)
	_clear_player_items(1)
	p0["character_id"] = "character_isaac"
	p0["eternal_item_id"] = "eternal_d6"
	p0["eternal_used"] = true   # neutralize the eternal item for this check
	p1["eternal_used"] = true
	var fly: CardResource = load(CARD_DIR + "monster_fly.tres")
	var on_reset := func(): _x_resets += 1
	EventBus.combat_state_reset.connect(on_reset)
	# PART A — kill path closes cleanly; ATTACK available again next turn.
	_set_single_monster("monster_fly#xa", fly, 1)
	_controller.begin_turn(0)
	_install_fake_rng([6])
	_x_resets = 0
	var res_a: Dictionary = await _controller.attack("monster_fly#xa", 0)
	var ok_a: bool = res_a.get("outcome", "") == "killed"
	ok_a = ok_a and _x_resets == 1 and _controller.stack.is_empty()
	ok_a = ok_a and not _controller.is_combat_in_progress()
	_restore_rng()
	# ...and on the FOLLOWING turn a fresh attack is accepted (= clickable).
	_set_single_monster("monster_fly#xa2", fly, 1)
	_controller.begin_turn(0)
	_install_fake_rng([6])
	var res_again: Dictionary = await _controller.attack("monster_fly#xa2", 0)
	ok_a = ok_a and res_again.get("valid", false) and res_again.get("outcome", "") == "killed"
	_restore_rng()
	# PART B — the player dies instead: reset MUST still happen.
	p0["max_hp"] = 99
	p0["hp"] = 99
	_set_single_monster("monster_fly#xb", fly, 99)   # cannot die; the player will
	_controller.begin_turn(0)
	p0["hp"] = 1                                     # any miss is lethal now
	_install_fake_rng([1])                           # 1 vs die 5 -> MISS -> 1 damage -> dead
	_x_resets = 0
	var res_b: Dictionary = await _controller.attack("monster_fly#xb", 0)
	var ok_b: bool = res_b.get("outcome", "") == "player_died"
	ok_b = ok_b and _x_resets == 1 and _controller.stack.is_empty()
	ok_b = ok_b and not _controller.is_combat_in_progress()
	# a fresh attempt must be refused for TURN reasons only — never "busy"
	var probe: Dictionary = await _controller.attack("monster_fly#xb", 0)
	ok_b = ok_b and not probe.get("valid", true) and not probe.has("busy")
	ok_b = ok_b and GameState.current_player_index == 1   # death ended P1's turn (advance ran)
	_restore_rng()
	EventBus.combat_state_reset.disconnect(on_reset)
	p0["max_hp"] = 2
	p0["hp"] = 2
	print("  STEP X ESEMPIO-3 check: %s (kill: reset x%d + re-attack ok %s | death: reset x%d, outcome '%s', not busy)" % [
		"PASS" if (ok_a and ok_b) else "FAIL", _x_resets, res_again.get("valid", false), 1, res_b.get("outcome", "")])
	_record_check("STEP X ESEMPIO 3 combat closure on every exit path", ok_a and ok_b)

## --- STEP Y (ESEMPIO 4): Yum Heart is prevention, not a heal ---------------------

func _check_ex4_yum_heart_shield() -> void:
	print("\n-- CHECK: ESEMPIO 4 — Yum Heart prevention shield --")
	var p0: Dictionary = GameState.players[0]
	var p1: Dictionary = GameState.players[1]
	p0["character_id"] = "character_isaac"
	p0["eternal_item_id"] = "eternal_d6"
	p1["character_id"] = "character_magdalene"
	p1["eternal_item_id"] = "eternal_yum_heart"
	_controller.begin_turn(1)                 # Magdalene's turn: owner-scoped expiry below
	p1["eternal_used"] = false
	_y_shield_events.clear()
	var on_applied := func(target: int, item_name: String, owner: int):
		_y_shield_events.append(["applied", target, item_name, owner])
	var on_consumed := func(target: int, absorbed: int):
		_y_shield_events.append(["consumed", target, absorbed])
	var on_expired := func(target: int):
		_y_shield_events.append(["expired", target])
	EventBus.shield_applied.connect(on_applied)
	EventBus.shield_consumed.connect(on_consumed)
	EventBus.shield_expired.connect(on_expired)
	var hp_before: int = p0["hp"]
	# step 2: apply_shield(P1) — ONE call, menu closes here, no quantities
	var used: Dictionary = _controller.use_eternal_item(1, {"target_id": 0})
	var ok: bool = used.get("ok", false)
	ok = ok and p0["shield_next_damage"]
	ok = ok and _y_shield_events.has(["applied", 0, "Yum Heart", 1])
	# step 3: the damage arrives -> consume_shield cancels ALL of it, flag removed
	GameState.damage_player(0, 99, "shield_test")
	ok = ok and p0["hp"] == hp_before                    # 0 hp lost
	ok = ok and _y_shield_events.has(["consumed", 0, 99])
	ok = ok and not p0["shield_next_damage"]
	# step 4: reapplied and never consumed -> expires at the end of the OWNER's turn
	p1["eternal_used"] = false
	used = _controller.use_eternal_item(1, {"target_id": 0})
	ok = ok and used.get("ok", false) and p0["shield_next_damage"]
	_controller.end_turn()                               # owner (P2) ending phase
	ok = ok and _y_shield_events.has(["expired", 0])
	ok = ok and not p0["shield_next_damage"]
	ok = ok and not p1["eternal_used"]                   # Yum Heart recharged for P2
	ok = ok and GameState.shields.is_empty()
	EventBus.shield_applied.disconnect(on_applied)
	EventBus.shield_consumed.disconnect(on_consumed)
	EventBus.shield_expired.disconnect(on_expired)
	print("  STEP Y ESEMPIO-4 check: %s (applied on P1, absorbed 99 dmg with 0 hp lost, expired unused + recharged)" % [
		"PASS" if ok else "FAIL"])
	_record_check("STEP Y ESEMPIO 4 Yum Heart prevention shield", ok)

## --- STEP Z (ESEMPIO 5): loot plays go through the stack -------------------------

## Playing loot pushes a pending_effect and opens the priority window to ALL
## players — including the NON-active one — before "Bomb resolves: Gaper
## takes 2 damage".
func _check_ex5_loot_stack() -> void:
	print("\n-- CHECK: ESEMPIO 5 — loot play as pending_effect with open window --")
	var p0: Dictionary = GameState.players[0]
	_clear_player_items(0)
	_clear_player_items(1)
	var gaper: CardResource = load(CARD_DIR + "monster_gaper.tres")
	_set_single_monster("monster_gaper#z", gaper, 5)     # survives the 2 damage
	_controller.begin_turn(0)
	# TWO cards: Bomb is played (and leaves the hand in the engine, not in the
	# caller), Dinner stays as a legal response so the ACTIVE player is asked
	# too. With a single card P1 would correctly be auto-passed after playing.
	p0["hand"] = ["loot_bomb", "loot_dinner"]
	p0["loot_played"] = 0
	p0["character_tapped"] = false
	# give the NON-active player something to answer with, so the window asks
	# them too (players without responses are auto-passed by the engine):
	GameState.players[1]["character_id"] = "character_judas"
	GameState.players[1]["eternal_item_id"] = "eternal_belial_book"
	GameState.players[1]["eternal_used"] = true
	GameState.players[1]["character_tapped"] = false
	GameState.players[1]["hand"] = ["loot_dinner"]
	_z_asks.clear()
	_z_pushed.clear()
	var on_ask := func(pid: int, stack_type: String, _payload: Dictionary):
		_z_asks.append([pid, stack_type])
	var on_push := func(e: Dictionary): _z_pushed.append([e.get("type"), e.get("payload", {}).get("target_id", "")])
	EventBus.priority_pending.connect(on_ask)
	EventBus.stack_entry_pushed.connect(on_push)
	var bomb: CardResource = load(CARD_DIR + "loot_bomb.tres")
	var played: bool = await _controller.play_loot(bomb, 0, {"target_id": "monster_gaper#z"})
	EventBus.priority_pending.disconnect(on_ask)
	EventBus.stack_entry_pushed.disconnect(on_push)
	p0["hand"].erase("loot_bomb")
	var ok: bool = played
	ok = ok and _z_pushed == [["pending_effect", "monster_gaper#z"]]
	ok = ok and _z_asks == [[0, "pending_effect"], [1, "pending_effect"]]   # NON-active P2 asked too
	ok = ok and _find_table_hp("monster_gaper#z") == 3                      # resolved: 2 damage
	ok = ok and p0["loot_played"] == 1
	ok = ok and _controller.stack.is_empty()
	print("  STEP Z ESEMPIO-5 check: %s (Bomb pushed pending_effect; asked %s; Gaper hp 5 -> %d)" % [
		"PASS" if ok else "FAIL", str(_z_asks), _find_table_hp("monster_gaper#z")])
	_record_check("STEP Z ESEMPIO 5 loot pending_effect + window for all", ok)

## --- STEP AE: one round of passes resolves exactly ONE stack entry -----------

## Comprehensive Rules (same as MTG): when everybody passes in sequence, only
## the TOP entry resolves. A loot played in response goes ON the stack (it does
## not resolve during the window), resolves first as a single entry, and the
## pending roll underneath then gets a FRESH priority window before resolving
## — which is what makes "draw in response, then answer the roll" possible.
var _ae_resolved: Array = []
var _ae_trace: Array = []
var _ae_stack_after_first: int = -1
var _ae_hp_at_effect_resolution: int = -1

func _check_single_resolution() -> void:
	print("\n-- CHECK: STEP AE — a pass round resolves only the TOP entry --")
	var p0: Dictionary = GameState.players[0]
	var p1: Dictionary = GameState.players[1]
	_clear_player_items(0)
	_clear_player_items(1)
	var fly: CardResource = load(CARD_DIR + "monster_attack_fly.tres")
	if fly == null:
		Log.error("turn_loop_test: monster_attack_fly.tres missing (run the import)")
		get_tree().quit(1)
		return
	_set_single_monster("monster_attack_fly#ae", fly, 5)
	_controller.begin_turn(0)
	# Only P1 can answer: no eternal items anywhere, P0 with no hand.
	p0["character_id"] = "character_isaac"
	p0["eternal_item_id"] = ""
	p0["eternal_used"] = false
	p0["character_tapped"] = false
	p0["hand"] = []
	p1["character_id"] = "character_judas"
	p1["eternal_item_id"] = ""
	p1["eternal_used"] = true
	p1["character_tapped"] = false
	p1["hp"] = 1
	p1["max_hp"] = 2
	p1["hand"] = ["loot_dinner"]
	_ae_resolved.clear()
	_ae_trace.clear()
	_ae_stack_after_first = -1
	_ae_hp_at_effect_resolution = -1
	var on_resolved := func(entry: Dictionary, _result: Dictionary):
		var kind: String = String(entry.get("type", ""))
		_ae_resolved.append([kind, String(entry.get("card_id", entry.get("id", "")))])
		_ae_trace.append("resolve:" + kind)
		if _ae_resolved.size() == 1:
			# ONLY the top resolved: the roll must still be on the stack, and the
			# effect must already be visible in the state.
			_ae_stack_after_first = _controller.stack.size()
			_ae_hp_at_effect_resolution = int(p1["hp"])
	var on_closed := func(stack_type: String, _payload: Dictionary):
		_ae_trace.append("close:" + stack_type)
	EventBus.stack_entry_resolved.connect(on_resolved)
	EventBus.priority_closed.connect(on_closed)
	# 1. a pending roll sits alone on the stack, exactly as an attack leaves it
	_controller.stack.push({"type": "pending_roll", "owner": 0,
		"target": "monster_attack_fly#ae", "value": 2, "bonus": 0,
		"die_value": fly.die_value, "source": "attack"})
	# 2. P1 answers the window with a loot card: it goes ON TOP, still pending
	var dinner: CardResource = load(CARD_DIR + "loot_dinner.tres")
	var responded: bool = _controller._play_loot_in_priority(dinner, 1, "")
	var stack_before: int = _controller.stack.size()
	var dinner_still_in_hand: bool = (p1["hand"] as Array).has("loot_dinner")
	# 3. the real resolution loop (windows + one entry per round)
	var result: Dictionary = await _controller._resolve_stack()
	EventBus.stack_entry_resolved.disconnect(on_resolved)
	EventBus.priority_closed.disconnect(on_closed)
	var ok: bool = responded and not dinner_still_in_hand
	ok = ok and stack_before == 2                                   # nothing resolved during the window
	ok = ok and _ae_resolved.size() == 2
	ok = ok and String(_ae_resolved[0][0]) == "pending_effect"      # TOP first (LIFO)
	ok = ok and _ae_stack_after_first == 1                          # ONE entry resolved, not the block
	ok = ok and _ae_hp_at_effect_resolution == 2                    # Dinner already applied
	ok = ok and String(_ae_resolved[1][0]) == "pending_roll"        # the roll resolves later
	ok = ok and _ae_trace == ["close:pending_effect", "resolve:pending_effect",
		"close:pending_roll", "resolve:pending_roll"]              # NEW window before the roll resolves
	ok = ok and result.get("roll", -1) == 2 and not result.get("hit", true)  # 2 vs die 3: MISS
	ok = ok and _controller.stack.is_empty()
	ok = ok and p1["character_tapped"]                              # out-of-turn loot paid with the tap
	print("  STEP AE single-resolution check: %s (trace %s; stack after the first resolution: %d)" % [
		"PASS" if ok else "FAIL", str(_ae_trace), _ae_stack_after_first])
	_record_check("STEP AE single-entry stack resolution (top only per pass round)", ok)

## --- STEP AF (M2): the protocol carries pure data only ----------------------

## Every command and every message must survive JSON as-is: no Object, no
## Resource, no Callable may cross the client/server boundary. The validator
## must also REJECT an impure command and a command with a bad type/player.
func _check_protocol_purity() -> void:
	print("\n-- CHECK: STEP AF — protocol boundary carries pure data only --")
	var commands: Array = [
		Protocol.command(Protocol.CMD_PLAY_LOOT, 0, {"card_id": "loot_bomb", "target_id": "monster_gaper#1"}),
		Protocol.command(Protocol.CMD_DECLARE_ATTACK, 1, {"target_id": "monster_gaper#1"}),
		Protocol.command(Protocol.CMD_BUY_SHOP, 0, {"slot": 0}),
		Protocol.command(Protocol.CMD_PASS_PRIORITY, 1, {}, "pr12"),
		Protocol.command(Protocol.CMD_SELECT_TARGET, 1, {"target_id": "monster_gaper#1"}, "tg3"),
		Protocol.command(Protocol.CMD_CHOOSE_DEATH_PENALTY, 0, {"loot_id": "loot_bomb", "item_id": "treasure_the_bible"}, "dr4"),
		Protocol.command(Protocol.CMD_ACTIVATE_ITEM, 0, {"delta": -1}),
		Protocol.command(Protocol.CMD_END_TURN, 0),
	]
	var messages: Array = [
		Protocol.state_snapshot(_controller.snapshot_for(0), _controller.ui_actions(0), "priority"),
		Protocol.priority_request({
			"request_id": "pr1", "player_id": 1, "stack_type": "pending_roll",
			"entry": {"type": "pending_roll", "id": "r1", "value": 3},
			"legal_actions": [{"action": "pass"}], "phase": "combat", "turn_player_id": 0}),
		Protocol.target_request("tg1", 0, Protocol.CMD_PLAY_LOOT, "loot_bomb", [{"instance_id": "m#1"}]),
		Protocol.death_request({"request_id": "dr1", "player_id": 0, "penalty": {"loot_options": ["loot_bomb"]}}),
		Protocol.domain_event("card_drawn", {"player_id": 0, "card_id": "loot_bomb"}, 0),
	]
	var ok: bool = true
	for cmd in commands:
		ok = ok and Protocol.validation_error(cmd) == ""
		ok = ok and Protocol.is_pure(cmd)
		ok = ok and Protocol.to_wire(cmd) != ""
		var back: Dictionary = Protocol.from_wire(Protocol.to_wire(cmd))
		ok = ok and String(back.get("type", "")) == String(cmd["type"])
		ok = ok and int(back.get("schema_version", 0)) == Protocol.SCHEMA_VERSION
	for msg in messages:
		ok = ok and Protocol.is_pure(msg)
		ok = ok and Protocol.to_wire(msg) != ""
	# ...and the validator rejects everything that must never ship.
	ok = ok and Protocol.validation_error(Protocol.command("NOT_A_COMMAND", 0)) == "unknown_command"
	ok = ok and Protocol.validation_error(Protocol.command(Protocol.CMD_BUY_SHOP, -1, {})) == "bad_player_id"
	var impure := {"kind": "command", "schema_version": Protocol.SCHEMA_VERSION,
		"type": Protocol.CMD_BUY_SHOP, "player_id": 0, "request_id": "",
		"payload": {"card": CardResource.new()}}
	ok = ok and Protocol.validation_error(impure) == "impure_payload"
	# the RAW state is NOT shippable (resources on the table) — the snapshot is.
	ok = ok and not Protocol.is_pure(_controller.state.table_monsters)
	print("  STEP AF protocol check: %s (%d commands, %d messages, JSON roundtrip; impure payload refused)" % [
		"PASS" if ok else "FAIL", commands.size(), messages.size()])
	_record_check("STEP AF protocol purity (JSON-only commands/messages)", ok)

## --- STEP AA (ratifica #3): input is bound to ONE request and ONE player ------

## A driver answer with a stale request id, or addressed to another player, must
## become a PASS. An answer with the right identity must pass validation and
## reach the engine unchanged (it is the ONLY way to act on a window).
func _check_priority_identity() -> void:
	print("\n-- CHECK: priority request identity (ratifica #3) --")
	var saved_driver = _controller.driver
	var stale := StaleDriver.new()
	_controller.driver = stale
	var request := {
		"request_id": "pr-check", "player_id": 0, "stack_type": "pending_roll", "entry": {}}
	var stale_answer: Dictionary = await _controller._ask_priority(request)
	var ok: bool = String(stale_answer.get("action", "")) == "pass"
	var foreign := StaleDriver.new()
	foreign.stale_request_id = false
	foreign.wrong_player = true
	_controller.driver = foreign
	var foreign_answer: Dictionary = await _controller._ask_priority(request)
	ok = ok and String(foreign_answer.get("action", "")) == "pass"
	var good := StaleDriver.new()
	good.stale_request_id = false
	_controller.driver = good
	var good_answer: Dictionary = await _controller._ask_priority(request)
	ok = ok and String(good_answer.get("action", "")) == "loot"
	ok = ok and int(good_answer.get("player_id", -1)) == 0
	ok = ok and String(good_answer.get("request_id", "")) == "pr-check"
	_controller.driver = saved_driver
	print("  STEP AA identity check: %s (stale id -> pass, wrong player -> pass, bound answer -> accepted)" % ["PASS" if ok else "FAIL"])
	_record_check("STEP AA priority request identity binding", ok)

## --- STEP AB (ratifica #2): per-viewer snapshots keep hands private ---------

## The table view sees NO hand contents (counts only); each client sees only its
## own hand in full and the opponents' counts. This is the boundary a future
## socket will serialize, so it is verified here, not in the UI.
func _check_state_snapshot() -> void:
	print("\n-- CHECK: per-viewer snapshot privacy (ratifica #2) --")
	var hand_backup: Array = (GameState.players[0]["hand"] as Array).duplicate()
	var opponent_hand_size: int = (GameState.players[1]["hand"] as Array).size()
	GameState.players[0]["hand"] = ["loot_bomb", "loot_dinner"]
	var own_view: Dictionary = _controller.snapshot_for(0)
	var table_view: Dictionary = _controller.snapshot_for(-1)
	var own_players: Array = own_view.get("players", [])
	var table_players: Array = table_view.get("players", [])
	var ok: bool = own_players.size() == 2 and table_players.size() == 2
	ok = ok and own_players[0]["hand"] == ["loot_bomb", "loot_dinner"]
	ok = ok and (own_players[1]["hand"] as Array).is_empty()          # opponent hand hidden
	ok = ok and int(own_players[1]["hand_count"]) == opponent_hand_size
	ok = ok and (table_players[0]["hand"] as Array).is_empty()        # the table sees no hand either
	ok = ok and int(table_players[0]["hand_count"]) == 2
	ok = ok and table_view.has("deck_counts") and not table_view.has("decks")
	GameState.players[0]["hand"] = hand_backup
	print("  STEP AB snapshot check: %s (own hand %s, opponent hand hidden, counts kept)" % [
		"PASS" if ok else "FAIL", str(own_players[0]["hand"])])
	_record_check("STEP AB per-viewer snapshot privacy", ok)

## --- STEP AC (ratifica #2): the state survives a serialization roundtrip -----

func _check_state_roundtrip() -> void:
	print("\n-- CHECK: MatchState serialization roundtrip --")
	var image: Dictionary = _controller.state.to_dict()
	var restored = MatchStateScript.new()
	restored.load_from_dict(image)
	var ok: bool = restored.players.size() == _controller.state.players.size()
	ok = ok and restored.current_player_index == _controller.state.current_player_index
	ok = ok and restored.phase == _controller.state.phase
	ok = ok and restored.turn_number == _controller.state.turn_number
	ok = ok and restored.players[0]["hand"] == _controller.state.players[0]["hand"]
	ok = ok and restored.players[0]["cents"] == _controller.state.players[0]["cents"]
	ok = ok and restored.soul_total(0) == _controller.state.soul_total(0)
	ok = ok and restored.table_monsters.size() == _controller.state.table_monsters.size()
	ok = ok and restored.shop_slots.size() == _controller.state.shop_slots.size()
	ok = ok and restored.loot_deck.size() == _controller.state.loot_deck.size()
	ok = ok and restored.monster_deck.size() == _controller.state.monster_deck.size()
	ok = ok and restored.treasure_deck.size() == _controller.state.treasure_deck.size()
	# card ids were re-resolved into resources on load
	ok = ok and not restored.table_monsters.is_empty() and restored.table_monsters[0]["card"] != null
	ok = ok and restored.table_monsters[0]["card"].id == _controller.state.table_monsters[0]["card"].id
	print("  STEP AC roundtrip check: %s (%d cards re-resolved, phase '%s', active P%d)" % [
		"PASS" if ok else "FAIL", restored.table_monsters.size() + restored.shop_slots.size(),
		restored.phase, restored.current_player_index + 1])
	_record_check("STEP AC MatchState serialization roundtrip", ok)

## --- STEP AD (audit C4): teardown() is complete and idempotent ---------------

## A scored match must not leak into the next one: after teardown (twice, to
## prove idempotence) there are no effects, no shields, no players, no stack;
## and the SAME controller can be set up again and is fully functional.
func _check_teardown() -> void:
	print("\n-- CHECK: teardown / restart isolation (audit C4) --")
	var scratch = MatchControllerScript.new()
	var scratch_driver := ScriptedDriver.new()
	scratch_driver.policy = _robot_policy
	scratch.setup(2, 11, scratch_driver)
	var sack: CardResource = load(CARD_DIR + "treasure_sack_of_pennies.tres")
	CardEffectRegistry.register_card(sack, 0, "treasure_sack_of_pennies#teardown")
	GameState.apply_shield(0, 0, "Yum Heart")
	scratch.teardown()
	scratch.teardown()  # idempotent
	var ok: bool = CardEffectRegistry.effect_count() == 0
	ok = ok and GameState.shields.is_empty()
	ok = ok and GameState.players.is_empty()
	ok = ok and scratch.stack == null
	# the same instance comes back clean and playable
	scratch.setup(2, 11, scratch_driver)
	ok = ok and scratch.table_monsters.size() == MatchControllerScript.MONSTER_SLOTS
	ok = ok and scratch.shop_slots.size() == MatchControllerScript.SHOP_SLOTS
	ok = ok and scratch.stack != null and scratch.stack.is_empty()
	ok = ok and GameState.players.size() == 2 and GameState.players[0]["cents"] == 3
	scratch.teardown()
	# the main controller's state was only detached by the scratch setup: put it back
	GameState.adopt(_controller.state)
	print("  STEP AD teardown check: %s (no effects, no shields, no players; fresh setup works)" % ["PASS" if ok else "FAIL"])
	_record_check("STEP AD teardown idempotence + restart isolation", ok)

## Unmounts every card copy a player owns, then empties items_passive — used
## to make the self-checks self-contained regardless of demo purchases.
## Re-injects loot cards into the discard pile: several self-checks ASSIGN hand
## arrays directly, which leaks cards out of the deck+discard circulation —
## without this the loot deck runs dry before the later checks draw.
func _restock_loot(count: int) -> void:
	var card: CardResource = load(CARD_DIR + "loot_swallowed_penny.tres")
	if card == null:
		Log.error("turn_loop_test: loot_swallowed_penny.tres missing (run the import)")
		get_tree().quit(1)
		return
	for i in range(count):
		_controller.state.loot_discard.append(card)

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