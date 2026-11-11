extends Node
## GameState (autoload/singleton)
##
## FACADE, no longer a state holder (audit C2, ratifica #2). All match data
## lives in ONE serializable object (scripts/core/match_state.gd); this node
## exposes it to the rest of the project as `state` plus the historical
## accessors and mutation helpers, so existing call sites keep working:
##
##   GameState.players              -> state.players
##   GameState.current_player_index -> state.current_player_index
##   GameState.soul_values/shields  -> the SAME Dictionary objects
##
## Why keep the façade at all: ~40 call sites (cards, UI, tests) read
## GameState.players. Rewriting them all would be churn without a behavior
## change; the invariant that matters is that there is exactly ONE state
## object, and that every mutation goes through a helper that also emits the
## matching EventBus notification (state and notifications never drift).
##
## Networking note: this node is the LOCAL host's view. It is not synchronized
## with anyone — a future server sends MatchState.snapshot_for(player_id)
## DTOs, never this object.

const MatchStateScript := preload("res://scripts/core/match_state.gd")

## THE single match state. Never reassigned by anything except reset_match()/
## adopt(); MatchController owns the lifecycle.
var state = MatchStateScript.new()

var players: Array:
	get:
		return state.players

var current_player_index: int:
	get:
		return state.current_player_index
	set(value):
		state.current_player_index = value

var turn_number: int:
	get:
		return state.turn_number
	set(value):
		state.turn_number = value

## "start" | "action" | "combat" | "end" (MatchState.PHASE_*).
var phase: String:
	get:
		return state.phase
	set(value):
		state.phase = value

var soul_values: Dictionary:
	get:
		return state.soul_values

## Active shields: target_player_id -> {owner, item_name}.
var shields: Dictionary:
	get:
		return state.shields

## Installs a freshly reset state. Called by MatchController.setup() before
## anything else touches the match.
func adopt(new_state) -> void:
	if new_state == null:
		state = MatchStateScript.new()
		state.reset(0)
		return
	state = new_state

## New empty match. Kept for teardown and for callers that only need the
## player list (setup goes through MatchController.adopt_state()).
func reset_match(player_count: int) -> void:
	state = MatchStateScript.new()
	state.reset(player_count)

func clear() -> void:
	reset_match(0)

func get_current_player() -> Dictionary:
	if state.players.is_empty():
		return {}
	return state.players[state.current_player_index]

## Shared active_player_id (ESEMPIO 1): called ALWAYS at the end of the
## ending phase — the step that must never be missing. Logs and emits so
## drivers/UI can re-read the pointer afterwards.
func advance_active_player() -> int:
	if state.players.is_empty():
		return state.current_player_index
	var previous: int = state.current_player_index
	var current: int = state.advance_active_player()
	print("end of turn: active player = P%d" % (current + 1))
	EventBus.active_player_advanced.emit(previous, current)
	return current

# --- Mutations -------------------------------------------------------------
# Effects and the turn loop mutate match state ONLY through these helpers,
# so GameState (state) and EventBus (notifications) never drift apart.

func gain_cents(player_id: int, amount: int) -> void:
	var player: Dictionary = get_player(player_id)
	if player.is_empty():
		return
	player["cents"] = int(player["cents"]) + amount
	EventBus.cents_changed.emit(player_id, amount, player["cents"])

func lose_cents(player_id: int, amount: int) -> void:
	gain_cents(player_id, -amount)

## Gives the player a soul card. A boss soul is ONE entry in the souls list
## (its NAME) that counts `value` towards the 4-soul win condition (MP07 J).
## Every souls change re-checks the win condition immediately.
func gain_soul(player_id: int, soul_type: String, value: int = 1) -> void:
	var player: Dictionary = get_player(player_id)
	if player.is_empty():
		return
	player["souls"].append(soul_type)
	state.soul_values[soul_type] = value
	var total: int = soul_total(player_id)
	EventBus.soul_gained.emit(player_id, soul_type, total)
	EventBus.souls_changed.emit(player_id, player["souls"], total)
	var winner: int = has_winner()
	if winner >= 0:
		EventBus.game_won.emit(winner)

## Sum of the player's soul VALUES (bosses count 2, normal souls 1).
func soul_total(player_id: int) -> int:
	return state.soul_total(player_id)

func damage_player(player_id: int, amount: int, source_id: String) -> void:
	var player: Dictionary = get_player(player_id)
	if player.is_empty():
		return
	if consume_shield(player_id, amount):
		EventBus.player_damaged.emit(player_id, 0, source_id)  # fully prevented
		return
	player["hp"] = int(player["hp"]) - amount
	EventBus.player_damaged.emit(player_id, amount, source_id)

# --- Shields (ESEMPIO 4): prevention flags, never heals ----------------------

## Yum Heart activation, step 2: one call does everything — there is no
## follow-up menu and no quantity.
func apply_shield(target_id: int, owner_id: int, item_name: String) -> void:
	var player: Dictionary = get_player(target_id)
	if player.is_empty():
		return
	player["shield_next_damage"] = true
	state.shields[target_id] = {"owner": owner_id, "item_name": item_name}
	EventBus.shield_applied.emit(target_id, item_name, owner_id)

## Called by damage_player when the flag is up: the WHOLE instance is
## cancelled, the flag is removed after consumption.
func consume_shield(target_id: int, absorbed_amount: int) -> bool:
	if not state.shields.has(target_id):
		return false
	var info: Dictionary = state.shields[target_id]
	state.shields.erase(target_id)
	var player: Dictionary = get_player(target_id)
	if not player.is_empty():
		player["shield_next_damage"] = false
	print("P%d's shield (%s) absorbs the damage, 0 hp lost" % [target_id + 1, info.get("item_name", "?")])
	EventBus.shield_consumed.emit(target_id, absorbed_amount)
	return true

## Ending phase of the OWNER's turn: every shield they handed out that was
## never consumed is removed. Returns the target ids whose shields expired.
func expire_shields_owned_by(owner_id: int) -> Array:
	var expired: Array = []
	for target_id in state.shields.keys():
		if int(state.shields[target_id].get("owner", -1)) == owner_id:
			var info: Dictionary = state.shields[target_id]
			expired.append(target_id)
			state.shields.erase(target_id)
			var player: Dictionary = get_player(int(target_id))
			if not player.is_empty():
				player["shield_next_damage"] = false
			print("%s shield on P%d expires unused" % [info.get("item_name", "?"), int(target_id) + 1])
			EventBus.shield_expired.emit(int(target_id))
	return expired

## Heals a player. Healing beyond max HP permanently increases max HP (MP06 g).
func heal(player_id: int, amount: int) -> void:
	var player: Dictionary = get_player(player_id)
	if player.is_empty():
		return
	if amount <= 0:
		return
	var new_hp: int = int(player["hp"]) + amount
	if new_hp > int(player["max_hp"]):
		player["max_hp"] = new_hp
	player["hp"] = new_hp
	EventBus.player_healed.emit(player_id, amount, player["hp"])

## End-of-turn full restore (MP06 d): sets HP to max WITHOUT the permanent
## increase rule — only card effects grow max HP.
func restore_hp(player_id: int) -> void:
	var player: Dictionary = get_player(player_id)
	if player.is_empty():
		return
	player["hp"] = player["max_hp"]
	EventBus.hp_restored.emit(player_id, player["hp"])

func get_player(player_id: int) -> Dictionary:
	return state.get_player(player_id)

## Win condition (MP07 J): the SUM of soul values reaches 4.
func has_winner() -> int:
	return state.has_winner()
