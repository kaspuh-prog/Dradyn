extends TextureRect
class_name StatsSheetRightPanel

# ===============================
# Inspector: Placement
# ===============================
@export_category("Placement")
@export var tab_size: Vector2i = Vector2i(256, 224)
@export var margin: int = 16
@export var header_h: int = 24
@export var left_col_w: int = 112
@export var gap: int = 8

# Your confirmed values
@export var panel_size: Vector2i = Vector2i(112, 160)
@export var nudge_x: int = -8
@export var nudge_y: int = -46

@export var show_guide: bool = false
@export var debug_logs: bool = false

# ===============================
# Inspector: Content Layout
# ===============================
@export_category("Content Layout")
@export var list_inset: int = 4
@export var row_spacing: int = 0
@export var label_clip: bool = true
@export var value_align_right: bool = true

# ===============================
# Inspector: Font Controls
# ===============================
@export_category("Font Controls")

@export_group("Unified Override (single knob)")
@export var use_unified_font_settings: bool = false
@export var unified_font: FontFile
@export_range(6, 48, 1) var unified_font_size: int = 10
@export var unified_font_color: Color = Color8(102, 57, 49, 255)

@export_group("Per-Section (used when Unified is OFF)")
@export var ui_font: FontFile
@export_range(6, 48, 1) var header_font_size: int = 10
@export var header_font_color: Color = Color8(102, 57, 49, 255)
@export_range(6, 48, 1) var row_font_size: int = 10
@export var row_font_color: Color = Color8(102, 57, 49, 255)

# ===============================
# Inspector: Scrollbar
# ===============================
@export_category("Scrollbar")
@export var use_custom_scrollbar: bool = true
@export_range(4, 24, 1) var scrollbar_width: int = 8
@export var hide_scroll_track: bool = true
@export var scrollbar_grabber_color: Color = Color8(0x40, 0x22, 0x1c, 255) # #40221c
@export_range(0.0, 1.0, 0.01) var scrollbar_alpha_normal: float = 0.55
@export_range(0.0, 1.0, 0.01) var scrollbar_alpha_hover: float = 0.70
@export_range(0.0, 1.0, 0.01) var scrollbar_alpha_pressed: float = 0.85
@export_range(0, 12, 1) var scrollbar_corner_radius: int = 4

# ===============================
# Inspector: Stat Order Override
# ===============================
@export_category("Stat Order")
@export var stat_order_override: PackedStringArray = []  # Optional explicit order from the panel

# ===============================
# Runtime nodes
# ===============================
var _scroll: ScrollContainer
var _vbox: VBoxContainer

# ===============================
# Data sources
# ===============================
var _actor: Node = null
var _stats: Node = null     # StatsComponent
var _level: Node = null     # LevelComponent

func _get_party_node() -> Node:
	var root: Node = get_tree().root
	var by_name: Node = root.get_node_or_null("Party")
	if by_name != null:
		return by_name
	var by_group: Node = get_tree().get_first_node_in_group("PartyManager")
	if by_group != null:
		return by_group
	return null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 0
	clip_contents = false

	_normalize_anchors()
	_apply_layout()
	_ensure_hierarchy()

	_apply_scrollbar_theme(_scroll)

	resized.connect(_on_resized)
	visibility_changed.connect(_on_visibility_changed)
	get_viewport().size_changed.connect(_on_viewport_size_changed)

	_autobind_party()
	_rebuild_deferred()

func _on_viewport_size_changed() -> void:
	_apply_layout()
	_layout_content()
	_rebuild_deferred()
	_apply_scrollbar_theme(_scroll)

func _on_resized() -> void:
	_layout_content()
	_rebuild_deferred()
	_apply_scrollbar_theme(_scroll)

func _on_visibility_changed() -> void:
	if visible:
		_layout_content()
		_rebuild_deferred()
		_apply_scrollbar_theme(_scroll)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAW and show_guide == true:
		var c: Color = Color(1.0, 0.0, 1.0, 1.0)
		draw_rect(Rect2(Vector2.ZERO, size), c, false, 1.0)

# ---------------------------
# Placement
# ---------------------------
func _normalize_anchors() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

func _apply_layout() -> void:
	var safe_x: int = margin
	var safe_y: int = margin

	var right_x: int = safe_x + left_col_w + gap
	var right_y: int = safe_y + header_h

	right_x += nudge_x
	right_y += nudge_y

	position = Vector2(float(right_x), float(right_y))
	custom_minimum_size = Vector2(float(panel_size.x), float(panel_size.y))
	size = custom_minimum_size

# ---------------------------
# UI construction
# ---------------------------
func _ensure_hierarchy() -> void:
	if _scroll == null:
		_scroll = ScrollContainer.new()
		_scroll.name = "PanelScroll"
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
		_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(_scroll)

	if _vbox == null:
		_vbox = VBoxContainer.new()
		_vbox.name = "StatsList"
		_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_vbox.add_theme_constant_override(&"separation", row_spacing)
		_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_vbox.size_flags_vertical = Control.SIZE_FILL
		_scroll.add_child(_vbox)

	_layout_content()
	_apply_scrollbar_theme(_scroll)

func _layout_content() -> void:
	if _scroll == null:
		return
	_scroll.anchor_left = 0.0
	_scroll.anchor_top = 0.0
	_scroll.anchor_right = 0.0
	_scroll.anchor_bottom = 0.0
	_scroll.position = Vector2(float(list_inset), float(list_inset))
	_scroll.size = size - Vector2(float(list_inset) * 2.0, float(list_inset) * 2.0)

# ---------------------------
# Party binding / sources
# ---------------------------
func _autobind_party() -> void:
	var party: Node = _get_party_node()
	if party == null:
		_log("Party autoload not found under /root or by group. Will retry on next rebuild.")
		return

	if party.has_signal("controlled_changed"):
		if not party.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
			party.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))

	if party.has_method("get_controlled"):
		var a_v: Variant = party.call("get_controlled")
		var a: Node = a_v as Node
		_assign_actor(a)
	else:
		_log("Party has no method get_controlled().")

func _on_party_controlled_changed(current: Node) -> void:
	_assign_actor(current)

func _assign_actor(actor: Node) -> void:
	_disconnect_sources()
	_actor = actor
	_stats = null
	_level = null
	if _actor != null:
		_stats = _find_stats_component(_actor)
		_level = _find_level_component(_actor)
	_connect_sources()
	_rebuild_deferred()

func set_sources(stats: Node, level: Node) -> void:
	_disconnect_sources()
	_actor = null
	_stats = stats
	_level = level
	_connect_sources()
	_rebuild_deferred()

func _disconnect_sources() -> void:
	if _stats != null and _stats.has_signal("stat_changed"):
		if _stats.is_connected("stat_changed", Callable(self, "_on_stat_changed")):
			_stats.disconnect("stat_changed", Callable(self, "_on_stat_changed"))
	if _level != null:
		if _level.has_signal("xp_changed"):
			if _level.is_connected("xp_changed", Callable(self, "_on_xp_changed")):
				_level.disconnect("xp_changed", Callable(self, "_on_xp_changed"))
		if _level.has_signal("level_up"):
			if _level.is_connected("level_up", Callable(self, "_on_level_up")):
				_level.disconnect("level_up", Callable(self, "_on_level_up"))

func _connect_sources() -> void:
	if _stats != null and _stats.has_signal("stat_changed"):
		_stats.connect("stat_changed", Callable(self, "_on_stat_changed"))
	if _level != null:
		if _level.has_signal("xp_changed"):
			_level.connect("xp_changed", Callable(self, "_on_xp_changed"))
		if _level.has_signal("level_up"):
			_level.connect("level_up", Callable(self, "_on_level_up"))

# ---- Deep component searches ----
func _find_stats_component(n: Node) -> Node:
	if n == null:
		return null
	var s: Node = n.get_node_or_null("StatsComponent")
	if s != null:
		return s
	return n.find_child("StatsComponent", true, false)

func _find_level_component(n: Node) -> Node:
	if n == null:
		return null
	var d: Node = n.get_node_or_null("LevelComponent")
	if d != null:
		return d
	return n.find_child("LevelComponent", true, false)

# ---------------------------
# React to changes
# ---------------------------
func _on_stat_changed(_name: String, _value: float) -> void:
	_rebuild_deferred()

func _on_xp_changed(_cxp: int, _to_next: int, _lvl: int) -> void:
	_rebuild_deferred()

func _on_level_up(_lvl: int, _gained: int) -> void:
	_rebuild_deferred()

func _rebuild_deferred() -> void:
	call_deferred("_rebuild_contents")

# ---------------------------
# Build scroll content
# ---------------------------
func _rebuild_contents() -> void:
	if _vbox == null:
		return

	# Clear
	var children: Array = _vbox.get_children()
	var i: int = 0
	while i < children.size():
		var n: Node = children[i]
		n.queue_free()
		i += 1

	# Header
	var xp_label: Label = Label.new()
	xp_label.text = _format_xp_line()
	xp_label.clip_text = label_clip
	xp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_label_theme(xp_label, true)
	_vbox.add_child(xp_label)

	var sep: HSeparator = HSeparator.new()
	sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_child(sep)

	# Stats list
	var stats_dict: Dictionary = {}
	if _stats != null and _stats.has_method("get_all_final_stats"):
		var ret: Variant = _stats.call("get_all_final_stats")
		if typeof(ret) == TYPE_DICTIONARY:
			stats_dict = ret

	if stats_dict.is_empty():
		_log("Stats dict empty (either not ready or no stats). Showing placeholder.")
		var none_lbl: Label = Label.new()
		none_lbl.text = "No stats available."
		_apply_label_theme(none_lbl, false)
		_vbox.add_child(none_lbl)
		_apply_scrollbar_theme(_scroll)
		return

	var keys: Array = _get_sorted_keys(stats_dict)
	var k: int = 0
	while k < keys.size():
		var key_any: Variant = keys[k]
		var display_key: String = str(key_any)
		if stats_dict.has(display_key):
			var vv: Variant = stats_dict[display_key]
			var val: float = 0.0
			if vv != null:
				val = float(vv)
			_add_stat_row(display_key, int(round(val)))
		k += 1

	# Ensure scrollbar theme persists if content changes size
	_apply_scrollbar_theme(_scroll)

# Row creation
func _add_stat_row(key_text: String, value_int: int) -> void:
	var row: HBoxContainer = HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var k_lbl: Label = Label.new()
	k_lbl.text = key_text
	k_lbl.clip_text = label_clip
	k_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	k_lbl.size_flags_stretch_ratio = 0.6
	_apply_label_theme(k_lbl, false)

	var v_lbl: Label = Label.new()
	v_lbl.text = str(value_int)
	v_lbl.clip_text = label_clip
	v_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_lbl.size_flags_stretch_ratio = 0.4
	if value_align_right == true:
		v_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	else:
		v_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_apply_label_theme(v_lbl, false)

	row.add_child(k_lbl)
	row.add_child(v_lbl)
	_vbox.add_child(row)

# ---------------------------
# Label theming
# ---------------------------
func _apply_label_theme(lbl: Label, is_header: bool) -> void:
	if lbl == null:
		return

	if use_unified_font_settings == true:
		if unified_font != null:
			lbl.add_theme_font_override(&"font", unified_font)
		lbl.add_theme_font_size_override(&"font_size", unified_font_size)
		lbl.add_theme_color_override(&"font_color", unified_font_color)
		return

	if ui_font != null:
		lbl.add_theme_font_override(&"font", ui_font)
	if is_header == true:
		lbl.add_theme_font_size_override(&"font_size", header_font_size)
		lbl.add_theme_color_override(&"font_color", header_font_color)
	else:
		lbl.add_theme_font_size_override(&"font_size", row_font_size)
		lbl.add_theme_color_override(&"font_color", row_font_color)

# ---------------------------
# Scrollbar theming (Inspector knobs)
# ---------------------------
func _apply_scrollbar_theme(sc: ScrollContainer) -> void:
	if sc == null:
		return
	var vbar: VScrollBar = sc.get_v_scroll_bar()
	if vbar == null:
		return

	if use_custom_scrollbar == false:
		vbar.remove_theme_stylebox_override("scroll")
		vbar.remove_theme_stylebox_override("grabber")
		vbar.remove_theme_stylebox_override("grabber_highlight")
		vbar.remove_theme_stylebox_override("grabber_pressed")
		vbar.custom_minimum_size = Vector2.ZERO
		return

	vbar.custom_minimum_size = Vector2(float(scrollbar_width), 0.0)

	if hide_scroll_track == true:
		var track_empty := StyleBoxEmpty.new()
		vbar.add_theme_stylebox_override("scroll", track_empty)
	else:
		vbar.remove_theme_stylebox_override("scroll")

	var base_col: Color = scrollbar_grabber_color

	var grabber := StyleBoxFlat.new()
	grabber.bg_color = Color(base_col.r, base_col.g, base_col.b, scrollbar_alpha_normal)
	grabber.corner_radius_top_left = scrollbar_corner_radius
	grabber.corner_radius_top_right = scrollbar_corner_radius
	grabber.corner_radius_bottom_left = scrollbar_corner_radius
	grabber.corner_radius_bottom_right = scrollbar_corner_radius
	vbar.add_theme_stylebox_override("grabber", grabber)

	var grabber_hover := StyleBoxFlat.new()
	grabber_hover.bg_color = Color(base_col.r, base_col.g, base_col.b, scrollbar_alpha_hover)
	grabber_hover.corner_radius_top_left = scrollbar_corner_radius
	grabber_hover.corner_radius_top_right = scrollbar_corner_radius
	grabber_hover.corner_radius_bottom_left = scrollbar_corner_radius
	grabber_hover.corner_radius_bottom_right = scrollbar_corner_radius
	vbar.add_theme_stylebox_override("grabber_highlight", grabber_hover)

	var grabber_pressed := StyleBoxFlat.new()
	grabber_pressed.bg_color = Color(base_col.r, base_col.g, base_col.b, scrollbar_alpha_pressed)
	grabber_pressed.corner_radius_top_left = scrollbar_corner_radius
	grabber_pressed.corner_radius_top_right = scrollbar_corner_radius
	grabber_pressed.corner_radius_bottom_left = scrollbar_corner_radius
	grabber_pressed.corner_radius_bottom_right = scrollbar_corner_radius
	vbar.add_theme_stylebox_override("grabber_pressed", grabber_pressed)

# ---------------------------
# Sorting helpers (match StatsComponent order)
# ---------------------------
func _get_sorted_keys(stats_dict: Dictionary) -> Array:
	# Build a normalization lookup from the dict that maps normalized name -> original key
	var norm_to_original: Dictionary = {}
	var insertion_order: Array = []
	for key_any in stats_dict.keys():
		var key_str: String = str(key_any)
		var norm: String = _normalize_key(key_str)
		norm_to_original[norm] = key_str
		insertion_order.append(key_str)

	# 1) Panel override takes priority
	if stat_order_override.size() > 0:
		return _map_order_to_existing(stat_order_override, norm_to_original, insertion_order)

	# 2) Ask StatsComponent for its order
	var comp_order: Array = _resolve_stat_order()
	if comp_order.size() > 0:
		return _map_order_to_existing(comp_order, norm_to_original, insertion_order)

	# 3) No order available: preserve insertion order from the dictionary
	return insertion_order

func _map_order_to_existing(order_any: Array, norm_to_original: Dictionary, insertion_order: Array) -> Array:
	var out: Array = []
	var added: Dictionary = {}

	# Place known keys in the given order (case-insensitive)
	var i: int = 0
	while i < order_any.size():
		var want_str: String = str(order_any[i])
		var norm: String = _normalize_key(want_str)
		if norm_to_original.has(norm):
			var original: String = norm_to_original[norm]
			if not added.has(original):
				out.append(original)
				added[original] = true
		i += 1

	# Append any remaining keys in their original insertion order
	var j: int = 0
	while j < insertion_order.size():
		var k: String = insertion_order[j]
		if not added.has(k):
			out.append(k)
			added[k] = true
		j += 1

	return out

func _normalize_key(s: String) -> String:
	# Case-insensitive, trim spaces/underscores/dashes
	var t: String = s.strip_edges()
	t = t.replace("_", "")
	t = t.replace("-", "")
	return t.to_lower()

func _resolve_stat_order() -> Array:
	var order: Array = []
	if _stats == null:
		return order

	# Preferred explicit method
	if _stats.has_method("get_stat_order"):
		var v: Variant = _stats.call("get_stat_order")
		if v is Array:
			return v as Array

	# Fallback properties
	if "stat_order" in _stats:
		var v2: Variant = _stats.get("stat_order")
		if v2 is Array:
			return v2 as Array
	if "display_order" in _stats:
		var v3: Variant = _stats.get("display_order")
		if v3 is Array:
			return v3 as Array

	return order

# ---------------------------
# Misc helpers
# ---------------------------
func _sort_keys(a: Variant, b: Variant) -> bool:
	var sa: String = str(a)
	var sb: String = str(b)
	return sa < sb

func _format_xp_line() -> String:
	var cxp: int = 0
	var to_next: int = 0

	if _level != null:
		# Prefer method then property for current_xp
		if _level.has_method("get_current_xp"):
			var v1: Variant = _level.call("get_current_xp")
			if v1 != null:
				cxp = int(v1)
		elif "current_xp" in _level:
			var v2: Variant = _level.get("current_xp")
			if v2 != null:
				cxp = int(v2)

		# Prefer method then property for xp_to_next
		if _level.has_method("get_xp_to_next"):
			var v3: Variant = _level.call("get_xp_to_next")
			if v3 != null:
				to_next = int(v3)
		elif "xp_to_next" in _level:
			var v4: Variant = _level.get("xp_to_next")
			if v4 != null:
				to_next = int(v4)

	return "Current EXP: " + str(cxp) + " / To Next Level: " + str(to_next)

func _log(msg: String) -> void:
	if debug_logs == true:
		print("[StatsSheetRightPanel] ", msg)
