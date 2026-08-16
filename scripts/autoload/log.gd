extends Node
## Log (autoload/singleton)
##
## Game-code logging that is ALWAYS visible. push_warning/push_error are
## silent in headless runs (verified during Phase 1), which hid a bug —
## this wrapper prints through print() instead so warnings never vanish.
## Not an elaborate logging system: two static helpers, that's it.
## Import tools (scripts/tools/) keep using push_error directly.

static func warn(msg: String) -> void:
	print("WARN: ", msg)

static func error(msg: String) -> void:
	print("ERROR: ", msg)