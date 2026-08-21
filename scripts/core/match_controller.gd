class_name MatchController
extends RefCounted
## Shared rules engine for a match: decks, the 2-slot monster table, the 2-slot
## shop, buy / attack / play / draw / end-turn actions, the death penalty,
## characters, the priority/stack window and the soul win condition.
##
## Two drivers use this same engine — game rules live HERE, never duplicated:
##  - scenes/turn_loop_test.gd (self-play robot, deterministic seed)
##  - scenes/game_scene.gd    (human hotseat input)
##
## Like card effects, the controller talks to the rest of the game ONLY via
## EventBus + GameState (+ Rng for rolls and shuffles). Drivers handle
## presentation: the robot prints, the game scene renders Controls.
##
## MP06 rules in play: 2 monster slots, 10c shop, free action order with per-
## turn limits (1 buy / 1 attack / 1 loot +1 character effect), full HP restore
## at turn end, death = penalty (never match over), characters + eternal items.
##
## MP07 rules now in play:
##  - players start with 3¢ (C), the shop has TWO slots refilled from the
##    treasure deck (E)
##  - STOP attack no longer exists as a voluntary action (D): attacks continue
##    until the monster dies or the player dies
##  - rolls are PENDING on the stack first; the priority window opens, eternal
##    modifiers (D6/Belial) apply to the pending roll, and only then the roll
##    resolves into hit/miss + damage (B)
##  - a generic priority window (F): attack declaration, roll, damage and
##    monster death each go on the stack; ALL players respond in turn order
##    from the active player (loot play / eternal item / pass); consecutive
##    passes resolve the top of the stack (LIFO)
##  - hit damage = the attacker's base `damage` + item/scripted bonuses, never
##    a hardcoded value (G)
##  - boss kills turn the monster card into ONE soul card in the player's soul
##    list, counting `soul_value` (1 or 2) towards the 4-soul win check (J)

const CARD_DIR := "res://resources/cards/base_set/"
const MONSTER_SLOTS := 2
const SHOP_SLOTS := 2
const LOOT_PER_TURN := 1

var table_monsters: Array = []          # [{instance_id, card, hp}] up to MONSTER_SLOTS
var shop_slots: Array = []              # [{card}] up to SHOP_SLOTS, refilled from _treasure_deck
var characters: Array = []              # Array[CardResource] — CHARACTER cards, drawn randomly
var total_cards_at_setup := 0           # catalogue size before any draw
var last_killed_monster := ""           # display name, for UI logs that run after removal

var _monster_deck: Array = []
var _loot_deck: Array = []
var _loot_discard: Array = []
var _treasure_deck: Array = []
var _instance_counter: int = 0
var _bought: Dictionary = {}            # player_id -> {card_id: true}
var _pending_roll: Dictionary = {}      # {player_id, roll, bonus, die_value} while a roll is pending (B)
var _attack_in_progress: bool = false

## Builds decks, characters, the initial table and the 2-slot shop. The caller
## picks the seed (the robot passes a fixed one, the human game passes a
## random one). Every player starts with exactly 3¢ (MP07 C).
func setup(player_count: int, seed_value: int) -> void:
	Rng.seed_rng(seed_value)
	EventBus.monster_damaged.connect(_on_monster_damaged)
	EventBus.monster_killed.connect(_on_monster_killed)
	GameState.reset_match(player_count)
	_build_decks()
	_assign_characters()
	_refill_monsters()
	_refill_shop()
	print("start: %d players, each with 3¢ and 3 loot per turn (MP07 C)" % player_count)

## --- Turn structure ----------------------------------------------------------

## Starts the given player's turn: resets their per-turn action counters,
## draws LOOT_PER_TURN into their hand and emits turn_started.
func begin_turn(player_id: int) -> void:
	GameState.current_player_index = player_id
	var p: Dictionary = GameState.players[player_id]
	p["attacks_used"] = 0
	p["buys_used"] = 0
	p["loot_played"] = 0
	p["character_effect_used"] = false
	p["eternal_used"] = false
	draw_loot(player_id)
	EventBus.turn_started.emit(player_id)

## Ends the current turn (player-initiated). End-of-turn resolution is shared
## with the death flow: eternal-item recharge, then full HP restore for every
## player and every table monster (MP06 d). Returns the NEXT player's id —
## the driver MUST call begin_turn(next) so the active player alternates
## P1 -> P2 -> P1 ... (MP07 A; the human scene had a bug that re-started the
## same player, fixed in game_scene.gd).
func end_turn() -> int:
	var pid := GameState.current_player_index
	_resolve_end_of_turn(pid)
	return (pid + 1) % GameState.players.size()

## --- Player actions ----------------------------------------------------------

## Buys the treasure in the given shop SLOT (once per own turn). Returns false
## if the slot is empty, the buy limit is spent, it was already bought, or it
## is unaffordable. On success the slot refills from the treasure deck, so the
## shop always shows exactly SHOP_SLOTS cards (MP07 E).
func buy(slot_index: int, player_id: int) -> bool:
	if slot_index < 0 or slot_index >= shop_slots.size():
		return false
	var card: CardResource = shop_slots[slot_index]["card"]
	if card == null:
		return false
	var player := GameState.players[player_id]
	if player.is_empty() or player_id != GameState.current_player_index:
		return false
	if player["buys_used"] >= 1:
		return false
	if player["cents"] < card.cost_cents:
		return false
	var bought: Dictionary = _bought.get(player_id, {})
	if bought.has(card.id):
		return false
	GameState.lose_cents(player_id, card.cost_cents)
	player["items_passive"].append(card.id)
	bought[card.id] = true
	_bought[player_id] = bought
	player["buys_used"] += 1
	_instance_counter += 1
	var instance_id := "%s#%d" % [card.id, _instance_counter]
	shop_slots.remove_at(slot_index)
	_refill_shop()
	EventBus.item_bought.emit(player_id, card.id)
	CardEffectRegistry.register_card(card, player_id, instance_id)
	return true

## Attacks the monster with the given instance_id: a SEQUENCE of consecutive
## rolls against the same monster until the monster dies or the player dies —
## STOP attacks is NOT a voluntary action (MP07 D). Each step goes on the
## stack with a priority window (MP07 F):
##   1. "attack_declared" — before the first roll
##   2. "roll" — the roll is PENDING: eternal modifiers (D6 reroll, Belial +-1)
##      apply to _pending_roll here, then the roll resolves (B)
##   3. "monster_damage" / "player_damage" — before the damage applies
##   4. "monster_dying" — before the kill resolves (rewards, souls, refill)
## Returns {"valid", "outcome": "killed"|"player_died", "steps", "rolls",
## "final_roll"}.
func attack(instance_id: String, player_id: int) -> Dictionary:
	var monster := _find_monster(instance_id)
	if monster.is_empty():
		return {"valid": false}
	if _attack_in_progress:
		return {"valid": false, "busy": true}
	if player_id != GameState.current_player_index:
		return {"valid": false}
	var player := GameState.players[player_id]
	if player["attacks_used"] >= 1:
		return {"valid": false, "limit": true}
	player["attacks_used"] += 1
	_attack_in_progress = true
	var monster_card: CardResource = monster["card"]
	await _run_priority("attack_declared", {
		"instance_id": instance_id, "monster_id": monster_card.id, "die_value": monster_card.die_value})
	var steps := 0
	var outcome := ""
	var rolls: Array = []
	var final_roll := 0
	while true:
		steps += 1
		var base_roll := Rng.roll_die()
		var bonus := CardEffectRegistry.get_roll_bonus(player_id)
		var roll := base_roll + bonus
		_pending_roll = {"player_id": player_id, "roll": roll, "bonus": bonus, "die_value": monster_card.die_value}
		await _run_priority("roll", {
			"instance_id": instance_id, "roll": roll, "die_value": monster_card.die_value})
		roll = _pending_roll["roll"]
		final_roll = roll
		rolls.append(roll)
		_pending_roll = {}  # resolved (B): modifiers no longer apply
		print("  attack: %s — roll %d%s vs die %d -> %s" % [
			monster_card.display_name, roll,
			" (+%d bonus)" % bonus if bonus != 0 else "",
			monster_card.die_value, "HIT" if roll >= monster_card.die_value else "MISS"])
		EventBus.monster_attacked.emit(player_id, instance_id, roll, bonus, monster_card.die_value)
		CardEffectRegistry.notify_monster_attacked(instance_id, player_id, roll)
		if roll >= monster_card.die_value:
			var damage: int = GameState.players[player_id]["damage"] + CardEffectRegistry.get_damage(player_id)
			await _run_priority("monster_damage", {
				"instance_id": instance_id, "amount": damage, "monster_id": monster_card.id})
			EventBus.monster_damaged.emit(instance_id, damage)
			var m := _find_monster(instance_id)
			if not m.is_empty() and m["hp"] <= 0:
				await _run_priority("monster_dying", {
					"instance_id": instance_id, "monster_id": monster_card.id})
				EventBus.monster_killed.emit(player_id, instance_id, _kill_rewards(monster_card))
				outcome = "killed"
				break
			if _find_monster(instance_id).is_empty():
				outcome = "killed"
				break
		else:
			await _run_priority("player_damage", {
				"player_id": player_id, "amount": 1, "source": instance_id})
			GameState.damage_player(player_id, 1, instance_id)
			if GameState.players[player_id]["hp"] <= 0:
				print("  >>> P%d dies mid-attack" % (player_id + 1))
				await die(player_id)
				outcome = "player_died"
				break
	_attack_in_progress = false
	return {"valid": true, "outcome": outcome, "steps": steps, "rolls": rolls, "final_roll": final_roll}

## Plays a card from hand (loot or active item) with an optional target.
## LOOT plays are limited per the MP06 c rules: 1 free loot on your own turn,
## then 1 more by spending the character effect ("play_loot", usable on any
## turn, recharges at the owner's turn start). Active items are not loot
## plays and never consume the limit. Returns false when the play is refused.
func play_loot(card: CardResource, player_id: int, payload: Dictionary = {}) -> bool:
	if card == null:
		return false
	if card.type == CardResource.CardType.LOOT:
		var player := GameState.players[player_id]
		if player_id == GameState.current_player_index:
			if player["loot_played"] < 1:
				player["loot_played"] += 1
			elif _character_effect_is_loot(player_id) and not player["character_effect_used"]:
				player["character_effect_used"] = true
				print("  P%d uses character effect to play an extra loot" % (player_id + 1))
			else:
				return false
		else:
			if not _character_effect_is_loot(player_id) or player["character_effect_used"]:
				return false
			player["character_effect_used"] = true
			print("  P%d uses character effect to play loot on another turn" % (player_id + 1))
	CardEffectRegistry.play_card(card, player_id, payload)
	EventBus.card_played.emit(player_id, card.id)
	return true

## Uses the player's eternal item. payload:
##  - D6 (reroll_die): {} — rerolls the pending roll (attack or not).
##  - Belial Book (adjust_die): {"delta": 1|-1}
##  - Yum Heart (heal_player): {"target_id": player_id}
## Returns {"ok", ...} ; false when recharging, no pending roll, or bad args.
## "no_pending_roll" enforces MP07 B: the modifier can ONLY be applied while
## the roll is pending (after the roll, before it resolves).
func use_eternal_item(player_id: int, payload: Dictionary = {}) -> Dictionary:
	var player := GameState.players[player_id]
	if player.is_empty():
		return {"ok": false}
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
			if _pending_roll.is_empty():
				return {"ok": false, "reason": "no_pending_roll"}
			var old_roll: int = _pending_roll["roll"]
			var new_roll: int = Rng.roll_die() + _pending_roll["bonus"]
			_pending_roll["roll"] = new_roll
			result["old_roll"] = old_roll
			result["new_roll"] = new_roll
		"adjust_die":
			if _pending_roll.is_empty():
				return {"ok": false, "reason": "no_pending_roll"}
			var delta: int = payload.get("delta", 1)
			_pending_roll["roll"] += delta
			result["new_roll"] = _pending_roll["roll"]
		"heal_player":
			var target: int = payload.get("target_id", -1)
			if target < 0 or target >= GameState.players.size():
				return {"ok": false, "reason": "no_target"}
			GameState.heal(target, 1)
			result["target_id"] = target
		_:
			return {"ok": false, "reason": "unknown_action"}
	player["eternal_used"] = true
	EventBus.eternal_used.emit(player_id, item_id, result)
	return result

## Draws one loot from the deck into the player's hand (reshuffling the
## discard when needed). Returns the card, or null if no loot is left.
func draw_loot(player_id: int) -> CardResource:
	var card := _pop_loot()
	if card == null:
		return null
	EventBus.card_drawn.emit(player_id, card.id, "loot")
	GameState.players[player_id]["hand"].append(card.id)
	return card

## --- Priority / stack (MP07 F) ------------------------------------------------
## Every stack item (attack declaration, roll, damage, monster death) opens a
## priority window: each player is asked in turn order starting from the ACTIVE
## player (round-robin). A player may respond with a loot play (their turn loot
## limit applies) or an eternal item use; anything else counts as a pass. When
## ALL players pass consecutively the window closes and the top of the stack
## resolves (LIFO). Responses are atomic — they never open a nested window.
func _run_priority(stack_type: String, payload: Dictionary) -> Dictionary:
	var count := GameState.players.size()
	if count == 0:
		return payload
	var idx := GameState.current_player_index
	var passes := 0
	while passes < count:
		EventBus.priority_pending.emit(idx, stack_type, payload)
		var args: Array = await EventBus.priority_given
		var pid: int = args[0] if args.size() > 0 and typeof(args[0]) == TYPE_INT else idx
		var response: Dictionary = args[1] if args.size() > 1 and typeof(args[1]) == TYPE_DICTIONARY else {}
		var action: String = response.get("action", "pass")
		var acted := false
		match action:
			"loot":
				var card: CardResource = card_resource(response.get("card_id", ""))
				if card != null and _play_loot_in_priority(card, pid, response.get("target_id", "")):
					acted = true
					print("  [priority] P%d responds: plays %s" % [pid + 1, card.display_name])
			"eternal":
				var res: Dictionary = use_eternal_item(pid, response.get("payload", {}))
				if res.get("ok", false):
					acted = true
					print("  [priority] P%d responds: uses %s" % [pid + 1, res.get("item_id", "?")])
			"stop":
				print("  [priority] 'stop attack' is NOT a rule (MP07 D) — the attack continues")
			_:
				pass  # "pass" / "resolve" / unknown: counts as a pass
		if acted:
			passes = 0  # a response restarts the priority round from the active player
			idx = GameState.current_player_index
		else:
			passes += 1
			idx = (idx + 1) % count
	EventBus.priority_closed.emit(stack_type, payload)
	return payload

## Plays a loot card as a priority response for `player_id`. The card must be
## in hand and the turn's loot limit (incl. the character effect) must allow
## it — the same rules as a normal play_loot.
func _play_loot_in_priority(card: CardResource, player_id: int, target_id: String) -> bool:
	if not GameState.players[player_id]["hand"].has(card.id):
		return false
	var payload := {}
	if target_id != "":
		payload = {"target_id": target_id}
	if not play_loot(card, player_id, payload):
		return false
	GameState.players[player_id]["hand"].erase(card.id)
	return true

## --- Death (MP06 f) ----------------------------------------------------------
## HP <= 0 is NOT match over: the turn ends immediately, the player loses
## 1 loot from hand (if any) and 1 cent (if any), then must choose one owned
## item to lose (the eternal item is protected). Finally the turn resolves
## like any other turn end: everyone restores to full HP. Asynchronous: the
## driver must answer player_death_resolved(player_id, item_id) — the robot
## auto-picks the first item, the human scene shows a choice overlay.
func die(player_id: int) -> void:
	var player := GameState.players[player_id]
	var penalty := {"cents_lost": false, "loot_lost": "", "item_options": []}
	if player["cents"] > 0:
		player["cents"] -= 1
		penalty["cents_lost"] = true
		EventBus.cents_changed.emit(player_id, -1, player["cents"])
	if not player["hand"].is_empty():
		penalty["loot_lost"] = player["hand"][0]
		player["hand"].pop_front()
		EventBus.card_discarded.emit(player_id, penalty["loot_lost"])
	for card_id in player["items_passive"]:
		var item: CardResource = card_resource(card_id)
		if item == null or not item.is_eternal:
			penalty["item_options"].append(card_id)
	EventBus.player_died.emit(player_id, penalty)
	var args: Array = await EventBus.player_death_resolved
	var item_id: String = args[1] if args.size() > 1 else ""
	if item_id != "" and player["items_passive"].has(item_id):
		player["items_passive"].erase(item_id)
		CardEffectRegistry.unregister_card_by_card_id(player_id, item_id)
		print("  P%d loses item %s to the death penalty" % [player_id + 1, item_id])
	_resolve_end_of_turn(player_id)

## --- Table / deck internals ---------------------------------------------------

func card_resource(card_id: String) -> CardResource:
	return load(CARD_DIR + card_id + ".tres")

func is_bought(card_id: String, player_id: int) -> bool:
	return _bought.get(player_id, {}).has(card_id)

func get_pending_roll() -> Dictionary:
	return _pending_roll

func get_shop_card(slot_index: int) -> CardResource:
	if slot_index < 0 or slot_index >= shop_slots.size():
		return null
	return shop_slots[slot_index]["card"]

func _find_monster(instance_id: String) -> Dictionary:
	for monster in table_monsters:
		if monster["instance_id"] == instance_id:
			return monster
	return {}

func _character_effect_is_loot(player_id: int) -> bool:
	var char_card := card_resource(GameState.players[player_id]["character_id"])
	return char_card != null and char_card.character_effect == "play_loot"

## Kill rewards (MP07 J): a boss yields its OWN soul card (id + soul_value);
## other soul_reward monsters yield their color; vanilla monsters yield 1¢.
func _kill_rewards(card: CardResource) -> Dictionary:
	if card.is_boss:
		return {"soul": card.id, "soul_value": card.soul_value}
	if card.soul_reward != "":
		return {"soul": card.soul_reward}
	return {"cents": 1}

func _build_decks() -> void:
	var dir := DirAccess.open(CARD_DIR)
	if dir == null:
		Log.error("MatchController: cannot open %s (did you run the import?)" % CARD_DIR)
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".tres"):
			var card: CardResource = load(CARD_DIR + f)
			if card == null:
				Log.warn("MatchController: failed to load %s" % f)
			else:
				total_cards_at_setup += 1
				match card.type:
					CardResource.CardType.MONSTER:
						_monster_deck.append(card)
					CardResource.CardType.LOOT:
						_loot_deck.append(card)
					CardResource.CardType.TREASURE:
						_treasure_deck.append(card)
					CardResource.CardType.CHARACTER:
						characters.append(card)
					_:  # ITEM_ACTIVE eternal items: catalogue only, no deck
						pass
		f = dir.get_next()
	Rng.shuffle(_monster_deck)
	Rng.shuffle(_loot_deck)
	Rng.shuffle(_treasure_deck)
	print("decks: %d monsters, %d loot, %d treasures, %d characters (%d cards total)" % [
		_monster_deck.size(), _loot_deck.size(), _treasure_deck.size(), characters.size(), total_cards_at_setup])

## Each player draws a random character: starting/max HP AND base attack damage
## from the character card, plus its eternal item (owned forever, protected
## from the penalty). Base damage is 1 for every current character (MP07 G).
func _assign_characters() -> void:
	if characters.is_empty():
		Log.error("MatchController: no CHARACTER cards in the catalogue (run the import)")
		return
	Rng.shuffle(characters)
	for i in range(GameState.players.size()):
		var char_card: CardResource = characters[i % characters.size()]
		var p: Dictionary = GameState.players[i]
		p["character_id"] = char_card.id
		p["eternal_item_id"] = char_card.eternal_item_id
		p["hp"] = char_card.hp
		p["max_hp"] = char_card.hp
		p["damage"] = max(1, char_card.damage)
		print("  P%d character: %s (eternal: %s, damage %d)" % [i + 1, char_card.display_name, char_card.eternal_item_id, p["damage"]])

## Keeps the table at MONSTER_SLOTS monsters, drawing from the deck to fill
## empty slots (match start and after every kill).
func _refill_monsters() -> void:
	while table_monsters.size() < MONSTER_SLOTS and not _monster_deck.is_empty():
		var card: CardResource = _monster_deck.pop_front()
		_instance_counter += 1
		var instance_id := "%s#%d" % [card.id, _instance_counter]
		table_monsters.append({"instance_id": instance_id, "card": card, "hp": card.hp})
		CardEffectRegistry.register_monster(card, instance_id)
		print("  table: drew %s (die %d, hp %d) [%s]" % [card.display_name, card.die_value, card.hp, instance_id])

## Keeps the shop at SHOP_SLOTS cards, drawing from the treasure deck to fill
## empty slots (match start and after every purchase — MP07 E).
func _refill_shop() -> void:
	while shop_slots.size() < SHOP_SLOTS and not _treasure_deck.is_empty():
		var card: CardResource = _treasure_deck.pop_front()
		shop_slots.append({"card": card})
		EventBus.shop_refilled.emit(card.id, shop_slots.size() - 1)
		print("  shop: %s now available (slot %d)" % [card.display_name, shop_slots.size() - 1])

func _pop_loot() -> CardResource:
	if _loot_deck.is_empty():
		if _loot_discard.is_empty():
			return null
		_loot_deck = _loot_discard.duplicate()
		Rng.shuffle(_loot_deck)
		_loot_discard.clear()
	return _loot_deck.pop_front()

## Shared turn-end resolution (MP06 d, f): recharges the ending player's
## eternal item when its card allows it, emits turn_ended, then restores FULL
## HP to every player and every table monster.
func _resolve_end_of_turn(ending_player_id: int) -> void:
	var p: Dictionary = GameState.players[ending_player_id]
	var item_id: String = p["eternal_item_id"]
	if item_id != "":
		var item: CardResource = card_resource(item_id)
		if item != null and item.recharges_on_turn_end:
			p["eternal_used"] = false
			print("  %s recharges (end of owner's turn)" % item.display_name)
	EventBus.turn_ended.emit(ending_player_id)
	for player in GameState.players:
		GameState.restore_hp(player["id"])
	for monster in table_monsters:
		monster["hp"] = monster["card"].hp
	EventBus.monsters_restored.emit()

## --- EventBus listeners: authoritative table state ----------------------------

## Subtracts damage. When the monster dies the kill is emitted immediately
## ONLY outside an attack flow (card-effect kills like Bomb resolve without a
## priority window); during an attack the monster stays on the table at 0 HP
## and the attack flow opens the "monster_dying" window before killing (F).
func _on_monster_damaged(instance_id: String, amount: int) -> void:
	var monster := _find_monster(instance_id)
	if monster.is_empty():
		Log.warn("MatchController: damage to unknown monster %s ignored" % instance_id)
		return
	monster["hp"] = monster["hp"] - amount
	print("  %s takes %d damage (hp %d)" % [instance_id, amount, monster["hp"]])
	if monster["hp"] <= 0 and not _attack_in_progress:
		EventBus.monster_killed.emit(GameState.current_player_index, instance_id, _kill_rewards(monster["card"]))

## Kill resolution: rewards, boss soul (MP07 J), refill. The monster is removed
## BEFORE the soul/cents rewards so simultaneous passive triggers (Crow's
## Heart etc.) see a consistent table state.
func _on_monster_killed(player_id: int, instance_id: String, rewards: Dictionary) -> void:
	var monster := _find_monster(instance_id)
	last_killed_monster = monster.get("card", CardResource.new()).display_name if not monster.is_empty() else instance_id
	print("  %s killed!" % instance_id)
	CardEffectRegistry.notify_monster_killed(instance_id, player_id)
	CardEffectRegistry.unregister_monster(instance_id)
	for i in range(table_monsters.size()):
		if table_monsters[i]["instance_id"] == instance_id:
			table_monsters.remove_at(i)
			break
	if rewards.has("soul"):
		var value: int = rewards.get("soul_value", 1)
		if value > 1:
			print("  >>> BOSS SCONFITTO: %s <<<" % last_killed_monster)
			EventBus.boss_defeated.emit(player_id, rewards["soul"], value)
		GameState.gain_soul(player_id, rewards["soul"], value)
		var p: Dictionary = GameState.players[player_id]
		print("  + soul %s (P%d souls: %s, total value %d)" % [
			rewards["soul"], player_id + 1, str(p["souls"]), GameState.soul_total(player_id)])
	if rewards.has("cents"):
		GameState.gain_cents(player_id, rewards["cents"])
		print("  + %d cent" % rewards["cents"])
	_refill_monsters()