extends HBoxContainer
class_name AbilityListItem
# Godot 4.5 — fully typed, no ternaries.
# Lets SkillTreeSheet own row width; keeps cost label visible.
# Has control for vertical gap (between name + description) and desc font.

signal clicked(item_name: String)
signal drag_started(item_name: String)
signal drag_ended(item_name: String)
signal purchase_requested(ability_id: String, cost_points: int)

@export var icon: Texture2D = null
@export var item_name: String = "Ability"
@export var description: String = ""
@export var ability_id: String = ""
@export var ability_level: int = 1
@export var cost_points: int = 1
@export var locked: bool = false
@export var affordable: bool = true
@export var row_height: int = 24
@export var name_font_size: int = 10
@export var desc_font_size: int = 9
@export var cost_font_size: int = 9

# Vertical space between name + description
@export var text_line_separation: int = 0

# Description font (control wrap line spacing via this resource)
@export var desc_font: Font = null

# Cost rail geometry (make this small so text gets most of the width)
@export var cost_min_width: int = 5
@export var cost_left_inset: int = 0
@export var cost_right_inset: int = 1

@export var color_name_unlocked: Color = Color(1, 1, 1, 1)
@export var color_name_locked: Color = Color(0.85, 0.85, 0.85, 0.9)
@export var color_desc_unlocked: Color = Color(0.85, 0.85, 0.85, 1.0)
@export var color_desc_locked: Color = Color(0.7, 0.7, 0.7, 0.9)
@export var color_cost_normal: Color = Color(1, 1, 1, 1)
@export var color_cost_affordable: Color = Color(0.8, 1.0, 0.8, 1.0)
@export var color_cost_unaffordable: Color = Color(1.0, 0.6, 0.6, 1.0)

@export var icon_locked_opacity: float = 0.45
@export var icon_unlocked_opacity: float = 1.0

@export var slot_bg_color: Color = Color(0, 0, 0, 0.25)
@export var slot_border_color: Color = Color(1, 1, 1, 0.55)
@export var slot_border_width: int = 1
@export var slot_corner_radius: int = 2
@export var slot_question_color: Color = Color(1, 1, 1, 0.8)

@export var debug_allow_drag_when_locked: bool = false
@export var debug_logs: bool = false
@export var drag_threshold_pixels: float = 6.0

var _icon_holder: Control = null
var _icon_slot_panel: Panel = null
var _icon_rect: TextureRect = null

var _text_column: VBoxContainer = null
var _name_label: Label = null
var _desc_label: Label = null

var _pad_left: Control = null
var _cost_label: Label = null
var _pad_right: Control = null

var _built: bool = false

var _lmb_down: bool = false
var _drag_active: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO


# --------------------------------------------------------------------
# READY
# --------------------------------------------------------------------
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_CLICK

	# Row itself does not request extra width; SkillTreeSheet clamps width.
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	custom_minimum_size = Vector2(max(custom_minimum_size.x, 96.0), float(max(1, row_height)))

	_ensure_built()
	_apply_texts_and_values()
	_refresh_icon_visibility()
	_refresh_visual_state()
	_apply_layout_metrics()

	if debug_logs:
		mouse_entered.connect(_on_mouse_enter)
		mouse_exited.connect(_on_mouse_exit)


func _on_mouse_enter() -> void:
	if debug_logs:
		print("[AbilityListItem] mouse_enter ", item_name, " id=", ability_id)


func _on_mouse_exit() -> void:
	if debug_logs:
		print("[AbilityListItem] mouse_exit  ", item_name, " id=", ability_id)


# --------------------------------------------------------------------
# BUILD INTERNAL CHILDREN
# --------------------------------------------------------------------
func _ensure_built() -> void:
	if _built:
		return

	alignment = ALIGNMENT_BEGIN
	clip_contents = false
	custom_minimum_size = Vector2(custom_minimum_size.x, float(row_height))

	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical = Control.SIZE_SHRINK_CENTER

	mouse_filter = Control.MOUSE_FILTER_STOP

	# -------------- ICON HOLDER -----------------
	_icon_holder = Control.new()
	_icon_holder.custom_minimum_size = Vector2(16.0, 16.0)
	_icon_holder.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_icon_holder.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon_holder)

	_icon_slot_panel = Panel.new()
	_icon_slot_panel.name = "IconSlot"
	_icon_slot_panel.custom_minimum_size = Vector2(16.0, 16.0)
	_icon_slot_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_slot_stylebox(_icon_slot_panel)
	_icon_holder.add_child(_icon_slot_panel)

	_icon_rect = TextureRect.new()
	_icon_rect.custom_minimum_size = Vector2(16.0, 16.0)
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
	_icon_rect.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	_icon_rect.texture = icon
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_holder.add_child(_icon_rect)

	# -------------- TEXT COLUMN -----------------
	_text_column = VBoxContainer.new()
	# Uses all remaining width between icon and cost.
	_text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_text_column.alignment = BoxContainer.ALIGNMENT_BEGIN
	_text_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_column.add_theme_constant_override("separation", text_line_separation)
	add_child(_text_column)

	# NAME LABEL
	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.clip_text = true
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_label.add_theme_font_size_override("font_size", name_font_size)
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_column.add_child(_name_label)

	# DESCRIPTION LABEL
	_desc_label = Label.new()
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_desc_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_desc_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_desc_label.add_theme_font_size_override("font_size", desc_font_size)
	if desc_font != null:
		_desc_label.add_theme_font_override("font", desc_font)
	_desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_column.add_child(_desc_label)

	# -------- COST RAIL (UNSQUEEZABLE BUT NARROW) --------
	_pad_left = Control.new()
	_pad_left.custom_minimum_size = Vector2(float(cost_left_inset), 1.0)
	_pad_left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_pad_left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pad_left)

	_cost_label = Label.new()
	_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cost_label.custom_minimum_size = Vector2(float(cost_min_width), float(row_height))
	_cost_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_cost_label.add_theme_font_size_override("font_size", cost_font_size)
	_cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_cost_label)

	_pad_right = Control.new()
	_pad_right.custom_minimum_size = Vector2(float(cost_right_inset), 1.0)
	_pad_right.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_pad_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_pad_right)

	_built = true


# --------------------------------------------------------------------
# SLOT STYLEBOX
# --------------------------------------------------------------------
func _apply_slot_stylebox(p: Panel) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = slot_bg_color
	sb.border_color = slot_border_color
	sb.border_width_left = slot_border_width
	sb.border_width_top = slot_border_width
	sb.border_width_right = slot_border_width
	sb.border_width_bottom = slot_border_width
	sb.corner_radius_top_left = slot_corner_radius
	sb.corner_radius_top_right = slot_corner_radius
	sb.corner_radius_bottom_left = slot_corner_radius
	sb.corner_radius_bottom_right = slot_corner_radius
	p.add_theme_stylebox_override("panel", sb)

	var q := p.get_node_or_null("SlotQuestion") as Label
	if q == null:
		q = Label.new()
		q.name = "SlotQuestion"
		q.text = "?"
		q.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		q.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		q.add_theme_color_override("font_color", slot_question_color)
		q.add_theme_font_size_override("font_size", 9)
		q.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		q.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		q.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.add_child(q)


# --------------------------------------------------------------------
# PUBLIC API
# --------------------------------------------------------------------
func set_data(
		name_in: String,
		cost_in: int,
		icon_in: Texture2D,
		ability_id_in: String = "",
		unlocked_in: bool = false,
		description_in: String = "",
		level_in: int = -1
	) -> void:

	item_name = name_in
	cost_points = cost_in
	icon = icon_in

	if ability_id_in != "":
		ability_id = ability_id_in
	if unlocked_in:
		locked = false
	if description_in != "":
		description = description_in
	if level_in >= 0:
		ability_level = level_in

	_ensure_built()
	_apply_texts_and_values()
	_refresh_icon_visibility()
	_refresh_visual_state()
	_apply_layout_metrics()


func set_layout_metrics(name_fs: int, cost_fs: int, cost_min: int, inset_l: int, inset_r: int) -> void:
	name_font_size = name_fs
	cost_font_size = cost_fs
	cost_min_width = cost_min
	cost_left_inset = inset_l
	cost_right_inset = inset_r
	_apply_layout_metrics()


func set_locked(is_locked: bool) -> void:
	locked = is_locked
	_ensure_built()
	_refresh_visual_state()


func set_unlocked(is_unlocked: bool) -> void:
	locked = not is_unlocked
	_ensure_built()
	_refresh_visual_state()


func set_affordable(is_affordable: bool) -> void:
	affordable = is_affordable
	_ensure_built()
	_refresh_visual_state()


# --------------------------------------------------------------------
# INPUT & CLICK
# --------------------------------------------------------------------
func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_lmb_down = true
			_drag_active = false
			_drag_start_pos = mb.position
			if debug_logs:
				print("[AbilityListItem] LMB down name=", item_name, " id=", ability_id, " locked=", locked)
			accept_event()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			var was_drag: bool = _drag_active
			_lmb_down = false
			_drag_active = false

			if not was_drag:
				if debug_logs:
					print("[AbilityListItem] LMB up click name=", item_name, " id=", ability_id, " locked=", locked)
				clicked.emit(item_name)
				if locked and ability_id != "":
					purchase_requested.emit(ability_id, cost_points)
			accept_event()
			return

	var mm := event as InputEventMouseMotion
	if mm != null and _lmb_down:
		var delta: Vector2 = mm.position - _drag_start_pos
		if delta.length() >= drag_threshold_pixels:
			_try_begin_manual_drag()
			accept_event()
			return


# --------------------------------------------------------------------
# DRAG HELPERS
# --------------------------------------------------------------------
func _try_begin_manual_drag() -> void:
	if _drag_active:
		return

	var allow_drag: bool = true
	if not debug_allow_drag_when_locked and locked:
		allow_drag = false
	if ability_id == "":
		allow_drag = false

	if not allow_drag:
		if debug_logs:
			print("[AbilityListItem] drag blocked name=", item_name, " id=", ability_id, " locked=", locked)
		return

	_drag_active = true
	drag_started.emit(item_name)

	var payload: Dictionary = _build_drag_payload()
	var preview: Control = _build_drag_preview()
	force_drag(payload, preview)


func _get_drag_data(at_position: Vector2) -> Variant:
	return get_drag_data(at_position)


func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	return can_drop_data(at_position, data)


func _drop_data(at_position: Vector2, data: Variant) -> void:
	drop_data(at_position, data)


func get_drag_data(_at_position: Vector2) -> Variant:
	var allow_drag: bool = true

	if not debug_allow_drag_when_locked and locked:
		allow_drag = false
	if ability_id == "":
		allow_drag = false

	if not allow_drag:
		if debug_logs:
			print("[AbilityListItem] get_drag_data blocked name=", item_name, " id=", ability_id, " locked=", locked)
		return null

	_drag_active = true
	drag_started.emit(item_name)

	var preview := _build_drag_preview()
	set_drag_preview(preview)
	return _build_drag_payload()


func can_drop_data(_at_position: Vector2, _data: Variant) -> bool:
	return false


func drop_data(_at_position: Vector2, _data: Variant) -> void:
	drag_ended.emit(item_name)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		drag_ended.emit(item_name)
		_drag_active = false
		_lmb_down = false


# --------------------------------------------------------------------
# DRAG PAYLOAD
# --------------------------------------------------------------------
func _build_drag_payload() -> Dictionary:
	var payload: Dictionary = {}
	payload["drag_type"] = "ability"
	payload["ability_id"] = ability_id
	payload["type"] = "ability"
	payload["id"] = ability_id
	return payload


func _build_drag_preview() -> Control:
	var preview := HBoxContainer.new()
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.custom_minimum_size = Vector2(64.0, 18.0)

	var pi := TextureRect.new()
	pi.custom_minimum_size = Vector2(16.0, 16.0)
	pi.stretch_mode = TextureRect.STRETCH_KEEP
	pi.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	pi.texture = icon
	pi.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_child(pi)

	var pl := Label.new()
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pl.add_theme_font_size_override("font_size", name_font_size)

	var title: String = item_name
	if ability_level > 0:
		title = "Lv " + str(ability_level) + "  " + item_name
	pl.text = title

	preview.add_child(pl)

	return preview


# --------------------------------------------------------------------
# VISUAL STATE
# --------------------------------------------------------------------
func _apply_texts_and_values() -> void:
	if _name_label != null:
		var title: String = item_name
		if ability_level > 0:
			title = "Lv " + str(ability_level) + "  " + item_name
		_name_label.text = title

	if _desc_label != null:
		_desc_label.text = description

	if _cost_label != null:
		_cost_label.text = str(cost_points)

	if _icon_rect != null:
		_icon_rect.texture = icon


func _refresh_icon_visibility() -> void:
	if _icon_slot_panel == null or _icon_rect == null:
		return

	var has_tex: bool = icon != null
	_icon_slot_panel.visible = not has_tex
	_icon_rect.visible = true

	var m: Color = _icon_rect.modulate
	m.a = icon_unlocked_opacity
	_icon_rect.modulate = m

	if not has_tex:
		_icon_rect.texture = null


func _refresh_visual_state() -> void:
	if _name_label != null:
		if locked:
			_name_label.add_theme_color_override("font_color", color_name_locked)
		else:
			_name_label.add_theme_color_override("font_color", color_name_unlocked)

	if _desc_label != null:
		if locked:
			_desc_label.add_theme_color_override("font_color", color_desc_locked)
		else:
			_desc_label.add_theme_color_override("font_color", color_desc_unlocked)

	if _cost_label != null:
		if locked:
			if affordable:
				_cost_label.add_theme_color_override("font_color", color_cost_affordable)
			else:
				_cost_label.add_theme_color_override("font_color", color_cost_unaffordable)
		else:
			_cost_label.add_theme_color_override("font_color", color_cost_normal)

	if _icon_rect != null:
		var m: Color = _icon_rect.modulate
		if locked:
			m.a = icon_locked_opacity
		else:
			m.a = icon_unlocked_opacity
		_icon_rect.modulate = m


# --------------------------------------------------------------------
# LAYOUT METRICS
# --------------------------------------------------------------------
func _apply_layout_metrics() -> void:
	custom_minimum_size.y = float(max(1, row_height))

	if _name_label != null:
		_name_label.add_theme_font_size_override("font_size", name_font_size)
		_name_label.clip_text = true
		_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	if _desc_label != null:
		_desc_label.add_theme_font_size_override("font_size", desc_font_size)
		_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		_desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if desc_font != null:
			_desc_label.add_theme_font_override("font", desc_font)

	if _text_column != null:
		_text_column.add_theme_constant_override("separation", text_line_separation)

	if _pad_left != null:
		_pad_left.custom_minimum_size.x = float(max(0, cost_left_inset))

	if _cost_label != null:
		_cost_label.add_theme_font_size_override("font_size", cost_font_size)
		_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_cost_label.size_flags_horizontal = Control.SIZE_SHRINK_END
		_cost_label.custom_minimum_size.x = float(max(0, cost_min_width))

	if _pad_right != null:
		_pad_right.custom_minimum_size.x = float(max(0, cost_right_inset))

	# Row width is owned by the parent (SkillTreeSheet); do not expand.
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
