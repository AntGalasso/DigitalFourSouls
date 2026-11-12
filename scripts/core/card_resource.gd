extends Resource
class_name CardResource
## Base data container for every card in the game.
##
## IMPORTANT: this resource holds DATA only (stats, metadata). The actual
## effect logic lives in a separate script referenced by `effect_script_path`,
## which must extend CardEffect (see card_effect.gd) and implement the
## relevant hook(s). This split keeps card data importable from CSV/JSON
## while effects stay in version-controlled, testable GDScript.

enum CardType { CHARACTER, MONSTER, ITEM_ACTIVE, ITEM_PASSIVE, LOOT, TREASURE, SOUL, CURSE }

@export var id: String                     # unique stable id, e.g. "monster_gaper"
@export var display_name: String
@export var type: CardType
@export var cost_cents: int = 0             # for shop-buyable items
@export var die_value: int = 0              # monsters: roll needed to hit
@export var hp: int = 0                     # monsters
@export var soul_reward: String = ""        # monster/treasure kill reward, "" if none
@export var text: String = ""               # rules text, for UI only — NOT parsed for logic
@export var effect_script_path: String = "" # path to a CardEffect script, "" if vanilla stat card
@export var trigger_events: Array[String] = [] # which EventBus signals this card cares about
@export var simple_effect: String = ""      # data-driven effect keyword (e.g. "gain_cents"), "" if none
@export var simple_effect_value: int = 0    # argument for simple_effect (e.g. 2 for "gain_cents")
@export var roll_bonus: int = 0             # static +N to owner's attack rolls (data-driven modifier)
@export var needs_target: bool = false      # played from hand: player must pick a monster target
@export var playable: bool = false          # active-use treasure: can be USED from the items area
@export var is_eternal: bool = false        # eternal item (cannot be lost to the death penalty)
@export var eternal_action: String = ""     # "reroll_die" | "adjust_die" | "heal_player"
@export var recharges_on_turn_end: bool = false  # eternal item also recharges at the end of the owner's turn
@export var character_effect: String = ""   # character: "play_loot" (1 extra loot on any turn)
@export var eternal_item_id: String = ""    # character: id of the eternal item card it owns

## MP07 fields (rules-fidelity data, MP07 H/I/J/G):
@export var damage: int = 0                 # characters: base attack damage (1)
@export var damage_bonus: int = 0           # static +N to owner's attack damage (data modifier, G)
@export var description: String = ""        # UI-readable effect description (H)
@export var activation_type: String = ""    # "passive" | "activated_free" | "activated_paid" (H)
@export var activation_cost: String = ""    # human-readable activation cost, e.g. "tap", "3¢" (H)
@export var effect_trigger: String = ""     # monster: "none" | "on_roll" | "on_death" | "on_miss" (I)
@export var effect_condition: String = ""   # monster: condition for the trigger, e.g. "roll == 1" (I)
@export var effect_description: String = "" # monster: effect text (I), "" forbidden (explicit "none")
@export var is_boss: bool = false           # boss: soul card on death, win-condition double count (J)
@export var soul_value: int = 0             # boss: 1 or 2 souls, ONE soul card that counts twice (J)
## M4 TriggerEngine (data path): when `effect_trigger` fires and
## `effect_condition` holds, this keyword is pushed on the stack as a
## "trigger" entry and resolved by scripts/core/trigger_engine.gd.
##   "damage_attacker" | "damage_random_player" | "discard_random" |
##   "gain_cents" | "lose_cents" | "gain_hp" | "skip_draw" | "damage_monster"
@export var trigger_effect: String = ""
## Argument for trigger_effect (damage/cents/cards).
@export var trigger_value: int = 0
