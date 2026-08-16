extends CardEffect
## "Soul of Hope" — loot: "If you have 2 or less HP, gain a soul."
## Conditional on-play: grants the black soul only while the player is at
## 2 or less HP (the loop may play it at full HP — then it does nothing).

func on_play(payload: Dictionary = {}) -> void:
	if GameState.players[owning_player_id]["hp"] <= 2:
		GameState.gain_soul(owning_player_id, "black")