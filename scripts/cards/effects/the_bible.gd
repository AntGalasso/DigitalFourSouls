extends CardEffect
## "Use: deal 3 damage to target monster."
## Active-use treasure: deals 3 damage to the monster whose instance id is in
## the play payload, via the monster_damaged event.

func on_play(payload: Dictionary = {}) -> void:
	var target_id: String = payload.get("target_id", "")
	if target_id == "":
		Log.warn("The Bible: played without a target in the payload")
		return
	EventBus.monster_damaged.emit(target_id, 3)