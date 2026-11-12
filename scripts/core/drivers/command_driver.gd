extends RefCounted
## CommandDriver — the MatchDriver transport for M2/M3 phone clients, extended
## in M4 with the REFLEX PRIORITY ROUND.
##
## Contract (same as any MatchDriver, see match_driver.gd):
##  - the engine builds a REQUEST and awaits the answer;
##  - this driver emits PRIORITY_REQUEST / DEATH_PENALTY_REQUEST through
##    `message_sink` (a Callable: the session's message bus);
##  - `receive_command()` validates the command's request id AND player id
##    against the requests in flight, translates it into the engine's response
##    shape and resumes the engine;
##  - a command for another request or another player is REJECTED here (and
##    would be rejected again by the engine: defence in depth).
##
## M4 changes, all transport-level (the rules do not move):
##  - ONE ROUND = EVERY eligible player asked at the same time. Before M4 the
##    window visited players one by one, so a phone had to wait for its "turn
##    to speak"; now the first real answer wins and everybody else's request
##    simply closes.
##  - COUNTDOWN: `window_ms` (default 2000) limits the round. When it expires
##    nobody reacted and the engine resolves the top of the stack. `window_ms
##    <= 0` means "wait forever" — that is the hotseat setting, where a human
##    reading the screen must never be auto-passed.
##  - PAUSE: while a player is choosing a target the countdown freezes
##    (`pause_window`/`resume_window`), so the selection can take as long as it
##    needs without losing the reaction.
##  - The remaining time is measured against the monotonic clock, so both the
##    table screen and the phones can animate the same bar.
##
## Not a class_name on purpose (headless CLI): preload it.

const Protocol := preload("res://scripts/core/match_protocol.gd")

## Emitted when a queued answer must resume the engine. Emitting this resumes
## the awaiting coroutine (Godot resumes awaiters synchronously on emit).
signal answered()

## func(message: Dictionary) -> void — where the session listens.
var message_sink: Callable = Callable()

## M4 reaction countdown in milliseconds. 0 disables it (hotseat).
var window_ms: int = 2000

## Open round: request_id -> request. Empty when no window is open.
var _round: Dictionary = {}
var _round_winner: Dictionary = {}
var _round_total_ms: int = 0
var _round_deadline_ms: int = 0
var _round_expired: bool = false
var _paused_remaining_ms: int = -1
var _timer_generation: int = 0

## Single-request view (hotseat / reconnect prompts). The round also records
## its requests here while it is open.
var _request: Dictionary = {}
var _death_request: Dictionary = {}
## request_id -> response, filled by receive_command() and consumed by the
## awaiting request_* call. Keyed by id so a nested window cannot eat an
## answer meant for its parent.
var _answers: Dictionary = {}

func is_interactive() -> bool:
	return true

func has_window() -> bool:
	return not _round.is_empty() or not _request.is_empty() or not _death_request.is_empty()

## "priority", "death" or "".
func window_kind() -> String:
	if not _round.is_empty() or not _request.is_empty():
		return "priority"
	if not _death_request.is_empty():
		return "death"
	return ""

func pending_request() -> Dictionary:
	if not _request.is_empty():
		return _request.duplicate(true)
	for request_id in _round.keys():
		return (_round[request_id] as Dictionary).duplicate(true)
	return _death_request.duplicate(true)

## Every priority request currently open (one per eligible player).
func pending_requests() -> Array:
	var out: Array = []
	for request_id in _round.keys():
		out.append((_round[request_id] as Dictionary).duplicate(true))
	if out.is_empty() and not _request.is_empty():
		out.append(_request.duplicate(true))
	return out

## The request this player still owes an answer to ({} when none): used by the
## reconnect path so a reloaded phone gets its prompt back.
func pending_request_for(player_id: int) -> Dictionary:
	for request in pending_requests():
		if int((request as Dictionary).get("player_id", -1)) == player_id:
			return (request as Dictionary).duplicate(true)
	if not _death_request.is_empty() and int(_death_request.get("player_id", -1)) == player_id:
		return _death_request.duplicate(true)
	return {}

func pending_player_id() -> int:
	for request in pending_requests():
		return int((request as Dictionary).get("player_id", -1))
	if not _death_request.is_empty():
		return int(_death_request.get("player_id", -1))
	return -1

# --- Timing (M4) ---------------------------------------------------------------

func window_total_ms() -> int:
	return _round_total_ms

func window_remaining_ms() -> int:
	if _round_total_ms <= 0:
		return 0
	if _paused_remaining_ms >= 0:
		return _paused_remaining_ms
	if _round_deadline_ms <= 0:
		return 0
	return maxi(0, _round_deadline_ms - Time.get_ticks_msec())

func pause_window() -> void:
	if _round_total_ms <= 0:
		return
	var remaining: int = window_remaining_ms()
	_timer_generation += 1            # invalidate the timer already scheduled
	_paused_remaining_ms = maxi(1, remaining)
	_round_deadline_ms = 0

func resume_window() -> void:
	if _paused_remaining_ms < 0:
		return
	var remaining: int = _paused_remaining_ms
	_paused_remaining_ms = -1
	_start_countdown(remaining)

# --- Round --------------------------------------------------------------------

## M4: opens ONE round for all the requests and waits for the first real answer
## or for the countdown. Returns the winning response ({} on timeout/no answer).
func request_priority_round(requests: Array) -> Dictionary:
	_round.clear()
	_round_winner = {}
	_round_expired = false
	_paused_remaining_ms = -1
	_round_total_ms = maxi(0, window_ms)
	for raw_request in requests:
		var request: Dictionary = (raw_request as Dictionary).duplicate(true)
		request["window_total_ms"] = _round_total_ms
		request["window_remaining_ms"] = _round_total_ms
		_round[String(request.get("request_id", ""))] = request
		if message_sink.is_valid():
			message_sink.call(Protocol.priority_request(request))
	if _round_total_ms > 0:
		_start_countdown(_round_total_ms)
	while _round_winner.is_empty() and not _round_expired:
		await answered
	var winner: Dictionary = _round_winner.duplicate(true)
	_round.clear()
	_round_winner = {}
	_round_deadline_ms = 0
	_paused_remaining_ms = -1
	_timer_generation += 1
	return winner

func _start_countdown(ms: int) -> void:
	_round_deadline_ms = Time.get_ticks_msec() + ms
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	_timer_generation += 1
	var generation: int = _timer_generation
	var timer := tree.create_timer(float(ms) / 1000.0, true, false, true)
	timer.timeout.connect(func() -> void:
		if generation != _timer_generation:
			return
		if not _round_winner.is_empty() or _round_expired:
			return
		if _paused_remaining_ms >= 0:
			return
		_round_expired = true
		_round_deadline_ms = 0
		print("  [priority] window expired (%d ms) — auto-resolving" % ms)
		answered.emit())

# --- Legacy single-request entry points ---------------------------------------

func request_priority(request: Dictionary) -> Dictionary:
	_request = request.duplicate(true)
	var winner: Dictionary = await request_priority_round([request])
	if String(_request.get("request_id", "")) == String(request.get("request_id", "")):
		_request = {}
	if winner.is_empty():
		return {}
	return _bind(request, winner)

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

## Routes a client COMMAND into the round (or the death request) in flight.
## Returns true when the command was accepted as the answer to that request.
func receive_command(command: Dictionary) -> bool:
	var rid: String = String(command.get("request_id", ""))
	var pid: int = int(command.get("player_id", -1))
	if not _round.is_empty():
		var request: Dictionary = _round.get(rid, {})
		if request.is_empty() or pid != int(request.get("player_id", -1)):
			Log.warn("CommandDriver: answer '%s' from P%d does not match any open window" % [rid, pid + 1])
			return false
		if not _round_winner.is_empty():
			return false   # somebody already reacted: this round is closed
		_round_winner = _bind(request, _command_to_response(command))
		answered.emit()
		return true
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
