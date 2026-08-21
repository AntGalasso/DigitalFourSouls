extends RefCounted
class_name CardEffect
## Base interface for scripted card effects.
##
## One subclass per card that needs custom logic (roughly: everything beyond
## "vanilla stat stick"). Subclasses override only the hooks they need.
## The CardEffectRegistry (not yet implemented) instantiates these and wires
## them to EventBus signals listed in CardResource.trigger_events.
##
## Keep each effect file SMALL and SELF-CONTAINED. Do not reach into other
## cards' effect scripts directly — go through EventBus / GameState only.

var owner_card: CardResource
var owning_player_id: int = -1

func setup(card: CardResource, player_id: int) -> void:
	owner_card = card
	owning_player_id = player_id

## Called when the card is actively played from hand (loot/treasure with an
## effect). payload carries targeting/choice info (e.g. {"target_id": "..."}),
## following the EventBus convention that payloads are Dictionaries.
func on_play(payload: Dictionary = {}) -> void:
	pass

## Called when this card is attacked (monster cards).
func on_attacked(_attacker_id: int, _roll: int) -> void:
	pass

## Called when this card (monster) dies.
func on_killed(_killer_id: int) -> void:
	pass

## Generic passive/trigger hook, called by the registry for any subscribed
## EventBus signal not covered by a dedicated hook above.
func on_event(_event_name: String, _payload: Dictionary) -> void:
	pass

## Called by the registry when the owner attacks: bonus added to the attack
## roll. Default 0 — override for conditional modifiers (e.g. based on cents).
func get_roll_bonus() -> int:
	return 0

## Called by the registry when the owner's attack HITS: bonus added to the
## damage dealt to the monster (MP07 G — the resolver always uses the
## character's base damage + this bonus, never a hardcoded value).
func get_damage_bonus() -> int:
	return 0
