extends RefCounted
## TriggerEngine (M4) — data-driven triggers, APNAP order, on the stack.
##
## Before this file the only triggers were the monster hooks wired in
## CardEffectRegistry (scripted on_attacked/on_killed) and the passive treasures
## that reacted to EventBus signals OUTSIDE the stack. Both ignored the priority
## window: a passives' gain happened atomically and nobody could answer.
##
## Now a card declares, in its .tres data:
##     effect_trigger    = "on_roll" | "on_miss" | "on_death" |
##                         "on_monster_killed" | "on_card_played" | "on_turn_start"
##     effect_condition  = "" (always) | "roll == 1" | "hp <= 1" (and/&& chains)
##     trigger_effect    = "damage_attacker" | "damage_random_player" |
##                         "discard_random" | "gain_cents" | "lose_cents" |
##                         "gain_hp" | "skip_draw" | "damage_monster"
##     trigger_value     = the number the effect uses
##
## When the trigger fires, the controller asks this engine to COLLECT matching
## entries. They are pushed on the event stack in APNAP order (Active Player,
## Non-Active Player: active player first, then clockwise), each one resolving
## through its own 2.0 s priority window — so a trigger is answerable exactly
## like a played card.
##
## `effect_trigger = "passive"` means "static data only" (damage_bonus /
## roll_bonus): it never goes on the stack and this engine ignores it.
##
## Not a class_name on purpose (headless CLI): preload it.

const CARD_DIR := "res://resources/cards/base_set/"

## Trigger names this engine understands. Anything else is inert data.
const TRIGGERS := [
	"on_roll", "on_miss", "on_death",
	"on_monster_killed", "on_card_played", "on_turn_start",
]

## Events that belong to ONE player ("when YOU play a card", "at the start of
## YOUR turn"): only that owner's copies fire. "when any player kills" is
## global on purpose (Crow's Heart).
const OWNER_ONLY := ["on_card_played", "on_turn_start"]

## Collects the entries that must go on the stack for `trigger_name`.
## `context` keys (all optional, ints): active_player, attacker, roll,
## die_value, hit, instance_id, card_id, owner.
## Returns dictionaries ready for EventStack.push() ordered APNAP.
func collect(trigger_name: String, context: Dictionary, state) -> Array:
	if state == null or not TRIGGERS.has(trigger_name):
		return []
	var active: int = int(context.get("active_player", state.current_player_index))
	var entries: Array = []
	# 1. Cards OWNED by players (bought treasures), APNAP order.
	for offset in range(state.players.size()):
		var pid: int = (active + offset) % state.players.size()
		var player: Dictionary = state.players[pid]
		if OWNER_ONLY.has(trigger_name) and pid != int(context.get("attacker", pid)):
			continue
		for card_id in player.get("items_passive", []):
			var card: CardResource = _card(String(card_id))
			if card == null or card.effect_trigger != trigger_name:
				continue
			var entry: Dictionary = _entry_for(card, pid, pid, "item", "", context)
			if not entry.is_empty():
				entries.append(entry)
	# 2. Monsters on the table: nobody controls them, they go last, in table
	#    order (deterministic), and their effect hits the attacker/active player.
	for monster in state.table_monsters:
		var monster_card: CardResource = monster.get("card")
		if monster_card == null or monster_card.effect_trigger != trigger_name:
			continue
		var affected: int = int(context.get("attacker", active))
		var monster_entry: Dictionary = _entry_for(
			monster_card, affected, affected, "monster",
			String(monster.get("instance_id", "")), context)
		if not monster_entry.is_empty():
			entries.append(monster_entry)
	return entries

## Pushes the collected entries on the stack (top = last pushed) and announces
## them. Returns the pushed entries in push order.
func push_all(entries: Array, stack) -> Array:
	var pushed: Array = []
	if stack == null:
		return pushed
	for entry in entries:
		var copy: Dictionary = (entry as Dictionary).duplicate(true)
		stack.push(copy)
		EventBus.trigger_pushed.emit(copy.duplicate(true))
		pushed.append(copy)
	return pushed

## Applies one trigger entry. Target validity is checked HERE as well as in the
## controller: a trigger whose monster is gone must fizzle, never crash.
## Returns {applied: bool, fizzled?: bool, reason?: String}.
func resolve(entry: Dictionary, state) -> Dictionary:
	var effect: String = String(entry.get("effect", ""))
	if effect == "":
		return {"applied": false, "reason": "no_effect"}
	var affected: int = int(entry.get("affected", entry.get("owner", 0)))
	var value: int = int(entry.get("value", 1))
	var target_id: String = String(entry.get("target_id", ""))
	var card_id: String = String(entry.get("card_id", ""))
	if target_id != "" and effect == "damage_monster":
		var found := false
		for monster in state.table_monsters:
			if String(monster.get("instance_id", "")) == target_id:
				found = true
				break
		if not found:
			return {"applied": false, "fizzled": true, "reason": "target_gone"}
	match effect:
		"damage_attacker", "damage_player":
			GameState.damage_player(affected, value, "trigger:%s" % card_id)
			return {"applied": true, "damage": value, "target_player": affected}
		"damage_random_player":
			if state.players.is_empty():
				return {"applied": false}
			var victim: int = int(Rng.rng.randi_range(0, state.players.size() - 1))
			GameState.damage_player(victim, value, "trigger:%s" % card_id)
			return {"applied": true, "damage": value, "target_player": victim}
		"discard_random":
			return _discard_random(state, affected, value)
		"gain_cents":
			GameState.gain_cents(affected, value)
			return {"applied": true, "cents": value}
		"lose_cents":
			GameState.lose_cents(affected, value)
			return {"applied": true, "cents": -value}
		"gain_hp":
			GameState.heal(affected, value)
			return {"applied": true, "hp": value}
		"skip_draw":
			var player: Dictionary = state.players[affected]
			player["skip_draw"] = int(player.get("skip_draw", 0)) + value
			return {"applied": true, "skip_draw": value}
		"damage_monster":
			EventBus.monster_damaged.emit(target_id, value)
			return {"applied": true, "damage": value, "target_id": target_id}
		_:
			return {"applied": false, "reason": "unknown_effect"}

# --- Conditions ----------------------------------------------------------------

## Tiny, fail-closed evaluator for the .tres `effect_condition` strings:
##   "" | "none"           -> always true
##   "roll == 1"           -> one comparison against an int in `context`
##   "roll == 1 and hp  <= 1" / "&&" chains -> every clause must hold
## An unknown identifier or a malformed clause is FALSE: a data typo must never
## make an effect fire "always".
func condition_ok(expression: String, context: Dictionary) -> bool:
	var text: String = expression.strip_edges()
	if text == "" or text.to_lower() == "none" or text.to_lower() == "always":
		return true
	var clauses: Array = text.replace("&&", " and ").split(" and ", false)
	if clauses.is_empty():
		return false
	for raw_clause in clauses:
		var clause: String = String(raw_clause).strip_edges()
		var parsed: Dictionary = _parse_comparison(clause)
		if parsed.is_empty():
			Log.warn("TriggerEngine: cannot parse condition '%s' — treating it as false" % clause)
			return false
		var key: String = String(parsed["key"])
		if not context.has(key):
			return false
		var left: int = int(context[key])
		var right: int = int(parsed["value"])
		var ok: bool = false
		match String(parsed["op"]):
			"==": ok = left == right
			"!=": ok = left != right
			">": ok = left > right
			">=": ok = left >= right
			"<": ok = left < right
			"<=": ok = left <= right
		if not ok:
			return false
	return true

func _parse_comparison(clause: String) -> Dictionary:
	for op in ["==", "!=", ">=", "<=", ">", "<"]:
		var index: int = clause.find(op)
		if index <= 0:
			continue
		var key: String = clause.substr(0, index).strip_edges()
		var value_text: String = clause.substr(index + op.length()).strip_edges()
		if key == "" or not key.is_valid_identifier():
			return {}
		if not value_text.is_valid_int():
			return {}
		return {"key": key, "op": op, "value": int(value_text)}
	return {}

# --- Helpers -------------------------------------------------------------------

func _entry_for(card: CardResource, owner: int, affected: int, source: String,
		instance_id: String, context: Dictionary) -> Dictionary:
	if card == null or card.trigger_effect == "":
		return {}
	var trigger: String = card.effect_trigger
	var condition: String = card.effect_condition
	var check_context: Dictionary = context.duplicate(true)
	check_context["owner"] = owner
	check_context["affected"] = affected
	if condition != "" and not condition_ok(condition, check_context):
		return {}
	return {
		"type": "trigger",
		"owner": owner,
		"affected": affected,
		"source": source,
		"instance_id": instance_id,
		"card_id": card.id,
		"trigger": trigger,
		"effect": card.trigger_effect,
		"value": card.trigger_value,
		"target_id": String(context.get("instance_id", "")),
		"condition": condition,
	}

func _discard_random(state, player_id: int, count: int) -> Dictionary:
	var player: Dictionary = state.players[player_id]
	var hand: Array = player["hand"]
	var discarded: Array = []
	for i in range(mini(count, hand.size())):
		var index: int = int(Rng.rng.randi_range(0, hand.size() - 1))
		var card_id: String = String(hand.pop_at(index))
		var card: CardResource = _card(card_id)
		if card != null:
			state.loot_discard.append(card)
		EventBus.card_discarded.emit(player_id, card_id)
		discarded.append(card_id)
	return {"applied": true, "discarded": discarded}

func _card(card_id: String) -> CardResource:
	if card_id == "":
		return null
	return load(CARD_DIR + card_id + ".tres")
