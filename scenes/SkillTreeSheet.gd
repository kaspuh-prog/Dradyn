extends Control
# SkillTreeSheet
# Godot 4.5 — fully typed, no ternaries.

signal section_changed(index: int, name: String)
signal points_changed(spent: int, available: int)
signal ability_purchase_requested(ability_id: String, cost_points: int)

# Row visual "knobs" (sheet-level; affects newly created rows and can be re-applied to existing rows)
@export var row_name_font_size_override: int = 4
@export var row_cost_font_size_override: int = 4
@export var row_cost_min_width: int = 28
@export var row_cost_left_inset: int = 2
@export var row_cost_right_inset: int = 5

@export var panel_size: Vector2i = Vector2i(256, 224)
@export var tabs_height: int = 48
@export var background_size: Vector2i = Vector2i(146, 160)

@export var button_size: Vector2i = Vector2i(64, 16)
@export var button_v_spacing: int = 4
@export var button_top_offset: int = 0
@export var section_names: PackedStringArray = ["Type A", "Type B", "Type C", "Type D"]

@export var ui_theme: Theme

@export var bg_block_nudge: Vector2i = Vector2i(-14, -54)
@export var background_nudge: Vector2i = Vector2i(0, 0)
@export var panel_1_nudge: Vector2i = Vector2i(0, 0)
@export var panel_2_nudge: Vector2i = Vector2i(0, 0)
@export var panel_3_nudge: Vector2i = Vector2i(0, 0)
@export var panel_4_nudge: Vector2i = Vector2i(0, 0)
@export var buttons_column_nudge: Vector2i = Vector2i(0, -48)
@export var btn_1_nudge: Vector2i = Vector2i(0, 0)
@export var btn_2_nudge: Vector2i = Vector2i(0, 0)
@export var btn_3_nudge: Vector2i = Vector2i(0, 0)
@export var btn_4_nudge: Vector2i = Vector2i(0, 0)
@export var label_1_nudge: Vector2i = Vector2i(0, 0)
@export var label_2_nudge: Vector2i = Vector2i(0, 0)
@export var label_3_nudge: Vector2i = Vector2i(0, 0)
@export var label_4_nudge: Vector2i = Vector2i(0, 0)

@export var panel_inset: int = 3

@export var points_spent: int = 0
@export var points_available: int = 0
@export var points_hud_nudge: Vector2i = Vector2i(0, 6)
@export var points_hud_size: Vector2i = Vector2i(64, 24)

@export var points_font: Font
@export var points_font_size: int = 9
@export var points_font_color_spent: Color = Color(1, 1, 1, 1)
@export var points_font_color_avail: Color = Color(0.9, 1, 0.9, 1)
@export var points_line_gap: int = 0
@export var points_text_prefix_spent: String = "Spent: "
@export var points_text_prefix_avail: String = "Avail: "

@export var scrollbar_width: int = 5
@export var scrollbar_grabber_min_size: int = 12
@export var scrollbar_track_color: Color = Color(0, 0, 0, 0.35)
@export var scrollbar_grabber_color: Color = Color(1, 1, 1, 0.55)
@export var scrollbar_grabber_hover_color: Color = Color(1, 1, 1, 0.75)
@export var scrollbar_grabber_pressed_color: Color = Color(1, 1, 1, 0.95)
@export var scrollbar_roundness: int = 3

@export var debug_draw_layout: bool = false
@export var ability_item_scene: PackedScene
@export var demo_icon: Texture2D

# Offset for the ability rows inside each panel (applied via a MarginContainer pad)
@export var rows_offset: Vector2i = Vector2i(4, 2)

# Font tweak for the row name/level (legacy sheet-side theme override for the whole row)
@export var name_font_size_override: int = 9

# Inline description (legacy helper; now used only as a fallback)
@export var desc_inline_prefix: String = " — "
@export var desc_inline_max_chars: int = 64

var _bg_tex: TextureRect
var _panels: Array[ScrollContainer] = []
var _panel_pads: Array[MarginContainer] = []
var _panel_vboxes: Array[VBoxContainer] = []
var _btns: Array[BaseButton] = []
var _labels: Array[Label] = []

var _points_hud: Control
var _points_label_top: Label
var _points_label_bottom: Label

var _bg_origin: Vector2i


func _ready() -> void:
	if ui_theme != null:
		theme = ui_theme

	z_as_relative = false
	z_index = 10
	mouse_filter = Control.MOUSE_FILTER_PASS

	if not _discover_base_nodes():
		push_error("SkillTreeSheet: required nodes missing (SkillTreeBG and/or buttons).")
		return

	_ensure_scrollable_panels()
	_ensure_points_hud()

	_apply_panel_frame()
	_layout_everything()
	_connect_buttons()
	_select_section(0)
	_update_points_text()
	_apply_scrollbar_theme()
	_sync_row_widths()
	queue_redraw()

	call_deferred("_fix_mouse_filters_and_layers")


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		queue_redraw()
	elif what == NOTIFICATION_DRAG_BEGIN:
		_set_panels_drag_passthrough(true)
	elif what == NOTIFICATION_DRAG_END:
		_set_panels_drag_passthrough(false)


func _discover_base_nodes() -> bool:
	_bg_tex = get_node_or_null("SkillTreeBG") as TextureRect
	if _bg_tex == null:
		push_error("Missing node: SkillTreeBG (TextureRect)")
		return false
	_bg_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg_tex.z_as_relative = false
	_bg_tex.z_index = 0

	_btns.clear()
	_labels.clear()
	var i: int = 0
	while i < 4:
		var btn := get_node_or_null("Btn_%d" % (i + 1)) as BaseButton
		if btn == null:
			push_error("Missing node: Btn_%d" % (i + 1))
			return false
		_btns.append(btn)

		var label := btn.get_node_or_null("Btn_Label%d" % (i + 1)) as Label
		if label == null:
			label = Label.new()
			label.name = "Btn_Label%d" % (i + 1)
			btn.add_child(label)
		_labels.append(label)
		i += 1

	return true


func _ensure_points_hud() -> void:
	_points_hud = get_node_or_null("PointsHUD") as Control
	if _points_hud == null:
		_points_hud = Control.new()
		_points_hud.name = "PointsHUD"
		add_child(_points_hud)
	_points_hud.mouse_filter = Control.MOUSE_FILTER_PASS

	_points_label_top = _points_hud.get_node_or_null("Top") as Label
	if _points_label_top == null:
		_points_label_top = Label.new()
		_points_label_top.name = "Top"
		_points_hud.add_child(_points_label_top)

	_points_label_bottom = _points_hud.get_node_or_null("Bottom") as Label
	if _points_label_bottom == null:
		_points_label_bottom = Label.new()
		_points_label_bottom.name = "Bottom"
		_points_hud.add_child(_points_label_bottom)

	_points_label_top.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points_label_top.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_points_label_bottom.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points_label_bottom.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_points_label_top.autowrap_mode = TextServer.AUTOWRAP_OFF
	_points_label_bottom.autowrap_mode = TextServer.AUTOWRAP_OFF

	_apply_points_font_and_colors()


func _apply_panel_frame() -> void:
	custom_minimum_size = Vector2(panel_size)
	size = Vector2(panel_size)
	position = Vector2.ZERO
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0
	pivot_offset = Vector2.ZERO


func _layout_everything() -> void:
	var base_left: int = panel_size.x - background_size.x
	_bg_origin = Vector2i(base_left, tabs_height) + bg_block_nudge

	_bg_tex.position = Vector2(_bg_origin + background_nudge)
	_bg_tex.custom_minimum_size = Vector2(background_size)
	_bg_tex.size = Vector2(background_size)
	_bg_tex.clip_contents = true

	# Panels EXACTLY match SkillTreeBG; positioned in BG-local space.
	var panel_w: float = float(background_size.x)
	var panel_h: float = float(background_size.y)
	var nudges: Array[Vector2i] = [panel_1_nudge, panel_2_nudge, panel_3_nudge, panel_4_nudge]

	var i: int = 0
	while i < _panels.size():
		var sc := _panels[i]
		var n := nudges[i]

		sc.anchor_left = 0.0
		sc.anchor_top = 0.0
		sc.anchor_right = 0.0
		sc.anchor_bottom = 0.0
		sc.pivot_offset = Vector2.ZERO
		sc.position = Vector2(float(n.x), float(n.y))
		sc.custom_minimum_size = Vector2(panel_w, panel_h)
		sc.size = Vector2(panel_w, panel_h)

		sc.visible = false
		sc.z_as_relative = false
		sc.z_index = 10
		sc.mouse_filter = Control.MOUSE_FILTER_PASS
		sc.focus_mode = Control.FOCUS_NONE
		sc.clip_contents = true

		var pad := _panel_pads[i]
		_apply_rows_offset_to_pad(pad)

		var vb := _panel_vboxes[i]
		vb.custom_minimum_size = Vector2(panel_w, 0.0)
		vb.mouse_filter = Control.MOUSE_FILTER_PASS
		i += 1

	# Button column and points HUD
	var col_left_base: int = _bg_origin.x - button_size.x - 8
	var col_top_base: int = tabs_height + button_top_offset
	var col_left: int = col_left_base + buttons_column_nudge.x
	var y_cursor: int = col_top_base + buttons_column_nudge.y

	var btn_nudges: Array[Vector2i] = [btn_1_nudge, btn_2_nudge, btn_3_nudge, btn_4_nudge]
	var lbl_nudges: Array[Vector2i] = [label_1_nudge, label_2_nudge, label_3_nudge, label_4_nudge]

	var b: int = 0
	while b < _btns.size():
		var btn := _btns[b]
		var b_n := btn_nudges[b]
		btn.position = Vector2(float(col_left + b_n.x), float(y_cursor + b_n.y))
		btn.custom_minimum_size = Vector2(button_size)
		btn.size = Vector2(button_size)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

		var lbl := _labels[b]
		if b < section_names.size():
			lbl.text = section_names[b]
		else:
			lbl.text = "Section %d" % (b + 1)
		lbl.position = Vector2(lbl_nudges[b])
		lbl.size = btn.size
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

		y_cursor += button_size.y + button_v_spacing
		b += 1

	var hud_pos_x: int = col_left
	var hud_pos_y: int = y_cursor + points_hud_nudge.y
	_points_hud.position = Vector2(float(hud_pos_x), float(hud_pos_y))
	_points_hud.custom_minimum_size = Vector2(points_hud_size)
	_points_hud.size = Vector2(points_hud_size)
	_points_hud.mouse_filter = Control.MOUSE_FILTER_PASS

	var top_h: int = int(points_hud_size.y / 2) - int(points_line_gap / 2)
	var bottom_y: int = top_h + points_line_gap
	_points_label_top.position = Vector2(0.0, 0.0)
	_points_label_top.size = Vector2(float(points_hud_size.x), float(top_h))
	_points_label_bottom.position = Vector2(0.0, float(bottom_y))
	_points_label_bottom.size = Vector2(float(points_hud_size.x), float(points_hud_size.y - bottom_y))

	_apply_points_font_and_colors()


func _ensure_scrollable_panels() -> void:
	_panels.clear()
	_panel_pads.clear()
	_panel_vboxes.clear()

	var i: int = 0
	while i < 4:
		var name_want: String = "Panel_%d" % (i + 1)
		var node: Node = _bg_tex.get_node_or_null(name_want)

		var sc: ScrollContainer
		if node == null:
			sc = ScrollContainer.new()
			sc.name = name_want
			_bg_tex.add_child(sc)
		else:
			sc = node as ScrollContainer
			if sc == null:
				var replacement := ScrollContainer.new()
				replacement.name = name_want
				var idx: int = node.get_index()
				_bg_tex.remove_child(node)
				_bg_tex.add_child(replacement)
				_bg_tex.move_child(replacement, idx)
				var carry: Array[Node] = []
				for c in node.get_children():
					carry.append(c)
				for c in carry:
					node.remove_child(c)
					replacement.add_child(c)
				node.queue_free()
				sc = replacement

		# Clean anchors/sizing
		sc.anchor_left = 0.0
		sc.anchor_top = 0.0
		sc.anchor_right = 0.0
		sc.anchor_bottom = 0.0
		sc.pivot_offset = Vector2.ZERO
		sc.mouse_filter = Control.MOUSE_FILTER_PASS
		sc.focus_mode = Control.FOCUS_NONE
		sc.clip_contents = true
		sc.z_as_relative = false
		sc.z_index = 10

		# Ensure a MarginContainer "Pad" exists as the single child of sc
		var pad := sc.get_node_or_null("Pad") as MarginContainer
		if pad == null:
			pad = MarginContainer.new()
			pad.name = "Pad"
			sc.add_child(pad)
		pad.anchor_left = 0.0
		pad.anchor_top = 0.0
		pad.anchor_right = 1.0
		pad.anchor_bottom = 0.0
		pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_apply_rows_offset_to_pad(pad)

		# Ensure a VBoxContainer exists INSIDE the pad
		var vb := pad.get_node_or_null("VBox") as VBoxContainer
		if vb == null:
			var old_vb := sc.get_node_or_null("VBox") as VBoxContainer
			if old_vb != null:
				sc.remove_child(old_vb)
				pad.add_child(old_vb)
				old_vb.name = "VBox"
				vb = old_vb
			else:
				vb = VBoxContainer.new()
				vb.name = "VBox"
				pad.add_child(vb)

		# VBox layout config
		vb.custom_minimum_size = Vector2(float(background_size.x), 0.0)
		vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vb.anchor_left = 0.0
		vb.anchor_top = 0.0
		vb.anchor_right = 1.0
		vb.anchor_bottom = 0.0
		vb.mouse_filter = Control.MOUSE_FILTER_PASS
		vb.focus_mode = Control.FOCUS_NONE

		_panels.append(sc)
		_panel_pads.append(pad)
		_panel_vboxes.append(vb)
		i += 1


func _apply_rows_offset_to_pad(pad: MarginContainer) -> void:
	pad.add_theme_constant_override("margin_left", rows_offset.x)
	pad.add_theme_constant_override("margin_top", rows_offset.y)
	pad.add_theme_constant_override("margin_right", 0)
	pad.add_theme_constant_override("margin_bottom", 0)


func _apply_scrollbar_theme() -> void:
	for sc in _panels:
		sc.add_theme_constant_override("scrollbar_width", scrollbar_width)
		var vbar := sc.get_v_scroll_bar()
		if vbar != null:
			_style_scrollbar(vbar)
		var hbar := sc.get_h_scroll_bar()
		if hbar != null:
			_style_scrollbar(hbar)


func _style_scrollbar(bar: ScrollBar) -> void:
	bar.add_theme_constant_override("min_grabber_size", scrollbar_grabber_min_size)
	bar.add_theme_constant_override("thickness", scrollbar_width)
	var track_sb := _make_stylebox(scrollbar_track_color, scrollbar_roundness)
	bar.add_theme_stylebox_override("scroll", track_sb)
	var grabber_normal := _make_stylebox(scrollbar_grabber_color, scrollbar_roundness)
	var grabber_hover := _make_stylebox(scrollbar_grabber_hover_color, scrollbar_roundness)
	var grabber_pressed := _make_stylebox(scrollbar_grabber_pressed_color, scrollbar_roundness)
	bar.add_theme_stylebox_override("grabber", grabber_normal)
	bar.add_theme_stylebox_override("grabber_highlight", grabber_hover)
	bar.add_theme_stylebox_override("grabber_pressed", grabber_pressed)


func _make_stylebox(col: Color, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	return sb


func _connect_buttons() -> void:
	var i: int = 0
	while i < _btns.size():
		_btns[i].pressed.connect(_on_btn_pressed.bind(i))
		i += 1


func _on_btn_pressed(index: int) -> void:
	_select_section(index)


func _select_section(index: int) -> void:
	var i: int = 0
	while i < _panels.size():
		var vis: bool = i == index
		_panels[i].visible = vis
		i += 1
	var name_text: String = ""
	if index >= 0 and index < section_names.size():
		name_text = section_names[index]
	section_changed.emit(index, name_text)
	_sync_row_widths()
	refresh_all_row_layouts() # ensure current section rows respect latest knobs
	queue_redraw()


# -------------------------------------------------------------------
# External API for class-driven tabs
# -------------------------------------------------------------------
func set_section_names(names: PackedStringArray) -> void:
	if names.size() != 4:
		return
	section_names = names
	_refresh_section_labels()


func set_section_name(index: int, name: String) -> void:
	if index < 0:
		return
	if index > 3:
		return
	section_names[index] = name
	_refresh_section_labels()


func _refresh_section_labels() -> void:
	var i: int = 0
	while i < _labels.size():
		var lbl: Label = _labels[i]
		var text_out: String = "Section %d" % (i + 1)
		if i < section_names.size():
			text_out = section_names[i]
		lbl.text = text_out
		i += 1
	var current_index: int = _current_visible_section_index()
	if current_index >= 0:
		var current_name: String = ""
		if current_index < section_names.size():
			current_name = section_names[current_index]
		section_changed.emit(current_index, current_name)
	queue_redraw()


func _current_visible_section_index() -> int:
	var i: int = 0
	while i < _panels.size():
		if _panels[i].visible:
			return i
		i += 1
	return 0


# -------------------------------------------------------------------

func set_points(spent: int, available: int) -> void:
	points_spent = spent
	points_available = available
	_update_points_text()
	points_changed.emit(points_spent, points_available)


func _update_points_text() -> void:
	if _points_label_top != null:
		_points_label_top.text = points_text_prefix_spent + str(points_spent)
	if _points_label_bottom != null:
		_points_label_bottom.text = points_text_prefix_avail + str(points_available)


func _apply_points_font_and_colors() -> void:
	if _points_label_top != null:
		if points_font != null:
			_points_label_top.add_theme_font_override("font", points_font)
		_points_label_top.add_theme_font_size_override("font_size", points_font_size)
		_points_label_top.add_theme_color_override("font_color", points_font_color_spent)
	if _points_label_bottom != null:
		if points_font != null:
			_points_label_bottom.add_theme_font_override("font", points_font)
		_points_label_bottom.add_theme_font_size_override("font_size", points_font_size)
		_points_label_bottom.add_theme_color_override("font_color", points_font_color_avail)


func get_panel_vbox(index: int) -> VBoxContainer:
	if index >= 0 and index < _panel_vboxes.size():
		return _panel_vboxes[index]
	return null


func clear_panel(index: int) -> void:
	var vb := get_panel_vbox(index)
	if vb == null:
		return
	for c in vb.get_children():
		vb.remove_child(c)
		c.queue_free()


# -------------------------------------------------------------------
# ROW SIZE / MOUSE CONFIG
# -------------------------------------------------------------------
func _apply_row_mouse_and_width(row: Control) -> void:
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.focus_mode = Control.FOCUS_CLICK

	# IMPORTANT: rows should not try to expand beyond the inner background width.
	row.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var desired_w: float = float(background_size.x) - float(rows_offset.x) * 2.0
	if desired_w < 32.0:
		desired_w = 32.0

	var h: float = max(row.custom_minimum_size.y, 18.0)
	var sz := Vector2(desired_w, h)

	row.custom_minimum_size = sz
	row.size = sz

	# Note: vertical size flags can still be whatever the row prefers; we only clamp width.


func _make_ability_item(
		name_in: String,
		cost_in: int,
		icon_in: Texture2D,
		ability_id: String,
		unlocked: bool,
		level_in: int = 1,
		desc_in: String = ""
	) -> Control:
	var short_desc: String = _shorten_desc(desc_in)

	# If a custom scene is assigned, prefer it but keep things backwards-compatible.
	if ability_item_scene != null:
		var inst_node := ability_item_scene.instantiate()
		var as_ctrl := inst_node as Control
		if as_ctrl != null:
			# Baseline data BEFORE set_data builds internals
			if as_ctrl.has_method("set"):
				as_ctrl.set("ability_id", ability_id)
				as_ctrl.set("cost_points", cost_in)
				as_ctrl.set("locked", not unlocked)
				as_ctrl.set("icon", icon_in)
				as_ctrl.set("item_name", name_in)

				# New fields, if the row exposes them
				if "ability_level" in as_ctrl:
					as_ctrl.set("ability_level", level_in)
				if "description" in as_ctrl:
					as_ctrl.set("description", desc_in)
				elif short_desc != "":
					# Fallback: keep old behavior by inlining a short desc if there is no dedicated field
					as_ctrl.set("item_name", name_in + desc_inline_prefix + short_desc)

				# If the row exposes raw font exports, set them (keeps backward-compat)
				if "name_font_size" in as_ctrl:
					as_ctrl.set("name_font_size", row_name_font_size_override)
				if "cost_font_size" in as_ctrl:
					as_ctrl.set("cost_font_size", row_cost_font_size_override)

			# For custom scenes, keep the classic 5-arg call in case set_data does not accept extras
			if as_ctrl.has_method("set_data"):
				as_ctrl.call_deferred("set_data", name_in, cost_in, icon_in, ability_id, unlocked)

			if as_ctrl.has_signal("purchase_requested"):
				as_ctrl.connect("purchase_requested", _on_row_purchase_requested)
			if as_ctrl.has_signal("clicked"):
				as_ctrl.connect("clicked", _on_row_clicked)

			_apply_row_mouse_and_width(as_ctrl)
			return as_ctrl

	# Fallback to a new row instance (AbilityListItem)
	var row := AbilityListItem.new()

	if "name_font_size" in row:
		row.name_font_size = row_name_font_size_override
	if "cost_font_size" in row:
		row.cost_font_size = row_cost_font_size_override

	row.ability_id = ability_id
	row.cost_points = cost_in
	row.locked = not unlocked
	row.icon = icon_in
	row.item_name = name_in

	# New: feed level + description into the row's own fields
	row.ability_level = level_in
	row.description = desc_in

	# Keep the classic 5-arg call; AbilityListItem.set_data has defaults for the extras
	row.call_deferred("set_data", name_in, cost_in, icon_in, ability_id, unlocked)

	if row.has_method("set_affordable"):
		var affordable_now: bool = points_available >= cost_in
		row.set_affordable(affordable_now)

	if row.has_signal("purchase_requested"):
		row.connect("purchase_requested", _on_row_purchase_requested)
	if row.has_signal("clicked"):
		row.connect("clicked", _on_row_clicked)

	_apply_row_mouse_and_width(row)
	return row


# ---------------------------
# Row visual configuration (preferred API + safe fallback)
# ---------------------------
func _configure_row_visual(row: Control) -> void:
	# Preferred: dedicated API on the row (keeps Sheet decoupled from internals)
	if row.has_method("set_layout_metrics"):
		row.call(
			"set_layout_metrics",
			row_name_font_size_override,
			row_cost_font_size_override,
			row_cost_min_width,
			row_cost_left_inset,
			row_cost_right_inset
		)
		return

	# Fallback: set exposed properties if they exist
	if row.has_method("set"):
		if "name_font_size" in row:
			row.set("name_font_size", row_name_font_size_override)
		if "cost_font_size" in row:
			row.set("cost_font_size", row_cost_font_size_override)
		if "cost_min_width" in row:
			row.set("cost_min_width", row_cost_min_width)
		if "cost_left_inset" in row:
			row.set("cost_left_inset", row_cost_left_inset)
		if "cost_right_inset" in row:
			row.set("cost_right_inset", row_cost_right_inset)

	# If the row exposes a live apply, nudge it
	if row.has_method("_apply_layout_metrics"):
		row.call("_apply_layout_metrics")


# Convenience: apply current sheet knobs to all existing rows
func refresh_all_row_layouts() -> void:
	var s: int = 0
	while s < 4:
		var vb := get_panel_vbox(s)
		if vb != null:
			for c in vb.get_children():
				var row := c as Control
				if row != null:
					_configure_row_visual(row)
		s += 1


# ---------------------------
# Sorting & entry helpers
# ---------------------------
func _entry_get_level(v: Variant) -> int:
	if typeof(v) == TYPE_DICTIONARY:
		var d := v as Dictionary
		if d.has("level"):
			return int(d["level"])
	return 1


func _entry_get_name(v: Variant) -> String:
	if typeof(v) == TYPE_DICTIONARY:
		var d := v as Dictionary
		if d.has("name"):
			return String(d["name"])
	return ""


func _entry_get_desc(v: Variant) -> String:
	if typeof(v) == TYPE_DICTIONARY:
		var d := v as Dictionary
		if d.has("description"):
			return String(d["description"])
		if d.has("desc"):
			return String(d["desc"])
	return ""


func _cmp_entries_by_level_then_name(a: Variant, b: Variant) -> bool:
	var la: int = _entry_get_level(a)
	var lb: int = _entry_get_level(b)
	if la < lb:
		return true
	if la > lb:
		return false
	var na: String = _entry_get_name(a)
	var nb: String = _entry_get_name(b)
	na = na.to_lower()
	nb = nb.to_lower()
	if na < nb:
		return true
	return false


func _shorten_desc(s: String) -> String:
	var t: String = s.strip_edges()
	t = t.replace("\n", " ")
	if desc_inline_max_chars > 0 and t.length() > desc_inline_max_chars:
		t = t.substr(0, desc_inline_max_chars - 1) + "…"
	return t


func populate_panel(index: int, entries: Array) -> void:
	var vb := get_panel_vbox(index)
	if vb == null:
		return
	clear_panel(index)

	# Sort by level ascending, then name (case-insensitive)
	var sorted: Array = entries.duplicate()
	sorted.sort_custom(Callable(self, "_cmp_entries_by_level_then_name"))

	for e in sorted:
		var level_in: int = 1
		var name_in: String = ""
		var cost_in: int = 1
		var icon_in: Texture2D = demo_icon
		var ability_id: String = ""
		var unlocked: bool = false
		var desc_in: String = ""

		if typeof(e) == TYPE_DICTIONARY:
			var d := e as Dictionary
			if d.has("level"):
				level_in = int(d["level"])
			if d.has("name"):
				name_in = String(d["name"])
			if d.has("cost"):
				cost_in = int(d["cost"])
			if d.has("icon"):
				icon_in = d["icon"] as Texture2D
			if d.has("ability_id"):
				ability_id = String(d["ability_id"])
			if d.has("unlocked"):
				unlocked = bool(d["unlocked"])
			desc_in = _entry_get_desc(d)

		var row_display_name: String = name_in

		var row := _make_ability_item(row_display_name, cost_in, icon_in, ability_id, unlocked, level_in, desc_in)
		vb.add_child(row)
		_apply_row_mouse_and_width(row)
		_configure_row_visual(row)  # push sheet knobs into the row

	_sync_row_widths()
	refresh_all_row_layouts()  # ensure all rows reflect current Inspector knobs immediately


func _on_row_purchase_requested(ability_id: String, cost_points: int) -> void:
	ability_purchase_requested.emit(ability_id, cost_points)


func _on_row_clicked(_ability_name_or_id: String) -> void:
	pass


# -------------------------------------------------------------------
# SYNC ROW WIDTHS (CLAMP TO BACKGROUND)
# -------------------------------------------------------------------
func _sync_row_widths() -> void:
	# Inner usable width inside the SkillTreeBG frame.
	var desired_w: float = float(background_size.x) - float(rows_offset.x) * 2.0
	if desired_w < 32.0:
		desired_w = 32.0

	var i: int = 0
	while i < _panel_vboxes.size():
		var vb := _panel_vboxes[i]
		if vb != null:
			var j: int = 0
			while j < vb.get_child_count():
				var c := vb.get_child(j) as Control
				if c != null:
					# Rows should not expand beyond this width; clamp.
					c.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

					var sz: Vector2 = c.custom_minimum_size
					if sz.y < 18.0:
						sz.y = 18.0
					sz.x = desired_w

					c.custom_minimum_size = sz
					c.size = sz
					c.mouse_filter = Control.MOUSE_FILTER_STOP
				j += 1
		i += 1


func _fix_mouse_filters_and_layers() -> void:
	if _bg_tex != null:
		_bg_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_bg_tex.z_as_relative = false
		_bg_tex.z_index = 0

	var i: int = 0
	while i < _panels.size():
		var sc: ScrollContainer = _panels[i]
		if sc != null:
			sc.mouse_filter = Control.MOUSE_FILTER_PASS
			sc.focus_mode = Control.FOCUS_NONE
			sc.clip_contents = true
			sc.z_as_relative = false
			sc.z_index = 10
		var vb: VBoxContainer = _panel_vboxes[i]
		if vb != null:
			vb.mouse_filter = Control.MOUSE_FILTER_PASS
			vb.focus_mode = Control.FOCUS_NONE
			for c in vb.get_children():
				var row: Control = c as Control
				if row != null:
					row.mouse_filter = Control.MOUSE_FILTER_STOP
					row.focus_mode = Control.FOCUS_CLICK
		i += 1


func _set_panels_drag_passthrough(active: bool) -> void:
	var mf: int = Control.MOUSE_FILTER_PASS
	if active:
		mf = Control.MOUSE_FILTER_IGNORE
	var i: int = 0
	while i < _panels.size():
		var sc: ScrollContainer = _panels[i]
		if sc != null:
			sc.mouse_filter = mf
		var vb: VBoxContainer = _panel_vboxes[i]
		if vb != null:
			vb.mouse_filter = Control.MOUSE_FILTER_PASS
		i += 1


func _draw() -> void:
	if not debug_draw_layout:
		return
	# Red: tabs bar across the top of the whole sheet
	draw_rect(Rect2(Vector2(0, 0), Vector2(panel_size.x, tabs_height)), Color(1.0, 0.2, 0.2, 0.5), false, 1.0)

	# Green: SkillTreeBG (the background block)
	var bg_rect := Rect2(Vector2(_bg_origin), Vector2(background_size))
	draw_rect(bg_rect, Color(0.2, 1.0, 0.2, 0.35), false, 1.0)

	# Blue: panel area == EXACTLY the background area
	draw_rect(bg_rect, Color(0.2, 0.6, 1.0, 0.7), false, 1.0)
