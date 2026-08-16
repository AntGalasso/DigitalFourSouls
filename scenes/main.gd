extends Node
## Minimal Phase-1 main scene: placeholder until the STEP-3 turn loop test
## replaces it. Just proves the project boots and the imported card set loads.

func _ready() -> void:
	var dir := DirAccess.open("res://resources/cards/base_set/")
	if dir == null:
		print("main: no cards found — run the import pipeline first (scripts/tools/import_cards.gd)")
		get_tree().quit(1)
		return
	dir.list_dir_begin()
	var count := 0
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".tres"):
			count += 1
		f = dir.get_next()
	print("Four Souls Digital — project boots OK, %d cards loaded." % count)
	get_tree().quit(0)