extends CardEffect
## "Deal 2 damage to target monster."
## Loot card played from hand: deals 2 damage to the monster whose instance
## id is in the play payload, via the monster_damaged event. The turn loop /
## registry supplies the target; this effect never touches other cards.

func on_play(payload: Dictionary = {}) -> void:
	var target_id: String = payload.get("target_id", "")
	if target_id == "":
		Log.warn("Bomb: played without a target in the payload")
		return
	EventBus.monster_damaged.emit(target_id, 2)