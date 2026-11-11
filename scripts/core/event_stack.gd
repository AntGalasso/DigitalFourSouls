class_name EventStack
extends RefCounted
## The real event/stack queue (MP07 build).
##
## Typed LIFO entries, exactly the three kinds from the metaprompt examples:
##   {"type": "pending_roll",  "id": "r1", "owner": pid, "target": instance_id,
##    "value": int, "bonus": int, "die_value": int}
##   {"type": "pending_effect","id": "e1", "owner": pid, "card_id": String,
##    "payload": Dictionary}                       (loot played from hand)
##   {"type": "modifier",      "id": "m1", "owner": pid, "target_id": "r1",
##    "effect": "reroll"|"adjust", "item_id"/"item_name", ["delta": +-1,
##    "applied": true]}                            (D6 / Belial Book responses)
##
## resolve_one() resolves EXACTLY ONE entry: the one on top when the priority
## window closed. That is the Comprehensive Rules behaviour (same as MTG): a
## round of consecutive passes resolves a single stack object, never the whole
## stack. Everything still below stays on the stack and the controller opens a
## FRESH priority window for it before it resolves — so a player who drew a
## card in response can play it against the entry underneath, and a +2
## modifier's new value can be answered before the roll resolves.
##
## It deliberately does NOT assume what the entry is: the old version
## hardcoded "modifier, then its pending_roll", which meant an effect that
## pushed a NEW entry while resolving had nowhere to go and was destroyed by
## reset_combat_state() (audit C1). Resolution is delegated to the `resolver`
## Callable owned by the controller; this class only owns ORDER.
##
## Entries pushed WHILE the top resolves appear on top and therefore get their
## own window (and their own single resolution) from the controller's loop:
## recursive multi-effect resolution without ever resolving a block at once.

signal changed()

var entries: Array = []            # LIFO — last element is the top
var resolver: Callable = Callable()  # func(entry: Dictionary) -> Dictionary
var _counters := {"r": 0, "e": 0, "m": 0}

func push(entry: Dictionary) -> Dictionary:
	var kind: String = entry.get("type", "?")
	var prefix := "r"
	match kind:
		"pending_roll": prefix = "r"
		"pending_effect": prefix = "e"
		"modifier": prefix = "m"
		_: prefix = "x"
	_counters[prefix] = _counters.get(prefix, 0) + 1
	entry["id"] = "%s%d" % [prefix, _counters[prefix]]
	entries.append(entry)
	EventBus.stack_entry_pushed.emit(entry.duplicate())
	changed.emit()
	return entry

func pop() -> Dictionary:
	if entries.is_empty():
		return {}
	var entry: Dictionary = entries.pop_back()
	changed.emit()
	return entry

func top() -> Dictionary:
	if entries.is_empty():
		return {}
	return entries[-1]

## By-reference lookup: mutating the returned Dictionary mutates the entry.
func find(id: String) -> Dictionary:
	for entry in entries:
		if entry.get("id", "") == id:
			return entry
	return {}

func top_of_type(type: String) -> Dictionary:
	for i in range(entries.size() - 1, -1, -1):
		if entries[i].get("type", "") == type:
			return entries[i]
	return {}

func size() -> int:
	return entries.size()

func is_empty() -> bool:
	return entries.is_empty()

func clear(reason: String = "") -> void:
	entries.clear()
	EventBus.stack_cleared.emit(reason)
	changed.emit()

## Resolves ONLY the top entry (LIFO) and returns its result. The caller is
## responsible for reopening a priority window if anything is left: this
## class never resolves a block, because one round of passes = one resolution.
func resolve_one() -> Dictionary:
	if entries.is_empty():
		return {}
	var entry: Dictionary = pop()
	var result: Dictionary = await resolver.call(entry)
	EventBus.stack_entry_resolved.emit(entry.duplicate(), result.duplicate())
	return result
