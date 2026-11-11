extends RefCounted
## LocalUiDriver — adapter between the engine and the local hotseat UI.
##
## It is INTERACTIVE (a human must click), so the engine awaits it. The only
## thing it does is turn an engine REQUEST into the existing UI notifications
## and wait for the UI's answer, then stamp the request identity onto it:
##   request_priority -> EventBus.priority_pending -> await priority_given
##   request_death    -> await player_death_resolved  (player_died is emitted
##                       by the controller, which owns the penalty data)
##
## This is deliberately a thin adapter: the engine no longer knows EventBus
## exists for input. M1 used it for the hotseat scene; since M2 the scene speaks
## the protocol through CommandDriver (scripts/core/drivers/command_driver.gd),
## which is the same contract with messages/commands instead of signals. This
## file stays as the reference "simplest possible interactive driver".
##
## Not a class_name on purpose (headless CLI): preload it.

const MatchDriverScript := preload("res://scripts/core/drivers/match_driver.gd")

var _awaiting_priority: bool = false
var _awaiting_death: bool = false

func is_interactive() -> bool:
	return true

func request_priority(request: Dictionary) -> Dictionary:
	var player_id: int = int(request.get("player_id", -1))
	if _awaiting_priority:
		# One window at a time is an engine invariant; a second request here
		# means the previous answer was lost. Fail safe with a pass.
		Log.warn("LocalUiDriver: reentrant priority request %s — auto-passing" % String(request.get("request_id", "?")))
		return _bound_pass(request)
	_awaiting_priority = true
	EventBus.priority_pending.emit(player_id, String(request.get("stack_type", "")), request.get("entry", {}))
	var args: Array = await EventBus.priority_given
	_awaiting_priority = false
	var answered_by: int = int(args[0]) if args.size() > 0 and typeof(args[0]) == TYPE_INT else -1
	var response: Dictionary = {}
	if args.size() > 1 and typeof(args[1]) == TYPE_DICTIONARY:
		response = (args[1] as Dictionary).duplicate()
	if answered_by != player_id:
		# The UI answered out of turn / for the wrong player: refuse it rather
		# than letting a mis-wired screen act for somebody else.
		Log.warn("LocalUiDriver: answer from P%d for a request addressed to P%d — ignoring" % [answered_by + 1, player_id + 1])
		response = {"action": "pass"}
	return _bind_identity(request, response)

func request_death(request: Dictionary) -> Dictionary:
	var player_id: int = int(request.get("player_id", -1))
	if _awaiting_death:
		Log.warn("LocalUiDriver: reentrant death request %s — taking the fallback" % String(request.get("request_id", "?")))
		return _bind_identity(request, {})
	_awaiting_death = true
	var args: Array = await EventBus.player_death_resolved
	_awaiting_death = false
	var answered_by: int = int(args[0]) if args.size() > 0 and typeof(args[0]) == TYPE_INT else -1
	var choice: Dictionary = {}
	if args.size() > 1 and typeof(args[1]) == TYPE_DICTIONARY:
		choice = (args[1] as Dictionary).duplicate()
	if answered_by != player_id:
		Log.warn("LocalUiDriver: death choice from P%d for P%d — ignoring" % [answered_by + 1, player_id + 1])
		choice = {}
	return _bind_identity(request, choice)

## The UI does not know about request ids: this adapter is the transport, so it
## stamps the identity of the request it was actually waiting for. The engine
## still validates it (and rejects anything else).
func _bind_identity(request: Dictionary, payload: Dictionary) -> Dictionary:
	payload["request_id"] = String(request.get("request_id", ""))
	payload["player_id"] = int(request.get("player_id", -1))
	return payload

func _bound_pass(request: Dictionary) -> Dictionary:
	return _bind_identity(request, {"action": "pass"})
