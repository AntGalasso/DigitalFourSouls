class_name CardImporter
## Shared logic for the CSV -> CardResource import pipeline.
##
## Used by two entry points:
##  - scripts/tools/import_cards.gd  (run from the Godot script editor)
##  - scripts/tools/run_import_cli.gd (headless CLI verification)
##
## Reads data/cards_base_set_template.csv and writes one CardResource .tres
## per row under resources/cards/base_set/. Empty effect_script_path and
## trigger_events fields produce "vanilla" cards with no scripted behavior.
## Re-running the import overwrites every generated .tres (idempotent).

const CARD_RESOURCE_PATH := "res://scripts/core/card_resource.gd"
const DEFAULT_CSV_PATH := "res://data/cards_base_set_template.csv"
const DEFAULT_OUTPUT_DIR := "res://resources/cards/base_set/"

## Returns the number of .tres files written, or -1 on a fatal error.
static func import_from_csv(csv_path: String = DEFAULT_CSV_PATH, output_dir: String = DEFAULT_OUTPUT_DIR) -> int:
	var text := FileAccess.get_file_as_string(csv_path)
	if text.is_empty():
		push_error("CardImporter: cannot read CSV at %s" % csv_path)
		return -1
	var rows := _parse_csv(text)
	if rows.size() < 2:
		push_error("CardImporter: no data rows found in %s" % csv_path)
		return -1
	var headers: Array = rows[0]
	var card_script = load(CARD_RESOURCE_PATH)
	if card_script == null:
		push_error("CardImporter: cannot load %s" % CARD_RESOURCE_PATH)
		return -1
	var type_map := {
		"CHARACTER": card_script.CardType.CHARACTER,
		"MONSTER": card_script.CardType.MONSTER,
		"ITEM_ACTIVE": card_script.CardType.ITEM_ACTIVE,
		"ITEM_PASSIVE": card_script.CardType.ITEM_PASSIVE,
		"LOOT": card_script.CardType.LOOT,
		"TREASURE": card_script.CardType.TREASURE,
		"SOUL": card_script.CardType.SOUL,
		"CURSE": card_script.CardType.CURSE,
	}
	var dir := DirAccess.open("res://")
	if dir == null:
		push_error("CardImporter: cannot open res://")
		return -1
	dir.make_dir_recursive(output_dir.trim_prefix("res://"))
	var created := 0
	var errors: Array = []   # one entry per problem; all problems are reported
	var seen_ids := {}
	for i in range(1, rows.size()):
		var fields: Array = rows[i]
		if fields.size() != headers.size():
			errors.append("row %d: %d fields, expected %d" % [i + 1, fields.size(), headers.size()])
			continue
		var row := {}
		for j in range(headers.size()):
			row[String(headers[j]).strip_edges()] = String(fields[j]).strip_edges()
		var problems: Array = []
		var card_id: String = row.get("id", "")
		if card_id == "":
			problems.append("missing id")
		elif seen_ids.has(card_id):
			problems.append("duplicate id '%s'" % card_id)
		seen_ids[card_id] = true
		var effect_path: String = row.get("effect_script_path", "")
		if effect_path != "" and not FileAccess.file_exists(effect_path):
			problems.append("effect script not found: %s" % effect_path)
		var card = card_script.new()
		_apply_fields(card, row, type_map, problems)
		if not problems.is_empty():
			for problem in problems:
				errors.append("card '%s' (row %d): %s" % [card_id if card_id != "" else "?", i + 1, problem])
			continue
		var err := ResourceSaver.save(card, output_dir + card_id + ".tres")
		if err != OK:
			errors.append("card '%s': failed to save .tres (error %d)" % [card_id, err])
		else:
			created += 1
	if errors.is_empty():
		print("CardImporter: %d cards written to %s, 0 errors" % [created, output_dir])
	else:
		print("CardImporter: %d cards written to %s, %d error(s):" % [created, output_dir, errors.size()])
		for problem in errors:
			print("  - " + problem)
		push_error("CardImporter: import completed with %d error(s)" % errors.size())
	return created if errors.is_empty() else -errors.size()

static func _apply_fields(card: Resource, row: Dictionary, type_map: Dictionary, problems: Array) -> bool:
	var type_name: String = row.get("type", "")
	if not type_map.has(type_name):
		problems.append("unknown card type '%s'" % type_name)
		return false
	card.id = row.get("id", "")
	card.display_name = row.get("display_name", "")
	card.type = type_map[type_name]
	for num_field in ["cost_cents", "die_value", "hp", "roll_bonus", "simple_effect_value", "needs_target", "playable"]:
		var raw: String = row.get(num_field, "")
		if raw != "" and not raw.is_valid_int():
			problems.append("field '%s' is not an integer ('%s')" % [num_field, raw])
			return false
	card.cost_cents = int(row.get("cost_cents", ""))
	card.die_value = int(row.get("die_value", ""))
	card.hp = int(row.get("hp", ""))
	card.roll_bonus = int(row.get("roll_bonus", ""))
	card.needs_target = int(row.get("needs_target", "")) != 0
	card.playable = int(row.get("playable", "")) != 0
	card.soul_reward = row.get("soul_reward", "")
	card.text = row.get("text", "")
	card.effect_script_path = row.get("effect_script_path", "")
	var triggers: String = row.get("trigger_events", "")
	card.trigger_events.clear()
	if triggers != "":
		for t in triggers.split(";"):
			var trimmed := String(t).strip_edges()
			if trimmed != "":
				card.trigger_events.append(trimmed)
	card.simple_effect = row.get("simple_effect", "")
	card.simple_effect_value = int(row.get("simple_effect_value", ""))
	return true

## Minimal CSV parser: handles double-quoted fields and CRLF/LF line endings.
static func _parse_csv(text: String) -> Array:
	var rows: Array = []
	var row: Array = []
	var field := ""
	var in_quotes := false
	var i := 0
	while i < text.length():
		var c: String = text[i]
		if in_quotes:
			if c == '"':
				if i + 1 < text.length() and text[i + 1] == '"':
					field += '"'
					i += 1
				else:
					in_quotes = false
			else:
				field += c
		elif c == '"':
			in_quotes = true
		elif c == ",":
			row.append(field)
			field = ""
		elif c == "\n" or c == "\r":
			if field != "" or not row.is_empty():
				row.append(field)
				rows.append(row)
				row = []
				field = ""
		else:
			field += c
		i += 1
	if field != "" or not row.is_empty():
		row.append(field)
		rows.append(row)
	return rows