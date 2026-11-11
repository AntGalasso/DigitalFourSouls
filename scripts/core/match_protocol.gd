extends RefCounted
## MatchProtocol — the ONLY vocabulary that may cross the client/server
## boundary (M2, ratifica #1/#2).
##
## Everything here is PURE DATA: String, int, float, bool, null, Array,
## Dictionary. No Object, RefCounted, Resource, Callable, Node or signal may
## ever appear in a command or a message, because the wire is JSON: a phone
## client (PWA, no engine) must be able to build and read every one of these
## with JSON.stringify/JSON.parse and nothing else.
##
## Directions:
##   client -> server  COMMANDS   (what the player wants to do)
##   server -> client  MESSAGES   (what the authoritative engine decides)
##
## Rules are NEVER enforced here: this file only defines shape, names and
## validation. The engine (MatchController via MatchSession) owns legality.
##
## Deliberately NOT a class_name (headless CLI does not refresh the global
## class cache): preload it, e.g.
##   const Protocol := preload("res://scripts/core/match_protocol.gd")
##   var cmd := Protocol.command(Protocol.CMD_PLAY_LOOT, 0, {"card_id": "loot_bomb"})

const SCHEMA_VERSION := 1

# --- client -> server ---------------------------------------------------------

## Play a card from hand. payload: {card_id, target_id?}
## target_id may be omitted: the server answers with TARGET_REQUEST instead of
## guessing a target for the player.
const CMD_PLAY_LOOT := "PLAY_LOOT"
## Use the player's eternal item. payload: {delta?, target_id?}
const CMD_ACTIVATE_ITEM := "ACTIVATE_ITEM"
## Declare an attack on a table monster. payload: {target_id?}
const CMD_DECLARE_ATTACK := "DECLARE_ATTACK"
## Buy the treasure in a shop slot. payload: {slot}
const CMD_BUY_SHOP := "BUY_SHOP"
## Give up priority on the current window (an answer: carries request_id).
const CMD_PASS_PRIORITY := "PASS_PRIORITY"
## Answer a TARGET_REQUEST. payload: {target_id} (+ request_id)
const CMD_SELECT_TARGET := "SELECT_TARGET"
## Answer a DEATH_PENALTY_REQUEST. payload: {loot_id, item_id}
const CMD_CHOOSE_DEATH_PENALTY := "CHOOSE_DEATH_PENALTY"
## End the current turn (the server runs the ending phase and starts the next).
const CMD_END_TURN := "END_TURN"

# --- server -> client ---------------------------------------------------------

## The viewer's filtered state + the server-computed legal actions.
const MSG_STATE_SNAPSHOT := "STATE_SNAPSHOT"
## A priority window is open for this player: render legal_actions, answer with
## a command that carries the same request_id.
const MSG_PRIORITY_REQUEST := "PRIORITY_REQUEST"
## The last command needs a target: answer with SELECT_TARGET.
const MSG_TARGET_REQUEST := "TARGET_REQUEST"
## HP hit 0: the player must choose the loot (and the item) to lose.
const MSG_DEATH_PENALTY_REQUEST := "DEATH_PENALTY_REQUEST"
## Something happened in the game world (log/clients): card drawn, soul gained…
const MSG_DOMAIN_EVENT := "DOMAIN_EVENT"

# --- builders -----------------------------------------------------------------

## A client command. `request_id` is empty for "free" actions and MUST be the
## id of the server request when the command answers a window.
static func command(type: String, player_id: int, payload: Dictionary = {}, request_id: String = "") -> Dictionary:
	return {
		"kind": "command",
		"schema_version": SCHEMA_VERSION,
		"type": type,
		"player_id": player_id,
		"request_id": request_id,
		"payload": payload.duplicate(true),
	}

## A server message.
static func message(type: String, payload: Dictionary = {}) -> Dictionary:
	return {
		"kind": "message",
		"schema_version": SCHEMA_VERSION,
		"type": type,
		"payload": payload.duplicate(true),
	}

## `window_kind` is the server's word on whether a request is still open: a
## client that trusts it can never leave a stale overlay on screen.
static func state_snapshot(snapshot: Dictionary, legal: Dictionary, window_kind: String = "") -> Dictionary:
	return message(MSG_STATE_SNAPSHOT, {"snapshot": snapshot, "legal": legal, "window_kind": window_kind})

## The engine request, reduced to what a client may know: the entry keeps ids
## and numbers only (never a card resource, never another player's hand).
static func priority_request(request: Dictionary) -> Dictionary:
	var entry: Dictionary = (request.get("entry", {}) as Dictionary).duplicate(true)
	return message(MSG_PRIORITY_REQUEST, {
		"request_id": String(request.get("request_id", "")),
		"player_id": int(request.get("player_id", -1)),
		"stack_type": String(request.get("stack_type", "")),
		"entry_id": String(entry.get("id", "")),
		"entry": entry,
		"legal_actions": (request.get("legal_actions", []) as Array).duplicate(true),
		"phase": String(request.get("phase", "")),
		"turn_player_id": int(request.get("turn_player_id", -1)),
	})

static func target_request(request_id: String, player_id: int, command_type: String, card_id: String, options: Array) -> Dictionary:
	return message(MSG_TARGET_REQUEST, {
		"request_id": request_id,
		"player_id": player_id,
		"command_type": command_type,
		"card_id": card_id,
		"options": options.duplicate(true),
	})

static func death_request(request: Dictionary) -> Dictionary:
	return message(MSG_DEATH_PENALTY_REQUEST, {
		"request_id": String(request.get("request_id", "")),
		"player_id": int(request.get("player_id", -1)),
		"penalty": (request.get("penalty", {}) as Dictionary).duplicate(true),
	})

## `private_to >= 0` means only that player may receive the payload contents.
static func domain_event(event_name: String, data: Dictionary, private_to: int = -1) -> Dictionary:
	return message(MSG_DOMAIN_EVENT, {
		"event": event_name,
		"data": data.duplicate(true),
		"private_to": private_to,
	})

# --- validation ---------------------------------------------------------------

static func is_command_type(type: String) -> bool:
	match type:
		CMD_PLAY_LOOT, CMD_ACTIVATE_ITEM, CMD_DECLARE_ATTACK, CMD_BUY_SHOP, \
		CMD_PASS_PRIORITY, CMD_SELECT_TARGET, CMD_CHOOSE_DEATH_PENALTY, CMD_END_TURN:
			return true
	return false

## "" when the command is shippable, otherwise a short machine-readable reason.
static func validation_error(cmd: Dictionary) -> String:
	if String(cmd.get("kind", "")) != "command":
		return "not_a_command"
	if int(cmd.get("schema_version", -1)) != SCHEMA_VERSION:
		return "schema_mismatch"
	var type: String = String(cmd.get("type", ""))
	if not is_command_type(type):
		return "unknown_command"
	if typeof(cmd.get("player_id", null)) != TYPE_INT or int(cmd.get("player_id", -1)) < 0:
		return "bad_player_id"
	if typeof(cmd.get("payload", null)) != TYPE_DICTIONARY:
		return "bad_payload"
	if typeof(cmd.get("request_id", "")) != TYPE_STRING:
		return "bad_request_id"
	if not is_pure(cmd.get("payload", {})):
		return "impure_payload"
	return ""

## True when `value` can survive a JSON roundtrip unchanged in KIND: no Godot
## objects, no Callables, no signals, no packed arrays of objects.
static func is_pure(value) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return true
		TYPE_ARRAY:
			for item in value:
				if not is_pure(item):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value.keys():
				if typeof(key) != TYPE_STRING:
					return false
				if not is_pure(value[key]):
					return false
			return true
		_:
			return false

# --- wire ---------------------------------------------------------------------

## Exactly what a socket would send. Godot objects make stringify fail (empty
## string), which is why is_pure() is checked before building messages.
static func to_wire(value) -> String:
	return JSON.stringify(value)

static func from_wire(text: String) -> Dictionary:
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed
