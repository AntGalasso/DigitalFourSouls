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

# --- Combat ---
signal monster_attacked(player_id: int, monster_instance_id: String, roll: int)
signal monster_damaged(monster_instance_id: String, amount: int)
signal monster_killed(player_id: int, monster_instance_id: String, rewards: Dictionary)
signal player_damaged(player_id: int, amount: int, source_id: String)

# --- Cards ---
signal card_drawn(player_id: int, card_id: String, deck: String) # deck: "loot"|"treasure"|"monster"
signal card_played(player_id: int, card_id: String)
signal card_discarded(player_id: int, card_id: String)

# --- Souls / win condition ---
signal soul_gained(player_id: int, soul_type: String, new_total: int)
signal game_won(player_id: int)

# --- Generic hook for card-specific custom effects that don't fit above ---
signal custom_effect(effect_name: String, payload: Dictionary)
