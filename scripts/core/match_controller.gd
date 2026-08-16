class_name MatchController
extends RefCounted
## Shared rules engine for a match: decks, the 3-slot monster table, buy /
## attack / play / draw / end-turn actions and the kill flow.
##
## Two drivers use this same engine — game rules live HERE, never duplicated:
##  - scenes/turn_loop_test.gd (self-play robot, deterministic seed)
##  - scenes/game_scene.gd    (human hotseat input)
##
## Like card effects, the controller talks to the rest of the game ONLY via
## EventBus + GameState (+ Rng for rolls and shuffles). Drivers handle
## presentation: the robot prints, the game scene renders Controls.

const CARD_DIR := "res://resources/cards/base_set/"
const MONSTER_SLOTS := 3
const LOOT_PER_TURN := 1

var table_monsters: Array = []          # [{instance_id, card, hp}] up to MONSTER_SLOTS
var shop: Array = []                    # Array[CardResource] — all treasures, one copy each
var total_cards_at_setup := 0           # catalogue size before any draw
var last_killed_monster := ""           # display name, for UI logs that run after removal

var _monster_deck: Array = []
var _loot_deck: Array = []
var _loot_discard: Array = []
var _instance_counter: int = 0
var _bought: Dictionary = {}            # player_id -> {card_id: true}

## Builds decks and the initial table. The caller picks the seed (the robot
## passes a fixed one, the human game passes a random one).
func setup(player_count: int, seed_value: int) -> void:
	Rng.seed_rng(seed_value)
	EventBus.monster_damaged.connect(_on_monster_damaged)
	EventBus.monster_killed.connect(_on_monster_killed)
	GameState.reset_match(player_count)
	GameState.gain_cents(0, 4)  # tune: both players start with 7c so the
	GameState.gain_cents(1, 4)  # Sack of Pennies (6c) is actually affordable
	_build_decks()
	_refill_monsters()

## --- Turn structure ----------------------------------------------------------

## Starts the given player's turn: draws LOOT_PER_TURN into their hand and
## emits turn_started (passive triggers fire in policy order via the registry).
func begin_turn(player_id: int) -> void:
	GameState.current_player_index = player_id
	draw_loot(player_id)
	EventBus.turn_started.emit(player_id)

## Ends the current turn and moves the index to the next player (clockwise).
## The NEXT player's begin_turn is called by the driver (the human scene shows
## a "pass the device" overlay first; the robot calls it directly).
func end_turn() -> int:
	var pid := GameState.current_player_index
	EventBus.turn_ended.emit(pid)
	return (pid + 1) % GameState.players.size()

## --- Player actions ----------------------------------------------------------

## Buys a treasure for the player. Returns false if already bought or
## unaffordable. Registers the card copy with a fresh instance_id.
func buy(card: CardResource, player_id: int) -> bool:
	if card == null:
		return false
	var player := GameState.players[player_id]
	if player.is_empty() or player["cents"] < card.cost_cents:
		return false
	var bought: Dictionary = _bought.get(player_id, {})
	if bought.has(card.id):
		return false
	GameState.lose_cents(player_id, card.cost_cents)
	player["items_passive"].append(card.id)
	bought[card.id] = true
	_bought[player_id] = bought
	_instance_counter += 1
	var instance_id := "%s#%d" % [card.id, _instance_counter]
	EventBus.item_bought.emit(player_id, card.id)
	CardEffectRegistry.register_card(card, player_id, instance_id)
	return true

## Attacks the monster with the given instance_id: rolls 1d6 + roll bonus,
## emits monster_attacked, then hit -> monster_damaged(1) or miss -> the
## monster deals 1 damage to the attacker.
func attack(instance_id: String, player_id: int) -> Dictionary:
	var monster := _find_monster(instance_id)
	if monster.is_empty():
		return {"valid": false, "hit": false, "roll": 0, "bonus": 0}
	var monster_card: CardResource = monster["card"]
	var base_roll := Rng.roll_die()
	var bonus := CardEffectRegistry.get_roll_bonus(player_id)
	var roll := base_roll + bonus
	EventBus.monster_attacked.emit(player_id, instance_id, roll)
	var hit := roll >= monster_card.die_value
	if hit:
		EventBus.monster_damaged.emit(instance_id, 1)
	else:
		GameState.damage_player(player_id, 1, instance_id)
	return {"valid": true, "hit": hit, "roll": base_roll, "bonus": bonus}

## Plays a card from hand (loot or active item) with an optional target.
func play_loot(card: CardResource, player_id: int, payload: Dictionary = {}) -> void:
	if card == null:
		return
	CardEffectRegistry.play_card(card, player_id, payload)
	EventBus.card_played.emit(player_id, card.id)

## Draws one loot from the deck into the player's hand (reshuffling the
## discard when needed). Returns the card, or null if no loot is left.
func draw_loot(player_id: int) -> CardResource:
	var card := _pop_loot()
	if card == null:
		return null
	EventBus.card_drawn.emit(player_id, card.id, "loot")
	GameState.players[player_id]["hand"].append(card.id)
	return card

## --- Table / deck internals ---------------------------------------------------

func card_resource(card_id: String) -> CardResource:
	return load(CARD_DIR + card_id + ".tres")

func is_bought(card_id: String, player_id: int) -> bool:
	return _bought.get(player_id, {}).has(card_id)

func _find_monster(instance_id: String) -> Dictionary:
	for monster in table_monsters:
		if monster["instance_id"] == instance_id:
			return monster
	return {}

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
				match card.type:
					CardResource.CardType.MONSTER:
						_monster_deck.append(card)
					CardResource.CardType.LOOT:
						_loot_deck.append(card)
					CardResource.CardType.TREASURE:
						shop.append(card)
		f = dir.get_next()
	Rng.shuffle(_monster_deck)
	Rng.shuffle(_loot_deck)
	total_cards_at_setup = _monster_deck.size() + _loot_deck.size() + shop.size()
	print("decks: %d monsters, %d loot, %d treasures in shop" % [_monster_deck.size(), _loot_deck.size(), shop.size()])

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

func _pop_loot() -> CardResource:
	if _loot_deck.is_empty():
		if _loot_discard.is_empty():
			return null
		_loot_deck = _loot_discard.duplicate()
		Rng.shuffle(_loot_deck)
		_loot_discard.clear()
	return _loot_deck.pop_front()

## --- EventBus listeners: authoritative table state ----------------------------

func _on_monster_damaged(instance_id: String, amount: int) -> void:
	var monster := _find_monster(instance_id)
	if monster.is_empty():
		Log.warn("MatchController: damage to unknown monster %s ignored" % instance_id)
		return
	monster["hp"] = monster["hp"] - amount
	print("  %s takes %d damage (hp %d)" % [instance_id, amount, monster["hp"]])
	if monster["hp"] <= 0:
		var card: CardResource = monster["card"]
		var rewards := {"cents": 1}
		if card.soul_reward != "":
			rewards = {"soul": card.soul_reward}
		EventBus.monster_killed.emit(GameState.current_player_index, instance_id, rewards)

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
		GameState.gain_soul(player_id, rewards["soul"])
		print("  + soul %s (P%d now has %d)" % [rewards["soul"], player_id + 1, GameState.players[player_id]["souls"].size()])
	if rewards.has("cents"):
		GameState.gain_cents(player_id, rewards["cents"])
		print("  + %d cent" % rewards["cents"])
	_refill_monsters()
