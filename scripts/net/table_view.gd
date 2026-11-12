extends Control
## Tavolo Host (M3/M4) — the PC screen when the phones are the controllers.
##
## Purely passive and PUBLIC: it renders `snapshot_for(-1)`, which has no hand
## contents at all (only `hand_count`). M4 turns it from a debug dump into the
## real table: card-shaped monsters with HP bars, the shop with prices, the
## central STACK showing who played what on whom, the public player boards
## (character rotated 90° when tapped, items rotated when spent) and the
## 2.0 s reaction countdown that the phones are racing against.
##
## No input: the table never plays, it only shows what the server decided.
##
## Not a class_name on purpose (headless CLI): preload it.

const Protocol := preload("res://scripts/core/match_protocol.gd")
const CARD_DIR := "res://resources/cards/base_set/"

const BG := Color(0.078, 0.071, 0.11)
const PANEL := Color(0.118, 0.106, 0.161)
const PANEL_HI := Color(0.149, 0.133, 0.2)
const LINE := Color(0.227, 0.204, 0.314)
const TEXT := Color(0.925, 0.91, 0.965)
const MUTED := Color(0.655, 0.624, 0.745)
const GOLD := Color(0.898, 0.71, 0.404)
const GREEN := Color(0.498, 0.82, 0.639)
const RED := Color(0.886, 0.439, 0.478)
const BLUE := Color(0.55, 0.68, 0.95)

var _session = null
var _net = null

var _turn_label: Label
var _url_label: Label
var _seats_label: Label
var _timer_bar: ProgressBar
var _timer_label: Label
var _players_box: HBoxContainer
var _monsters_box: HBoxContainer
var _shop_box: HBoxContainer
var _stack_box: VBoxContainer
var _decks_label: Label
var _log_label: RichTextLabel

func setup(session, net) -> void:
	_session = session
	_net = net
	_build()
	if not _session.changed.is_connected(_refresh):
		_session.changed.connect(_refresh)
	if not _session.message.is_connected(_on_message):
		_session.message.connect(_on_message)
	if _net != null and not _net.seats_changed.is_connected(_refresh):
		_net.seats_changed.connect(_refresh)
	_refresh()

func _build() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	# --- header: turn, address, seats, countdown -----------------------------
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 18)
	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 24)
	_turn_label.add_theme_color_override("font_color", GOLD)
	header.add_child(_turn_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_url_label = Label.new()
	_url_label.add_theme_font_size_override("font_size", 20)
	_url_label.add_theme_color_override("font_color", GREEN)
	header.add_child(_url_label)
	root.add_child(header)

	var seats_row := HBoxContainer.new()
	seats_row.add_theme_constant_override("separation", 14)
	_seats_label = Label.new()
	_seats_label.add_theme_font_size_override("font_size", 14)
	_seats_label.add_theme_color_override("font_color", MUTED)
	seats_row.add_child(_seats_label)
	_timer_bar = ProgressBar.new()
	_timer_bar.custom_minimum_size = Vector2(220, 18)
	_timer_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_timer_bar.max_value = 1000.0
	_timer_bar.value = 0.0
	seats_row.add_child(_timer_bar)
	_timer_label = Label.new()
	_timer_label.add_theme_font_size_override("font_size", 14)
	_timer_label.add_theme_color_override("font_color", GOLD)
	seats_row.add_child(_timer_label)
	root.add_child(seats_row)

	# --- main area: boards | table | log -------------------------------------
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 14)
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(main)

	_players_box = HBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 8)
	_players_box.custom_minimum_size = Vector2(250, 0)
	main.add_child(_players_box)

	var center := VBoxContainer.new()
	center.add_theme_constant_override("separation", 10)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.add_child(center)

	center.add_child(_section_title("MOSTRI IN TAVOLA"))
	_monsters_box = HBoxContainer.new()
	_monsters_box.add_theme_constant_override("separation", 10)
	center.add_child(_monsters_box)

	center.add_child(_section_title("NEGOZIO"))
	_shop_box = HBoxContainer.new()
	_shop_box.add_theme_constant_override("separation", 10)
	center.add_child(_shop_box)

	center.add_child(_section_title("PILA — chi gioca cosa, su chi"))
	var stack_scroll := ScrollContainer.new()
	stack_scroll.custom_minimum_size = Vector2(0, 120)
	stack_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(stack_scroll)
	_stack_box = VBoxContainer.new()
	_stack_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack_scroll.add_child(_stack_box)

	_decks_label = Label.new()
	_decks_label.add_theme_font_size_override("font_size", 14)
	_decks_label.add_theme_color_override("font_color", MUTED)
	center.add_child(_decks_label)

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.scroll_active = true
	_log_label.custom_minimum_size = Vector2(280, 0)
	_log_label.add_theme_font_size_override("normal_font_size", 13)
	main.add_child(_log_label)

func _section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", GOLD)
	return label

# --- Frame loop: the countdown is the only thing that moves every frame --------

func _process(_delta: float) -> void:
	if _session == null:
		return
	var total: int = _session.window_total_ms()
	var remaining: int = _session.window_remaining_ms()
	var open: bool = String(_session.window_kind()) != ""
	if not open or total <= 0:
		_timer_bar.value = 0.0
		_timer_label.text = ""
		_timer_label.add_theme_color_override("font_color", MUTED)
		return
	_timer_bar.max_value = float(total)
	_timer_bar.value = float(remaining)
	_timer_label.text = "%.1f s" % (float(remaining) / 1000.0)
	_timer_label.add_theme_color_override("font_color", RED if remaining < 600 else GOLD)

# --- Render -------------------------------------------------------------------

func _refresh() -> void:
	if _session == null or _session.controller == null:
		return
	var snapshot: Dictionary = _session.controller.snapshot_for(-1)
	_turn_label.text = "TAVOLO — turno %d · P%d · %s" % [
		int(snapshot.get("turn_number", 0)), int(snapshot.get("current_player_index", 0)) + 1,
		String(snapshot.get("phase", "?")).to_upper()]
	if _net != null:
		_url_label.text = "Telefoni: %s" % _net.web_url()
		_seats_label.text = _seats_text()
	else:
		_url_label.text = "Server di rete spento"
		_seats_label.text = ""
	var counts: Dictionary = snapshot.get("deck_counts", {})
	_decks_label.text = "MAZZI  mostri %d · loot %d · scarti %d · tesori %d" % [
		int(counts.get("monster", 0)), int(counts.get("loot", 0)),
		int(counts.get("loot_discard", 0)), int(counts.get("treasure", 0))]
	_render_players(snapshot)
	_render_monsters(snapshot)
	_render_shop(snapshot)
	_render_stack(snapshot)

func _seats_text() -> String:
	var parts: Array = []
	for entry in _net.seat_status():
		parts.append("P%d %s" % [int(entry.get("seat", 0)) + 1,
			"●" if bool(entry.get("connected", false)) else "○"])
	return "POSTI  " + "  ".join(parts)

func _render_players(snapshot: Dictionary) -> void:
	_clear(_players_box)
	for raw_player in snapshot.get("players", []):
		var player: Dictionary = raw_player
		_players_box.add_child(_player_board(player))

## Public board: character (rotated when tapped), HP bar, coins, souls, hand
## COUNT (never contents), items and eternal (rotated when spent).
func _player_board(player: Dictionary) -> Control:
	var active: bool = int(player.get("id", 0)) == int(_session.controller.state.current_player_index)
	var panel := _panel(PANEL_HI if active else PANEL, GOLD if active else LINE)
	panel.custom_minimum_size = Vector2(230, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var head := HBoxContainer.new()
	var who := Label.new()
	who.text = "P%d" % (int(player.get("id", 0)) + 1)
	who.add_theme_color_override("font_color", GOLD)
	who.add_theme_font_size_override("font_size", 16)
	head.add_child(who)
	var name_label := Label.new()
	name_label.text = _name(String(player.get("character_id", "")))
	name_label.add_theme_font_size_override("font_size", 16)
	head.add_child(name_label)
	box.add_child(head)

	var character := _mini_card(_name(String(player.get("character_id", ""))), 64)
	character.modulate = Color(1, 1, 1, 0.55) if bool(player.get("character_tapped", false)) else Color.WHITE
	if bool(player.get("character_tapped", false)):
		_rotate_90(character)
	box.add_child(character)

	box.add_child(_hp_bar(int(player.get("hp", 0)), int(player.get("max_hp", 1)), 1.0))
	var stats := Label.new()
	stats.add_theme_font_size_override("font_size", 14)
	stats.text = "%d¢ · anime %d/4 · mano %d · att %d" % [
		int(player.get("cents", 0)), int(player.get("soul_value", 0)),
		int(player.get("hand_count", 0)), int(player.get("attacks_used", 0))]
	box.add_child(stats)

	var eternal: String = String(player.get("eternal_item_id", ""))
	if eternal != "":
		var eternal_card := _mini_card("ETERNAL " + _name(eternal), 26)
		eternal_card.modulate = Color(1, 1, 1, 0.5) if bool(player.get("eternal_used", false)) else Color.WHITE
		if bool(player.get("eternal_used", false)):
			_rotate_90(eternal_card)
		box.add_child(eternal_card)

	var items: Array = player.get("items_passive", [])
	var tapped: Array = player.get("tapped_items", [])
	if items.is_empty():
		var none := Label.new()
		none.text = "nessun oggetto"
		none.add_theme_font_size_override("font_size", 12)
		none.add_theme_color_override("font_color", MUTED)
		box.add_child(none)
	else:
		var items_caption := Label.new()
		items_caption.text = "OGGETTI"
		items_caption.add_theme_font_size_override("font_size", 11)
		items_caption.add_theme_color_override("font_color", MUTED)
		box.add_child(items_caption)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		box.add_child(row)
		for card_id in items:
			var item_card := _mini_card(_name(String(card_id)), 22)
			if tapped.has(card_id):
				item_card.modulate = Color(1, 1, 1, 0.5)
				_rotate_90(item_card)
			row.add_child(item_card)
	return panel

func _render_monsters(snapshot: Dictionary) -> void:
	_clear(_monsters_box)
	var monsters: Array = snapshot.get("table_monsters", [])
	if monsters.is_empty():
		_monsters_box.add_child(_empty("nessun mostro"))
		return
	for raw_monster in monsters:
		var monster: Dictionary = raw_monster
		var panel := _panel(PANEL, GOLD if bool(monster.get("is_boss", false)) else LINE)
		panel.custom_minimum_size = Vector2(210, 0)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 4)
		panel.add_child(box)

		var title := Label.new()
		title.text = String(monster.get("display_name", "?"))
		title.add_theme_font_size_override("font_size", 17)
		title.add_theme_color_override("font_color", GOLD if bool(monster.get("is_boss", false)) else TEXT)
		box.add_child(title)

		var badges: Array = []
		if bool(monster.get("is_boss", false)):
			badges.append("BOSS")
		if bool(monster.get("shielded", false)):
			badges.append("SCUDO")
		if not badges.is_empty():
			var badge := Label.new()
			badge.text = " · ".join(badges)
			badge.add_theme_font_size_override("font_size", 11)
			badge.add_theme_color_override("font_color", BLUE)
			box.add_child(badge)

		box.add_child(_hp_bar(int(monster.get("hp", 0)), int(monster.get("max_hp", 1)), 1.0))
		var stats := Label.new()
		stats.add_theme_font_size_override("font_size", 13)
		var reward: String = "anima " + String(monster.get("soul_reward", "")) \
			if String(monster.get("soul_reward", "")) != "" else "1¢"
		stats.text = "dado %d · dmg %d · %s" % [
			int(monster.get("die_value", 0)), int(monster.get("damage", 0)), reward]
		box.add_child(stats)

		var ability: String = String(monster.get("effect_description", ""))
		if ability == "":
			ability = String(monster.get("text", ""))
		if ability != "":
			var ability_label := Label.new()
			ability_label.text = ability
			ability_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ability_label.add_theme_font_size_override("font_size", 11)
			ability_label.add_theme_color_override("font_color", MUTED)
			ability_label.custom_minimum_size = Vector2(190, 0)
			box.add_child(ability_label)
		_monsters_box.add_child(panel)

func _render_shop(snapshot: Dictionary) -> void:
	_clear(_shop_box)
	for raw_slot in snapshot.get("shop_slots", []):
		var slot: Dictionary = raw_slot
		var panel := _panel(PANEL, LINE)
		panel.custom_minimum_size = Vector2(190, 0)
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 4)
		panel.add_child(box)
		var title := Label.new()
		title.text = String(slot.get("display_name", "?"))
		title.add_theme_font_size_override("font_size", 16)
		box.add_child(title)
		var cost := Label.new()
		cost.text = "%d¢" % int(slot.get("cost_cents", 0))
		cost.add_theme_color_override("font_color", GOLD)
		box.add_child(cost)
		var description: String = String(slot.get("description", ""))
		if description != "":
			var text := Label.new()
			text.text = description
			text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			text.add_theme_font_size_override("font_size", 11)
			text.add_theme_color_override("font_color", MUTED)
			text.custom_minimum_size = Vector2(175, 0)
			box.add_child(text)
		_shop_box.add_child(panel)

## The pile, TOP FIRST: "P1: Bomb ➔ Gaper" is the line the whole table reads.
func _render_stack(snapshot: Dictionary) -> void:
	_clear(_stack_box)
	var stack: Array = snapshot.get("stack", [])
	if stack.is_empty():
		_stack_box.add_child(_empty("pila vuota"))
		return
	for i in range(stack.size() - 1, -1, -1):
		var entry: Dictionary = stack[i]
		var is_top: bool = i == stack.size() - 1
		var label := Label.new()
		label.add_theme_font_size_override("font_size", 15 if is_top else 13)
		label.add_theme_color_override("font_color", GOLD if is_top else TEXT)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.text = _stack_line(entry, is_top)
		_stack_box.add_child(label)

func _stack_line(entry: Dictionary, is_top: bool) -> String:
	var owner: int = int(entry.get("owner", -1))
	var who: String = ("P%d" % (owner + 1)) if owner >= 0 else "—"
	var kind: String = String(entry.get("type", ""))
	var prefix: String = "▶ " if is_top else "   "
	match kind:
		"pending_effect":
			var target: String = _target_name(String(entry.get("target_id", "")))
			var card: String = _name(String(entry.get("card_id", "")))
			return "%s%s: %s ➔ %s" % [prefix, who, card, target]
		"pending_roll":
			return "%s%s: tira %d vs dado %d" % [prefix, who,
				int(entry.get("value", 0)), int(entry.get("die_value", 0))]
		"modifier":
			return "%s%s: %s (%s)" % [prefix, who,
				String(entry.get("item_name", "modifier")), String(entry.get("effect", ""))]
		"trigger":
			return "%s%s: trigger %s (%s)" % [prefix, _name(String(entry.get("card_id", ""))),
				String(entry.get("trigger", "")), String(entry.get("effect", ""))]
		_:
			return "%s%s: %s" % [prefix, who, kind]

func _target_name(instance_id: String) -> String:
	if instance_id == "":
		return "—"
	for monster in _session.controller.state.table_monsters:
		if String(monster.get("instance_id", "")) == instance_id:
			var card: CardResource = monster.get("card")
			return card.display_name if card != null else instance_id
	return "bersaglio morto"

# --- Small visual building blocks ---------------------------------------------

func _panel(color: Color, border: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", style)
	return panel

func _mini_card(text: String, height: int) -> PanelContainer:
	var panel := _panel(PANEL_HI, LINE)
	panel.custom_minimum_size = Vector2(96, height)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 11)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	panel.add_child(label)
	return panel

## The 90° tap state: the card is still there, just turned sideways.
func _rotate_90(node: Control) -> void:
	node.rotation_degrees = 90.0
	node.pivot_offset = node.size / 2.0
	node.resized.connect(func() -> void:
		node.pivot_offset = node.size / 2.0)

func _hp_bar(hp: int, max_hp: int, _unused: float = 1.0) -> Control:
	var bar := ProgressBar.new()
	bar.max_value = float(maxi(1, max_hp))
	bar.value = float(maxi(0, hp))
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 14)
	var fill := StyleBoxFlat.new()
	fill.bg_color = RED if hp * 3 <= max_hp else GREEN
	fill.set_corner_radius_all(6)
	bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.07, 0.12)
	bg.set_corner_radius_all(6)
	bar.add_theme_stylebox_override("background", bg)
	var wrapper := VBoxContainer.new()
	wrapper.add_child(bar)
	var caption := Label.new()
	caption.text = "HP %d/%d" % [hp, max_hp]
	caption.add_theme_font_size_override("font_size", 11)
	caption.add_theme_color_override("font_color", MUTED)
	wrapper.add_child(caption)
	return wrapper

func _empty(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", MUTED)
	return label

func _clear(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

func _name(card_id: String) -> String:
	if card_id == "":
		return "—"
	var card: CardResource = load(CARD_DIR + card_id + ".tres")
	return card.display_name if card != null else card_id

# --- Log ----------------------------------------------------------------------

func _on_message(msg: Dictionary) -> void:
	if String(msg.get("type", "")) != Protocol.MSG_DOMAIN_EVENT:
		return
	var payload: Dictionary = msg.get("payload", {})
	var data: Dictionary = payload.get("data", {})
	var private_to: int = int(payload.get("private_to", -1))
	var may_see: bool = private_to < 0
	var event: String = String(payload.get("event", ""))
	var who: String = "P%d" % (int(data.get("player_id", 0)) + 1)
	var card: String = _name(String(data.get("card_id", ""))) if may_see else "una carta"
	match event:
		"card_drawn":
			_log_line("%s pesca %s" % [who, card])
		"card_played":
			_log_line("%s gioca %s" % [who, card])
		"card_discarded":
			_log_line("%s scarta %s" % [who, card])
		"item_bought":
			_log_line("%s compra %s" % [who, card])
		"monster_attacked":
			_log_line("%s attacca: %d vs dado %d → %s" % [
				who, int(data.get("roll", 0)), int(data.get("die_value", 0)),
				"HIT" if int(data.get("roll", 0)) >= int(data.get("die_value", 0)) else "MISS"])
		"monster_killed":
			_log_line("[color=#e5b567]mostro ucciso da %s[/color]" % who)
		"eternal_used":
			_log_line("%s attiva %s" % [who, card])
		"souls_changed":
			_log_line("%s: anime %d/4" % [who, int(data.get("total_value", 0))])
		"turn_started":
			_log_line("[b]— turno di %s —[/b]" % who)
		"trigger_pushed":
			_log_line("trigger: %s (%s)" % [_name(String(data.get("card_id", ""))),
				String(data.get("trigger", ""))])
		"effect_fizzled":
			_log_line("[color=#e2707a]%s fizzla: bersaglio sparito[/color]" % _name(String(data.get("card_id", ""))))
		"target_expired":
			_log_line("[color=#e2707a]scelta del bersaglio scaduta[/color]")
		"game_won":
			_log_line("[b]*** %s VINCE ***[/b]" % who)

func _log_line(text: String) -> void:
	_log_label.append_text("> " + text + "\n")
