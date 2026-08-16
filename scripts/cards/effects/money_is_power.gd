extends CardEffect
## "The Money = Power" — passive treasure (8c): "Your attack rolls gain +1
## for every 4 cents you have."
## Scripted roll modifier, proving the get_roll_bonus() aggregation: the turn
## loop adds this to the roll before comparing against the monster's die.

func get_roll_bonus() -> int:
	return GameState.players[owning_player_id]["cents"] / 4