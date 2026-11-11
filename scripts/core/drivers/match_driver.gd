extends RefCounted
## MatchDriver — the engine's ONLY way to obtain outside input.
##
## Before this existed, MatchController awaited EventBus.priority_given, a
## GLOBAL signal: the first answer from anywhere was accepted, the player id
## inside it was trusted, and the engine had no idea whether the answer
## belonged to the request still in flight (audit C3, ratifica #3).
##
## Contract:
##  - The controller builds a REQUEST (request_id, player_id, stack entry,
##    legal_actions) and never reads presentation state.
##  - The driver answers with a RESPONSE dictionary. It may be interactive
##    (a human/network client: the controller awaits) or automatic (robot,
##    self-check, future AI: decided synchronously).
##  - The controller validates request_id AND player_id and drops stale or
##    foreign answers (treating them as a pass). A driver can therefore never
##    answer for another player or for a window that already closed.
##
## Subclasses override decide_*/request_* only. A driver must NEVER mutate
## match state: it returns intentions, the engine applies them.
##
## Not a class_name on purpose (headless CLI does not refresh the global class
## cache): preload this script, e.g.
##   const MatchDriverScript := preload("res://scripts/core/drivers/match_driver.gd")

## True when the engine must await request_* (a human or a remote client is
## answering). False for instantaneous policies (robot, tests, auto-pass).
func is_interactive() -> bool:
	return false

## Automatic policy. Must return a RESPONSE dictionary; the default is a pass.
## request carries: request_id, window, player_id, stack_type, entry,
## legal_actions, phase, turn_player_id.
func decide_priority(_request: Dictionary) -> Dictionary:
	return {"action": "pass"}

## Interactive transport: wait for the real answer to THIS request.
## Only called when is_interactive() is true.
func request_priority(request: Dictionary) -> Dictionary:
	return decide_priority(request)

## Automatic death-penalty policy: {"loot_id": String, "item_id": String}.
## Returning {} means "no choice" — the engine then applies the documented
## fallback (automatic only when there is exactly one legal option).
func decide_death(_request: Dictionary) -> Dictionary:
	return {}

## Interactive death-penalty transport: same contract as decide_death.
func request_death(request: Dictionary) -> Dictionary:
	return decide_death(request)
