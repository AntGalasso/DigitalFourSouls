extends RefCounted
## CommandDriver — the MatchDriver transport for M2: instead of a global
## signal (M1's LocalUiDriver), the engine's requests leave as PROTOCOL
## MESSAGES and the answers come back as PROTOCOL COMMANDS.
##
## Why a new driver: ratifica #1 wants the phone clients to speak JSON over a
## socket while the engine stays transport-agnostic. This class is the last
## piece that changes when the socket arrives — the engine and the rules are
## untouched.
##
## Contract (same as any MatchDriver, see match_driver.gd):
##  - the engine builds a request and awaits the answer;
##  - this driver emits PRIORITY_REQUEST / DEATH_PENALTY_REQUEST through
##    `message_sink` (a Callable: the session's message bus);
##  - `receive_command()` validates the command's request id AND player id
##    against the request in flight, translates it into the engine's response
##    shape and resumes the engine;
##  - a command for another request or another player is REJECTED here (and
##    would be rejected again by the engine: defence in depth).
##
## Not a class_name on purpose (headless CLI): preload it.

const Protocol := preload("res://scripts/core/match_protocol.gd")

## Emitted when a queued answer must resume the engine. Emitting this resumes
## the awaiting coroutine (Godot resumes awaiters synchronously on emit).
signal answered()

## func(message: Dictionary) -> void — where the session listens.
var message_sink: Callable = Callable()

## The priority request in flight ({} when no window is open).
var _request: Dictionary = {}
## The death request in flight ({} when none).
var _death_request: Dictionary = {}
## request_id -> response, filled by receive_command() and consumed by the
## awaiting request_* call. Keyed by id so a nested window cannot eat an
## answer meant for its parent.
var _answers: Dictionary = {}

func is_interactive() -> bool:
	return true

func has_window() -> bool:
	return not _request.is_empty() or not _death_request.is_empty()

## "priority", "death" or "".
func window_kind() -> String:
	if not _request.is_empty():
		return "priority"
	if not _death_request.is_empty():
		return "death"
	return ""

func pending_request() -> Dictionary:
	if not _request.is_empty():
		return _request.duplicate(true)
	return _death_request.duplicate(true)

func pending_player_id() -> int:
	if not _request.is_empty():
		return int(_request.get("player_id", -1))
	if not _death_request.is_empty():
		return int(_death_request.get("player_id", -1))
	return -1

func request_priority(request: Dictionary) -> Dictionary:
	var rid: String = String(request.get("request_id", ""))
	_request = request.duplicate(true)
	if message_sink.is_valid():
		message_sink.call(Protocol.priority_request(request))
	while not _answers.has(rid):
		await answered
	var response: Dictionary = _answers[rid]
	_answers.erase(rid)
	if String(_request.get("request_id", "")) == rid:
		_request = {}
	return _bind(request, response)

func request_death(request: Dictionary) -> Dictionary:
	var rid: String = String(request.get("request_id", ""))
	_death_request = request.duplicate(true)
	if message_sink.is_valid():
		message_sink.call(Protocol.death_request(request))
	while not _answers.has(rid):
		await answered
	var choice: Dictionary = _answers[rid]
	_answers.erase(rid)
	if String(_death_request.get("request_id", "")) == rid:
		_death_request = {}
	return _bind(request, choice)

## Routes a client COMMAND into the request in flight.
## Returns true when the command was accepted as the answer to that request.
func receive_command(command: Dictionary) -> bool:
	var rid: String = String(command.get("request_id", ""))
	var pid: int = int(command.get("player_id", -1))
	if not _request.is_empty():
		if rid != String(_request.get("request_id", "")) \
				or pid != int(_request.get("player_id", -1)):
			Log.warn("CommandDriver: answer '%s' from P%d does not match the open window ('%s' for P%d)" % [
				rid, pid + 1, String(_request.get("request_id", "")), int(_request.get("player_id", -1)) + 1])
			return false
		_answers[rid] = _command_to_response(command)
		answered.emit()
		return true
	if not _death_request.is_empty():
		if rid != String(_death_request.get("request_id", "")) \
				or pid != int(_death_request.get("player_id", -1)):
			Log.warn("CommandDriver: death answer '%s' from P%d rejected" % [rid, pid + 1])
			return false
		var payload: Dictionary = command.get("payload", {})
		_answers[rid] = {
			"loot_id": String(payload.get("loot_id", "")),
			"item_id": String(payload.get("item_id", "")),
		}
		answered.emit()
		return true
	return false

## The engine's response shape, built ONLY from the command payload.
func _command_to_response(command: Dictionary) -> Dictionary:
	var type: String = String(command.get("type", ""))
	var payload: Dictionary = command.get("payload", {})
	match type:
		Protocol.CMD_PLAY_LOOT:
			return {
				"action": "loot",
				"card_id": String(payload.get("card_id", "")),
				"target_id": String(payload.get("target_id", "")),
			}
		Protocol.CMD_ACTIVATE_ITEM:
			return {"action": "eternal", "payload": payload.duplicate(true)}
		_:
			# PASS_PRIORITY and anything else that does not act is a pass.
			return {"action": "pass"}

func _bind(request: Dictionary, payload: Dictionary) -> Dictionary:
	var bound: Dictionary = payload.duplicate(true)
	bound["request_id"] = String(request.get("request_id", ""))
	bound["player_id"] = int(request.get("player_id", -1))
	return bound
