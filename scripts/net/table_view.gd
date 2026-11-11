extends Control
## Tavolo Host (M3) — the PC screen when the phones are the controllers.
##
## Purely passive and PUBLIC: it renders `snapshot_for(-1)`, which has no hand
## contents at all (only `hand_count`), plus the network address, the seat
## status, the table, the shop, the stack and the event log. No input.
##
## Not a class_name on purpose (headless CLI): preload it.

const Protocol := preload("res://scripts/core/match_protocol.gd")

var _session = null
var _net = null

var _turn_label: Label
var _url_label: Label
var _seats_label: Label
var _stack_label: Label
var _decks_label: Label
var _players_box: HBoxContainer
var _monsters_box: HBoxContainer
var _shop_box: HBoxContainer
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
		margin.add_theme_constant_override(side, 18)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", 28)
	root.add_child(_turn_label)

	_url_label = Label.new()
	_url_label.add_theme_font_size_override("font_size", 22)
	_url_label.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
	root.add_child(_url_label)

	_seats_label = Label.new()
	_seats_label.add_theme_font_size_override("font_size", 16)
	root.add_child(_seats_label)

	root.add_child(_section("GIOCATORI (plance pubbliche — nessuna mano a schermo)"))
	_players_box = HBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 10)
	root.add_child(_players_box)

	root.add_child(_section("MOSTRI IN TAVOLA"))
	_monsters_box = HBoxContainer.new()
	_monsters_box.add_theme_constant_override("separation", 10)
	root.add_child(_monsters_box)

	root.add_child(_section("NEGOZIO"))
	_shop_box = HBoxContainer.new()
	_shop_box.add_theme_constant_override("separation", 10)
	root.add_child(_shop_box)

	var info_row := HBoxContainer.new()
	info_row.add_theme_constant_override("separation", 24)
	_stack_label = Label.new()
	_decks_label = Label.new()
	info_row.add_child(_stack_label)
	info_row.add_child(_decks_label)
	root.add_child(info_row)

	_log_label = RichTextLabel.new()
	_log_label.bbcode_enabled = true
	_log_label.scroll_active = true
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log_label)

func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.5))
	return label

# --- Render -------------------------------------------------------------------

func _refresh() -> void:
	if _session == null or _session.controller == null:
		return
	var snapshot: Dictionary = _session.controller.snapshot_for(-1)
	var state = _session.controller.state
	_turn_label.text = "TAVOLO — turno %d · P%d · fase %s" % [
		int(snapshot.get("turn_number", 0)), int(snapshot.get("current_player_index", 0)) + 1,
		String(snapshot.get("phase", "?"))]
	if _net != null:
		_url_label.text = "Telefoni: apri %s   ·   websocket ws://%s:%d" % [
			_net.web_url(), _net.lan_ip(), _net.ws_port]
		_seats_label.text = _seats_text()
	else:
		_url_label.text = "Server di rete spento"
		_seats_label.text = ""
	_stack_label.text = "Pila: %d entry%s" % [
		int(snapshot.get("stack_size", 0)),
		(" · tiro pendente %d" % int(snapshot.get("pending_roll", {}).get("roll", 0))) if not (snapshot.get("pending_roll", {}) as Dictionary).is_empty() else ""]
	var counts: Dictionary = snapshot.get("deck_counts", {})
	_decks_label.text = "Mazzi: mostri %d · loot %d (%d scarti) · tesori %d" % [
		int(counts.get("monster", 0)), int(counts.get("loot", 0)),
		int(counts.get("loot_discard", 0)), int(counts.get("treasure", 0))]
	_render_players(snapshot)
	_render_monsters(snapshot)
	_render_shop(snapshot)
	state.phase = state.phase  # keep the reference alive for the linter

func _seats_text() -> String:
	var parts: Array = []
	for entry in _net.seat_status():
		var seat: int = int(entry.get("seat", 0)) + 1
		parts.append("P%d: %s" % [seat, "connesso" if bool(entry.get("connected", false)) else "in attesa"])
	if parts.is_empty():
		return "Nessun posto configurato"
	return "Posti — " + " · ".join(parts)

func _render_players(snapshot: Dictionary) -> void:
	_clear(_players_box)
	for raw_player in snapshot.get("players", []):
		var player: Dictionary = raw_player
		var label := Label.new()
		label.custom_minimum_size = Vector2(280, 0)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var tapped: String = "TAPPATO" if bool(player.get("character_tapped", false)) else "pronto"
		label.text = "P%d — %s\n  HP %d/%d · %d¢ · anime %d/4\n  oggetti: %s\n  mano: %d carte · personaggio %s\n  eterno: %s%s" % [
			int(player.get("id", 0)) + 1, _name(String(player.get("character_id", ""))),
			int(player.get("hp", 0)), int(player.get("max_hp", 0)), int(player.get("cents", 0)),
			int(player.get("soul_value", 0)), _list_names(player.get("items_passive", [])),
			int(player.get("hand_count", 0)), tapped,
			_name(String(player.get("eternal_item_id", ""))),
			" (scaricato)" if bool(player.get("eternal_used", false)) else ""]
		_players_box.add_child(label)

func _render_monsters(snapshot: Dictionary) -> void:
	_clear(_monsters_box)
	var monsters: Array = snapshot.get("table_monsters", [])
	if monsters.is_empty():
		_monsters_box.add_child(_empty_label("nessun mostro"))
		return
	for raw_monster in monsters:
		var monster: Dictionary = raw_monster
		var label := Label.new()
		label.custom_minimum_size = Vector2(200, 0)
		var boss: String = " · BOSS" if bool(monster.get("is_boss", false)) else ""
		var shield: String = " · scudo" if bool(monster.get("shielded", false)) else ""
		label.text = "%s%s%s\n  die %d · hp %d" % [
			String(monster.get("display_name", "?")), boss, shield,
			int(monster.get("die_value", 0)), int(monster.get("hp", 0))]
		_monsters_box.add_child(label)

func _render_shop(snapshot: Dictionary) -> void:
	_clear(_shop_box)
	for raw_slot in snapshot.get("shop_slots", []):
		var slot: Dictionary = raw_slot
		var label := Label.new()
		label.custom_minimum_size = Vector2(220, 0)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.text = "%s\n  %d¢%s" % [
			String(slot.get("display_name", "?")), int(slot.get("cost_cents", 0)),
			"  (già comprata)" if bool(slot.get("bought_by_viewer", false)) else ""]
		_shop_box.add_child(label)

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
			_log_line("%s attacca: tiro %d vs die %d → %s" % [
				who, int(data.get("roll", 0)), int(data.get("die_value", 0)),
				"HIT" if int(data.get("roll", 0)) >= int(data.get("die_value", 0)) else "MISS"])
		"monster_killed":
			_log_line("mostro ucciso da %s" % who)
		"eternal_used":
			_log_line("%s attiva %s" % [who, card])
		"souls_changed":
			_log_line("%s: anime %d/4" % [who, int(data.get("total_value", 0))])
		"turn_started":
			_log_line("— turno di %s —" % who)
		"game_won":
			_log_line("*** %s VINCE ***" % who)

func _log_line(text: String) -> void:
	_log_label.append_text("> " + text + "\n")

func _clear(box: Node) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

func _empty_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label

func _name(card_id: String) -> String:
	if card_id == "":
		return "—"
	var card: CardResource = load("res://resources/cards/base_set/" + card_id + ".tres")
	return card.display_name if card != null else card_id

func _list_names(card_ids: Array) -> String:
	if card_ids.is_empty():
		return "—"
	var names: Array = []
	for card_id in card_ids:
		names.append(_name(String(card_id)))
	return ", ".join(names)
