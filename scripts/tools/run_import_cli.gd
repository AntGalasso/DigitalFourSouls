extends SceneTree
## Headless CLI wrapper for the import pipeline, so the CSV -> .tres step can
## be verified without opening the editor:
##   godot --path <project> --headless -s res://scripts/tools/run_import_cli.gd
## Imports, then reloads every generated .tres and prints its fields.
## Optional user args: <csv_path> <output_dir> (used for import validation).

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var csv_path := "res://data/cards_base_set_template.csv"
	var output_dir := "res://resources/cards/base_set/"
	if args.size() >= 1:
		csv_path = args[0]
	if args.size() >= 2:
		output_dir = args[1]
	var importer = load("res://scripts/tools/card_importer.gd")
	if importer == null:
		push_error("run_import_cli: cannot load CardImporter")
		quit(1)
		return
	importer.import_from_csv(csv_path, output_dir)
	_verify(output_dir)
	quit(0)

func _verify(dir_path: String = "res://resources/cards/base_set/") -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("run_import_cli: output directory not found")
		return
	dir.list_dir_begin()
	var files: Array = []
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".tres"):
			files.append(f)
		f = dir.get_next()
	files.sort()
	print("run_import_cli: %d .tres files:" % files.size())
	for fname in files:
		var card = load(dir_path + fname)
		if card == null:
			push_error("run_import_cli: failed to load %s" % fname)
			continue
		print("  %s | %s | type=%d | cost=%d die=%d hp=%d | effect='%s' | triggers=%s" % [
			card.id, card.display_name, card.type, card.cost_cents, card.die_value,
			card.hp, card.effect_script_path, str(card.trigger_events)])