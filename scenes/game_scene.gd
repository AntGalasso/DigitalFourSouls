extends Control
## PASSIVE hotseat client (M2) — no rules live here.
##
## Before M2 this scene knew the buy limit, picked the first monster as a
## target by itself, mutated hands and gated the D6 on a pending roll: every
## one of those decisions now belongs to the server (ratifica #2).
##
## What it does now:
##  - renders STATE_SNAPSHOT (public table + the local viewer's own hand) and
##    the server-computed `legal` block;
##  - sends COMMANDS through MatchSession (PLAY_LOOT, DECLARE_ATTACK, BUY_SHOP,
##    ACTIVATE_ITEM, SELECT_TARGET, PASS_PRIORITY, CHOOSE_DEATH_PENALTY,
##    END_TURN) and nothing else;
##  - draws the three server requests: PRIORITY_REQUEST (blocking overlay with
##    the legal actions), TARGET_REQUEST (hint + click a monster) and
##    DEATH_PENALTY_REQUEST (two-step choice: loot, then item);
##  - shows a "pass the device" screen so the next player does not see the
##    previous player's hand (the snapshot is buffered until they continue).
##
## Display names come from the card catalogue (presentation only): the ids of
## the cards themselves always come from the snapshot.

const CARD_DIR := "res://resources/cards/base_set/"
const SessionScript := preload("res://scripts/core/match_session.gd")
const Protocol := preload("res://scripts/core/match_protocol.gd")

const DISPLAY_MONSTER_SLOTS := 4
const DISPLAY_SHOP_SLOTS := 2

var _session
var _snapshot: Dictionary = {}
var _legal: Dictionary = {}
var _window: Dictionary = {}
var _death: Dictionary = {}
var _target: Dictionary = {}

var _awaiting_device: bool = false
var _first_turn: bool = true
var _won_shown: bool = false
var _deferred_log: Array = []

var _rendered_window_id: String = ""
var _rendered_death_id: String = ""
var _death_stage: String = ""
var _death_loot_id: String = ""

var _turn_label: Label
var _hint_label: Label
var _player_labels: Array = []
var _monster_buttons: Array = []
var _shop_buttons: Array = []
var _hand_box: HBoxContainer
var _items_box: HBoxContainer
var _eternal_label: Label
var _end_button: Button
var _cancel_button: Button
var _log_label: RichTextLabel
var _overlay: Control
var _overlay_label: Label
var _overlay_box: VBoxContainer
var _overlay_button: Button

func _ready() -> void:
	_build_ui()
	_session = SessionScript.new()
	_session.message.connect(_on_message)
	_session.start(2, Rng.rng.randi())
	_log_line("Four Souls — authoritative session. Click a monster to attack, a card to play.")

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

	root.add_child(_section_label("MONSTERS — click one to attack (or to pick a target)"))
	var monsters_row := HBoxContainer.new()
	monsters_row.add_theme_constant_override("separation", 8)
	for i in range(DISPLAY_MONSTER_SLOTS):
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_monster_pressed.bind(i))
		monsters_row.add_child(button)
		_monster_buttons.append(button)
	root.add_child(monsters_row)

	root.add_child(_section_label("SHOP — click a card to buy it"))
	var shop_row := HBoxContainer.new()
	shop_row.add_theme_constant_override("separation", 8)
	for i in range(DISPLAY_SHOP_SLOTS):
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_shop_pressed.bind(i))
		shop_row.add_child(button)
		_shop_buttons.append(button)
	root.add_child(shop_row)

	root.add_child(_section_label("HAND — your cards this turn"))
	_hand_box = HBoxContainer.new()
	_hand_box.add_theme_constant_override("separation", 8)
	root.add_child(_hand_box)

	root.add_child(_section_label("ITEMS — active items you own"))
	_items_box = HBoxContainer.new()
	_items_box.add_theme_constant_override("separation", 8)
	root.add_child(_items_box)

	_eternal_label = _section_label("ETERNAL ITEM")
	root.add_child(_eternal_label)

	var actions := HBoxContainer.new()
	_end_button = Button.new()
	_end_button.text = "END TURN"
	_end_button.pressed.connect(_on_end_turn)
	_cancel_button = Button.new()
	_cancel_button.text = "Cancel target"
	_cancel_button.visible = false
	_cancel_button.pressed.connect(_on_cancel_target)
	actions.add_child(_end_button)
	actions.add_child(_cancel_button)
	root.add_child(actions)

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.scroll_active = true
	_log_label.custom_minimum_size = Vector2(0, 180)
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log_label)

	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.8)
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

# --- Protocol in --------------------------------------------------------------

func _on_message(msg: Dictionary) -> void:
	var type: String = String(msg.get("type", ""))
	var payload: Dictionary = msg.get("payload", {})
	if type == Protocol.MSG_STATE_SNAPSHOT:
		_snapshot = payload.get("snapshot", {})
		_legal = payload.get("legal", {})
		# The server says whether a request is still open: no stale overlay.
		if String(payload.get("window_kind", "")) == "":
			_window = {}
			_rendered_window_id = ""
		if not _awaiting_device:
			_refresh()
	elif type == Protocol.MSG_PRIORITY_REQUEST:
		_window = payload
		_refresh()
	elif type == Protocol.MSG_TARGET_REQUEST:
		_target = payload
		_refresh()
	elif type == Protocol.MSG_DEATH_PENALTY_REQUEST:
		_death = payload
		_refresh()
	elif type == Protocol.MSG_DOMAIN_EVENT:
		_on_domain_event(payload)

func _on_domain_event(payload: Dictionary) -> void:
	var event: String = String(payload.get("event", ""))
	var data: Dictionary = payload.get("data", {})
	match event:
		"turn_started":
			var pid: int = int(data.get("player_id", 0))
			if _first_turn:
				_first_turn = false
				_log_line("P%d starts (turn 0)" % (pid + 1))
			else:
				_begin_device_handover(pid)
		"card_drawn":
			var who: int = int(data.get("player_id", 0))
			var card_id: String = String(data.get("card_id", ""))
			_log_line("P%d draws %s" % [who + 1, _card_name(card_id) if card_id != "" else "a card"])
		"card_played":
			_log_line("P%d plays %s" % [int(data.get("player_id", 0)) + 1, _card_name(String(data.get("card_id", "")))])
		"card_discarded":
			_log_line("P%d discards %s" % [int(data.get("player_id", 0)) + 1, _card_name(String(data.get("card_id", "")))])
		"item_bought":
			_log_line("P%d buys %s" % [int(data.get("player_id", 0)) + 1, _card_name(String(data.get("card_id", "")))])
		"monster_attacked":
			var bonus: int = int(data.get("bonus", 0))
			var bonus_text: String = (" (+%d)" % bonus) if bonus != 0 else ""
			_log_line("attack: roll %d%s vs die %d -> %s" % [
				int(data.get("roll", 0)), bonus_text, int(data.get("die_value", 0)),
				"HIT" if int(data.get("roll", 0)) >= int(data.get("die_value", 0)) else "MISS"])
		"monster_killed":
			var rewards: Dictionary = data.get("rewards", {})
			_log_line("monster killed!")
			if rewards.has("soul"):
				_log_line("P%d gains a soul (%s)" % [int(data.get("player_id", 0)) + 1, String(rewards["soul"])])
			elif rewards.has("cents"):
				_log_line("P%d gains %d cent" % [int(data.get("player_id", 0)) + 1, int(rewards["cents"])])
		"eternal_used":
			_log_line("P%d uses %s" % [int(data.get("player_id", 0)) + 1, _card_name(String(data.get("item_id", "")))])
		"souls_changed":
			_log_line("P%d souls: %d total" % [int(data.get("player_id", 0)) + 1, int(data.get("total_value", 0))])
		"game_won":
			_log_line("P%d wins the match" % (int(data.get("player_id", 0)) + 1))
	_refresh()

# --- Protocol out -------------------------------------------------------------

func _viewer() -> int:
	return int(_snapshot.get("viewer_player_id", 0))

func _submit(cmd: Dictionary) -> void:
	var result: Dictionary = await _session.submit_command(cmd)
	if not result.get("ok", true):
		_log_line("refused: %s" % String(result.get("error", "?")))
	_refresh()

func _on_shop_pressed(slot: int) -> void:
	await _submit(Protocol.command(Protocol.CMD_BUY_SHOP, _viewer(), {"slot": slot}))

func _on_hand_pressed(card_id: String) -> void:
	await _submit(Protocol.command(Protocol.CMD_PLAY_LOOT, _viewer(), {"card_id": card_id}))

func _on_item_pressed(card_id: String) -> void:
	await _submit(Protocol.command(Protocol.CMD_PLAY_LOOT, _viewer(), {"card_id": card_id}))

func _on_monster_pressed(slot: int) -> void:
	var instance_id: String = _monster_instance(slot)
	if instance_id == "":
		return
	if not _target.is_empty():
		var rid: String = String(_target.get("request_id", ""))
		await _submit(Protocol.command(Protocol.CMD_SELECT_TARGET, _viewer(), {"target_id": instance_id}, rid))
		if String(_target.get("request_id", "")) == rid:
			_target = {}
		_refresh()
		return
	if not _window.is_empty() or not _death.is_empty() or _awaiting_device:
		return
	await _submit(Protocol.command(Protocol.CMD_DECLARE_ATTACK, _viewer(), {"target_id": instance_id}))

func _on_end_turn() -> void:
	await _submit(Protocol.command(Protocol.CMD_END_TURN, _viewer()))

func _on_cancel_target() -> void:
	if _target.is_empty():
		return
	var rid: String = String(_target.get("request_id", ""))
	await _submit(Protocol.command(Protocol.CMD_SELECT_TARGET, _viewer(), {"target_id": ""}, rid))
	_target = {}
	_refresh()

## Answer to a PRIORITY_REQUEST. The request id is part of the answer: the
## server (and then the engine) reject an answer bound to another window.
func _answer_window(rid: String, type: String, payload: Dictionary) -> void:
	var result: Dictionary = await _session.submit_command(
		Protocol.command(type, _viewer(), payload, rid))
	if not result.get("ok", false):
		_log_line("refused: %s" % String(result.get("error", "?")))
	if String(_window.get("request_id", "")) == rid:
		_window = {}
		_rendered_window_id = ""
	_refresh()

func _send_death_choice(rid: String, loot_id: String, item_id: String) -> void:
	var result: Dictionary = await _session.submit_command(
		Protocol.command(Protocol.CMD_CHOOSE_DEATH_PENALTY, _viewer(),
			{"loot_id": loot_id, "item_id": item_id}, rid))
	if not result.get("ok", false):
		_log_line("refused: %s" % String(result.get("error", "?")))
	if String(_death.get("request_id", "")) == rid:
		_death = {}
		_rendered_death_id = ""
	_refresh()

# --- Rendering (read-only: snapshot + legal actions) --------------------------

func _refresh() -> void:
	if _snapshot.is_empty():
		return
	var players: Array = _snapshot.get("players", [])
	var viewer: int = _viewer()
	var active: int = int(_snapshot.get("current_player_index", 0))
	_turn_label.text = "TURN %d — P%d · %s" % [
		int(_snapshot.get("turn_number", 0)), active + 1, String(_snapshot.get("phase", "?"))]
	for i in range(_player_labels.size()):
		if i < players.size():
			_player_labels[i].text = _player_line(players[i], i == viewer)
	_render_monsters()
	_render_shop()
	_render_hand(players, viewer)
	_render_items()
	_render_eternal()
	_end_button.disabled = not bool(_legal.get("can_end_turn", false)) \
		or not _window.is_empty() or not _death.is_empty()
	_cancel_button.visible = not _target.is_empty()
	_update_hint(active, viewer)
	var winner: int = int(_snapshot.get("winner", -1))
	if not _death.is_empty():
		_render_death()
	elif not _window.is_empty():
		_render_window()
	elif winner >= 0:
		_show_win(winner)
	elif not _awaiting_device:
		_overlay.visible = false

func _player_line(p: Dictionary, is_viewer: bool) -> String:
	var tapped: String = "character TAPPED" if bool(p.get("character_tapped", false)) else "character ready"
	var you: String = " (you)" if is_viewer else ""
	return "P%d%s — %s\n  HP %d/%d · %d¢ · soul value %d / 4\n  items: %s\n  %s" % [
		int(p.get("id", 0)) + 1, you, _card_name(String(p.get("character_id", ""))),
		int(p.get("hp", 0)), int(p.get("max_hp", 0)), int(p.get("cents", 0)),
		int(p.get("soul_value", 0)), str(p.get("items_passive", [])), tapped]

func _render_monsters() -> void:
	var monsters: Array = _snapshot.get("table_monsters", [])
	for slot in range(_monster_buttons.size()):
		var button: Button = _monster_buttons[slot]
		if slot >= monsters.size():
			button.text = ""
			button.visible = false
			button.disabled = true
			continue
		var monster: Dictionary = monsters[slot]
		button.visible = true
		var boss: String = " — BOSS" if bool(monster.get("is_boss", false)) else ""
		var shield: String = " [shielded]" if bool(monster.get("shielded", false)) else ""
		button.text = "%s%s%s\n die %d — hp %d" % [
			String(monster.get("display_name", "?")), boss, shield,
			int(monster.get("die_value", 0)), int(monster.get("hp", 0))]
		button.tooltip_text = String(monster.get("effect_description", ""))
		button.disabled = _awaiting_device or not _death.is_empty()

func _render_shop() -> void:
	var shop: Array = _snapshot.get("shop_slots", [])
	var slots: Dictionary = {}
	for entry in _legal.get("shop", []):
		slots[int(entry.get("slot", -1))] = entry
	for i in range(_shop_buttons.size()):
		var button: Button = _shop_buttons[i]
		if i >= shop.size():
			button.text = "empty shop"
			button.disabled = true
			continue
		var card: Dictionary = shop[i]
		var legal_entry: Dictionary = slots.get(i, {})
		var reason: String = "" if bool(legal_entry.get("buyable", false)) else _shop_reason(String(legal_entry.get("reason", "")))
		if reason == "":
			button.text = "%s (%d¢)" % [String(card.get("display_name", "?")), int(card.get("cost_cents", 0))]
			button.disabled = false
		else:
			button.text = "%s (%d¢) — %s" % [String(card.get("display_name", "?")), int(card.get("cost_cents", 0)), reason]
			button.disabled = true
		button.tooltip_text = String(card.get("description", ""))

func _shop_reason(reason: String) -> String:
	match reason:
		"not_your_turn": return "not your turn"
		"buy_used": return "buy limit used"
		"already_bought": return "bought"
		"too_poor": return "too poor"
	return ""

func _render_hand(players: Array, viewer: int) -> void:
	_clear_box(_hand_box)
	if viewer < 0 or viewer >= players.size():
		return
	var hand: Array = (players[viewer] as Dictionary).get("hand", [])
	var playable: Array = _legal.get("loot_playable", [])
	for raw_id in hand:
		var card_id: String = String(raw_id)
		var button := Button.new()
		button.text = _card_name(card_id)
		var card: CardResource = _card(card_id)
		button.tooltip_text = card.description if card != null else ""
		button.disabled = not playable.has(card_id) or not _window.is_empty()
		button.pressed.connect(_on_hand_pressed.bind(card_id))
		_hand_box.add_child(button)

func _render_items() -> void:
	_clear_box(_items_box)
	for raw_id in _legal.get("items_playable", []):
		var card_id: String = String(raw_id)
		var button := Button.new()
		button.text = "USE %s" % _card_name(card_id)
		var card: CardResource = _card(card_id)
		button.tooltip_text = card.description if card != null else ""
		button.disabled = not _window.is_empty()
		button.pressed.connect(_on_item_pressed.bind(card_id))
		_items_box.add_child(button)

func _render_eternal() -> void:
	var eternal: Dictionary = _legal.get("eternal", {})
	if eternal.is_empty():
		_eternal_label.text = "ETERNAL ITEM — none"
		return
	var state: String = "ready" if bool(eternal.get("available", false)) else "recharging"
	if bool(eternal.get("pending_roll", false)):
		state += " (a roll is on the stack)"
	_eternal_label.text = "ETERNAL ITEM — %s (%s)" % [
		_card_name(String(eternal.get("item_id", ""))), state]

func _update_hint(active: int, viewer: int) -> void:
	if not _death.is_empty():
		_hint_label.text = "P%d died — choose the penalty" % (int(_death.get("player_id", 0)) + 1)
	elif not _target.is_empty():
		_hint_label.text = "P%d: click a monster to choose the target" % (int(_target.get("player_id", 0)) + 1)
	elif not _window.is_empty():
		_hint_label.text = "Priority window (%s) — P%d responds" % [
			String(_window.get("stack_type", "")), int(_window.get("player_id", 0)) + 1]
	elif _awaiting_device:
		_hint_label.text = "Pass the device"
	elif active != viewer:
		_hint_label.text = "P%d's turn" % (active + 1)
	else:
		_hint_label.text = "Buy, attack, play a card, or end the turn."

# --- Server requests ----------------------------------------------------------

func _render_window() -> void:
	var rid: String = String(_window.get("request_id", ""))
	if rid == _rendered_window_id and _overlay.visible and _overlay_box.get_child_count() > 0:
		return
	_rendered_window_id = rid
	_rendered_death_id = ""
	_overlay_label.text = "PRIORITY (%s) — P%d must respond" % [
		String(_window.get("stack_type", "")), int(_window.get("player_id", 0)) + 1]
	_overlay_button.visible = false
	_clear_box(_overlay_box)
	_add_overlay_button("PASS", _answer_window.bind(rid, Protocol.CMD_PASS_PRIORITY, {}))
	for raw_action in _window.get("legal_actions", []):
		var action: Dictionary = raw_action
		var kind: String = String(action.get("action", ""))
		if kind == "resolve":
			_add_overlay_button("RESOLVE / CONTINUE", _answer_window.bind(rid, Protocol.CMD_PASS_PRIORITY, {}))
		elif kind == "loot":
			var card_id: String = String(action.get("card_id", ""))
			_add_overlay_button("PLAY %s" % _card_name(card_id),
				_answer_window.bind(rid, Protocol.CMD_PLAY_LOOT, {"card_id": card_id}))
		elif kind == "eternal":
			_add_eternal_buttons(rid, String(action.get("item_action", "")))
	_overlay.visible = true

func _add_eternal_buttons(rid: String, item_action: String) -> void:
	var item_id: String = String(_legal.get("eternal", {}).get("item_id", ""))
	var item_name: String = _card_name(item_id)
	if item_action == "reroll_die":
		_add_overlay_button("USE %s (reroll)" % item_name,
			_answer_window.bind(rid, Protocol.CMD_ACTIVATE_ITEM, {}))
	elif item_action == "adjust_die":
		_add_overlay_button("%s +1" % item_name,
			_answer_window.bind(rid, Protocol.CMD_ACTIVATE_ITEM, {"delta": 1}))
		_add_overlay_button("%s -1" % item_name,
			_answer_window.bind(rid, Protocol.CMD_ACTIVATE_ITEM, {"delta": -1}))
	elif item_action == "prevent_damage":
		for raw_player in _snapshot.get("players", []):
			var pid: int = int((raw_player as Dictionary).get("id", 0))
			_add_overlay_button("%s on P%d" % [item_name, pid + 1],
				_answer_window.bind(rid, Protocol.CMD_ACTIVATE_ITEM, {"target_id": pid}))

## Death penalty: TWO choices, both server-driven (loot first, then item).
func _render_death() -> void:
	var rid: String = String(_death.get("request_id", ""))
	if rid != _rendered_death_id:
		_rendered_death_id = rid
		_rendered_window_id = ""
		_death_stage = "loot"
		_death_loot_id = ""
		_clear_box(_overlay_box)
	var penalty: Dictionary = _death.get("penalty", {})
	var loot_options: Array = penalty.get("loot_options", [])
	var item_options: Array = penalty.get("item_options", [])
	if _death_stage == "done" or _death_stage == "":
		return
	if _death_stage == "loot":
		if loot_options.size() > 1:
			_overlay_label.text = "P%d died — choose 1 loot card to discard" % (int(_death.get("player_id", 0)) + 1)
			_overlay_button.visible = false
			_clear_box(_overlay_box)
			for raw_id in loot_options:
				var card_id: String = String(raw_id)
				_add_overlay_button(_card_name(card_id), _on_death_loot_chosen.bind(rid, card_id))
			_overlay.visible = true
			return
		_death_loot_id = String(loot_options[0]) if loot_options.size() == 1 else ""
		_death_stage = "item"
	if _death_stage == "item":
		if item_options.is_empty():
			_death_stage = "done"
			_send_death_choice.call_deferred(rid, _death_loot_id, "")
			return
		_overlay_label.text = "P%d died — choose an item to lose" % (int(_death.get("player_id", 0)) + 1)
		_overlay_button.visible = false
		_clear_box(_overlay_box)
		for raw_id in item_options:
			var item_id: String = String(raw_id)
			_add_overlay_button(_card_name(item_id), _on_death_item_chosen.bind(rid, item_id))
		_overlay.visible = true

func _on_death_loot_chosen(rid: String, loot_id: String) -> void:
	_death_loot_id = loot_id
	_death_stage = "item"
	_render_death()

func _on_death_item_chosen(rid: String, item_id: String) -> void:
	_death_stage = "done"
	_send_death_choice.call_deferred(rid, _death_loot_id, item_id)

# --- Device handover / win ----------------------------------------------------

func _begin_device_handover(pid: int) -> void:
	_awaiting_device = true
	_overlay_label.text = "Pass the device to P%d" % (pid + 1)
	_overlay_button.text = "Start P%d's turn" % (pid + 1)
	_overlay_button.visible = true
	_clear_box(_overlay_box)
	_overlay.visible = true
	_hint_label.text = "Pass the device"

func _on_overlay_button() -> void:
	if not _awaiting_device:
		return
	_awaiting_device = false
	_overlay.visible = false
	_flush_log()
	_refresh()

func _show_win(pid: int) -> void:
	if _won_shown:
		return
	_won_shown = true
	_overlay_label.text = "P%d wins the match" % (pid + 1)
	_overlay_button.text = "Restart"
	_overlay_button.visible = true
	_clear_box(_overlay_box)
	_overlay_button.pressed.disconnect(_on_overlay_button)
	_overlay_button.pressed.connect(_on_restart)
	_overlay.visible = true

func _on_restart() -> void:
	get_tree().reload_current_scene()

# --- Helpers ------------------------------------------------------------------

func _add_overlay_button(text: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	_overlay_box.add_child(button)

func _clear_box(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

func _monster_instance(slot: int) -> String:
	var monsters: Array = _snapshot.get("table_monsters", [])
	if slot < 0 or slot >= monsters.size():
		return ""
	return String((monsters[slot] as Dictionary).get("instance_id", ""))

func _card(card_id: String) -> CardResource:
	if card_id == "":
		return null
	return load(CARD_DIR + card_id + ".tres")

func _card_name(card_id: String) -> String:
	var card: CardResource = _card(card_id)
	return card.display_name if card != null else card_id

func _log_line(line: String) -> void:
	if _awaiting_device:
		_deferred_log.append(line)
		return
	_log_label.append_text("> " + line + "\n")

func _flush_log() -> void:
	for line in _deferred_log:
		_log_label.append_text("> " + String(line) + "\n")
	_deferred_log.clear()
