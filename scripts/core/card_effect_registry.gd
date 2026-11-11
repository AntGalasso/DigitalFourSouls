extends Node
## CardEffectRegistry (autoload/singleton)
##
## Two card behavior paths, decided per card (never both):
##
##  DATA path (default): CardResource.simple_effect is a keyword applied by
##  _apply_simple_effect(), e.g. "gain_cents" / "gain_hp" / "damage_monster".
##  Trivial cards (the majority of a 300-card set) need nothing but a CSV row.
##  Data-driven passives use trigger_events the same way scripted ones do.
##
##  SCRIPT path (escape hatch): CardResource.effect_script_path points at a
##  CardEffect subclass for cards that need conditions, sequencing or choices.
##  The registry instantiates it, wires trigger_events to EventBus signals,
##  and dispatches on_play / on_attacked / on_killed when the turn loop plays
##  a card or fights a monster.
##
## Every card that enters play (bought treasure, drawn monster) gets an
## instance_id from the turn loop, so multiple copies of the same card never
## collide — _by_card and _owned are keyed by instance_id, not card_id.
## Effects are unmounted (signals disconnected, instance dropped) when their
## card leaves the game, so _effects does not grow without bound.

var _effects: Array = []                       # every live CardEffect instance
var _by_card: Dictionary = {}                  # instance_id -> CardEffect (scripted owned cards)
var _owned: Dictionary = {}                    # player_id -> {instance_id -> CardResource}
var _owned_effects: Dictionary = {}            # player_id -> Array[CardEffect] (scripted owned)
var _monster_by_instance: Dictionary = {}      # monster instance_id -> CardEffect
var _trigger_connections: Array = []           # [{instance_id, signal_name, callable, effect, player_id}]
## Connections are NOT attached to EventBus directly: one dispatcher per signal
## re-emits to them in _policy_order() (active player first, then clockwise,
## same player in registration order) — the deterministic default for
## simultaneous effects (Metaprompt 05, decision c).

func _ready() -> void:
	EventBus.turn_started.connect(_dispatch_turn_started)
	EventBus.card_played.connect(_dispatch_card_played)
	EventBus.monster_killed.connect(_dispatch_monster_killed)

## Drops EVERY effect instance, trigger connection and owned-card record.
## Called by MatchController.teardown(): this autoload outlives a match, so
## without this a restart (reload_current_scene / a new game) inherits the
## previous match's effects, rolled-up bonuses and monster hooks — the exact
## class of bug the audit flagged (C4). Idempotent, safe on a fresh process.
func reset() -> void:
	for effect in _effects:
		if effect != null:
			effect.owning_player_id = -1
	_effects.clear()
	_by_card.clear()
	_owned.clear()
	_owned_effects.clear()
	_monster_by_instance.clear()
	_trigger_connections.clear()

## Registers a card owned by a player (bought treasure): stores it, and if
## scripted, instantiates its effect + subscribes trigger_events.
## instance_id must be unique per copy (the loop assigns it).
func register_card(card: CardResource, player_id: int, instance_id: String) -> void:
	if card == null:
		return
	var owned: Dictionary = _owned.get(player_id, {})
	owned[instance_id] = card
	_owned[player_id] = owned
	if card.effect_script_path != "":
		var effect := _instantiate(card, player_id)
		if effect == null:
			return
		_by_card[instance_id] = effect
		var owned_effects: Array = _owned_effects.get(player_id, [])
		owned_effects.append(effect)
		_owned_effects[player_id] = owned_effects
		for signal_name in card.trigger_events:
			_wire_trigger(effect, instance_id, signal_name)
	elif card.simple_effect != "":
		for signal_name in card.trigger_events:
			_wire_data_trigger(card, player_id, instance_id, signal_name)

## Removes an owned card copy (discarded / leaves game): unmounts its effect
## and disconnects every trigger wired for that instance.
func unregister_card(player_id: int, instance_id: String) -> void:
	var owned: Dictionary = _owned.get(player_id, {})
	owned.erase(instance_id)
	var effect: CardEffect = _by_card.get(instance_id)
	if effect != null:
		_by_card.erase(instance_id)
		var owned_effects: Array = _owned_effects.get(player_id, [])
		owned_effects.erase(effect)
		_unmount(effect)
	_disconnect_connections(instance_id)

## Removes the first owned copy of a given card (e.g. the death penalty picking
## an item by card id): resolves its instance_id, then unregisters it.
func unregister_card_by_card_id(player_id: int, card_id: String) -> void:
	var owned: Dictionary = _owned.get(player_id, {})
	for instance_id in owned.keys():
		var card: CardResource = owned[instance_id]
		if card != null and card.id == card_id:
			unregister_card(player_id, instance_id)
			return

## Registers a monster instance (drawn onto the table) so its on_attacked /
## on_killed hooks can be dispatched. Vanilla/data monsters are skipped.
func register_monster(card: CardResource, instance_id: String) -> void:
	if card == null or card.effect_script_path == "":
		return
	var effect := _instantiate(card, -1)
	if effect == null:
		return
	_monster_by_instance[instance_id] = effect

## Removes a monster instance (killed/removed): unmounts its effect.
func unregister_monster(instance_id: String) -> void:
	var effect: CardEffect = _monster_by_instance.get(instance_id)
	_monster_by_instance.erase(instance_id)
	if effect != null:
		_unmount(effect)

## Plays an active card (loot or active-use treasure): resolves its behavior
## with the given payload (e.g. {"target_id": "..."}). instance_id identifies
## the owned copy; loot drawn from the deck is lazily instantiated, played,
## and unmounted (single use, never accumulates).
func play_card(card: CardResource, player_id: int, payload: Dictionary = {}, instance_id: String = "") -> void:
	if card == null:
		return
	if card.effect_script_path != "":
		var effect: CardEffect = _by_card.get(instance_id)
		if effect == null:
			effect = _instantiate(card, player_id)
		if effect == null:
			return
		effect.on_play(payload)
		if not _by_card.has(instance_id):
			_unmount(effect)
	elif card.simple_effect != "":
		_apply_simple_effect(card, player_id, payload)

## Interprets a data-driven simple_effect. Adding a new pattern here is a
## 3-6 line addition; anything that needs more than that belongs in a script.
func _apply_simple_effect(card: CardResource, player_id: int, payload: Dictionary = {}) -> void:
	match card.simple_effect:
		"gain_cents":
			GameState.gain_cents(player_id, card.simple_effect_value)
		"gain_hp":
			GameState.heal(player_id, card.simple_effect_value)
		"damage_monster":
			var target: String = payload.get("target_id", "")
			if target == "":
				Log.warn("simple_effect 'damage_monster' (card '%s') played without target" % card.id)
				return
			EventBus.monster_damaged.emit(target, card.simple_effect_value)
		_:
			Log.warn("CardEffectRegistry: unknown simple_effect '%s' (card '%s')" % [card.simple_effect, card.id])

## Sum of attack-roll bonuses from cards the player owns: static data
## (CardResource.roll_bonus) plus scripted modifiers (CardEffect.get_roll_bonus).
## The turn loop queries this BEFORE hit/miss resolution.
func get_roll_bonus(player_id: int) -> int:
	var total := 0
	var owned: Dictionary = _owned.get(player_id, {})
	for card in owned.values():
		total += card.roll_bonus
	for effect in _owned_effects.get(player_id, []):
		total += effect.get_roll_bonus()
	return total

## Sum of attack-damage bonuses (MP07 G): static data (CardResource.damage_bonus)
## plus scripted modifiers (CardEffect.get_damage_bonus). The combat resolver
## ALWAYS computes hit damage as the character's base `damage` + this total —
## never a hardcoded value.
func get_damage(player_id: int) -> int:
	var total := 0
	var owned: Dictionary = _owned.get(player_id, {})
	for card in owned.values():
		total += card.damage_bonus
	for effect in _owned_effects.get(player_id, []):
		total += effect.get_damage_bonus()
	return total

func effect_count() -> int:
	return _effects.size()

func notify_monster_attacked(instance_id: String, attacker_id: int, roll: int) -> void:
	var effect: CardEffect = _monster_by_instance.get(instance_id)
	if effect != null:
		effect.on_attacked(attacker_id, roll)

func notify_monster_killed(instance_id: String, killer_id: int) -> void:
	var effect: CardEffect = _monster_by_instance.get(instance_id)
	if effect != null:
		effect.on_killed(killer_id)

func _instantiate(card: CardResource, player_id: int) -> CardEffect:
	var script := load(card.effect_script_path)
	if script == null:
		Log.error("CardEffectRegistry: cannot load %s (card '%s')" % [card.effect_script_path, card.id])
		return null
	var effect: CardEffect = script.new()
	effect.setup(card, player_id)
	_effects.append(effect)
	return effect

## Detaches an effect from every signal and drops it: called when the owning
## card leaves the game (discarded, monster removed, single-use loot resolved).
func _unmount(effect: CardEffect) -> void:
	for conn in _trigger_connections.duplicate():
		if conn["effect"] == effect:
			_trigger_connections.erase(conn)
	_effects.erase(effect)

## Disconnects every trigger wired for one card instance (data-driven cards
## have no CardEffect, so they need their own cleanup path).
func _disconnect_connections(instance_id: String) -> void:
	for conn in _trigger_connections.duplicate():
		if conn["instance_id"] == instance_id:
			_trigger_connections.erase(conn)

## Records one trigger subscription for a scripted effect. The dispatchers in
## _ready re-emit the signal to connections in policy order.
func _wire_trigger(effect: CardEffect, instance_id: String, signal_name: String) -> void:
	match signal_name:
		"turn_started":
			var cb := func(player_id): effect.on_event(signal_name, {"player_id": player_id})
			_trigger_connections.append({"instance_id": instance_id, "signal_name": signal_name, "callable": cb, "effect": effect, "player_id": effect.owning_player_id})
		"card_played":
			var cb := func(player_id, _card_id): effect.on_event(signal_name, {"player_id": player_id})
			_trigger_connections.append({"instance_id": instance_id, "signal_name": signal_name, "callable": cb, "effect": effect, "player_id": effect.owning_player_id})
		"monster_killed":
			var cb := func(player_id, instance_id, _rewards): effect.on_event(signal_name, {"player_id": player_id, "instance_id": instance_id})
			_trigger_connections.append({"instance_id": instance_id, "signal_name": signal_name, "callable": cb, "effect": effect, "player_id": effect.owning_player_id})
		_:
			Log.warn("CardEffectRegistry: no wiring for trigger '%s' (card '%s')" % [signal_name, effect.owner_card.id])

## Records one trigger subscription for a data-driven passive: applies the
## card's simple_effect when the event fires for the owning player
## (player-scoped events) or for any player (game-scoped events like
## monster_killed).
func _wire_data_trigger(card: CardResource, player_id: int, instance_id: String, signal_name: String) -> void:
	match signal_name:
		"turn_started":
			var cb := func(pid): if pid == player_id: _apply_simple_effect(card, player_id, {"player_id": pid})
			_trigger_connections.append({"instance_id": instance_id, "signal_name": signal_name, "callable": cb, "effect": null, "player_id": player_id})
		"card_played":
			var cb := func(pid, _card_id): if pid == player_id: _apply_simple_effect(card, player_id, {"player_id": pid})
			_trigger_connections.append({"instance_id": instance_id, "signal_name": signal_name, "callable": cb, "effect": null, "player_id": player_id})
		"monster_killed":
			var cb := func(pid, iid, _rewards): _apply_simple_effect(card, player_id, {"player_id": pid, "instance_id": iid})
			_trigger_connections.append({"instance_id": instance_id, "signal_name": signal_name, "callable": cb, "effect": null, "player_id": player_id})
		_:
			Log.warn("CardEffectRegistry: no wiring for trigger '%s' (card '%s')" % [signal_name, card.id])

# --- Policy dispatchers (decision c, Metaprompt 05) ---------------------------
## Deterministic default order for simultaneous effects: the ACTIVE player's
## connections first, then the other players clockwise, and within one player
## in registration (= purchase) order. No human choice of order for now.

func _policy_order() -> Array:
	var count := GameState.players.size()
	if count == 0:
		return _trigger_connections.duplicate()
	var active := GameState.current_player_index
	var ordered: Array = []
	for i in range(count):
		var pid := (active + i) % count
		for conn in _trigger_connections:
			if conn["player_id"] == pid:
				ordered.append(conn)
	return ordered

func _dispatch_turn_started(player_id: int) -> void:
	for conn in _policy_order():
		if conn["signal_name"] == "turn_started":
			conn["callable"].call(player_id)

func _dispatch_card_played(player_id: int, card_id: String) -> void:
	for conn in _policy_order():
		if conn["signal_name"] == "card_played":
			conn["callable"].call(player_id, card_id)

func _dispatch_monster_killed(player_id: int, instance_id: String, rewards: Dictionary) -> void:
	for conn in _policy_order():
		if conn["signal_name"] == "monster_killed":
			conn["callable"].call(player_id, instance_id, rewards)