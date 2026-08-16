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
