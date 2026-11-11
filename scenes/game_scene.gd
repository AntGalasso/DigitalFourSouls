extends Control
## Human hotseat game scene (MP05 + MP06 + MP07). No art: Labels and Buttons only.
## Drives the SAME MatchController as the self-play test — game rules live
## there; this scene only renders state and translates clicks.
##
## MP07 hotseat flow: free action order — buy / attack / play loot in ANY
## order, each limited per turn (1 buy, 1 attack, 1 loot + 1 with the
## character effect) until "END TURN". Attacks are multi-roll sequences; every
## stack item (attack declared, roll, damage, monster death) opens a PRIORITY
## window in which ALL players respond in turn order starting from the active
## player — loot play and eternal items are valid responses (F). STOP attack
## no longer exists (D): an attack only ends when the monster or the player
## dies. Eternal modifiers (D6 / Belial) apply ONLY while the roll is pending,
## right after the roll and before it resolves (B). The shop has exactly 2
## slots refilled from the treasure deck (E). Boss kills become soul cards
## counting soul_value (Monstro = 2) towards the win condition at total 4 (J).
## Turn alternation P1->P2 is now enforced — the pass-device overlay starts
## the NEXT player, never the same one again (A).

const CARD_DIR := "res://resources/cards/base_set/"
const MatchControllerScript := preload("res://scripts/core/match_controller.gd")
const MONSTER_SLOTS := MatchControllerScript.MONSTER_SLOTS
const SHOP_SLOTS := MatchControllerScript.SHOP_SLOTS

var _controller
var _pending_action: String = ""    # "" | "attack" | "target:<hand index>" | "target_item"
var _next_player := 1               # who starts after "Pass the device" (MP07 A fix)
var _priority_open := false
var _priority_player := -1
var _priority_type := ""

var _turn_label: Label
var _hint_label: Label
var _player_labels: Array = []      # [Label P1, Label P2]
var _monster_buttons: Array = []    # [Button x MONSTER_SLOTS]
var _shop_buttons: Array = []       # [Button x SHOP_SLOTS]
var _hand_box: HBoxContainer
var _items_box: HBoxContainer
var _eternal_box: HBoxContainer
var _attack_button: Button
var _resolve_button: Button
var _cancel_button: Button
var _end_button: Button
var _log_label: RichTextLabel
var _overlay: Control
var _overlay_label: Label
var _overlay_box: VBoxContainer
var _overlay_button: Button

func _ready() -> void:
	_controller = MatchControllerScript.new()
	_controller.setup(2, Rng.rng.randi())
	_build_ui()
	EventBus.cents_changed.connect(func(_p, _d, _t): _refresh())
	EventBus.player_healed.connect(_on_player_healed)
	EventBus.player_damaged.connect(_on_player_damaged)
	EventBus.hp_restored.connect(_on_hp_restored)
	EventBus.monsters_restored.connect(_on_monsters_restored)
	EventBus.souls_changed.connect(func(_p, _s, _t): _refresh())
	EventBus.boss_defeated.connect(_on_boss_defeated)
	EventBus.monster_attacked.connect(_on_monster_attacked_log)
	EventBus.monster_damaged.connect(_on_monster_damaged_log)
	EventBus.monster_killed.connect(_on_monster_killed_log)
	EventBus.priority_pending.connect(_on_priority_pending)
	EventBus.priority_closed.connect(_on_priority_closed)
	EventBus.player_died.connect(_on_player_died)
	EventBus.eternal_used.connect(func(_p, _i, _r): _refresh())
	EventBus.card_drawn.connect(_on_card_drawn)
	EventBus.item_bought.connect(func(_p, _id): _refresh())
	EventBus.game_won.connect(_on_game_won)
	_controller.begin_turn(0)
	_refresh()
	_log_line("Welcome to Four Souls (prototype, %d cards). Free order: buy, ATTACK, play loot, use items — then END TURN." % _controller.total_cards_at_setup)

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
	for i in range(MONSTER_SLOTS):
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_monster_pressed.bind(i))
		monsters_row.add_child(button)
		_monster_buttons.append(button)
	root.add_child(monsters_row)

	root.add_child(_section_label("SHOP — 2 slots, click a card to buy it"))
	var shop_row := HBoxContainer.new()
	shop_row.add_theme_constant_override("separation", 8)
	for i in range(SHOP_SLOTS):
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_shop_pressed.bind(i))
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

	root.add_child(_section_label("ETERNAL ITEM — your character's eternal item"))
	_eternal_box = HBoxContainer.new()
	_eternal_box.add_theme_constant_override("separation", 8)
	root.add_child(_eternal_box)

	var actions := HBoxContainer.new()
	_attack_button = Button.new()
	_attack_button.text = "ATTACK (pick a monster)"
	_attack_button.pressed.connect(func(): _pending_action = "attack"; _refresh())
	_resolve_button = Button.new()
	_resolve_button.text = "RESOLVE roll"
	_resolve_button.pressed.connect(_on_resolve_pressed)
	_cancel_button = Button.new()
	_cancel_button.text = "Cancel"
	_cancel_button.pressed.connect(func(): _pending_action = ""; _refresh())
	_end_button = Button.new()
	_end_button.text = "END TURN"
	_end_button.pressed.connect(_on_end_turn)
	actions.add_child(_attack_button)
	actions.add_child(_resolve_button)
	actions.add_child(_cancel_button)
	actions.add_child(_end_button)
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
	_overlay_box = VBoxContainer.new()
	_overlay_box.add_theme_constant_override("separation", 8)
	_overlay_button = Button.new()
	_overlay_button.pressed.connect(_on_overlay_button)
	box.add_child(_overlay_label)
	box.add_child(_overlay_box)
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
		_refresh()
		var monster: Dictionary = _controller.table_monsters[slot]
		var monster_card: CardResource = monster["card"]
		var result: Dictionary = await _controller.attack(instance_id, GameState.current_player_index)
		match result.get("outcome", ""):
			"killed":
				_log_line("attack sequence: %s killed after %d rolls" % [monster_card.display_name, result["steps"]])
			"player_died":
				_log_line("attack sequence: you died after %d rolls" % result["steps"])
			_:
				if not result.get("valid", true):
					if result.has("busy"):
						_log_line("another action is still resolving — try again in a moment")
					elif result.get("limit", false):
						_log_line("attack limit reached (1 attack per turn)")
					else:
						_log_line("you can only attack on your own turn")
		_refresh()
	elif _pending_action.begins_with("target:"):
		var hand_index := int(_pending_action.substr(7))
		_pending_action = ""
		_play_hand_card(hand_index, instance_id)
	elif _pending_action == "target_item":
		_pending_action = ""
		_play_active_item(instance_id)
	_refresh()

func _on_shop_pressed(slot: int) -> void:
	var treasure: CardResource = _controller.get_shop_card(slot)
	if treasure != null and _controller.buy(slot, GameState.current_player_index):
		_log_line("bought %s for %dc" % [treasure.display_name, treasure.cost_cents])
	_refresh()

func _on_hand_pressed(hand_index: int) -> void:
	var card: CardResource = _card_from_hand(hand_index)
	if card == null:
		return
	var pid := GameState.current_player_index
	if _priority_open and _priority_player == pid:
		var target := ""
		if card.needs_target and not _controller.table_monsters.is_empty():
			target = _controller.table_monsters[0]["instance_id"]
		_respond({"action": "loot", "card_id": card.id, "target_id": target})
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
	if not await _controller.play_loot(card, player_id, payload):
		_log_line("can't play %s — one free loot per action phase, then your character is tapped" % card.display_name)
		return
	# the card left the hand inside play_loot(): the UI never mutates state
	_log_line("played %s" % card.display_name)
	_refresh()

func _on_items_use(card: CardResource) -> void:
	var pid := GameState.current_player_index
	if _priority_open and _priority_player == pid:
		var target := ""
		if card.needs_target and not _controller.table_monsters.is_empty():
			target = _controller.table_monsters[0]["instance_id"]
		_respond({"action": "loot", "card_id": card.id, "target_id": target})
		return
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
			await _controller.play_loot(card, player_id, payload)
			_refresh()
			return

## RESOLVE / CONTINUE: closes the window when the ACTIVE player is asked.
func _on_resolve_pressed() -> void:
	_respond({"action": "resolve"})

# --- Priority window (MP07 F) -------------------------------------------------

## One stack item opened a priority window: if the ACTIVE player is asked the
## inline buttons appear (RESOLVE/CONTINUE + hand + eternal); if the OTHER
## player is asked, a pass-the-device overlay offers PASS + their loot and
## eternal item.
func _on_priority_pending(pid: int, stack_type: String, _payload: Dictionary) -> void:
	_priority_open = true
	_priority_player = pid
	_priority_type = stack_type
	if pid != GameState.current_player_index:
		_show_priority_overlay(pid)
	_refresh()

func _on_priority_closed(_stack_type: String, _payload: Dictionary) -> void:
	_priority_open = false
	_priority_player = -1
	_priority_type = ""
	_overlay.visible = false
	_refresh()

func _respond(response: Dictionary) -> void:
	if not _priority_open:
		return
	EventBus.priority_given.emit(_priority_player, response)

func _show_priority_overlay(pid: int) -> void:
	_overlay_label.text = "PRIORITY — P%d must respond" % (pid + 1)
	_overlay_button.visible = false
	for child in _overlay_box.get_children():
		child.queue_free()
	var pass_button := Button.new()
	pass_button.text = "PASS"
	pass_button.pressed.connect(_respond.bind({"action": "pass"}))
	_overlay_box.add_child(pass_button)
	_render_priority_eternal(pid)
	_render_priority_hand(pid)
	_overlay.visible = true

## The other player's eternal item, gated on the pending roll (MP07 B): D6 /
## Belial only while a roll is PENDING on the stack — never before, never
## after. Yum Heart (prevent_damage) answers any window: one button per
## possible player target.
func _render_priority_eternal(pid: int) -> void:
	var player: Dictionary = GameState.players[pid]
	var item: CardResource = _controller.card_resource(player["eternal_item_id"])
	if item == null:
		return
	var pending: bool = not _controller.get_pending_roll().is_empty()
	match item.eternal_action:
		"reroll_die":
			var d6 := Button.new()
			d6.text = "USE %s (reroll the pending roll)" % item.display_name
			d6.disabled = player["eternal_used"] or not pending
			d6.pressed.connect(_respond.bind({"action": "eternal", "payload": {}}))
			_overlay_box.add_child(d6)
		"adjust_die":
			var plus := Button.new()
			plus.text = "%s +1" % item.display_name
			plus.disabled = player["eternal_used"] or not pending
			plus.pressed.connect(_respond.bind({"action": "eternal", "payload": {"delta": 1}}))
			var minus := Button.new()
			minus.text = "%s -1" % item.display_name
			minus.disabled = player["eternal_used"] or not pending
			minus.pressed.connect(_respond.bind({"action": "eternal", "payload": {"delta": -1}}))
			_overlay_box.add_child(plus)
			_overlay_box.add_child(minus)
		"prevent_damage":
			for target in range(GameState.players.size()):
				var shield := Button.new()
				shield.text = "%s on P%d (prevent next damage)" % [item.display_name, target + 1]
				shield.disabled = player["eternal_used"]
				shield.pressed.connect(_respond.bind({"action": "eternal", "payload": {"target_id": target}}))
				_overlay_box.add_child(shield)

## The other player's hand, played as a priority response (their turn loot
## limit and character effect still apply in the engine).
func _render_priority_hand(pid: int) -> void:
	for card_id in GameState.players[pid]["hand"]:
		var card: CardResource = _controller.card_resource(card_id)
		if card == null:
			continue
		var target := ""
		if card.needs_target and not _controller.table_monsters.is_empty():
			target = _controller.table_monsters[0]["instance_id"]
		var button := Button.new()
		button.text = "PLAY %s" % card.display_name
		button.pressed.connect(_respond.bind({"action": "loot", "card_id": card_id, "target_id": target}))
		_overlay_box.add_child(button)

# --- Eternal items (MP06 g) ---------------------------------------------------

func _on_eternal_use(payload: Dictionary) -> void:
	var pid := GameState.current_player_index
	if _priority_open and _priority_player == pid:
		_respond({"action": "eternal", "payload": payload})
		return
	var result: Dictionary = _controller.use_eternal_item(pid, payload)
	if not result.get("ok", false):
		_log_line("eternal item unavailable: %s" % result.get("reason", "?"))
		return
	var item_name: String = _controller.card_resource(GameState.players[pid]["eternal_item_id"]).display_name
	if result.has("new_roll") and result.has("old_roll"):
		_log_line("%s rerolls %d -> %d" % [item_name, result["old_roll"], result["new_roll"]])
	elif result.has("new_roll"):
		_log_line("%s adjusts the roll to %d" % [item_name, result["new_roll"]])
	elif result.has("target_player"):
		_log_line("%s on P%d: next damage this turn is prevented" % [item_name, result["target_player"] + 1])
	elif result.has("target_instance"):
		_log_line("%s on %s: next damage is prevented" % [item_name, result["target_instance"]])
	_refresh()

## Turn alternation fix (MP07 A): remember who starts next, and let the
## pass-device overlay begin THAT player — never the same one again.
func _on_end_turn() -> void:
	_next_player = _controller.end_turn()
	_show_overlay("Pass the device to P%d" % (_next_player + 1), "Start P%d's turn" % (_next_player + 1))

func _on_overlay_button() -> void:
	var pid := _next_player
	_controller.begin_turn(pid)
	_next_player = (pid + 1) % GameState.players.size()
	_overlay.visible = false
	_refresh()

func _show_overlay(text: String, button_text: String) -> void:
	_overlay_label.text = text
	_overlay_button.text = button_text
	_overlay_button.visible = true
	for child in _overlay_box.get_children():
		child.queue_free()
	_overlay.visible = true

## Choice overlay with raw values (Yum Heart targets): one button per option,
## the single action button hidden.
func _show_choice_overlay(text: String, options: Array, on_choose: Callable) -> void:
	var pairs: Array = []
	for option in options:
		pairs.append({"label": str(option), "value": option})
	_show_labeled_choice(text, pairs, on_choose)

## Choice overlay with display labels (card ids are neither readable nor
## unique-looking): pairs are [{label, value}].
func _show_labeled_choice(text: String, pairs: Array, on_choose: Callable) -> void:
	_overlay_label.text = text
	_overlay_button.visible = false
	for child in _overlay_box.get_children():
		child.queue_free()
	for pair in pairs:
		var button := Button.new()
		button.text = String(pair.get("label", "?"))
		button.pressed.connect(on_choose.bind(pair.get("value", "")))
		_overlay_box.add_child(button)
	_overlay.visible = true

# --- State rendering ----------------------------------------------------------

func _refresh() -> void:
	var pid := GameState.current_player_index
	_turn_label.text = "TURN — P%d" % (pid + 1)
	for i in range(2):
		var p: Dictionary = GameState.players[i]
		var active := " (your turn)" if i == pid else ""
		var char_name: String = p["character_id"].trim_prefix("character_").capitalize()
		var char_state := "character ready" if not p["character_tapped"] else "character TAPPED"
		_player_labels[i].text = "P%d%s — %s\n  HP %d/%d   cents %d   souls %s (value %d)\n  items: %s\n  %s (eternal: %s)" % [
			i + 1, active, char_name, p["hp"], p["max_hp"], p["cents"], str(p["souls"]),
			GameState.soul_total(i), str(p["items_passive"]), char_state, p["eternal_item_id"].trim_prefix("eternal_")]
	for slot in range(MONSTER_SLOTS):
		var button: Button = _monster_buttons[slot]
		if slot < _controller.table_monsters.size():
			var monster: Dictionary = _controller.table_monsters[slot]
			var monster_card: CardResource = monster["card"]
			var boss_tag := " — BOSS" if monster_card.is_boss else ""
			button.text = "%s%s\n die %d — hp %d" % [monster_card.display_name, boss_tag, monster_card.die_value, monster["hp"]]
			button.tooltip_text = monster_card.effect_description
			button.disabled = _priority_open
		else:
			button.text = "empty slot"
			button.disabled = true
	var player: Dictionary = GameState.players[pid]
	var buy_limit: bool = player["buys_used"] >= 1
	for i in range(SHOP_SLOTS):
		var button: Button = _shop_buttons[i]
		var treasure: CardResource = _controller.get_shop_card(i)
		if treasure == null:
			button.text = "empty shop"
			button.disabled = true
		elif _priority_open:
			button.text = "%s" % treasure.display_name
			button.disabled = true
		elif buy_limit:
			button.text = "%s — buy limit used" % treasure.display_name
			button.disabled = true
		elif _controller.is_bought(treasure.id, pid):
			button.text = "%s — bought" % treasure.display_name
			button.disabled = true
		elif player["cents"] < treasure.cost_cents:
			button.text = "%s (%dc) — too poor" % [treasure.display_name, treasure.cost_cents]
			button.disabled = true
		else:
			button.text = "%s (%dc)" % [treasure.display_name, treasure.cost_cents]
			button.disabled = false
		button.tooltip_text = treasure.description
	_rebuild_hand()
	_rebuild_items()
	_rebuild_eternal()
	_update_hint()
	_attack_button.disabled = _priority_open or player["attacks_used"] >= 1
	_resolve_button.visible = _priority_open and _priority_player == pid
	if _priority_open and _priority_player == pid:
		_resolve_button.text = "RESOLVE roll" if _priority_type == "roll" else "CONTINUE"
	_cancel_button.disabled = _pending_action == "" or _priority_open
	_end_button.disabled = _priority_open

func _rebuild_hand() -> void:
	for child in _hand_box.get_children():
		child.queue_free()
	var player: Dictionary = GameState.players[GameState.current_player_index]
	var loot_limit: bool = not _controller.can_play_loot(GameState.current_player_index)
	var hand: Array = player["hand"]
	for i in range(hand.size()):
		var card: CardResource = _controller.card_resource(hand[i])
		if card == null:
			continue
		var button := Button.new()
		button.text = "%s — %s" % [card.display_name, _card_summary(card)]
		button.tooltip_text = card.text
		button.pressed.connect(_on_hand_pressed.bind(i))
		if loot_limit:
			button.text += " (limit)"
			button.disabled = true
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
			button.tooltip_text = card.description
			button.pressed.connect(_on_items_use.bind(card))
			_items_box.add_child(button)

func _rebuild_eternal() -> void:
	for child in _eternal_box.get_children():
		child.queue_free()
	var pid := GameState.current_player_index
	var player: Dictionary = GameState.players[pid]
	var item: CardResource = _controller.card_resource(player["eternal_item_id"])
	if item == null:
		return
	var used: bool = player["eternal_used"]
	## MP07 B: D6 / Belial only act while the roll is PENDING — enabled only
	## inside the priority window with a pending roll on the stack.
	var roll_pending: bool = _priority_open and not _controller.get_pending_roll().is_empty()
	match item.eternal_action:
		"reroll_die":
			var d6 := Button.new()
			d6.text = "USE %s (reroll the pending roll)" % item.display_name
			d6.disabled = used or not roll_pending
			d6.pressed.connect(_on_eternal_use.bind({}))
			_eternal_box.add_child(d6)
		"adjust_die":
			var plus := Button.new()
			plus.text = "%s +1" % item.display_name
			plus.disabled = used or not roll_pending
			plus.pressed.connect(_on_eternal_use.bind({"delta": 1}))
			var minus := Button.new()
			minus.text = "%s -1" % item.display_name
			minus.disabled = used or not roll_pending
			minus.pressed.connect(_on_eternal_use.bind({"delta": -1}))
			_eternal_box.add_child(plus)
			_eternal_box.add_child(minus)
		"prevent_damage":
			var yum := Button.new()
			yum.text = "USE %s (prevent next damage)" % item.display_name
			yum.disabled = used
			yum.pressed.connect(_on_yum_heart)
			_eternal_box.add_child(yum)
	if used:
		var note := Label.new()
		note.text = " (recharging%s)" % (" — recharges at the end of your turn" if item.recharges_on_turn_end else "")
		_eternal_box.add_child(note)

func _on_yum_heart() -> void:
	_show_choice_overlay("Yum Heart — prevent damage to which player?", [0, 1], func(choice): _on_eternal_use({"target_id": choice}))

func _update_hint() -> void:
	if _priority_open:
		if _priority_player == GameState.current_player_index:
			_hint_label.text = "Priority window (%s) — play loot / use your eternal item, or RESOLVE" % _priority_type
		else:
			_hint_label.text = "Priority window (%s) — P%d must respond: pass the device" % [_priority_type, _priority_player + 1]
		return
	match _pending_action:
		"":
			_hint_label.text = "Choose: buy, ATTACK, play a card, use an item, or end turn."
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

## The roll line is logged HERE, from monster_attacked, which the controller
## emits AFTER the priority window resolved the pending roll and BEFORE
## applying damage — so the log order is always roll -> damage -> kill.
func _on_monster_attacked_log(_player_id: int, instance_id: String, roll: int, bonus: int, die_value: int) -> void:
	for monster in _controller.table_monsters:
		if monster["instance_id"] == instance_id:
			var bonus_text := (" (+%d bonus)" % bonus) if bonus != 0 else ""
			_log_line("attack %s: roll %d%s vs die %d -> %s" % [
				monster["card"].display_name, roll, bonus_text, die_value,
				"HIT" if roll >= die_value else "MISS"])
			break
	_refresh()

func _on_player_healed(player_id: int, amount: int, _new_total: int) -> void:
	_log_line("P%d gains %d HP" % [player_id + 1, amount])
	_refresh()

func _on_hp_restored(player_id: int, new_total: int) -> void:
	_log_line("end of turn: P%d restores to full HP (%d)" % [player_id + 1, new_total])
	_refresh()

func _on_monsters_restored() -> void:
	_log_line("end of turn: all monsters restore to full HP")
	_refresh()

func _on_player_damaged(player_id: int, amount: int, _source: String) -> void:
	_log_line("P%d takes %d damage" % [player_id + 1, amount])
	_refresh()

## Death is a penalty, not a match over (MP06 f / ratifica #5). The controller
## already took the cent and TAPPED the character + items; the player then
## chooses 1 loot card from their hand and 1 owned item to lose. The next
## player starts after the penalty (MP07 A).
func _on_player_died(player_id: int, penalty: Dictionary) -> void:
	var losses: Array = []
	if penalty.get("cents_lost", false):
		losses.append("1 cent")
	losses.append("character + items tapped")
	_log_line("P%d died — loses %s" % [player_id + 1, ", ".join(losses)])
	_next_player = (player_id + 1) % GameState.players.size()
	var loot_options: Array = penalty.get("loot_options", [])
	if loot_options.size() > 1:
		_show_labeled_choice(
			"P%d died — choose 1 loot card to discard" % (player_id + 1),
			_card_pairs(loot_options),
			func(choice): _on_death_loot_choice(player_id, String(choice), penalty))
	else:
		# 0 or 1 card: nothing to choose — the engine applies the documented
		# automatic fallback only when the hand holds exactly one card.
		_on_death_loot_choice(player_id, String(loot_options[0]) if loot_options.size() == 1 else "", penalty)

## Step 2 of the penalty: the loot is settled, now the item (if any).
func _on_death_loot_choice(player_id: int, loot_id: String, penalty: Dictionary) -> void:
	if loot_id != "":
		_log_line("P%d discards %s" % [player_id + 1, loot_id])
	var options: Array = penalty.get("item_options", [])
	if options.is_empty():
		_resolve_death(player_id, {"loot_id": loot_id, "item_id": ""})
		return
	_show_labeled_choice(
		"Choose an item to lose to the death penalty",
		_card_pairs(options),
		func(choice): _resolve_death(player_id, {"loot_id": loot_id, "item_id": String(choice)}))

func _resolve_death(player_id: int, choice: Dictionary) -> void:
	if String(choice.get("item_id", "")) != "":
		_log_line("P%d loses %s" % [player_id + 1, choice["item_id"]])
	EventBus.player_death_resolved.emit(player_id, choice)
	_show_overlay("P%d died — turn over" % (player_id + 1), "Pass to P%d" % (_next_player + 1))

## [{label: display name, value: card id}] for a choice overlay.
func _card_pairs(card_ids: Array) -> Array:
	var pairs: Array = []
	for card_id in card_ids:
		var card: CardResource = _controller.card_resource(String(card_id))
		pairs.append({"label": card.display_name if card != null else String(card_id), "value": String(card_id)})
	return pairs

func _on_monster_damaged_log(instance_id: String, amount: int) -> void:
	for monster in _controller.table_monsters:
		if monster["instance_id"] == instance_id:
			_log_line("%s takes %d damage (hp %d)" % [monster["card"].display_name, amount, monster["hp"]])
			break
	_refresh()

func _on_monster_killed_log(_player_id: int, _instance_id: String, rewards: Dictionary) -> void:
	_log_line("%s killed!" % _controller.last_killed_monster)
	if rewards.has("soul"):
		_log_line("P%d gains a %s soul (value %d)" % [_player_id + 1, rewards["soul"], rewards.get("soul_value", 1)])
	if rewards.has("cents"):
		_log_line("P%d gains %d cent" % [_player_id + 1, rewards["cents"]])
	_refresh()

## MP07 J: a boss kill is a milestone — one soul card worth soul_value (2).
func _on_boss_defeated(player_id: int, monster_card_id: String, soul_value: int) -> void:
	var card: CardResource = _controller.card_resource(monster_card_id)
	var name: String = card.display_name if card != null else monster_card_id
	_log_line(">>> BOSS SCONFITTO: %s — P%d gains a soul worth %d <<<" % [name, player_id + 1, soul_value])
	_refresh()

func _on_card_drawn(player_id: int, card_id: String, _deck: String) -> void:
	var card: CardResource = _controller.card_resource(card_id)
	if card != null:
		_log_line("P%d draws %s" % [player_id + 1, card.display_name])
	_refresh()

func _on_game_won(player_id: int) -> void:
	var souls: String = str(GameState.players[player_id]["souls"])
	_show_overlay("P%d wins! Souls: %s (total value 4)" % [player_id + 1, souls], "Restart")
	_overlay_button.pressed.disconnect(_on_overlay_button)
	_overlay_button.pressed.connect(_on_game_won_restart)

func _on_game_won_restart() -> void:
	get_tree().reload_current_scene()