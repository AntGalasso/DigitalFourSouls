@tool
extends EditorScript
## Import pipeline entry point (editor).
##
## Reads data/cards_base_set_template.csv and writes one CardResource .tres
## per row under resources/cards/base_set/.
##
## HOW TO RUN: open this file in the Godot script editor and press
## Ctrl+Shift+X (or Script Editor > File > Run). The import is idempotent —
## re-running overwrites every generated .tres.

func _run() -> void:
	CardImporter.import_from_csv()