extends Node
## EventBus (autoload/singleton)
##
## Central publish point for every game event. Cards NEVER call each other
## directly — they subscribe to the signals here and react. This is what
## lets us add new cards without touching the core turn loop.
##
## Naming convention: past tense, snake_case. Payload is always a Dictionary
## so we can add fields later without breaking existing listeners.

# --- Turn structure ---
signal turn_started(player_id: int)
signal turn_ended(player_id: int)
signal phase_changed(player_id: int, phase: String) # "buy" | "attack" | "loot"

# --- Economy ---
signal cents_changed(player_id: int, delta: int, new_total: int)
signal item_bought(player_id: int, card_id: String)
signal player_healed(player_id: int, amount: int, new_total: int)
signal hp_restored(player_id: int, new_total: int)     # end-of-turn full restore (not a heal effect)
signal monsters_restored()                              # end-of-turn full restore for every table monster

# --- Combat ---
## monster_attacked carries the FINAL roll (after D6/Belial modifiers), the
## roll bonus and the monster's die value so UI logs read "roll N vs die M"
## BEFORE any damage event fires.
signal monster_attacked(player_id: int, monster_instance_id: String, roll: int, bonus: int, die_value: int)
signal monster_damaged(monster_instance_id: String, amount: int)
signal monster_killed(player_id: int, monster_instance_id: String, rewards: Dictionary)
signal player_damaged(player_id: int, amount: int, source_id: String)

# --- Priority / stack (MP07 F) -------------------------------------------------
## Generic priority window: whenever something goes on the stack
## (stack_type: "attack_declared" | "roll" | "monster_damage" |
## "player_damage" | "monster_dying"), EVERY player is asked in turn order
## starting from the active player (round-robin, consecutive passes close the
## window). Responses are Dictionaries:
##   {"action": "pass"}                        — nothing to do
##   {"action": "resolve"}                     — close the window (active player)
##   {"action": "loot", "card_id", "target_id"}  — play a loot card (turn loot limit applies)
##   {"action": "eternal", "payload": {...}}   — use the eternal item
## STOP attacks is NOT a rule (MP07 D): the attack only ends when the monster
## dies or the player dies.
signal priority_pending(player_id: int, stack_type: String, payload: Dictionary)
signal priority_given(player_id: int, response: Dictionary)
signal priority_closed(stack_type: String, payload: Dictionary)

# --- Shop (MP07 E): 2 slots, refilled from the treasure deck -------------------
signal shop_refilled(card_id: String, slot: int)

# --- Death (MP06 f): penalty, NOT match over ---
signal player_died(player_id: int, penalty: Dictionary) # {cents_lost, loot_lost, item_options}
signal player_death_resolved(player_id: int, item_id: String)

# --- Eternal items (MP06 g) ---
signal eternal_used(player_id: int, eternal_item_id: String, result: Dictionary)

# --- Cards ---
signal card_drawn(player_id: int, card_id: String, deck: String) # deck: "loot"|"treasure"|"monster"
signal card_played(player_id: int, card_id: String)
signal card_discarded(player_id: int, card_id: String)

# --- Souls / win condition (MP07 J) ---
signal soul_gained(player_id: int, soul_type: String, new_total: int)
signal souls_changed(player_id: int, souls: Array, total_value: int)
signal boss_defeated(player_id: int, monster_card_id: String, soul_value: int)
signal game_won(player_id: int)

# --- Generic hook for card-specific custom effects that don't fit above ---
signal custom_effect(effect_name: String, payload: Dictionary)
