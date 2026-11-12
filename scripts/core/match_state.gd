extends RefCounted
## MatchState — THE single, serializable source of truth for one match.
##
## Deliberately NOT a class_name: the global class cache is only refreshed by
## the editor, so headless CLI runs must preload this script (same rule as
## EventStack / MatchController).
##
## Why this exists (audit C2, ratifica #2): mutable match data used to be
## spread across the GameState autoload, the controller (decks, slots,
## counters) and the registry. Now EVERYTHING a match owns lives here:
## players, turn pointer, phase, table, shop, decks, shields, souls, counters.
## Nothing in this file touches EventBus, the scene tree or the UI — it is
## pure data plus serialization, so it can be snapshotted, diffed, sent over a
## socket or reloaded from disk.
##
## Two serialization levels:
##  - to_dict()/load_from_dict(): the AUTHORITATIVE server image (includes
##    every private hand; never send this to a client).
##  - snapshot_for(viewer): the per-viewer DTO (public state + ONLY the
##    viewer's own hand, numeric counts for everybody else). viewer < 0 means
##    "the table"; hands are still reduced to counts.
##
## Card references: at runtime slots and decks hold CardResource objects
## (fast, typed); on the wire they are card ids and are re-resolved on load.
## The rule "one canonical representation" is about MATCH DATA, not about the
## immutable card catalogue.

const CARD_DIR := "res://resources/cards/base_set/"
const SCHEMA_VERSION := 1

## Turn phases (ratifica #5 / ESEMPIO 1). "start" is the beginning phase
## (untap + draw), "action" is where the free loot play lives, "combat" is an
## attack sequence in progress, "end" is the ending phase until the next turn
## begins.
const PHASE_START := "start"
const PHASE_ACTION := "action"
const PHASE_COMBAT := "combat"
const PHASE_END := "end"

## Every player dict is a deep copy of this template.
##  - hand: Array[String] card ids (PRIVATE — the only secret in the game)
##  - items_passive: Array[String] card ids on the table (public)
##  - loot_played: free loot plays used this turn (0 or 1)
##  - character_tapped: the character card is spent until the owner's next
##    begin_turn() — the cost of an extra/out-of-turn loot play (ratifica #5)
##  - tapped_items: owned items spent by the death penalty; untap next turn
const PLAYER_TEMPLATE := {
	"id": -1,
	"character_id": "",
	"eternal_item_id": "",
	"hp": 2,
	"max_hp": 2,
	"damage": 1,
	"cents": 3,
	"souls": [],         # Array[String] soul names (boss soul counts soul_values[...])
	"hand": [],          # Array[String] card ids — PRIVATE
	"items_active": [],  # Array[String] card ids
	"items_passive": [], # Array[String] card ids
	"attacks_used": 0,
	"buys_used": 0,
	"loot_played": 0,
	"character_tapped": false,
	"tapped_items": [],  # Array[String] card ids spent by the death penalty
	"eternal_used": false,
	"shield_next_damage": false,
	"skip_draw": 0,       # M4 triggers: loot draws skipped (e.g. Fistula's death)
}

# --- Match data ---------------------------------------------------------------

var players: Array = []                 # Array[Dictionary] (untyped: duplicate() loses the typed-array tag)
var current_player_index: int = 0
var turn_number: int = 0
var phase: String = PHASE_START
var soul_values: Dictionary = {}        # soul name -> value (bosses 2, normal 1)
var shields: Dictionary = {}            # target player_id -> {owner, item_name}
var table_monsters: Array = []          # [{instance_id, card: CardResource, hp}]
var shop_slots: Array = []              # [{card: CardResource}]
var monster_deck: Array = []            # Array[CardResource]
var characters: Array = []              # Array[CardResource] character pool (setup data)
var loot_deck: Array = []               # Array[CardResource]
var loot_discard: Array = []            # Array[CardResource]
var treasure_deck: Array = []           # Array[CardResource]
var instance_counter: int = 0
var bought: Dictionary = {}             # player_id -> {card_id: true}
var monster_shields: Dictionary = {}    # instance_id -> {owner, item_name}
var last_killed_monster: String = ""    # display name, for logs emitted after removal

## Resets this object to a fresh match. Reusing the instance (instead of
## swapping it) keeps GameState.adopt() references valid across restarts.
func reset(player_count: int) -> void:
	players.clear()
	for i in range(max(0, player_count)):
		var player: Dictionary = PLAYER_TEMPLATE.duplicate(true)
		player["id"] = i
		players.append(player)
	current_player_index = 0
	turn_number = 0
	phase = PHASE_START
	soul_values.clear()
	shields.clear()
	table_monsters.clear()
	shop_slots.clear()
	monster_deck.clear()
	characters.clear()
	loot_deck.clear()
	loot_discard.clear()
	treasure_deck.clear()
	instance_counter = 0
	bought.clear()
	monster_shields.clear()
	last_killed_monster = ""

# --- Queries (pure) -----------------------------------------------------------

func get_player(player_id: int) -> Dictionary:
	for player in players:
		if int(player["id"]) == player_id:
			return player
	return {}

func active_player() -> Dictionary:
	return get_player(current_player_index)

## Sum of soul VALUES (a boss soul is ONE card counting 2).
func soul_total(player_id: int) -> int:
	var player: Dictionary = get_player(player_id)
	if player.is_empty():
		return 0
	var total: int = 0
	for soul_name in player["souls"]:
		total += int(soul_values.get(soul_name, 1))
	return total

## Win at 4 soul value; -1 while nobody won.
func has_winner() -> int:
	for player in players:
		if soul_total(int(player["id"])) >= 4:
			return int(player["id"])
	return -1

## Moves the turn pointer clockwise and bumps the turn counter. PURE: the
## caller (GameState) owns the signal/log side effects.
func advance_active_player() -> int:
	if players.is_empty():
		return current_player_index
	current_player_index = (current_player_index + 1) % players.size()
	turn_number += 1
	return current_player_index

# --- Serialization: authoritative image ---------------------------------------

## Full server image. Contains every hand: never send this to a client.
func to_dict() -> Dictionary:
	var card_ids := func(cards: Array) -> Array:
		var ids: Array = []
		for card in cards:
			if card != null:
				ids.append(String(card.id))
		return ids
	var monsters: Array = []
	for monster in table_monsters:
		monsters.append({
			"instance_id": monster["instance_id"],
			"card_id": monster["card"].id if monster.get("card") != null else "",
			"hp": monster["hp"],
		})
	var shop: Array = []
	for slot in shop_slots:
		shop.append({"card_id": slot["card"].id if slot.get("card") != null else ""})
	return {
		"schema_version": SCHEMA_VERSION,
		"players": players.duplicate(true),
		"current_player_index": current_player_index,
		"turn_number": turn_number,
		"phase": phase,
		"soul_values": soul_values.duplicate(true),
		"shields": shields.duplicate(true),
		"table_monsters": monsters,
		"shop_slots": shop,
		"decks": {
			"monster": card_ids.call(monster_deck),
			"characters": card_ids.call(characters),
			"loot": card_ids.call(loot_deck),
			"loot_discard": card_ids.call(loot_discard),
			"treasure": card_ids.call(treasure_deck),
		},
		"instance_counter": instance_counter,
		"bought": bought.duplicate(true),
		"monster_shields": monster_shields.duplicate(true),
		"last_killed_monster": last_killed_monster,
	}

## Rebuilds this object from a to_dict() image. Card ids are re-resolved into
## CardResource objects; an unloadable id is dropped with a warning (the
## catalogue, not the match, is broken in that case).
func load_from_dict(data: Dictionary) -> void:
	reset(0)
	var version: int = int(data.get("schema_version", 0))
	if version != SCHEMA_VERSION:
		Log.warn("MatchState: snapshot schema %d (expected %d) — loading anyway" % [version, SCHEMA_VERSION])
	var loaded_players: Array = data.get("players", [])
	for player in loaded_players:
		players.append((player as Dictionary).duplicate(true))
	current_player_index = int(data.get("current_player_index", 0))
	turn_number = int(data.get("turn_number", 0))
	phase = String(data.get("phase", PHASE_START))
	soul_values = (data.get("soul_values", {}) as Dictionary).duplicate(true)
	shields = (data.get("shields", {}) as Dictionary).duplicate(true)
	for monster in data.get("table_monsters", []):
		var monster_card: Resource = _card(String(monster.get("card_id", "")))
		if monster_card == null:
			continue
		table_monsters.append({
			"instance_id": String(monster.get("instance_id", "")),
			"card": monster_card,
			"hp": int(monster.get("hp", 0)),
		})
	for slot in data.get("shop_slots", []):
		var shop_card: Resource = _card(String(slot.get("card_id", "")))
		if shop_card != null:
			shop_slots.append({"card": shop_card})
	var decks: Dictionary = data.get("decks", {})
	monster_deck = _cards(decks.get("monster", []))
	characters = _cards(decks.get("characters", []))
	loot_deck = _cards(decks.get("loot", []))
	loot_discard = _cards(decks.get("loot_discard", []))
	treasure_deck = _cards(decks.get("treasure", []))
	instance_counter = int(data.get("instance_counter", 0))
	bought = (data.get("bought", {}) as Dictionary).duplicate(true)
	monster_shields = (data.get("monster_shields", {}) as Dictionary).duplicate(true)
	last_killed_monster = String(data.get("last_killed_monster", ""))

func _card(card_id: String) -> Resource:
	if card_id == "":
		return null
	return load(CARD_DIR + card_id + ".tres")

func _cards(ids: Array) -> Array:
	var cards: Array = []
	for card_id in ids:
		var card: Resource = _card(String(card_id))
		if card != null:
			cards.append(card)
	return cards

# --- Serialization: per-viewer DTO (ratifica #2) -------------------------------

## What ONE screen is allowed to know.
##   viewer_player_id < 0  -> the table/spectator view: public state only,
##                            every hand reduced to a count.
##   viewer_player_id >= 0 -> that client's view: the same public state PLUS
##                            the full list of its own hand.
## Public means: characters, HP, cents, souls, items on the table, the monster
## table, the shop, whose turn it is, the phase. Decks are counts only
## (never their order or contents) and the discard pile is a count.
func snapshot_for(viewer_player_id: int) -> Dictionary:
	var public_players: Array = []
	for player in players:
		public_players.append(_public_player(player, viewer_player_id))
	var monsters: Array = []
	for monster in table_monsters:
		var card: Resource = monster.get("card")
		if card == null:
			continue
		monsters.append({
			"instance_id": monster["instance_id"],
			"card_id": card.id,
			"display_name": card.display_name,
			"hp": monster["hp"],
			"max_hp": card.hp,
			"die_value": card.die_value,
			"damage": card.damage,
			"soul_reward": card.soul_reward,
			"text": card.text,
			"is_boss": card.is_boss,
			"effect_trigger": card.effect_trigger,
			"effect_description": card.effect_description,
			"shielded": monster_shields.has(monster["instance_id"]),
		})
	var shop: Array = []
	for slot in shop_slots:
		var card: Resource = slot.get("card")
		if card == null:
			continue
		shop.append({
			"card_id": card.id,
			"display_name": card.display_name,
			"cost_cents": card.cost_cents,
			"description": card.description,
			"bought_by_viewer": bool(bought.get(viewer_player_id, {}).has(card.id)) if viewer_player_id >= 0 else false,
		})
	return {
		"schema_version": SCHEMA_VERSION,
		"viewer_player_id": viewer_player_id,
		"current_player_index": current_player_index,
		"turn_number": turn_number,
		"phase": phase,
		"players": public_players,
		"table_monsters": monsters,
		"shop_slots": shop,
		"deck_counts": {
			"monster": monster_deck.size(),
			"loot": loot_deck.size(),
			"loot_discard": loot_discard.size(),
			"treasure": treasure_deck.size(),
		},
		"winner": has_winner(),
	}

func _public_player(player: Dictionary, viewer_player_id: int) -> Dictionary:
	var is_viewer: bool = viewer_player_id >= 0 and int(player["id"]) == viewer_player_id
	var hand: Array = []
	if is_viewer:
		hand = (player["hand"] as Array).duplicate()
	return {
		"id": int(player["id"]),
		"character_id": player["character_id"],
		"eternal_item_id": player["eternal_item_id"],
		"hp": player["hp"],
		"max_hp": player["max_hp"],
		"damage": player["damage"],
		"cents": player["cents"],
		"souls": (player["souls"] as Array).duplicate(),
		"soul_value": soul_total(int(player["id"])),
		"items_passive": (player["items_passive"] as Array).duplicate(),
		"tapped_items": (player["tapped_items"] as Array).duplicate(),
		"attacks_used": player["attacks_used"],
		"buys_used": player["buys_used"],
		"loot_played": player["loot_played"],
		"character_tapped": player["character_tapped"],
		"eternal_used": player["eternal_used"],
		"shield_next_damage": player["shield_next_damage"],
		# the only private field: full ids for its owner, a NUMBER for everyone else
		"hand": hand,
		"hand_count": (player["hand"] as Array).size(),
	}
