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

const PLAYER_TEMPLATE := {
	"id": -1,
	"character_id": "",
	"hp": 2,
	"cents": 3,
	"souls": [],       # Array[String], e.g. ["red", "black"]
	"hand": [],         # Array[String] card ids
	"items_active": [], # Array[String] card ids
	"items_passive": [],# Array[String] card ids
}

func reset_match(player_count: int) -> void:
	players.clear()
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

func gain_soul(player_id: int, soul_type: String) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["souls"].append(soul_type)
	EventBus.soul_gained.emit(player_id, soul_type, player["souls"].size())
	var winner := has_winner()
	if winner >= 0:
		EventBus.game_won.emit(winner)

func damage_player(player_id: int, amount: int, source_id: String) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["hp"] -= amount
	EventBus.player_damaged.emit(player_id, amount, source_id)

func heal(player_id: int, amount: int) -> void:
	var player := _get_player(player_id)
	if player.is_empty():
		return
	player["hp"] += amount
	EventBus.player_healed.emit(player_id, amount, player["hp"])

func _get_player(player_id: int) -> Dictionary:
	for p in players:
		if p["id"] == player_id:
			return p
	return {}

func has_winner() -> int:
	for p in players:
		if p["souls"].size() >= 4:
			return p["id"]
	return -1
