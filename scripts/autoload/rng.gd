extends Node
## Rng (autoload/singleton)
##
## Centralized randomness. Game code never calls randi_range()/randomize()
## directly — it goes through Rng so that:
##  - determinism comes from one seam (seed_rng) instead of twenty randoms
##  - tests can inject their own RandomNumberGenerator by replacing rng
##  - a future network phase can pass the same rng to every client

var rng := RandomNumberGenerator.new()

func seed_rng(value: int) -> void:
	rng.seed = value

## 1..6 attack roll.
func roll_die() -> int:
	return rng.randi_range(1, 6)

## Fisher-Yates shuffle driven by the injected rng (deck shuffles).
func shuffle(items: Array) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = items[i]
		items[i] = items[j]
		items[j] = tmp