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
## resolve_batch() resolves the entries that were ON THE STACK when the
## priority window closed, strictly top-first (LIFO), without reopening the
## window between them (ESEMPIO 2 step 3: the D6 modifier resolves, then r1
## resolves with its updated value).
##
## It deliberately does NOT assume what the entries are: the old version
## hardcoded "modifier, then its pending_roll", which meant an effect that
## pushed a NEW entry while resolving had nowhere to go and was destroyed by
## reset_combat_state() (audit C1). Resolution is delegated to the `resolver`
## Callable owned by the controller; this class only owns ORDER.
##
## Entries pushed DURING a batch are appended on top and therefore resolved
## inside the same batch (the batch counter is fixed at window close), while
## anything still below them is left for the controller's outer resolution
## loop, which opens a fresh window for it (ratifica #3: recursive
## multi-effect resolution).

signal changed()

const MAX_RESOLUTIONS_PER_BATCH := 64

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

## Resolves the entries present when the window closed, top-first.
## Returns the last pending_roll result if one resolved (the hit/miss the
## attack flow needs), otherwise the last result produced.
func resolve_batch() -> Dictionary:
	var batch: int = entries.size()
	var last_roll: Dictionary = {}
	var last_result: Dictionary = {}
	var guard: int = 0
	while batch > 0 and not entries.is_empty():
		guard += 1
		if guard > MAX_RESOLUTIONS_PER_BATCH:
			Log.error("EventStack: resolution guard tripped (%d entries) — aborting the batch" % entries.size())
			break
		var entry: Dictionary = pop()
		var result: Dictionary = await resolver.call(entry)
		EventBus.stack_entry_resolved.emit(entry.duplicate(), result.duplicate())
		last_result = result
		if entry.get("type", "") == "pending_roll":
			last_roll = result
		batch -= 1
	if not last_roll.is_empty():
		return last_roll
	return last_result
