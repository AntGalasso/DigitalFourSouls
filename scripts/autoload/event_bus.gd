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
## MP07 stack build (ESEMPIO 1): advance_active_player() ALWAYS fires at the
## end of the ending phase — active_player_id is shared via GameState.
signal active_player_advanced(previous_id: int, new_id: int)

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
## Generic priority window: whenever an entry sits on top of the stack
## (entry "type": "pending_roll" | "pending_effect" | "modifier"), EVERY
## player WITH an available response is asked in turn order starting from
## the ACTIVE player (round-robin; response-less players are auto-passed by
## the controller, consecutive passes close the window). Responses are
## Dictionaries:
##   {"action": "pass"}                          — nothing to do
##   {"action": "resolve"}                       — close the window (active player)
##   {"action": "loot", "card_id", "target_id"}  — play a loot card ATOMICALLY
##                                                 (turn loot limit applies)
##   {"action": "eternal", "payload": {...}}     — use the eternal item; for
##       D6/Belial this PUSHES a generic "modifier" entry on the stack
## STOP attacks is NOT a rule (MP07 D): the attack only ends when the monster
## dies or the player dies. GENERAL RULE: any pending_* on top opens the
## window to ALL players — never assume only the active player may respond.
signal priority_pending(player_id: int, stack_type: String, payload: Dictionary)
signal priority_given(player_id: int, response: Dictionary)
signal priority_closed(stack_type: String, payload: Dictionary)

# --- Event stack (MP07 build): typed LIFO queue --------------------------------
## Entries are Dictionaries: {"type", "id", ...type fields}. The controller
## resolves the top only after every player passed consecutively; modifiers
## cascade onto their target pending_roll at resolution time.
signal stack_entry_pushed(entry: Dictionary)
signal stack_entry_resolved(entry: Dictionary, result: Dictionary)
signal stack_cleared(reason: String)

# --- Shields / damage prevention (ESEMPIO 4) ------------------------------------
## Yum Heart is a PREVENTION shield (never a heal): applied to a player,
## consumed by the next damage instance or expired unused at the end of the
## OWNER's turn (which also recharges the item).
signal shield_applied(target_player_id: int, source_item_name: String, owner_player_id: int)
signal shield_consumed(target_player_id: int, absorbed_amount: int)
signal shield_expired(target_player_id: int)

# --- Combat lifecycle (ESEMPIO 3) -----------------------------------------------
## Emitted by reset_combat_state() after EVERY combat flow — including the
## "the player died instead of the monster" path — so ATTACK becomes
## available again and the stack is verified empty.
signal combat_state_reset()

# --- Shop (MP07 E): 2 slots, refilled from the treasure deck -------------------
signal shop_refilled(card_id: String, slot: int)

# --- Death (MP06 f / ratifica #5): penalty, NOT match over ---
## penalty: {cents_lost: bool, character_tapped: bool,
##           loot_options: Array[String]  — the hand, the player CHOOSES one
##           item_options: Array[String]  — non-eternal items, one is lost}
## player_death_resolved carries the ANSWER to the death request:
##   {request_id, player_id, loot_id: String, item_id: String}
## Like priority, this is the local UI transport; the authoritative path is
## MatchDriver (see scripts/core/drivers/).
signal player_died(player_id: int, penalty: Dictionary)
signal player_death_resolved(player_id: int, choice: Dictionary)

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
