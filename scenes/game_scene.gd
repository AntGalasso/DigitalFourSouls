extends Control
## Human hotseat game scene (Metaprompt 05, STEP 3-4). No art: Labels and
## Buttons only. Drives the SAME MatchController as the self-play test — game
## rules live there; this scene only renders state and translates clicks.
##
## Hotseat flow: actions are available during the active player's turn; End
## Turn shows a "pass the device" overlay; the next player starts on click.
## Targeting is always an explicit choice: Attack or a needs_target card puts
## the game in targeting mode, then the player clicks ONE of the 3 monster
## slots. The shop shows every treasure at once.

const CARD_DIR := "res://resources/cards/base_set/"
const MatchControllerScript := preload("res://scripts/core/match_controller.gd")

var _controller
var _pending_action: String = ""    # "" | "attack" | "target:<hand index>" | "target_item"

var _turn_label: Label
var _hint_label: Label
var _player_labels: Array = []      # [Label P1, Label P2]
var _monster_buttons: Array = []    # [Button x3]
var _shop_buttons: Array = []       # [Button per treasure]
var _hand_box: HBoxContainer
var _items_box: HBoxContainer
var _cancel_button: Button
var _log_label: RichTextLabel
var _overlay: Control
var _overlay_label: Label
var _overlay_button: Button

func _ready() -> void:
	_controller = MatchControllerScript.new()
	_controller.setup(2, Rng.rng.randi())
	_build_ui()
	EventBus.cents_changed.connect(func(_p, _d, _t): _refresh())
	EventBus.player_healed.connect(_on_player_healed)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.soul_gained.connect(func(_p, _s, _t): _refresh())
	EventBus.monster_damaged.connect(_on_monster_damaged_log)
	EventBus.monster_killed.connect(_on_monster_killed_log)
	EventBus.card_drawn.connect(_on_card_drawn)
	EventBus.item_bought.connect(func(_p, _id): _refresh())
	EventBus.game_won.connect(_on_game_won)
	_controller.begin_turn(0)
	_refresh()
	_log_line("Welcome to Four Souls (prototype, 26 cards). Buy = click a shop card. Attack = ATTACK, then click a monster. Cards in hand = click to play (pick a monster if asked). Use = active items. End Turn = pass the device.")

# --- UI construction ----------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	var header := HBoxContainer.new()
	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 20)
	_hint_label = Label.new()
	_hint_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_turn_label)
	header.add_child(_hint_label)
	root.add_child(header)

	var players_row := HBoxContainer.new()
	players_row.add_theme_constant_override("separation", 8)
	for i in range(2):
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var label := Label.new()
		label.add_theme_constant_override("margin_left", 8)
		label.add_theme_constant_override("margin_right", 8)
		label.add_theme_constant_override("margin_top", 6)
		label.add_theme_constant_override("margin_bottom", 6)
		panel.add_child(label)
		players_row.add_child(panel)
		_player_labels.append(label)
	root.add_child(players_row)

	root.add_child(_section_label("MONSTERS — click a slot to target it"))
	var monsters_row := HBoxContainer.new()
	monsters_row.add_theme_constant_override("separation", 8)
	for i in range(3):
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_monster_pressed.bind(i))
		monsters_row.add_child(button)
		_monster_buttons.append(button)
	root.add_child(monsters_row)

	root.add_child(_section_label("SHOP — click a card to buy it"))
	var shop_row := HBoxContainer.new()
	shop_row.add_theme_constant_override("separation", 8)
	for treasure in _controller.shop:
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_shop_pressed.bind(treasure))
		shop_row.add_child(button)
		_shop_buttons.append(button)
	root.add_child(shop_row)

	root.add_child(_section_label("HAND — click a card to play it"))
	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 8)
	root.add_child(_hand_box)

	root.add_child(_section_label("ITEMS — active items you own"))
	_items_box = HBoxContainer.new()
	_items_box.add_theme_constant_override("separation", 8)
	root.add_child(_items_box)

	var actions := HBoxContainer.new()
	var attack_button := Button.new()
	attack_button.text = "ATTACK (pick a monster)"
	attack_button.pressed.connect(func(): _pending_action = "attack"; _refresh())
	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(func(): _pending_action = ""; _refresh())
	var end_button := Button.new()
	end_button.text = "END TURN"
	end_button.pressed.connect(_on_end_turn)
	actions.add_child(attack_button)
	actions.add_child(_cancel_button)
	actions.add_child(end_button)
	root.add_child(actions)

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.scroll_active = true
	_log_label.custom_minimum_size = Vector2(0, 180)
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log_label)

	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.75)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	_overlay_label = Label.new()
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_label.add_theme_font_size_override("font_size", 24)
	_overlay_button = Button.new()
	_overlay_button.pressed.connect(_on_overlay_button)
	box.add_child(_overlay_label)
	box.add_child(_overlay_button)
	center.add_child(box)
	add_child(_overlay)
	_overlay.visible = false

func _section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))
	return label

# --- Interaction --------------------------------------------------------------

func _on_monster_pressed(slot: int) -> void:
	var instance_id: String = _controller.table_monsters[slot]["instance_id"]
	if _pending_action == "attack":
		_pending_action = ""
		var monster: Dictionary = _controller.table_monsters[slot]
		var monster_card: CardResource = monster["card"]
		var result: Dictionary = _controller.attack(instance_id, GameState.current_player_index)
		var bonus_text := ""
		if result["bonus"] != 0:
			bonus_text = " (+%d bonus)" % result["bonus"]
		_log_line("attack %s: roll %d%s vs die %d -> %s" % [monster_card.display_name, result["roll"], bonus_text, monster_card.die_value, "HIT" if result["hit"] else "MISS"])
	elif _pending_action.begins_with("target:"):
		var hand_index := int(_pending_action.substr(7))
		_pending_action = ""
		_play_hand_card(hand_index, instance_id)
	elif _pending_action == "target_item":
		_pending_action = ""
		_play_active_item(instance_id)
	_refresh()

func _on_shop_pressed(treasure: CardResource) -> void:
	if _controller.buy(treasure, GameState.current_player_index):
		_log_line("bought %s for %dc" % [treasure.display_name, treasure.cost_cents])
	_refresh()

func _on_hand_pressed(hand_index: int) -> void:
	var card: CardResource = _card_from_hand(hand_index)
	if card == null:
		return
	if card.needs_target and not _controller.table_monsters.is_empty():
		_pending_action = "target:%d" % hand_index
		_refresh()
		return
	_play_hand_card(hand_index, "")

func _play_hand_card(hand_index: int, target_id: String) -> void:
	var player_id := GameState.current_player_index
	var card: CardResource = _card_from_hand(hand_index)
	if card == null:
		return
	var payload := {}
	if target_id != "":
		payload = {"target_id": target_id}
	_log_line("played %s" % card.display_name)
	_controller.play_loot(card, player_id, payload)
	GameState.players[player_id]["hand"].erase(card.id)
	_refresh()

func _on_items_use(card: CardResource) -> void:
	if card.needs_target and not _controller.table_monsters.is_empty():
		_pending_action = "target_item"
		_refresh()
		return
	_play_active_item("")

func _play_active_item(target_id: String) -> void:
	var player_id := GameState.current_player_index
	for card_id in GameState.players[player_id]["items_passive"]:
		var card: CardResource = _controller.card_resource(card_id)
		if card != null and card.playable:
			var payload := {}
			if target_id != "":
				payload = {"target_id": target_id}
			_log_line("used %s" % card.display_name)
			_controller.play_loot(card, player_id, payload)
			_refresh()
			return

func _on_end_turn() -> void:
	var next: int = _controller.end_turn()
	_show_overlay("Pass the device to P%d" % (next + 1), "Start P%d's turn" % (next + 1))

func _on_overlay_button() -> void:
	var pid := GameState.current_player_index
	_controller.begin_turn(pid)
	_overlay.visible = false
	_refresh()

func _show_overlay(text: String, button_text: String) -> void:
	_overlay_label.text = text
	_overlay_button.text = button_text
	_overlay.visible = true

# --- State rendering ----------------------------------------------------------

func _refresh() -> void:
	var pid := GameState.current_player_index
	_turn_label.text = "TURN — P%d" % (pid + 1)
	for i in range(2):
		var p := GameState.players[i]
		var active := " (your turn)" if i == pid else ""
		_player_labels[i].text = "P%d%s\n  HP %d   cents %d   souls %s\n  items: %s" % [
			i + 1, active, p["hp"], p["cents"], str(p["souls"]), str(p["items_passive"])]
	for slot in range(3):
		var button: Button = _monster_buttons[slot]
		if slot < _controller.table_monsters.size():
			var monster: Dictionary = _controller.table_monsters[slot]
			var monster_card: CardResource = monster["card"]
			button.text = "%s\n die %d — hp %d" % [monster_card.display_name, monster_card.die_value, monster["hp"]]
			button.disabled = false
		else:
			button.text = "empty slot"
			button.disabled = true
	for i in range(_shop_buttons.size()):
		var button: Button = _shop_buttons[i]
		var treasure: CardResource = _controller.shop[i]
		if _controller.is_bought(treasure.id, pid):
			button.text = "%s — bought" % treasure.display_name
			button.disabled = true
		elif GameState.players[pid]["cents"] < treasure.cost_cents:
			button.text = "%s (%dc) — too poor" % [treasure.display_name, treasure.cost_cents]
			button.disabled = true
		else:
			button.text = "%s (%dc)" % [treasure.display_name, treasure.cost_cents]
			button.disabled = false
	_rebuild_hand()
	_rebuild_items()
	_update_hint()
	_cancel_button.disabled = _pending_action == ""

func _rebuild_hand() -> void:
	for child in _hand_box.get_children():
		child.queue_free()
	var hand: Array = GameState.players[GameState.current_player_index]["hand"]
	for i in range(hand.size()):
		var card: CardResource = _controller.card_resource(hand[i])
		if card == null:
			continue
		var button := Button.new()
		button.text = "%s — %s" % [card.display_name, _card_summary(card)]
		button.pressed.connect(_on_hand_pressed.bind(i))
		_hand_box.add_child(button)

func _rebuild_items() -> void:
	for child in _items_box.get_children():
		child.queue_free()
	var items: Array = GameState.players[GameState.current_player_index]["items_passive"]
	for card_id in items:
		var card: CardResource = _controller.card_resource(card_id)
		if card != null and card.playable:
			var button := Button.new()
			button.text = "USE %s — %s" % [card.display_name, _card_summary(card)]
			button.pressed.connect(_on_items_use.bind(card))
			_items_box.add_child(button)

func _update_hint() -> void:
	match _pending_action:
		"":
			_hint_label.text = "Choose: buy, ATTACK, play a card, or end turn."
		"attack":
			_hint_label.text = "Click the monster you want to attack."
		"target_item":
			_hint_label.text = "Click a monster to target your active item."
		_:
			_hint_label.text = "Click a monster to target this card."

func _card_summary(card: CardResource) -> String:
	if card.simple_effect != "":
		return "%s %d" % [card.simple_effect, card.simple_effect_value]
	return card.text if card.text != "" else card.display_name

func _card_from_hand(hand_index: int) -> CardResource:
	var hand: Array = GameState.players[GameState.current_player_index]["hand"]
	if hand_index < 0 or hand_index >= hand.size():
		return null
	return _controller.card_resource(hand[hand_index])

# --- Event log + overlay ------------------------------------------------------

func _log_line(line: String) -> void:
	_log_label.append_text("> " + line + "\n")

func _on_player_healed(player_id: int, amount: int, _new_total: int) -> void:
	_log_line("P%d gains %d HP" % [player_id + 1, amount])
	_refresh()

func _on_player_damaged(player_id: int, amount: int, _source: String) -> void:
	_log_line("P%d takes %d damage" % [player_id + 1, amount])
	_refresh()
	if GameState.players[player_id]["hp"] <= 0:
		_show_overlay("P%d has died — match over" % (player_id + 1), "Restart")
		_overlay_button.pressed.disconnect(_on_overlay_button)
		_overlay_button.pressed.connect(func(): get_tree().reload_current_scene())

func _on_monster_damaged_log(instance_id: String, amount: int) -> void:
	for monster in _controller.table_monsters:
		if monster["instance_id"] == instance_id:
			_log_line("%s takes %d damage (hp %d)" % [monster["card"].display_name, amount, monster["hp"]])
			break
	_refresh()

func _on_monster_killed_log(_player_id: int, _instance_id: String, rewards: Dictionary) -> void:
	_log_line("%s killed!" % _controller.last_killed_monster)
	if rewards.has("soul"):
		_log_line("P%d gains a %s soul" % [_player_id + 1, rewards["soul"]])
	if rewards.has("cents"):
		_log_line("P%d gains %d cent" % [_player_id + 1, rewards["cents"]])
	_refresh()

func _on_card_drawn(player_id: int, card_id: String, _deck: String) -> void:
	var card: CardResource = _controller.card_resource(card_id)
	if card != null:
		_log_line("P%d draws %s" % [player_id + 1, card.display_name])
	_refresh()

func _on_game_won(player_id: int) -> void:
	_show_overlay("P%d wins with 4 souls!" % (player_id + 1), "Restart")
	_overlay_button.pressed.disconnect(_on_overlay_button)
	_overlay_button.pressed.connect(func(): get_tree().reload_current_scene())

