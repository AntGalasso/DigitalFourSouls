extends Node
## GameState (autoload/singleton)
##
## Single source of truth for the current match. Phase 1 (local hotseat)
## keeps this dead simple. Phase 2 (networked) will make this authoritative
## on the host and mirror it to peers via RPCs — deliberately NOT designed
## yet, don't add networking code here until the local loop is proven.

var players: Array[Dictionary] = []     # see PLAYER_TEMPLATE below
var current_player_index: int = 0
var current_phase: String = "buy"
var turn_number: int = 0
var soul_values: Dictionary = {}        # soul name -> value (1 by default, bosses 1-2 per MP07 J)

const PLAYER_TEMPLATE := {
	"id": -1,
	"character_id": "",        # set by MatchController at setup (random draw)
	"eternal_item_id": "",     # the character's eternal item (never lost to the death penalty)
	"hp": 2,
	"max_hp": 2,               # can permanently grow by healing at full HP
	"damage": 1,
	"cents": 3,
	"souls": [],       # Array[String] soul NAMES, e.g. ["monster_monstro", "blue"] (MP07 J)
	"hand": [],         # Array[String] card ids
	"items_active": [], # Array[String] card ids
	"items_passive": [],# Array[String] card ids
	"attacks_used": 0,  # per own turn (reset in begin_turn)
	"buys_used": 0,
	"loot_played": 0,
	"character_effect_used": false,  # recharges at the start of the owner's turn
	"eternal_used": false,           # recharges at the owner's turn start (+ turn end for D6/Belial)
}

func reset_match(player_count: int) -> void:
	players.clear()
	soul_values.clear()
	for i in range(player_count):
		var p := PLAYER_TEMPLATE.duplicate(true)
		p["id"] = i
		players.append(p)
	current_player_index = 0
	current_phase = "buy"
	turn_number = 0

func get_current_player() -> Dictionary:
	return players[current_player_index]

# --- Mutations -------------------------------------------------------------
# Effects and the turn loop mutate match state ONLY through these helpers,
# so GameState (state) and EventBus (notifications) never drift apart.

func gain_cents(player_id: int, amount: int) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["cents"] += amount
	EventBus.cents_changed.emit(player_id, amount, player["cents"])

func lose_cents(player_id: int, amount: int) -> void:
	gain_cents(player_id, -amount)

## Gives the player a soul card. A boss soul is ONE entry in the souls list
## (its NAME) that counts `value` towards the 4-soul win condition (MP07 J).
## Every souls change re-checks the win condition immediately.
func gain_soul(player_id: int, soul_type: String, value: int = 1) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["souls"].append(soul_type)
	soul_values[soul_type] = value
	var total := soul_total(player_id)
	EventBus.soul_gained.emit(player_id, soul_type, total)
	EventBus.souls_changed.emit(player_id, player["souls"], total)
	var winner := has_winner()
	if winner >= 0:
		EventBus.game_won.emit(winner)

## Sum of the player's soul VALUES (bosses count 2, normal souls 1).
func soul_total(player_id: int) -> int:
	var player := _get_player(player_id)
	if player.is_empty():
		return 0
	var total := 0
	for soul_name in player["souls"]:
		total += soul_values.get(soul_name, 1)
	return total

func damage_player(player_id: int, amount: int, source_id: String) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["hp"] -= amount
	EventBus.player_damaged.emit(player_id, amount, source_id)

## Heals a player. Healing beyond max HP permanently increases max HP (MP06 g):
## a heal at full HP still nets +1 HP, exactly like the official Yum Heart rule.
func heal(player_id: int, amount: int) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	if amount <= 0:
		return
	var new_hp: int = player["hp"] + amount
	if new_hp > player["max_hp"]:
		player["max_hp"] = new_hp
	player["hp"] = new_hp
	EventBus.player_healed.emit(player_id, amount, player["hp"])

## End-of-turn full restore (MP06 d): sets HP to max WITHOUT the permanent
## increase rule — only card effects grow max HP, not the turn-end heal.
func restore_hp(player_id: int) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["hp"] = player["max_hp"]
	EventBus.hp_restored.emit(player_id, player["hp"])

func _get_player(player_id: int) -> Dictionary:
	for p in players:
		if p["id"] == player_id:
			return p
	return {}

## Win condition (MP07 J): the SUM of soul values reaches 4 (a soul_value 2
## boss counts double, still ONE soul card in the list).
func has_winner() -> int:
	for p in players:
		if soul_total(p["id"]) >= 4:
			return p["id"]
	return -1
