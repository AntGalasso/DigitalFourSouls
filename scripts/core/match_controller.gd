extends RefCounted
## Shared rules engine for a match: decks, the monster table, the shop, buy /
## attack / play / draw / end-turn actions, the death penalty, characters,
## the priority/stack window and the soul win condition.
##
## M1 refactor (ratifiche #2, #3, #5):
##  - ALL match data lives in ONE serializable object (MatchState). This file
##    keeps only per-resolution locks (_combat_in_progress, _effect_window_open
##    and the stack itself).
##  - INPUT GOES THROUGH A DRIVER. The engine no longer awaits a global
##    EventBus signal: it builds a request (request_id, player_id, legal
##    actions, stack entry), asks the injected MatchDriver and validates the
##    answer. A stale request id or a foreign player id is a PASS, never an
##    action (audit C3).
##  - RESOLUTION IS RECURSIVE AND SINGLE-ENTRY. One round of consecutive
##    passes resolves EXACTLY the top of the stack (Comprehensive Rules, same
##    as MTG); if anything is left underneath, a FRESH priority window opens
##    before it resolves. An effect that pushes a new entry while it resolves
##    gets its own window instead of being wiped by reset_combat_state()
##    (audit C1).
##  - setup() begins with teardown(), and teardown() is idempotent: a restart
##    never inherits effects, shields or stack entries from the previous match
##    (audit C4).
##
## Two drivers use this same engine — game rules live HERE, never duplicated:
##  - scenes/turn_loop_test.gd (scripted robot, deterministic seed)
##  - scenes/game_scene.gd    (human hotseat, via LocalUiDriver)
##
## Not a class_name on purpose (headless CLI does not refresh the global class
## cache): preload this script.

const CARD_DIR := "res://resources/cards/base_set/"
## Preload (not class_name): the global class cache is only refreshed by the
## editor, so headless CLI runs resolve these via preload instead.
const EventStackScript := preload("res://scripts/core/event_stack.gd")
const MatchStateScript := preload("res://scripts/core/match_state.gd")
const LocalUiDriverScript := preload("res://scripts/core/drivers/local_ui_driver.gd")

const MONSTER_SLOTS := 2      # base slots; the table is a LIST so future cards
const SHOP_SLOTS := 2         # or events can add a slot without a refactor
const LOOT_PER_TURN := 1
const HAND_LIMIT := 10
const MAX_RESOLUTION_ROUNDS := 64

## THE state. Same object as GameState.state (GameState is the façade).
var state = MatchStateScript.new()
## Who answers the priority windows / death choices. Never null after setup().
var driver = null
## The event queue (typed entries, LIFO). Owned here, serialized by MatchState
## only between windows (a stack in flight is resolution state, not match data).
var stack = null

var total_cards_at_setup := 0

## Resolution locks. They are NOT match data: they only exist while the engine
## is inside an attack/loot resolution in this process.
var _combat_in_progress: bool = false
var _effect_window_open: bool = false
var _request_counter: int = 0

# --- Lifecycle ----------------------------------------------------------------

## Builds decks, characters, the initial table and the shop. The caller picks
## the seed (the robot passes a fixed one, the human game a random one) and
## optionally the driver (default: the local hotseat UI adapter).
func setup(player_count: int, seed_value: int, p_driver = null) -> void:
	teardown()
	Rng.seed_rng(seed_value)
	driver = p_driver if p_driver != null else LocalUiDriverScript.new()
	state = MatchStateScript.new()
	state.reset(player_count)
	total_cards_at_setup = 0
	GameState.adopt(state)
	stack = EventStackScript.new()
	stack.resolver = _resolve_stack_entry
	EventBus.monster_damaged.connect(_on_monster_damaged)
	EventBus.monster_killed.connect(_on_monster_killed)
	_build_decks()
	_assign_characters()
	_refill_monsters("")
	_refill_shop()
	print("start: %d players, each with 3¢ and %d loot per turn (MP07 C)" % [player_count, LOOT_PER_TURN])

## Full reset, safe to call at any moment and any number of times: stops
## listening to EventBus, drops the stack, every registered card effect and
## the match state. setup() calls it first, so "new game" is one call.
func teardown() -> void:
	if EventBus.monster_damaged.is_connected(_on_monster_damaged):
		EventBus.monster_damaged.disconnect(_on_monster_damaged)
	if EventBus.monster_killed.is_connected(_on_monster_killed):
		EventBus.monster_killed.disconnect(_on_monster_killed)
	if stack != null:
		stack.clear("teardown")
		stack.resolver = Callable()
		stack = null
	CardEffectRegistry.reset()
	GameState.clear()
	state = MatchStateScript.new()
	_combat_in_progress = false
	_effect_window_open = false
	_request_counter = 0
	driver = null

func _pname(player_id: int) -> String:
	return "P%d" % (player_id + 1)

## Per-viewer DTO, plus the private extras only that viewer may see (its own
## hand is already filtered by MatchState.snapshot_for). The networking layer
## will send exactly this, never the raw state.
func snapshot_for(viewer_player_id: int) -> Dictionary:
	var snapshot: Dictionary = state.snapshot_for(viewer_player_id)
	snapshot["pending_roll"] = get_pending_roll()
	snapshot["combat_in_progress"] = _combat_in_progress
	snapshot["stack_size"] = stack.size() if stack != null else 0
	return snapshot

# --- State accessors (kept as properties so drivers/tests do not change) ------

var table_monsters: Array:
	get:
		return state.table_monsters

var shop_slots: Array:
	get:
		return state.shop_slots

var last_killed_monster: String:
	get:
		return state.last_killed_monster
	set(value):
		state.last_killed_monster = value

# --- Turn structure (ESEMPIO 1) ------------------------------------------------

## Starts the given player's turn: untaps their character and items (the
## start phase), draws LOOT_PER_TURN into their hand and emits turn_started.
## Phase becomes "action", which is where the FREE loot play lives.
func begin_turn(player_id: int) -> void:
	if player_id < 0 or player_id >= state.players.size():
		Log.warn("MatchController.begin_turn: no player %d" % player_id)
		return
	state.current_player_index = player_id
	state.phase = MatchStateScript.PHASE_START
	var p: Dictionary = state.players[player_id]
	p["attacks_used"] = 0
	p["buys_used"] = 0
	p["loot_played"] = 0
	p["character_tapped"] = false          # untap: start phase of the OWNER's turn
	p["tapped_items"] = []                  # items spent by the death penalty untap
	p["eternal_used"] = false
	draw_loot(player_id)
	EventBus.turn_started.emit(player_id)
	state.phase = MatchStateScript.PHASE_ACTION

## Player-initiated end of turn. Runs the ENDING PHASE (which always ends
## with GameState.advance_active_player()) and returns the NEXT player id.
func end_turn() -> int:
	_finish_turn(state.current_player_index)
	return state.current_player_index

## ENDING PHASE (ESEMPIO 1 step 4-5), shared by end_turn and death:
##   heal_all_players() -> heal_all_monsters() -> discard_to_hand_limit()
##   -> refill_empty_slots(shop=true, monsters=true)
##   -> advance_active_player()   <- THIS STEP MUST NEVER BE MISSING
func _finish_turn(ending_player_id: int) -> void:
	state.phase = MatchStateScript.PHASE_END
	var p: Dictionary = state.players[ending_player_id]
	var item_id: String = p["eternal_item_id"]
	if item_id != "":
		var item: CardResource = card_resource(item_id)
		if item != null and item.recharges_on_turn_end and p["eternal_used"]:
			p["eternal_used"] = false
			print("  %s recharges (end of owner's turn)" % item.display_name)
	# ESEMPIO 4 point 4: unused shields expire at the end of the OWNER's turn.
	var expired_targets: Array = GameState.expire_shields_owned_by(ending_player_id)
	if not expired_targets.is_empty() and item_id == "eternal_yum_heart" and p["eternal_used"]:
		p["eternal_used"] = false
		print("  Yum Heart recharges for %s (shield expired)" % _pname(ending_player_id))
	print("  ending phase: heal_all_players()")
	for player in state.players:
		GameState.restore_hp(player["id"])
	print("  ending phase: heal_all_monsters()")
	for monster in state.table_monsters:
		monster["hp"] = monster["card"].hp
	EventBus.monsters_restored.emit()
	discard_to_hand_limit(ending_player_id, HAND_LIMIT)
	print("  ending phase: refill_empty_slots(shop=true, monsters=true)")
	_refill_shop()
	_refill_monsters("")
	EventBus.turn_ended.emit(ending_player_id)
	# [TURN SWITCH — QUESTO STEP NON DEVE MAI MANCARE]
	GameState.advance_active_player()

func discard_to_hand_limit(player_id: int, limit: int = HAND_LIMIT) -> void:
	print("  ending phase: discard_to_hand_limit(player=\"%s\", limit=%d)" % [_pname(player_id), limit])
	var hand: Array = state.players[player_id]["hand"]
	while hand.size() > limit:
		var card_id: String = hand.pop_front()
		var card: CardResource = card_resource(card_id)
		if card != null:
			state.loot_discard.append(card)
		EventBus.card_discarded.emit(player_id, card_id)
		print("  %s discards %s (hand limit %d)" % [_pname(player_id), card.display_name if card != null else card_id, limit])

# --- Player actions ----------------------------------------------------------

## Buys the treasure in the given shop SLOT (once per own turn). Returns false
## if the slot is empty, the buy limit is spent, it was already bought, or it
## is unaffordable. On success the slot refills, so the shop always shows
## exactly SHOP_SLOTS cards (MP07 E).
func buy(slot_index: int, player_id: int) -> bool:
	if slot_index < 0 or slot_index >= state.shop_slots.size():
		return false
	var card: CardResource = state.shop_slots[slot_index]["card"]
	if card == null:
		return false
	if player_id < 0 or player_id >= state.players.size():
		return false
	var player: Dictionary = state.players[player_id]
	if player_id != state.current_player_index:
		return false
	if player["buys_used"] >= 1:
		return false
	if player["cents"] < card.cost_cents:
		return false
	var bought: Dictionary = state.bought.get(player_id, {})
	if bought.has(card.id):
		return false
	GameState.lose_cents(player_id, card.cost_cents)
	player["items_passive"].append(card.id)
	bought[card.id] = true
	state.bought[player_id] = bought
	player["buys_used"] += 1
	state.instance_counter += 1
	var instance_id: String = "%s#%d" % [card.id, state.instance_counter]
	state.shop_slots.remove_at(slot_index)
	_refill_shop()
	EventBus.item_bought.emit(player_id, card.id)
	CardEffectRegistry.register_card(card, player_id, instance_id)
	return true

## Attacks the monster with the given instance_id (ESEMPI 2, 2b, 3). Each roll
## is PUSHED on the stack as a pending_roll, the priority window opens to ALL
## players, then the stack resolves top-first: modifier(s) onto the
## pending_roll which resolves into HIT/MISS. reset_combat_state() runs on
## EVERY exit path. Returns {"valid", "outcome": "killed"|"player_died",
## "steps", "rolls", "final_roll"}.
func attack(instance_id: String, player_id: int) -> Dictionary:
	var monster: Dictionary = _find_monster(instance_id)
	if monster.is_empty():
		return {"valid": false}
	if _combat_in_progress or _effect_window_open:
		return {"valid": false, "busy": true}
	if player_id != state.current_player_index:
		return {"valid": false}
	if player_id < 0 or player_id >= state.players.size():
		return {"valid": false}
	var player: Dictionary = state.players[player_id]
	if player["attacks_used"] >= 1:
		return {"valid": false, "limit": true}
	player["attacks_used"] += 1
	_combat_in_progress = true
	state.phase = MatchStateScript.PHASE_COMBAT
	var steps: int = 0
	var outcome: String = ""
	var rolls: Array = []
	var final_roll: int = 0
	while true:
		var m: Dictionary = _find_monster(instance_id)
		if m.is_empty():
			outcome = "killed"  # removed by an effect during the window
			break
		steps += 1
		var monster_card: CardResource = m["card"]
		# ESEMPIO 2 step 1: raw roll -> PUSH {type:"pending_roll", ...}
		var raw_roll: int = Rng.roll_die()
		var bonus: int = CardEffectRegistry.get_roll_bonus(player_id)
		stack.push({
			"type": "pending_roll", "owner": player_id, "target": instance_id,
			"value": raw_roll + bonus, "bonus": bonus, "die_value": monster_card.die_value,
			"source": "attack"})
		print("%s rolls %d (pending, not yet resolved)" % [_pname(player_id), raw_roll + bonus])
		# A window per entry, recursively: responses may push more entries.
		var result: Dictionary = await _resolve_stack()
		var roll: int = int(result.get("roll", 0))
		final_roll = roll
		rolls.append(roll)
		if result.get("hit", false):
			var damage: int = int(GameState.players[player_id]["damage"]) + CardEffectRegistry.get_damage(player_id)
			EventBus.monster_damaged.emit(instance_id, damage)
			var damaged: Dictionary = _find_monster(instance_id)
			if damaged.is_empty() or damaged["hp"] <= 0:
				outcome = "killed"
				EventBus.monster_killed.emit(player_id, instance_id, _kill_rewards(m["card"]))
				break
			# survived: the sequence continues (MP07 D — no voluntary stop)
		else:
			if await _run_player_damage(player_id, 1, instance_id):
				outcome = "player_died"
				break
	reset_combat_state()
	return {"valid": true, "outcome": outcome, "steps": steps, "rolls": rolls, "final_roll": final_roll}

## A miss hurts the attacker; if HP reaches 0 they die mid-attack and the
## death flow (penalty -> ending phase -> advance) completes before the
## attack returns. Returns true when the player died.
func _run_player_damage(player_id: int, amount: int, source_id: String) -> bool:
	GameState.damage_player(player_id, amount, source_id)
	if GameState.players[player_id]["hp"] <= 0:
		print("  >>> %s dies mid-attack" % _pname(player_id))
		await die(player_id)
		return true
	return false

## Plays a card from hand (loot or active item) with an optional target
## (ESEMPIO 5). The play becomes a PENDING_EFFECT entry, the priority window
## opens to ALL players, then the effect resolves. The loot cost is charged
## synchronously BEFORE the window, and the card leaves the hand HERE — the
## UI/robot must never mutate hands again (ratifica #2).
func play_loot(card: CardResource, player_id: int, payload: Dictionary = {}) -> bool:
	if card == null:
		return false
	if player_id < 0 or player_id >= state.players.size():
		return false
	if _effect_window_open or _combat_in_progress:
		return false
	if card.type == CardResource.CardType.LOOT:
		if not _charge_loot_play(player_id):
			return false
	_effect_window_open = true
	state.players[player_id]["hand"].erase(card.id)
	var entry: Dictionary = stack.push({
		"type": "pending_effect", "owner": player_id,
		"card_id": card.id, "payload": payload.duplicate()})
	var target_line: String = ""
	var target_id: String = payload.get("target_id", "")
	if target_id != "":
		var target: Dictionary = _find_monster(target_id)
		target_line = " targeting %s" % (target["card"].display_name if not target.is_empty() else target_id)
	print("%s plays %s%s (pending)" % [_pname(player_id), card.display_name, target_line])
	await _resolve_stack()
	_effect_window_open = false
	return true

## Charges ONE loot play (ratifica #5):
##  - the FIRST loot of your own ACTION phase is free;
##  - any other play (second in your turn, or any play outside your turn)
##    taps the CHARACTER card;
##  - a tapped character cannot pay again until its owner's start phase.
## Returns false when the cost cannot be paid.
func _charge_loot_play(player_id: int) -> bool:
	var player: Dictionary = state.players[player_id]
	if player_id == state.current_player_index \
			and state.phase == MatchStateScript.PHASE_ACTION \
			and int(player["loot_played"]) < 1:
		player["loot_played"] = int(player["loot_played"]) + 1
		return true
	if player["character_tapped"]:
		return false
	player["character_tapped"] = true
	print("  %s taps the character card to play an extra/out-of-turn loot" % _pname(player_id))
	return true

## Can this player pay for one more loot play right now? (pure predicate:
## used by the legal-action list so a client never has to guess)
func can_play_loot(player_id: int) -> bool:
	if player_id < 0 or player_id >= state.players.size():
		return false
	var player: Dictionary = state.players[player_id]
	if player_id == state.current_player_index \
			and state.phase == MatchStateScript.PHASE_ACTION \
			and int(player["loot_played"]) < 1:
		return true
	return not player["character_tapped"]

## Uses the player's eternal item as stack answers (ESEMPI 2, 2b, 4).
func use_eternal_item(player_id: int, payload: Dictionary = {}) -> Dictionary:
	if player_id < 0 or player_id >= state.players.size():
		return {"ok": false}
	var player: Dictionary = state.players[player_id]
	if player["eternal_used"]:
		return {"ok": false, "reason": "recharging"}
	var item_id: String = player["eternal_item_id"]
	if item_id == "":
		return {"ok": false, "reason": "no_eternal_item"}
	var item: CardResource = card_resource(item_id)
	if item == null:
		return {"ok": false, "reason": "missing_card"}
	var result := {"ok": true, "item_id": item_id}
	match item.eternal_action:
		"reroll_die":
			var roll_entry: Dictionary = stack.top_of_type("pending_roll") if stack != null else {}
			if roll_entry.is_empty():
				return {"ok": false, "reason": "no_pending_roll"}
			stack.push({
				"type": "modifier", "effect": "reroll", "item_id": item.id,
				"item_name": item.display_name, "owner": player_id,
				"target_id": roll_entry["id"]})
			print("%s activates %s targeting %s" % [_pname(player_id), item.display_name, roll_entry["id"]])
			result["target_roll"] = roll_entry["id"]
		"adjust_die":
			var roll_entry: Dictionary = stack.top_of_type("pending_roll") if stack != null else {}
			if roll_entry.is_empty():
				return {"ok": false, "reason": "no_pending_roll"}
			var delta: int = clampi(int(payload.get("delta", 1)), -1, 1)
			var old_value: int = roll_entry["value"]
			roll_entry["value"] = old_value + delta
			stack.push({
				"type": "modifier", "effect": "adjust", "delta": delta,
				"applied": true, "item_id": item.id, "item_name": item.display_name,
				"owner": player_id, "target_id": roll_entry["id"]})
			print("%s uses %s (%+d): %s value %d -> %d" % [
				_pname(player_id), item.display_name, delta, roll_entry["id"], old_value, roll_entry["value"]])
			result["new_roll"] = roll_entry["value"]
		"prevent_damage":
			var target = payload.get("target_id", -1)
			if typeof(target) == TYPE_STRING:
				if _find_monster(String(target)).is_empty():
					return {"ok": false, "reason": "no_target"}
				state.monster_shields[target] = {"owner": player_id, "item_name": item.display_name}
				print("%s uses %s on %s: next damage to %s this turn is prevented" % [
					_pname(player_id), item.display_name, target, target])
				result["target_instance"] = target
			else:
				var tid: int = int(target)
				if tid < 0 or tid >= state.players.size():
					return {"ok": false, "reason": "no_target"}
				GameState.apply_shield(tid, player_id, item.display_name)
				print("%s uses %s on %s: next damage to %s this turn is prevented" % [
					_pname(player_id), item.display_name, _pname(tid), _pname(tid)])
				result["target_player"] = tid
		_:
			return {"ok": false, "reason": "unknown_action"}
	player["eternal_used"] = true
	EventBus.eternal_used.emit(player_id, item_id, result)
	return result

## Draws one loot from the deck into the player's hand (reshuffling the
## discard when needed). Returns the card, or null if no loot is left.
func draw_loot(player_id: int) -> CardResource:
	var card: CardResource = _pop_loot()
	if card == null:
		return null
	EventBus.card_drawn.emit(player_id, card.id, "loot")
	state.players[player_id]["hand"].append(card.id)
	print("%s draws %s" % [_pname(player_id), card.display_name])
	return card

# --- Priority: requests, validation, legal actions (audit C3, ratifica #3) -----

## The window opened by ONE stack entry. Each player WITH a response is asked
## in turn order starting from the active player; players with nothing to
## answer with are auto-passed. A response restarts the round from the active
## player; consecutive passes close the window.
func _run_stack_window(entry: Dictionary) -> void:
	var count: int = state.players.size()
	if count == 0:
		return
	var idx: int = state.current_player_index
	var passes: int = 0
	while passes < count:
		if stack == null or stack.is_empty():
			break
		# A response may have pushed a new entry on top: every subsequent ask
		# (and its legal-action list) must be about the CURRENT top.
		entry = stack.top()
		if not _player_has_response(idx, entry):
			print("%s passes priority on %s (no responses available)" % [
				_pname(idx), stack.top().get("id", "?")])
			passes += 1
			idx = (idx + 1) % count
			continue
		var request: Dictionary = _build_priority_request(idx, entry)
		# Notification for observers (UI, logs, future spectating). Unlike the
		# old design this signal is NOT the input channel: the answer comes
		# back through the driver, bound to this request id.
		EventBus.priority_pending.emit(idx, String(entry.get("type", "")), entry.duplicate(true))
		var response: Dictionary = await _ask_priority(request)
		var acted: bool = false
		var action: String = String(response.get("action", "pass"))
		match action:
			"loot":
				var card: CardResource = card_resource(String(response.get("card_id", "")))
				if card != null and _play_loot_in_priority(card, idx, String(response.get("target_id", ""))):
					acted = true
					print("  [priority] %s responds: plays %s" % [_pname(idx), card.display_name])
			"eternal":
				var res: Dictionary = use_eternal_item(idx, response.get("payload", {}))
				if res.get("ok", false):
					acted = true
					print("  [priority] %s responds: uses %s" % [_pname(idx), res.get("item_id", "?")])
			"stop":
				print("  [priority] 'stop attack' is NOT a rule (MP07 D) — the attack continues")
			_:
				pass  # "pass" / "resolve" / unknown
		if acted:
			passes = 0
			idx = state.current_player_index
		else:
			print("%s passes priority on %s" % [_pname(idx), stack.top().get("id", "?")])
			passes += 1
			idx = (idx + 1) % count
	if stack != null:
		EventBus.priority_closed.emit(String(entry.get("type", "")), entry.duplicate(true))

## Builds the immutable request handed to the driver. It contains everything a
## client needs to render the window and nothing it must not know (no other
## player's hand).
func _build_priority_request(player_id: int, entry: Dictionary) -> Dictionary:
	_request_counter += 1
	return {
		"request_id": "pr%d" % _request_counter,
		"window": "priority",
		"player_id": player_id,
		"stack_type": String(entry.get("type", "")),
		"entry": entry.duplicate(true),
		"legal_actions": _legal_actions(player_id, entry),
		"phase": state.phase,
		"turn_player_id": state.current_player_index,
	}

## Asks the driver and validates the answer. Anything that is not a Dictionary
## bound to THIS request and THIS player becomes a pass (never an action).
func _ask_priority(request: Dictionary) -> Dictionary:
	if driver == null:
		return _pass_response(request)
	var raw = null
	if driver.is_interactive():
		raw = await driver.request_priority(request)
	else:
		raw = driver.decide_priority(request)
	if typeof(raw) != TYPE_DICTIONARY:
		Log.warn("MatchController: driver returned %s for %s — treating as pass" % [typeof(raw), String(request["request_id"])])
		return _pass_response(request)
	var response: Dictionary = raw
	if String(response.get("request_id", "")) != String(request["request_id"]):
		Log.warn("MatchController: stale/foreign answer (request '%s', expected '%s') — pass" % [
			String(response.get("request_id", "")), String(request["request_id"])])
		return _pass_response(request)
	if int(response.get("player_id", -1)) != int(request["player_id"]):
		Log.warn("MatchController: answer for P%d on a request addressed to P%d — pass" % [
			int(response.get("player_id", -1)) + 1, int(request["player_id"]) + 1])
		return _pass_response(request)
	return response

func _pass_response(request: Dictionary) -> Dictionary:
	return {
		"action": "pass",
		"request_id": String(request.get("request_id", "")),
		"player_id": int(request.get("player_id", -1)),
	}

## The full menu this player may legally choose from in this window. It is the
## engine OWNING the rules: a client renders these actions, it never invents
## them. "pass" is always implied and therefore not listed.
func _legal_actions(player_id: int, entry: Dictionary) -> Array:
	var actions: Array = []
	if player_id < 0 or player_id >= state.players.size():
		return actions
	var player: Dictionary = state.players[player_id]
	if player_id == state.current_player_index:
		actions.append({"action": "resolve"})
	if can_play_loot(player_id):
		for card_id in player["hand"]:
			var card: CardResource = card_resource(String(card_id))
			if card != null and card.type == CardResource.CardType.LOOT:
				actions.append({
					"action": "loot", "card_id": String(card_id),
					"display_name": card.display_name, "needs_target": card.needs_target})
	if not player["eternal_used"] and player["eternal_item_id"] != "":
		var item: CardResource = card_resource(player["eternal_item_id"])
		if item != null:
			match item.eternal_action:
				"reroll_die", "adjust_die":
					if String(entry.get("type", "")) == "pending_roll":
						actions.append({"action": "eternal", "payload": {}, "item_action": item.eternal_action})
				"prevent_damage":
					actions.append({"action": "eternal", "payload": {"item_action": "prevent_damage"}, "item_action": "prevent_damage"})
	return actions

## Server-owned legality for the LOCAL client (ratifica #2 / M2): the scene
## renders these flags and never recomputes a limit, a cost or a tap state.
## Pure read: no state mutation, no prints.
func ui_actions(player_id: int) -> Dictionary:
	var out := {
		"player_id": player_id,
		"phase": state.phase,
		"is_active": player_id == state.current_player_index,
		"busy": _effect_window_open or _combat_in_progress,
		"can_attack": false,
		"can_buy": false,
		"can_end_turn": false,
		"loot_playable": [],
		"items_playable": [],
		"shop": [],
		"eternal": {},
	}
	if player_id < 0 or player_id >= state.players.size():
		return out
	var player: Dictionary = state.players[player_id]
	var busy: bool = out["busy"]
	out["can_end_turn"] = bool(out["is_active"]) and not busy
	out["can_attack"] = bool(out["is_active"]) and not busy \
		and int(player["attacks_used"]) < 1 and not state.table_monsters.is_empty()
	for slot in range(state.shop_slots.size()):
		var treasure: CardResource = state.shop_slots[slot]["card"]
		if treasure == null:
			continue
		var reason: String = ""
		if not out["is_active"]:
			reason = "not_your_turn"
		elif int(player["buys_used"]) >= 1:
			reason = "buy_used"
		elif bool(state.bought.get(player_id, {}).has(treasure.id)):
			reason = "already_bought"
		elif int(player["cents"]) < treasure.cost_cents:
			reason = "too_poor"
		out["shop"].append({
			"slot": slot, "card_id": treasure.id, "cost_cents": treasure.cost_cents,
			"buyable": reason == "", "reason": reason})
		if reason == "":
			out["can_buy"] = true
	if bool(out["is_active"]) and state.phase == MatchStateScript.PHASE_ACTION \
			and not busy and can_play_loot(player_id):
		for card_id in player["hand"]:
			var loot: CardResource = card_resource(String(card_id))
			if loot != null and loot.type == CardResource.CardType.LOOT:
				out["loot_playable"].append(String(card_id))
	for card_id in player["items_passive"]:
		var item: CardResource = card_resource(String(card_id))
		if item != null and item.playable:
			out["items_playable"].append(String(card_id))
	var eternal: CardResource = card_resource(String(player["eternal_item_id"]))
	if eternal != null:
		out["eternal"] = {
			"item_id": eternal.id, "action": eternal.eternal_action,
			"available": not bool(player["eternal_used"]),
			"pending_roll": not get_pending_roll().is_empty()}
	return out

## A player is ASKED only when it has a real response (not merely "resolve"):
## otherwise the window auto-passes them, exactly like before, but now the
## decision comes from the same legal-action list the clients see.
func _player_has_response(player_id: int, entry: Dictionary) -> bool:
	for action in _legal_actions(player_id, entry):
		if String(action.get("action", "")) != "resolve":
			return true
	return false

## A loot card played AS A PRIORITY RESPONSE goes ON THE STACK as a
## pending_effect (Comprehensive Rules): it does NOT resolve during the
## window. The cost is charged and the card leaves the hand NOW, then a round
## of passes resolves it — one entry — and the entry underneath gets a new
## window. That is what lets "draw a card in response, then play it against
## the pending roll" actually work.
func _play_loot_in_priority(card: CardResource, player_id: int, target_id: String) -> bool:
	if not state.players[player_id]["hand"].has(card.id):
		return false
	# NOTE: combat_in_progress MUST NOT block this — responding during an attack
	# is the whole point of the window (only play_loot() outside a window does).
	if card.type == CardResource.CardType.LOOT and not _charge_loot_play(player_id):
		return false
	var payload := {}
	if target_id != "":
		payload = {"target_id": target_id}
	state.players[player_id]["hand"].erase(card.id)
	stack.push({"type": "pending_effect", "owner": player_id, "card_id": card.id, "payload": payload})
	print("%s responds with %s (pending on the stack)" % [_pname(player_id), card.display_name])
	return true

# --- Stack resolution (recursive, audit C1 / ratifica #3) ----------------------

## Drives resolution until the stack is empty, ONE ENTRY PER ROUND: a fresh
## priority window opens on the current top, consecutive passes close it, and
## exactly that top entry resolves (`resolve_one`). If anything is left, the
## loop opens ANOTHER window for it before it resolves — never a block
## resolution (Comprehensive Rules: one round of passes = one stack object).
## Returns the last pending_roll result (the hit/miss the attack needs) or the
## last entry result.
func _resolve_stack() -> Dictionary:
	var last_roll: Dictionary = {}
	var last_result: Dictionary = {}
	var rounds: int = 0
	while stack != null and not stack.is_empty():
		rounds += 1
		if rounds > MAX_RESOLUTION_ROUNDS:
			Log.error("MatchController: resolution guard tripped (%d rounds, %d entries) — clearing the stack" % [
				rounds, stack.size()])
			stack.clear("resolution_guard")
			break
		await _run_stack_window(stack.top())
		if stack == null or stack.is_empty():
			break
		var entry: Dictionary = stack.top()
		var result: Dictionary = await stack.resolve_one()
		if String(entry.get("type", "")) == "pending_roll":
			last_roll = result
		if not result.is_empty():
			last_result = result
	if not last_roll.is_empty():
		return last_roll
	return last_result

## One switch resolving every entry type; wired as EventStack.resolver.
func _resolve_stack_entry(entry: Dictionary) -> Dictionary:
	match String(entry.get("type", "")):
		"pending_roll":
			return _resolve_pending_roll(entry)
		"modifier":
			return _resolve_modifier(entry)
		"pending_effect":
			return await _resolve_pending_effect(entry)
		_:
			Log.warn("MatchController: unknown stack entry type '%s'" % String(entry.get("type", "")))
			return {}

## ESEMPIO 2 step 3 / 2b step 4: compare the (possibly modified) value with
## the monster's die value and log the canonical line.
func _resolve_pending_roll(entry: Dictionary) -> Dictionary:
	var die_value: int = int(entry.get("die_value", 0))
	var target: String = String(entry.get("target", ""))
	var monster: Dictionary = _find_monster(target)
	if not monster.is_empty():
		die_value = monster["card"].die_value
	var value: int = int(entry.get("value", 0))
	var hit: bool = value >= die_value
	print("%s attack resolves: %d vs die %d -> %s" % [
		_pname(int(entry.get("owner", 0))), value, die_value, "HIT" if hit else "MISS"])
	EventBus.monster_attacked.emit(int(entry.get("owner", 0)), target, value, int(entry.get("bonus", 0)), die_value)
	if target != "":
		CardEffectRegistry.notify_monster_attacked(target, int(entry.get("owner", 0)), value)
	return {"hit": hit, "roll": value, "die_value": die_value}

## Modifier resolution: reroll executes NOW (deferred from activation),
## updating the targeted pending_roll; adjust was already applied at
## activation, so resolving it is a no-op confirmation.
func _resolve_modifier(entry: Dictionary) -> Dictionary:
	var target: Dictionary = stack.find(String(entry.get("target_id", "")))
	match String(entry.get("effect", "")):
		"reroll":
			var old_value: int = int(target.get("value", 0))
			var bonus: int = int(target.get("bonus", 0))
			var new_value: int = Rng.roll_die() + bonus
			target["value"] = new_value
			print("%s reroll: %s value changes from %d to %d" % [
				entry.get("item_name", "Die"), entry.get("target_id", "?"), old_value, new_value])
			return {"rerolled_from": old_value, "roll": new_value}
		_:
			return {"applied": true}

## ESEMPIO 5 step 3: the loot effect applies and logs its resolution. Any entry
## it pushes while resolving is picked up by _resolve_stack().
func _resolve_pending_effect(entry: Dictionary) -> Dictionary:
	var card: CardResource = card_resource(String(entry.get("card_id", "")))
	if card == null:
		Log.warn("MatchController: pending_effect references missing card '%s'" % String(entry.get("card_id", "")))
		return {"applied": false}
	var payload: Dictionary = entry.get("payload", {})
	var target_id: String = String(payload.get("target_id", ""))
	var target: Dictionary = _find_monster(target_id)
	var target_name: String = target["card"].display_name if not target.is_empty() else target_id
	CardEffectRegistry.play_card(card, int(entry.get("owner", 0)), payload)
	if card.simple_effect == "damage_monster":
		print("%s resolves: %s takes %d damage" % [card.display_name, target_name, card.simple_effect_value])
	else:
		print("%s resolves" % card.display_name)
	EventBus.card_played.emit(int(entry.get("owner", 0)), card.id)
	return {"applied": true, "card_id": card.id}

## ESEMPIO 3 step 4 — called on EVERY attack exit path (kill OR player death):
## combat flag cleared, phase restored, stack VERIFIED empty (with the
## recursive resolution loop this is a safety net, not the normal path).
func reset_combat_state() -> void:
	_combat_in_progress = false
	if state.phase == MatchStateScript.PHASE_COMBAT:
		state.phase = MatchStateScript.PHASE_ACTION
	if stack != null and not stack.is_empty():
		Log.warn("MatchController: reset_combat_state found %d leftover entries — clearing" % stack.size())
		stack.clear("combat_reset")
	EventBus.combat_state_reset.emit()
	print("Combat resolved, stack empty, attack available again")

# --- Death (MP06 f / ratifica #5) ----------------------------------------------

## HP <= 0 is NOT match over. The penalty (ratifica #5):
##  1. lose 1 cent (if any)
##  2. the character card and every owned item are TAPPED (they untap in the
##     owner's next start phase)
##  3. the player CHOOSES 1 loot card from their hand to discard — the
##     automatic fallback applies ONLY when there is exactly one card
##  4. the player chooses 1 owned item to lose (the eternal item is protected)
## Then the ending phase resolves like any other turn end, INCLUDING
## advance_active_player(). Asynchronous: answered through the driver.
func die(player_id: int) -> void:
	var player: Dictionary = state.players[player_id]
	var penalty := {
		"cents_lost": false,
		"character_tapped": true,
		"loot_options": [],
		"item_options": [],
	}
	if player["cents"] > 0:
		player["cents"] = int(player["cents"]) - 1
		penalty["cents_lost"] = true
		EventBus.cents_changed.emit(player_id, -1, player["cents"])
	# 2. tap character + items
	player["character_tapped"] = true
	var tapped: Array = []
	for card_id in player["items_passive"]:
		if not tapped.has(card_id):
			tapped.append(card_id)
	player["tapped_items"] = tapped
	# 3. loot: the player chooses
	penalty["loot_options"] = (player["hand"] as Array).duplicate()
	for card_id in player["items_passive"]:
		var item: CardResource = card_resource(String(card_id))
		if item == null or not item.is_eternal:
			penalty["item_options"].append(card_id)
	EventBus.player_died.emit(player_id, penalty)
	var choice: Dictionary = await _ask_death_choice(player_id, penalty)
	var loot_id: String = String(choice.get("loot_id", ""))
	if loot_id == "" and penalty["loot_options"].size() == 1:
		loot_id = String(penalty["loot_options"][0])   # documented fallback
	if loot_id != "" and player["hand"].has(loot_id):
		player["hand"].erase(loot_id)
		var lost_card: CardResource = card_resource(loot_id)
		if lost_card != null:
			state.loot_discard.append(lost_card)
		EventBus.card_discarded.emit(player_id, loot_id)
		print("  %s discards %s to the death penalty" % [_pname(player_id), loot_id])
	var item_id: String = String(choice.get("item_id", ""))
	if item_id != "" and player["items_passive"].has(item_id):
		player["items_passive"].erase(item_id)
		CardEffectRegistry.unregister_card_by_card_id(player_id, item_id)
		print("  %s loses item %s to the death penalty" % [_pname(player_id), item_id])
	_finish_turn(player_id)

## Death request/answer pair: same request-id + player-id contract as the
## priority window.
func _ask_death_choice(player_id: int, penalty: Dictionary) -> Dictionary:
	_request_counter += 1
	var request := {
		"request_id": "dr%d" % _request_counter,
		"window": "death",
		"player_id": player_id,
		"penalty": penalty.duplicate(true),
		"phase": state.phase,
		"turn_player_id": state.current_player_index,
	}
	if driver == null:
		return _pass_response(request)
	var raw = null
	if driver.is_interactive():
		raw = await driver.request_death(request)
	else:
		raw = driver.decide_death(request)
	if typeof(raw) != TYPE_DICTIONARY:
		Log.warn("MatchController: death driver returned %s — using the fallback" % typeof(raw))
		return _pass_response(request)
	var choice: Dictionary = raw
	if String(choice.get("request_id", "")) != String(request["request_id"]):
		Log.warn("MatchController: stale death answer '%s' (expected '%s') — fallback" % [
			String(choice.get("request_id", "")), String(request["request_id"])])
		return _pass_response(request)
	if int(choice.get("player_id", -1)) != player_id:
		Log.warn("MatchController: death answer for the wrong player — fallback")
		return _pass_response(request)
	return choice

# --- Table / deck internals ---------------------------------------------------

func card_resource(card_id: String) -> CardResource:
	if card_id == "":
		return null
	return load(CARD_DIR + card_id + ".tres")

func is_bought(card_id: String, player_id: int) -> bool:
	var bought: Dictionary = state.bought.get(player_id, {})
	return bought.has(card_id)

## UI-facing shim (ESEMPIO 2 general rule): the D6/Belial buttons gate on
## "does a pending_roll sit on the stack?", never on whose turn it is.
func get_pending_roll() -> Dictionary:
	var entry: Dictionary = stack.top_of_type("pending_roll") if stack != null else {}
	if entry.is_empty():
		return {}
	return {
		"id": entry["id"], "player_id": entry.get("owner", 0),
		"roll": entry.get("value", 0), "bonus": entry.get("bonus", 0),
		"die_value": entry.get("die_value", 0), "target": entry.get("target", "")}

func is_combat_in_progress() -> bool:
	return _combat_in_progress

func get_shop_card(slot_index: int) -> CardResource:
	if slot_index < 0 or slot_index >= state.shop_slots.size():
		return null
	return state.shop_slots[slot_index]["card"]

func _find_monster(instance_id: String) -> Dictionary:
	for monster in state.table_monsters:
		if monster["instance_id"] == instance_id:
			return monster
	return {}

## Kill rewards (MP07 J): a boss yields its OWN soul card (id + soul_value);
## other soul_reward monsters yield their color; vanilla monsters yield 1¢.
## Rewards come from CARD DATA — never hardcoded (ESEMPIO 3 step 2).
func _kill_rewards(card: CardResource) -> Dictionary:
	if card.is_boss:
		return {"soul": card.id, "soul_value": card.soul_value}
	if card.soul_reward != "":
		return {"soul": card.soul_reward}
	return {"cents": 1}

## Builds the decks from the catalogue in a DETERMINISTIC order (file names
## sorted before shuffling): DirAccess order used to leak into the seed, so the
## same seed could produce different matches on different machines (audit C5).
func _build_decks() -> void:
	var dir: DirAccess = DirAccess.open(CARD_DIR)
	if dir == null:
		Log.error("MatchController: cannot open %s (did you run the import?)" % CARD_DIR)
		return
	var files: Array = []
	dir.list_dir_begin()
	var f: String = dir.get_next()
	while f != "":
		if f.ends_with(".tres"):
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	files.sort()
	for file_name in files:
		var card: CardResource = load(CARD_DIR + String(file_name))
		if card == null:
			Log.warn("MatchController: failed to load %s" % file_name)
			continue
		total_cards_at_setup += 1
		match card.type:
			CardResource.CardType.MONSTER:
				state.monster_deck.append(card)
			CardResource.CardType.LOOT:
				state.loot_deck.append(card)
			CardResource.CardType.TREASURE:
				state.treasure_deck.append(card)
			CardResource.CardType.CHARACTER:
				state.characters.append(card)
			_:  # ITEM_ACTIVE eternal items: catalogue only, no deck
				pass
	Rng.shuffle(state.monster_deck)
	Rng.shuffle(state.loot_deck)
	Rng.shuffle(state.treasure_deck)
	print("decks: %d monsters, %d loot, %d treasures, %d characters (%d cards total)" % [
		state.monster_deck.size(), state.loot_deck.size(), state.treasure_deck.size(),
		state.characters.size(), total_cards_at_setup])

## Each player draws a random character: starting/max HP AND base attack damage
## from the character card, plus its eternal item (owned forever, protected
## from the penalty).
func _assign_characters() -> void:
	if state.characters.is_empty():
		Log.error("MatchController: no CHARACTER cards in the catalogue (run the import)")
		return
	Rng.shuffle(state.characters)
	for i in range(state.players.size()):
		var char_card: CardResource = state.characters[i % state.characters.size()]
		var p: Dictionary = state.players[i]
		p["character_id"] = char_card.id
		p["eternal_item_id"] = char_card.eternal_item_id
		p["hp"] = char_card.hp
		p["max_hp"] = char_card.hp
		p["damage"] = maxi(1, char_card.damage)
		print("  P%d character: %s (eternal: %s, damage %d)" % [
			i + 1, char_card.display_name, char_card.eternal_item_id, p["damage"]])

## Keeps the table at MONSTER_SLOTS monsters, drawing from the deck to fill
## empty slots (match start, after every kill, and in the ending phase).
## The table is a LIST, so a future card/event can grow it past the base slots.
func _refill_monsters(prefix: String) -> void:
	while state.table_monsters.size() < MONSTER_SLOTS and not state.monster_deck.is_empty():
		var card: CardResource = state.monster_deck.pop_front()
		state.instance_counter += 1
		var instance_id: String = "%s#%d" % [card.id, state.instance_counter]
		state.table_monsters.append({"instance_id": instance_id, "card": card, "hp": card.hp})
		CardEffectRegistry.register_monster(card, instance_id)
		if prefix == "":
			print("  table: drew %s (die %d, hp %d) [%s]" % [card.display_name, card.die_value, card.hp, instance_id])
		else:
			print("%s%s" % [prefix, card.display_name])

## Keeps the shop at SHOP_SLOTS cards, drawing from the treasure deck to fill
## empty slots (match start, after every purchase, ending phase — MP07 E).
func _refill_shop() -> void:
	while state.shop_slots.size() < SHOP_SLOTS and not state.treasure_deck.is_empty():
		var card: CardResource = state.treasure_deck.pop_front()
		state.shop_slots.append({"card": card})
		EventBus.shop_refilled.emit(card.id, state.shop_slots.size() - 1)
		print("  shop: %s now available (slot %d)" % [card.display_name, state.shop_slots.size() - 1])

func _pop_loot() -> CardResource:
	if state.loot_deck.is_empty():
		if state.loot_discard.is_empty():
			return null
		state.loot_deck = state.loot_discard.duplicate()
		Rng.shuffle(state.loot_deck)
		state.loot_discard.clear()
	return state.loot_deck.pop_front()

# --- EventBus listeners: authoritative table state ----------------------------

## Subtracts damage. Monster shields (Yum Heart targeting a monster) consume
## the whole instance. When the monster dies OUTSIDE an attack flow
## (Bomb/Bible card effects) the kill is emitted immediately; during an attack
## the flow itself detects hp <= 0 and resolves the death through its own path.
func _on_monster_damaged(instance_id: String, amount: int) -> void:
	var monster: Dictionary = _find_monster(instance_id)
	if monster.is_empty():
		Log.warn("MatchController: damage to unknown monster %s ignored" % instance_id)
		return
	if state.monster_shields.has(instance_id):
		var info: Dictionary = state.monster_shields[instance_id]
		state.monster_shields.erase(instance_id)
		print("%s's shield (%s) absorbs the damage, 0 hp lost" % [monster["card"].display_name, info.get("item_name", "?")])
		EventBus.shield_consumed.emit(-1, amount)
		return
	monster["hp"] = int(monster["hp"]) - amount
	print("  %s takes %d damage (hp %d)" % [monster["card"].display_name, amount, monster["hp"]])
	if monster["hp"] <= 0 and not _combat_in_progress:
		EventBus.monster_killed.emit(state.current_player_index, instance_id, _kill_rewards(monster["card"]))

## Kill resolution (ESEMPIO 3 steps 2-3): reward FROM CARD DATA, boss souls +
## automatic win check (inside GameState.gain_soul), discard the monster card,
## refill the slot. The monster is removed BEFORE the rewards so simultaneous
## passive triggers see a consistent table state.
func _on_monster_killed(player_id: int, instance_id: String, rewards: Dictionary) -> void:
	var monster: Dictionary = _find_monster(instance_id)
	state.last_killed_monster = monster.get("card", CardResource.new()).display_name if not monster.is_empty() else instance_id
	CardEffectRegistry.notify_monster_killed(instance_id, player_id)
	CardEffectRegistry.unregister_monster(instance_id)
	state.monster_shields.erase(instance_id)
	for i in range(state.table_monsters.size()):
		if state.table_monsters[i]["instance_id"] == instance_id:
			state.table_monsters.remove_at(i)
			break
	if rewards.has("soul"):
		var value: int = int(rewards.get("soul_value", 1))
		if value > 1:
			print("  >>> BOSS SCONFITTO: %s <<<" % state.last_killed_monster)
			EventBus.boss_defeated.emit(player_id, rewards["soul"], value)
		GameState.gain_soul(player_id, rewards["soul"], value)
		print("%s killed! %s gains soul '%s' (value %d) (reward from card data)" % [
			state.last_killed_monster, _pname(player_id), rewards["soul"], value])
	elif rewards.has("cents"):
		GameState.gain_cents(player_id, int(rewards["cents"]))
		print("%s killed! %s gains %d cent (reward from card data)" % [
			state.last_killed_monster, _pname(player_id), rewards["cents"]])
	else:
		print("%s killed!" % state.last_killed_monster)
	_refill_monsters("Monster slot refilled: ")
