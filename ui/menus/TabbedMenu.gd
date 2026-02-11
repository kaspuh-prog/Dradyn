extends Control
class_name TabbedMenu

signal tab_selected(index: int)

@export var debug_log: bool = false

@export var right_margin_px: int = 0
@export var top_margin_px: int = 0

@export var content_gap_px: int = 2
@export var content_nudge: Vector2i = Vector2i(0, 0)

@export var toggle_action: StringName = &"ui_inventory"
@export var start_visible: bool = false
@export var alpha_when_visible: float = 0.65

@export var auto_wire_tabs: bool = true

@export var enable_tab_labels: bool = true
@export var ui_font: FontFile
@export var tab_titles: PackedStringArray = PackedStringArray(["Inventory", "Stats", "Skill Tree"])
@export var tab_label_font_size: int = 14
@export var tab_label_nudge: Vector2i = Vector2i(0, -4)
@export var tab_label_font_color: Color = Color8(102, 57, 49, 255)

@export var tab_button_paths: Array[NodePath] = []
@export var tab_button_node_names: PackedStringArray = PackedStringArray(["Tab_Inventory", "Tab_Stats", "Tab_SkillTree"])
@export var content_node_names: PackedStringArray = PackedStringArray(["InventorySheet", "StatsSheet", "SkillTreeSheet"])

@export var currency_value_label_path: NodePath = NodePath("")
@export var inventory_autoload_names: PackedStringArray = PackedStringArray(["InventorySys", "InventorySystem"])

# --- Drag safety toggles ---
@export var relax_mouse_filters_in_content: bool = true
@export var guard_tabbar_from_row_drags: bool = true

# --- UI SFX ----------------------------------------------------------
@export_group("UI SFX")
@export var ui_open_close_event: StringName = &"UI_open_close.mp3"
@export var ui_open_close_volume_db: float = 0.0
@export var ui_tab_change_event: StringName = &"UI_open_close.mp3"
@export var ui_tab_change_volume_db: float = 0.0

@export var audio_autoload_names: PackedStringArray = PackedStringArray(["AudioSys", "AudioSystem"])

var _bg: Control
var _tabs: Control
var _content: Control
var _buttons: Array[TextureButton] = []
var _current_index: int = 0

var _currency_label: Label = null
var _inventory_obj: Object = null
var _currency_connected: bool = false
var _currency_connected_to: Object = null

var _debug_printed_tabs_once: bool = false

# Audio autoload cache
var _audio_obj: Object = null
var _audio_checked_once: bool = false

# Suppress open/close SFX during initial _ready show/hide.
var _suppress_open_close_sfx: bool = true


func _ready() -> void:
	_bg = _get_control("BG")
	_tabs = _get_control("Tabs")
	_content = _ensure_content()

	_call_once__print_tab_buttons()

	mouse_filter = Control.MOUSE_FILTER_PASS
	if _bg != null:
		_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _tabs != null:
		_tabs.mouse_filter = Control.MOUSE_FILTER_PASS
	if _content != null:
		_content.mouse_filter = Control.MOUSE_FILTER_PASS

	if _bg != null and _tabs != null:
		if _bg.z_index >= _tabs.z_index:
			_bg.z_index = _tabs.z_index - 1

	if auto_wire_tabs and _tabs != null:
		_buttons = _collect_tab_buttons(_tabs)
		_connect_tab_buttons(_buttons)
		if enable_tab_labels:
			_ensure_tab_labels(_buttons, tab_titles)
			_apply_font_to_tab_labels(_buttons, ui_font)
			_apply_label_nudge(_buttons, tab_label_nudge)
			_apply_label_color(_buttons, tab_label_font_color)

	# Resolve audio autoload (best-effort).
	_resolve_audio_sys()

	# Initial layout.
	_layout_content_only()
	_move_group_to_top_right()

	if relax_mouse_filters_in_content:
		_relax_content_mouse_filters()

	# Visibility (no SFX on boot).
	_suppress_open_close_sfx = true
	if start_visible:
		_show_menu()
	else:
		_hide_menu()
	_suppress_open_close_sfx = false

	# Ensure we actually show current content once.
	_show_content_for_index(_current_index)

	get_viewport().size_changed.connect(_on_viewport_size_changed)


func _show_menu() -> void:
	if not _suppress_open_close_sfx:
		_play_ui_sound(ui_open_close_event, ui_open_close_volume_db)

	visible = true
	modulate = Color(1.0, 1.0, 1.0, alpha_when_visible)
	_layout_content_only()
	_move_group_to_top_right()
	_show_content_for_index(_current_index)


func _hide_menu() -> void:
	if not _suppress_open_close_sfx:
		_play_ui_sound(ui_open_close_event, ui_open_close_volume_db)

	visible = false
	modulate = Color(1.0, 1.0, 1.0, alpha_when_visible)


func _get_control(name_in_owner: String) -> Control:
	if has_node(name_in_owner):
		var c: Control = get_node(name_in_owner) as Control
		return c
	return null


func _ensure_content() -> Control:
	if has_node("Content"):
		return $Content as Control
	var c: Control = Control.new()
	c.name = "Content"
	add_child(c)
	return c


# -------- Tabs wiring ----------
func _collect_tab_buttons(container: Control) -> Array[TextureButton]:
	var out: Array[TextureButton] = []

	if tab_button_paths.size() > 0:
		var i: int = 0
		while i < tab_button_paths.size():
			var p: NodePath = tab_button_paths[i]
			if p != NodePath("") and has_node(p):
				var tb: TextureButton = get_node(p) as TextureButton
				if tb != null:
					out.append(tb)
			i += 1
		if out.size() > 0:
			return out

	if _tabs != null and tab_button_node_names.size() > 0:
		var j: int = 0
		while j < tab_button_node_names.size():
			var nm: String = tab_button_node_names[j]
			if _tabs.has_node(nm):
				var tb2: TextureButton = _tabs.get_node(nm) as TextureButton
				if tb2 != null:
					out.append(tb2)
			j += 1
		if out.size() > 0:
			return out

	var stack: Array[Node] = [container]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		var tb3: TextureButton = n as TextureButton
		if tb3 != null:
			out.append(tb3)
		var k: int = 0
		while k < n.get_child_count():
			stack.append(n.get_child(k))
			k += 1

	return out


func _connect_tab_buttons(buttons: Array[TextureButton]) -> void:
	var i: int = 0
	while i < buttons.size():
		var btn: TextureButton = buttons[i]
		if is_instance_valid(btn):
			var conns: Array = btn.pressed.get_connections()
			var j: int = 0
			while j < conns.size():
				var info: Dictionary = conns[j]
				if info.has("callable"):
					var cb: Callable = info["callable"]
					btn.pressed.disconnect(cb)
				j += 1
			btn.pressed.connect(_on_tab_pressed.bind(i))
		i += 1


# -------- Content layout ----------
func _layout_content_only() -> void:
	if _bg == null:
		return
	if _content == null:
		return

	var bg_pos: Vector2 = _bg.position
	var bg_size: Vector2 = _bg.size

	var top_y: float = bg_pos.y
	if _tabs != null:
		var tabs_bottom: float = _tabs.position.y + _tabs.size.y
		if tabs_bottom + float(content_gap_px) > top_y:
			top_y = tabs_bottom + float(content_gap_px)

	var desired_pos: Vector2 = Vector2(bg_pos.x, top_y) + Vector2(float(content_nudge.x), float(content_nudge.y))
	_content.anchor_left = 0.0
	_content.anchor_top = 0.0
	_content.anchor_right = 0.0
	_content.anchor_bottom = 0.0
	_content.position = desired_pos

	var remaining_h: float = (bg_pos.y + bg_size.y) - desired_pos.y
	if remaining_h < 0.0:
		remaining_h = 0.0
	_content.custom_minimum_size = Vector2(bg_size.x, remaining_h)
	_content.visible = true


# -------- Move whole group ----------
func _move_group_to_top_right() -> void:
	var have_any: bool = false
	var group_left: float = 0.0
	var group_top: float = 0.0
	var group_right: float = 0.0

	if _bg != null:
		var r_bg_right: float = _bg.position.x + _bg.size.x
		group_left = _bg.position.x
		group_top = _bg.position.y
		group_right = r_bg_right
		have_any = true

	if _tabs != null:
		var r_tabs_left: float = _tabs.position.x
		var r_tabs_top: float = _tabs.position.y
		var r_tabs_right: float = _tabs.position.x + _tabs.size.x
		if not have_any:
			group_left = r_tabs_left
			group_top = r_tabs_top
			group_right = r_tabs_right
			have_any = true
		else:
			if r_tabs_left < group_left:
				group_left = r_tabs_left
			if r_tabs_top < group_top:
				group_top = r_tabs_top
			if r_tabs_right > group_right:
				group_right = r_tabs_right

	if not have_any:
		return

	var vp: Rect2 = get_viewport_rect()
	var desired_right: float = vp.size.x - float(right_margin_px)
	var desired_top: float = float(top_margin_px)

	var current: Vector2 = position
	var delta_x: float = (desired_right - (current.x + group_right))
	var delta_y: float = (desired_top   - (current.y + group_top))
	position = current + Vector2(delta_x, delta_y)


# -------- Handlers ----------
func _on_viewport_size_changed() -> void:
	_layout_content_only()
	_move_group_to_top_right()
	_show_content_for_index(_current_index)
	if enable_tab_labels and _buttons.size() > 0:
		_apply_label_nudge(_buttons, tab_label_nudge)
		_apply_label_color(_buttons, tab_label_font_color)
	if relax_mouse_filters_in_content:
		_relax_content_mouse_filters()


func _on_tab_pressed(index: int) -> void:
	_play_ui_sound(ui_tab_change_event, ui_tab_change_volume_db)

	_current_index = index
	_show_content_for_index(index)
	emit_signal("tab_selected", index)


# -------- Public API ----------
func get_selected_index() -> int:
	return _current_index


# -------- Tab label helpers ----------
func _ensure_tab_labels(buttons: Array[TextureButton], titles: PackedStringArray) -> void:
	var i: int = 0
	while i < buttons.size():
		var tb: TextureButton = buttons[i]
		if tb != null:
			var title_text: String = ""
			if i < titles.size():
				title_text = titles[i]
			_set_tab_label(tb, title_text)
		i += 1


func _set_tab_label(tb: TextureButton, text: String) -> void:
	if tb == null:
		return
	var label: Label = tb.get_node_or_null("Label")
	if label == null:
		label = Label.new()
		label.name = "Label"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.anchor_left = 0.0
		label.anchor_top = 0.0
		label.anchor_right = 1.0
		label.anchor_bottom = 1.0
		label.grow_horizontal = Control.GROW_DIRECTION_BOTH
		label.grow_vertical = Control.GROW_DIRECTION_BOTH
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		tb.add_child(label)
	label.text = text


func _apply_font_to_tab_labels(buttons: Array[TextureButton], font_res: FontFile) -> void:
	var i: int = 0
	while i < buttons.size():
		var tb: TextureButton = buttons[i]
		if tb != null:
			var label: Label = tb.get_node_or_null("Label")
			if label != null:
				if font_res != null:
					label.add_theme_font_override(&"font", font_res)
				label.add_theme_font_size_override(&"font_size", tab_label_font_size)
		i += 1


func _apply_label_nudge(buttons: Array[TextureButton], nudge: Vector2i) -> void:
	var i: int = 0
	while i < buttons.size():
		var tb: TextureButton = buttons[i]
		if tb != null:
			var label: Label = tb.get_node_or_null("Label")
			if label != null:
				label.anchor_left = 0.0
				label.anchor_right = 1.0
				label.anchor_top = 0.0
				label.anchor_bottom = 1.0
				label.offset_left = float(nudge.x) * -1.0
				label.offset_right = float(nudge.x) * -1.0
				label.offset_top = float(nudge.y) * -1.0
				label.offset_bottom = float(nudge.y) * -1.0
		i += 1


func _apply_label_color(buttons: Array[TextureButton], color_in: Color) -> void:
	var i: int = 0
	while i < buttons.size():
		var tb: TextureButton = buttons[i]
		if tb != null:
			var label: Label = tb.get_node_or_null("Label")
			if label != null:
				label.add_theme_color_override(&"font_color", color_in)
		i += 1


# -------- Status sheet helpers ----------
func _get_stats_sheet() -> Control:
	if _content == null:
		return null
	if _content.has_node("StatsSheet"):
		var s: Control = _content.get_node("StatsSheet") as Control
		return s
	return null


func _show_status_sheet() -> void:
	var sheet: Control = _get_stats_sheet()
	if sheet == null:
		return

	var actor: Node = null
	var party: Node = get_node_or_null("/root/Party")
	if party != null and party.has_method("get_controlled"):
		actor = party.call("get_controlled") as Node
	if actor == null:
		return

	var binder: Node = sheet.get_node_or_null("StatsHeaderBinder")
	if binder != null:
		if binder.has_method("set_actor"):
			binder.call("set_actor", actor)

	var stats: Node = actor.get_node_or_null("StatsComponent")
	var level: Node = actor.get_node_or_null("LevelComponent")

	var klass_obj: Object = actor.get_node_or_null("ClassDescription")
	if klass_obj == null and level != null:
		var cd_var: Variant = level.get("class_def")
		if cd_var != null:
			klass_obj = cd_var

	if binder != null:
		if binder.has_method("set_targets"):
			binder.call("set_targets", stats, level, klass_obj, actor)

	var right_panel_bg: Node = sheet.get_node_or_null("RightPanel/RightPanelBG")
	if right_panel_bg != null:
		if right_panel_bg.has_method("set_sources"):
			right_panel_bg.call("set_sources", stats, level)


# -------- Content switching ----------
func _show_content_for_index(index: int) -> void:
	if _content == null:
		return

	var matched: bool = false
	if index >= 0 and index < content_node_names.size():
		var target_name: String = content_node_names[index]
		if _content.has_node(target_name):
			_set_content_visible_only(_content.get_node(target_name) as Control)
			matched = true

			if target_name == "StatsSheet":
				_show_status_sheet()

			if target_name == "InventorySheet":
				_force_refresh_currency_binding_and_value("show_inventory_tab")

	if not matched:
		var child_count: int = _content.get_child_count()
		var k: int = 0
		while k < child_count:
			var c: Control = _content.get_child(k) as Control
			if c != null:
				c.visible = (k == index)
			k += 1

		var shown: Control = null
		var i: int = 0
		while i < _content.get_child_count():
			var n: Node = _content.get_child(i)
			var cc: Control = n as Control
			if cc != null and cc.visible:
				shown = cc
			i += 1

		if shown != null and shown.name == "StatsSheet":
			_show_status_sheet()
		if shown != null and shown.name == "InventorySheet":
			_force_refresh_currency_binding_and_value("show_inventory_tab_fallback")

	_layout_content_only()
	if relax_mouse_filters_in_content:
		_relax_content_mouse_filters()


func _set_content_visible_only(target: Control) -> void:
	var i: int = 0
	while i < _content.get_child_count():
		var c: Control = _content.get_child(i) as Control
		if c != null:
			c.visible = (c == target)
		i += 1


# -------- Drag-friendliness helpers ----------
func _relax_content_mouse_filters() -> void:
	if _content == null:
		return

	var stack: Array[Node] = [_content]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		var c: Control = n as Control
		if c != null:
			if c is AbilityListItem:
				c.mouse_filter = Control.MOUSE_FILTER_STOP
			else:
				var is_button: bool = c is Button or c is TextureButton or c is BaseButton
				var is_scrollbar: bool = c is ScrollBar
				if not is_button and not is_scrollbar:
					c.mouse_filter = Control.MOUSE_FILTER_PASS

				var sc: ScrollContainer = c as ScrollContainer
				if sc != null:
					sc.mouse_filter = Control.MOUSE_FILTER_PASS
					var vbar: ScrollBar = sc.get_v_scroll_bar()
					var hbar: ScrollBar = sc.get_h_scroll_bar()
					if vbar != null:
						vbar.mouse_filter = Control.MOUSE_FILTER_PASS
					if hbar != null:
						hbar.mouse_filter = Control.MOUSE_FILTER_PASS
					sc.set("drag_to_scroll", false)

		var i: int = 0
		while i < n.get_child_count():
			stack.append(n.get_child(i))
			i += 1

	_enforce_row_mouse_filters()


func _enforce_row_mouse_filters() -> void:
	if _content == null:
		return
	var stack: Array[Node] = [_content]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is AbilityListItem:
			var row: AbilityListItem = n as AbilityListItem
			row.mouse_filter = Control.MOUSE_FILTER_STOP
		var i: int = 0
		while i < n.get_child_count():
			stack.append(n.get_child(i))
			i += 1


# -------- Input ----------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(toggle_action):
		if visible:
			_hide_menu()
		else:
			_show_menu()
		accept_event()
		return

	if guard_tabbar_from_row_drags and _tabs != null and event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var hovered: Control = get_viewport().gui_get_hovered_control()
			if _is_under_ability_row(hovered):
				return

	if visible and event is InputEventMouseButton:
		var mb2: InputEventMouseButton = event as InputEventMouseButton
		if mb2.pressed:
			var hovered2: Control = get_viewport().gui_get_hovered_control()
			var hover_path: NodePath = NodePath("")
			if hovered2 != null:
				hover_path = hovered2.get_path()
			print("[TabbedMenu] click at ", mb2.position, " hovered=", str(hover_path))


func _is_under_ability_row(node: Node) -> bool:
	var n: Node = node
	var depth: int = 0
	while n != null and depth < 8:
		if n is AbilityListItem:
			return true
		n = n.get_parent()
		depth += 1
	return false


# ====================== CURRENCY HOOKS ======================
func _force_refresh_currency_binding_and_value(reason: String) -> void:
	# Re-resolve every time we show the inventory tab to avoid stale label refs.
	_resolve_inventory_sys()
	_resolve_currency_label(true)
	_connect_currency_changed_signal()
	_refresh_currency_now(reason)


func _resolve_inventory_sys() -> void:
	if _inventory_obj != null and is_instance_valid(_inventory_obj):
		return

	_inventory_obj = null

	var root: Node = get_tree().get_root()
	var i: int = 0
	while i < inventory_autoload_names.size():
		var nm: String = inventory_autoload_names[i]
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_inventory_obj = obj
				if debug_log:
					print("[TabbedMenu] Resolved inventory autoload: ", path)
				return
		i += 1

	if debug_log:
		print("[TabbedMenu] Inventory autoload not found yet.")


func _resolve_currency_label(force: bool) -> void:
	if not force:
		if _currency_label != null and is_instance_valid(_currency_label):
			return

	_currency_label = null

	# 1) Explicit override path (best).
	if currency_value_label_path != NodePath(""):
		if has_node(currency_value_label_path):
			var lbl: Label = get_node(currency_value_label_path) as Label
			if lbl != null:
				_currency_label = lbl
				if debug_log:
					print("[TabbedMenu] Currency label bound (explicit): ", str(lbl.get_path()))
				return

	# 2) Known legacy paths under InventorySheet.
	var inv_sheet: Node = null
	if _content != null and _content.has_node("InventorySheet"):
		inv_sheet = _content.get_node("InventorySheet")

	if inv_sheet != null:
		var try_paths: Array[NodePath] = [
			NodePath("CurrencyBox/Label"),
			NodePath("Currency/Label"),
			NodePath("CurrencyLabel"),
			NodePath("Gold/Label"),
			NodePath("GoldBox/Label"),
			NodePath("GoldLabel")
		]
		var i2: int = 0
		while i2 < try_paths.size():
			var p: NodePath = try_paths[i2]
			if inv_sheet.has_node(p):
				var lbl2: Label = inv_sheet.get_node(p) as Label
				if lbl2 != null:
					_currency_label = lbl2
					if debug_log:
						print("[TabbedMenu] Currency label bound (known path): ", str(lbl2.get_path()))
					return
			i2 += 1

		# 3) Heuristic recursive search for any Label that looks like currency/gold.
		var found: Label = _find_currency_label_heuristic(inv_sheet)
		if found != null:
			_currency_label = found
			if debug_log:
				print("[TabbedMenu] Currency label bound (heuristic): ", str(found.get_path()), " name=", found.name)
			return

	if debug_log:
		print("[TabbedMenu] Currency label NOT found in InventorySheet.")


func _find_currency_label_heuristic(root_node: Node) -> Label:
	if root_node == null:
		return null

	var hints: Array[String] = ["currency", "gold", "coins", "coin", "money"]
	var queue: Array[Node] = []
	queue.append(root_node)

	while queue.size() > 0:
		var n: Node = queue.pop_front()
		var lbl: Label = n as Label
		if lbl != null:
			var nm: String = lbl.name.to_lower()
			var i: int = 0
			while i < hints.size():
				if nm.find(hints[i]) >= 0:
					return lbl
				i += 1

		var j: int = 0
		while j < n.get_child_count():
			queue.append(n.get_child(j))
			j += 1

	return null


func _connect_currency_changed_signal() -> void:
	if _inventory_obj == null or not is_instance_valid(_inventory_obj):
		return
	if not _inventory_obj.has_signal("currency_changed"):
		if debug_log:
			print("[TabbedMenu] Inventory has no signal currency_changed.")
		return

	if _currency_connected and _currency_connected_to == _inventory_obj:
		return

	_currency_connected = false
	_currency_connected_to = _inventory_obj

	var cb: Callable = Callable(self, "_on_currency_changed")
	if not _inventory_obj.is_connected("currency_changed", cb):
		_inventory_obj.connect("currency_changed", cb)

	_currency_connected = true
	if debug_log:
		print("[TabbedMenu] Connected currency_changed -> TabbedMenu")


func _on_currency_changed(total: int, _delta: int) -> void:
	# Always set if we can; harmless even if inventory not visible.
	_set_currency_text(total)
	if debug_log:
		print("[TabbedMenu] currency_changed total=", total, " label=", _currency_label_path_safe())


func _refresh_currency_now(reason: String) -> void:
	if _inventory_obj == null or not is_instance_valid(_inventory_obj):
		if debug_log:
			print("[TabbedMenu] refresh_currency_now skipped: inventory_obj invalid. reason=", reason)
		return

	if _inventory_obj.has_method("get_currency"):
		var total_any: Variant = _inventory_obj.call("get_currency")
		var total: int = int(total_any)
		_set_currency_text(total)
		if debug_log:
			print("[TabbedMenu] refresh_currency_now total=", total, " reason=", reason, " label=", _currency_label_path_safe())
	else:
		if debug_log:
			print("[TabbedMenu] Inventory has no method get_currency. reason=", reason)


func _set_currency_text(total: int) -> void:
	if _currency_label == null or not is_instance_valid(_currency_label):
		return
	_currency_label.text = _format_int_commas(total)


func _currency_label_path_safe() -> String:
	if _currency_label == null:
		return "<null>"
	if not is_instance_valid(_currency_label):
		return "<freed>"
	return str(_currency_label.get_path())


func _format_int_commas(value: int) -> String:
	var text_val: String = str(value)
	var s: PackedStringArray = []
	var i: int = text_val.length() - 1
	var group: int = 0
	while i >= 0:
		var ch: String = text_val[i]
		s.append(ch)
		group += 1
		if group == 3 and i > 0:
			s.append(",")
			group = 0
		i -= 1
	s.reverse()
	return "".join(s)


# --- Debug wiring ---
func _call_once__print_tab_buttons() -> void:
	if _debug_printed_tabs_once:
		return
	_debug_printed_tabs_once = true

	var list: Array[TextureButton] = []
	if _tabs != null:
		list = _collect_tab_buttons(_tabs)
	_buttons = list

	print("[TabbedMenu] wired ", str(_buttons.size()), " tab buttons:")
	var i: int = 0
	while i < _buttons.size():
		var b: TextureButton = _buttons[i]
		if b != null:
			print("  - Tab[", i, "] -> ", b.get_path())
			if not b.pressed.is_connected(_on_tab_pressed):
				print("    (note) pressed not directly connected; using bound index wiring.")
		i += 1


# ====================== AUDIO (UI SFX) ======================
func _resolve_audio_sys() -> void:
	if _audio_checked_once and _audio_obj != null and is_instance_valid(_audio_obj):
		return
	if _audio_checked_once and _audio_obj == null:
		return

	_audio_checked_once = true
	_audio_obj = null

	var root: Node = get_tree().get_root()
	var i: int = 0
	while i < audio_autoload_names.size():
		var nm: String = audio_autoload_names[i]
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_audio_obj = obj
				if debug_log:
					print("[TabbedMenu] Resolved audio autoload: ", path)
				return
		i += 1


func _play_ui_sound(event_name: StringName, volume_db: float) -> void:
	if event_name == StringName(""):
		return

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		_audio_checked_once = false
		_resolve_audio_sys()

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		return

	if _audio_obj.has_method("play_ui_sfx"):
		_audio_obj.call("play_ui_sfx", event_name, volume_db)
		return

	if _audio_obj.has_method("play_sfx_event"):
		_audio_obj.call("play_sfx_event", event_name, Vector2.INF, volume_db)
		return
