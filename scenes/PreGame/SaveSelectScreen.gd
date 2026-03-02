extends Control
class_name SaveSelectScreen

signal close_requested()
signal slot_action_completed(intent: int, slot_index: int)

enum SaveSelectIntent {
	LOAD = 0,
	SAVE = 1,
}

@export_group("Intent")
@export var intent: SaveSelectIntent = SaveSelectIntent.LOAD
@export var overlay_mode: bool = false
@export var close_after_action: bool = true

@export_file("*.tscn") var return_scene_path: String = ""

@export_file("*.tscn") var game_scene_path: String = "res://scenes/Main.tscn"
@export_file("*.tscn") var title_scene_path: String = "res://scenes/PreGame/TitleScreen.tscn"

@export var slots_container_path: NodePath = NodePath("Slots/VBox")

@export var row_height_px: int = 64
@export var row_padding_px: int = 8
@export var show_area_path: bool = true
@export var auto_focus_last_played: bool = true

@export var slot_label_font_size: int = 8
@export var title_font_size: int = 9
@export var sub_font_size: int = 8

@export_group("Theme Colors")
@export var slot_bg_hex: String = "#d9a066"
@export var text_hex: String = "#40221c"

@export var slot_bg_hover_mul: float = 1.06
@export var slot_bg_pressed_mul: float = 0.94
@export var slot_bg_disabled_mul: float = 0.78

@export_group("Party Preview")
@export var portrait_prefer_idle_right: bool = true
@export var portrait_member_gap_px: int = 3
@export var portrait_max_members: int = 4
@export var portrait_box_width_px: int = 24
@export var portrait_box_height_px: int = 64
@export var portrait_show_placeholder_when_missing: bool = true

@export var portrait_center_x_px: int = 32
@export var portrait_center_y_px: int = 32
@export var portrait_vertical_offset_px: int = 0

@export_group("Party Preview — VisualRoot")
@export var use_visualroot_subviewport: bool = true
@export var visualroot_node_name: String = "VisualRoot"
@export var equipment_visuals_node_name: String = "EquipmentVisuals"
@export var prefer_idle_side_name: String = "idle_side" # case-insensitive
@export var portrait_viewport_scale: float = 2.0
@export var portrait_viewport_offset_px: Vector2 = Vector2(0.0, 10.0)
@export var hide_weapon_nodes_in_portrait: bool = true
@export var weapon_node_names_to_hide: PackedStringArray = PackedStringArray(["WeaponRoot", "Mainhand", "Offhand", "WeaponTrail"])

# Apply saved leader customization (gender + hair) before applying equipment.
@export_group("Party Preview — Saved Customization")
@export var apply_player_customization_to_leader: bool = true

# Slot names in the equipment dict
@export var equipment_slot_chest_name: String = "chest"
@export var equipment_slot_back_name: String = "back"

@export_group("Selection Border")
@export var selection_border_enabled: bool = true
@export var selection_border_width_px: int = 1
@export var selection_border_color: Color = Color(1.0, 1.0, 1.0, 1.0)

@export_group("Scrolling")
@export var enable_scrolling: bool = true
@export var scroll_container_name: String = "SlotsScroll"
@export var scroll_wheel_step_px: int = 56

@export_group("Slots Panel")
@export var slots_fixed_width_px: int = 480
@export var slots_fixed_height_px: int = 270

var _save_sys: SaveSystem
var _slots_vbox: VBoxContainer
var _slots_panel: Control = null
var _scroll: ScrollContainer = null

var _slot_payload_cache: Dictionary = {}
var _scene_idle_frame_cache: Dictionary = {}
var _scene_class_title_cache: Dictionary = {}

var _slot_buttons: Dictionary = {}
var _selected_slot: int = -1

var _slot_bg: Color = Color(0.85, 0.62, 0.40, 1.0)
var _text_color: Color = Color(0.25, 0.13, 0.11, 1.0)

func _ready() -> void:
	_sanitize()

	_slot_bg = _color_from_hex(slot_bg_hex, Color(0.85, 0.62, 0.40, 1.0))
	_text_color = _color_from_hex(text_hex, Color(0.25, 0.13, 0.11, 1.0))

	_save_sys = get_node_or_null("/root/SaveSys") as SaveSystem
	_slots_vbox = get_node_or_null(slots_container_path) as VBoxContainer

	if _slots_vbox != null:
		_slots_panel = _slots_vbox.get_parent() as Control

	if enable_scrolling:
		_ensure_scroll_container()

	if not resized.is_connected(_sync_layout):
		resized.connect(_sync_layout)

	_sync_layout()
	_wire_signals()
	_rebuild_rows()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if overlay_mode:
			_request_close()
		else:
			_go_back()

func _sanitize() -> void:
	if slot_label_font_size < 6:
		slot_label_font_size = 8
	if title_font_size < 6:
		title_font_size = 9
	if sub_font_size < 6:
		sub_font_size = 8

	if row_height_px < 24:
		row_height_px = 64
	if row_padding_px < 0:
		row_padding_px = 0

	if portrait_member_gap_px < 0:
		portrait_member_gap_px = 0
	if portrait_max_members < 1:
		portrait_max_members = 4
	if portrait_box_width_px < 8:
		portrait_box_width_px = 24
	if portrait_box_height_px < 24:
		portrait_box_height_px = 64

	if selection_border_width_px < 1:
		selection_border_width_px = 1

	if scroll_wheel_step_px < 8:
		scroll_wheel_step_px = 56

	if slots_fixed_width_px < 64:
		slots_fixed_width_px = 480
	if slots_fixed_height_px < 64:
		slots_fixed_height_px = 270

	if slot_bg_hover_mul < 0.1:
		slot_bg_hover_mul = 1.06
	if slot_bg_pressed_mul < 0.1:
		slot_bg_pressed_mul = 0.94
	if slot_bg_disabled_mul < 0.1:
		slot_bg_disabled_mul = 0.78

func _color_from_hex(hex: String, fallback: Color) -> Color:
	var s: String = hex.strip_edges()
	if s == "":
		return fallback
	if not s.begins_with("#"):
		s = "#" + s
	var c: Color = Color.html(s)
	if c.a <= 0.0:
		return fallback
	return c

func _mul_rgb(c: Color, mul: float) -> Color:
	var out: Color = c
	out.r = clampf(out.r * mul, 0.0, 1.0)
	out.g = clampf(out.g * mul, 0.0, 1.0)
	out.b = clampf(out.b * mul, 0.0, 1.0)
	out.a = c.a
	return out

func _ensure_scroll_container() -> void:
	if _slots_vbox == null:
		return

	var parent_node: Node = _slots_vbox.get_parent()
	var parent_scroll: ScrollContainer = parent_node as ScrollContainer
	if parent_scroll != null:
		_scroll = parent_scroll
		_slots_panel = _scroll.get_parent() as Control
		return

	var slots_parent: Control = parent_node as Control
	if slots_parent == null:
		return

	_slots_panel = slots_parent

	var existing: Node = slots_parent.get_node_or_null(scroll_container_name)
	var existing_scroll: ScrollContainer = existing as ScrollContainer
	if existing_scroll != null:
		_scroll = existing_scroll
	else:
		_scroll = ScrollContainer.new()
		_scroll.name = scroll_container_name
		slots_parent.add_child(_scroll)

	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP

	_slots_vbox.reparent(_scroll)
	_slots_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slots_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

func _sync_layout() -> void:
	if _slots_panel != null:
		var target_size: Vector2 = Vector2(float(slots_fixed_width_px), float(slots_fixed_height_px))
		_slots_panel.custom_minimum_size = target_size
		_slots_panel.size = target_size

	if _scroll != null:
		_scroll.anchor_left = 0.0
		_scroll.anchor_top = 0.0
		_scroll.anchor_right = 1.0
		_scroll.anchor_bottom = 1.0
		_scroll.offset_left = 0.0
		_scroll.offset_top = 0.0
		_scroll.offset_right = 0.0
		_scroll.offset_bottom = 0.0

	if _slots_vbox != null:
		_slots_vbox.add_theme_constant_override("separation", 2)
		_slots_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_slots_vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

func _wire_signals() -> void:
	if _save_sys != null:
		if _save_sys.has_signal("save_slots_changed"):
			if not _save_sys.save_slots_changed.is_connected(_on_save_slots_changed):
				_save_sys.save_slots_changed.connect(_on_save_slots_changed)

func _on_save_slots_changed() -> void:
	_slot_payload_cache.clear()
	_scene_class_title_cache.clear()
	_rebuild_rows()

func _rebuild_rows() -> void:
	if _slots_vbox == null:
		return

	_clear_children(_slots_vbox)
	_slot_buttons.clear()
	_selected_slot = -1

	var max_slots: int = 6
	if _save_sys != null:
		max_slots = SaveSystem.MAX_SLOTS

	var focus_slot: int = -1
	if auto_focus_last_played and _save_sys != null:
		focus_slot = _save_sys.get_last_played_slot()

	var slot_index: int = 1
	while slot_index <= max_slots:
		var row_button: Button = _build_slot_row(slot_index)
		_slots_vbox.add_child(row_button)
		_slot_buttons[slot_index] = row_button

		if focus_slot == slot_index:
			row_button.grab_focus()
			_set_selected_slot(slot_index, true)

		slot_index += 1

func _apply_slot_button_theme(btn: Button, disabled: bool) -> void:
	var base: Color = _slot_bg

	var bg_normal: Color = base
	var bg_hover: Color = _mul_rgb(base, slot_bg_hover_mul)
	var bg_pressed: Color = _mul_rgb(base, slot_bg_pressed_mul)
	var bg_disabled: Color = _mul_rgb(base, slot_bg_disabled_mul)

	if disabled:
		bg_normal = bg_disabled
		bg_hover = bg_disabled
		bg_pressed = bg_disabled

	btn.add_theme_stylebox_override("normal", _make_flat_bg(bg_normal))
	btn.add_theme_stylebox_override("hover", _make_flat_bg(bg_hover))
	btn.add_theme_stylebox_override("pressed", _make_flat_bg(bg_pressed))
	btn.add_theme_stylebox_override("disabled", _make_flat_bg(bg_disabled))
	btn.add_theme_stylebox_override("focus", _make_flat_bg(bg_normal))

func _make_flat_bg(bg: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_width_left = 0
	sb.border_width_top = 0
	sb.border_width_right = 0
	sb.border_width_bottom = 0
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	return sb

func _build_slot_row(slot_index: int) -> Button:
	var btn: Button = Button.new()
	btn.name = "Slot_%d" % slot_index
	btn.focus_mode = Control.FOCUS_ALL
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0.0, float(row_height_px))
	btn.text = ""

	if not btn.pressed.is_connected(_on_slot_pressed.bind(slot_index)):
		btn.pressed.connect(_on_slot_pressed.bind(slot_index))

	if not btn.focus_entered.is_connected(_on_slot_focus_entered.bind(slot_index)):
		btn.focus_entered.connect(_on_slot_focus_entered.bind(slot_index))

	if not btn.mouse_entered.is_connected(_on_slot_mouse_entered.bind(slot_index)):
		btn.mouse_entered.connect(_on_slot_mouse_entered.bind(slot_index))

	if not btn.gui_input.is_connected(_on_row_gui_input.bind(btn)):
		btn.gui_input.connect(_on_row_gui_input.bind(btn))

	var exists: bool = false
	if _save_sys != null:
		exists = _save_sys.slot_exists(slot_index)

	var disabled: bool = false
	if intent == SaveSelectIntent.LOAD:
		disabled = not exists
	else:
		disabled = false

	btn.disabled = disabled
	_apply_slot_button_theme(btn, btn.disabled)

	var hb: HBoxContainer = HBoxContainer.new()
	hb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hb.add_theme_constant_override("separation", row_padding_px)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(hb)

	var payload: Dictionary = _get_payload_for_slot(slot_index)
	var strip: Control = _build_party_preview_strip(payload)
	hb.add_child(strip)

	var vb: VBoxContainer = VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 0)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(vb)

	var line_name: String = _get_slot_name_line(slot_index)
	var line_class: String = _get_slot_class_line(slot_index, payload)
	var line_level: String = _get_slot_level_line(slot_index)
	var line_story: String = _get_slot_sub_line(slot_index)

	var name_label: Label = Label.new()
	name_label.text = line_name
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", title_font_size)
	name_label.add_theme_color_override("font_color", _text_color)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_ellipsis_label(name_label)
	vb.add_child(name_label)

	var class_label: Label = Label.new()
	class_label.text = line_class
	class_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	class_label.add_theme_font_size_override("font_size", sub_font_size)
	class_label.add_theme_color_override("font_color", _text_color)
	class_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_ellipsis_label(class_label)
	vb.add_child(class_label)

	var level_label: Label = Label.new()
	level_label.text = line_level
	level_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	level_label.add_theme_font_size_override("font_size", sub_font_size)
	level_label.add_theme_color_override("font_color", _text_color)
	level_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_ellipsis_label(level_label)
	vb.add_child(level_label)

	var story_label: Label = Label.new()
	story_label.text = line_story
	story_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	story_label.add_theme_font_size_override("font_size", sub_font_size)
	story_label.add_theme_color_override("font_color", _text_color)
	story_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_ellipsis_label(story_label)
	vb.add_child(story_label)

	var border: Panel = _make_selection_border_panel()
	btn.add_child(border)
	btn.set_meta("selection_border", border)

	_update_border_for_button(btn, slot_index)
	return btn

func _on_row_gui_input(event: InputEvent, _btn: Button) -> void:
	if _scroll == null:
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_scroll.scroll_vertical = _scroll.scroll_vertical + scroll_wheel_step_px
				accept_event()
				return
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_scroll.scroll_vertical = _scroll.scroll_vertical - scroll_wheel_step_px
				accept_event()
				return

func _make_selection_border_panel() -> Panel:
	var p: Panel = Panel.new()
	p.name = "SelectionBorder"
	p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.visible = false

	if selection_border_enabled:
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		sb.border_color = selection_border_color
		sb.border_width_left = selection_border_width_px
		sb.border_width_top = selection_border_width_px
		sb.border_width_right = selection_border_width_px
		sb.border_width_bottom = selection_border_width_px
		p.add_theme_stylebox_override("panel", sb)

	return p

func _on_slot_focus_entered(slot_index: int) -> void:
	_set_selected_slot(slot_index, true)

func _on_slot_mouse_entered(slot_index: int) -> void:
	_set_selected_slot(slot_index, false)

func _set_selected_slot(slot_index: int, ensure_visible: bool) -> void:
	if selection_border_enabled == false:
		return
	if _selected_slot == slot_index:
		if ensure_visible:
			_ensure_selected_visible(slot_index)
		return

	_selected_slot = slot_index

	for k in _slot_buttons.keys():
		var idx: int = int(k)
		var b_any: Variant = _slot_buttons[k]
		var b: Button = b_any as Button
		if b != null:
			_update_border_for_button(b, idx)

	if ensure_visible:
		_ensure_selected_visible(slot_index)

func _ensure_selected_visible(slot_index: int) -> void:
	if _scroll == null:
		return
	if not _slot_buttons.has(slot_index):
		return
	var b_any: Variant = _slot_buttons[slot_index]
	var b: Control = b_any as Control
	if b == null:
		return
	_scroll.ensure_control_visible(b)

func _update_border_for_button(btn: Button, slot_index: int) -> void:
	if btn == null:
		return
	if selection_border_enabled == false:
		return
	if not btn.has_meta("selection_border"):
		return

	var border_any: Variant = btn.get_meta("selection_border")
	var border: Panel = border_any as Panel
	if border == null:
		return

	border.visible = (slot_index == _selected_slot)

# ---------------------------------------------------------------------
# Party strip (RIGHT -> LEFT)
# ---------------------------------------------------------------------
func _build_party_preview_strip(payload: Dictionary) -> Control:
	var strip: HBoxContainer = HBoxContainer.new()
	strip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	strip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	strip.add_theme_constant_override("separation", portrait_member_gap_px)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var reserved_w: int = _reserved_strip_width_px()
	var h: int = max(row_height_px, portrait_box_height_px)
	strip.custom_minimum_size = Vector2(float(reserved_w), float(h))

	var ordered_members: Array[Dictionary] = _extract_party_members_ordered_marked(payload)

	# Render RIGHT -> LEFT (reverse)
	var render_members: Array[Dictionary] = []
	var i_rev: int = ordered_members.size() - 1
	while i_rev >= 0:
		render_members.append(ordered_members[i_rev])
		i_rev -= 1

	var shown: int = 0
	var i: int = 0
	while i < render_members.size():
		if shown >= portrait_max_members:
			break
		strip.add_child(_build_member_box_for_member_dict(render_members[i], payload))
		shown += 1
		i += 1

	while shown < portrait_max_members:
		strip.add_child(_build_empty_member_box())
		shown += 1

	return strip

func _reserved_strip_width_px() -> int:
	var gaps: int = portrait_max_members - 1
	if gaps < 0:
		gaps = 0
	return (portrait_box_width_px * portrait_max_members) + (portrait_member_gap_px * gaps)

func _build_member_box_for_member_dict(member_dict: Dictionary, payload: Dictionary) -> Control:
	var box: Control = Control.new()
	box.custom_minimum_size = Vector2(float(portrait_box_width_px), float(portrait_box_height_px))
	box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.clip_contents = true

	var scene_path: String = ""
	if member_dict.has("scene_path"):
		scene_path = str(member_dict["scene_path"]).strip_edges()

	if use_visualroot_subviewport and scene_path != "":
		var ok: bool = _try_build_member_visualroot_viewport(box, scene_path, member_dict, payload)
		if ok:
			return box

	# Fallback: legacy single-frame
	var tex: Texture2D = _get_idle_frame_for_scene(scene_path)
	if tex == null:
		if portrait_show_placeholder_when_missing:
			var ph: Label = Label.new()
			ph.text = "?"
			ph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			ph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			ph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			ph.add_theme_color_override("font_color", _text_color)
			ph.mouse_filter = Control.MOUSE_FILTER_IGNORE
			box.add_child(ph)
		return box

	var tr: TextureRect = TextureRect.new()
	tr.texture = tex
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.stretch_mode = TextureRect.STRETCH_KEEP
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var ts: Vector2 = tex.get_size()
	var desired_center: Vector2 = Vector2(float(portrait_center_x_px), float(portrait_center_y_px))
	var box_center: Vector2 = Vector2(float(portrait_box_width_px) * 0.5, float(portrait_box_height_px) * 0.5)

	var pos: Vector2 = box_center - desired_center
	pos.y += float(portrait_vertical_offset_px)

	tr.position = pos
	tr.size = ts

	box.add_child(tr)
	return box

func _try_build_member_visualroot_viewport(parent_box: Control, scene_path: String, member_dict: Dictionary, payload: Dictionary) -> bool:
	if parent_box == null:
		return false
	if scene_path.strip_edges() == "":
		return false
	if not ResourceLoader.exists(scene_path):
		return false

	var ps_any: Resource = ResourceLoader.load(scene_path)
	var ps: PackedScene = ps_any as PackedScene
	if ps == null:
		return false

	var inst: Node = ps.instantiate()
	if inst == null:
		return false

	# 1) Apply leader customization (gender + hair) BEFORE equipment.
	if apply_player_customization_to_leader:
		var is_leader: bool = false
		if member_dict.has("__is_leader"):
			is_leader = bool(member_dict["__is_leader"])
		if is_leader:
			_apply_player_customization_to_actor_instance(inst, payload)

	# 2) Apply saved equipment (chest/back) onto EquipmentVisuals before cloning VisualRoot.
	_apply_saved_equipment_to_actor_instance(inst, member_dict)

	# 3) Clone VisualRoot.
	var vr: Node = _find_visual_root(inst)
	if vr == null:
		inst.queue_free()
		return false

	var clone: Node = vr.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
	inst.queue_free()

	if clone == null:
		return false

	# 4) Viewport
	var sv: SubViewport = SubViewport.new()
	sv.name = "PortraitViewport"
	sv.transparent_bg = true
	sv.disable_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.size = Vector2i(portrait_box_width_px, portrait_box_height_px)
	parent_box.add_child(sv)

	var root2d: Node2D = Node2D.new()
	root2d.name = "PortraitRoot2D"
	sv.add_child(root2d)

	root2d.add_child(clone)

	_disable_processing_recursive(clone)

	if hide_weapon_nodes_in_portrait:
		_hide_named_nodes_recursive(clone, weapon_node_names_to_hide)

	# Force idle_side case-insensitive.
	_force_animation_on_all_animated_sprites(clone, prefer_idle_side_name)

	var center: Vector2 = Vector2(float(sv.size.x) * 0.5, float(sv.size.y) * 0.5)
	var n2d: Node2D = clone as Node2D
	if n2d != null:
		n2d.position = center + portrait_viewport_offset_px
		n2d.scale = Vector2(portrait_viewport_scale, portrait_viewport_scale)

	var tr: TextureRect = TextureRect.new()
	tr.texture = sv.get_texture()
	tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent_box.add_child(tr)

	return true

func _apply_saved_equipment_to_actor_instance(actor_inst: Node, member_dict: Dictionary) -> void:
	if actor_inst == null:
		return
	if member_dict.is_empty():
		return
	if not member_dict.has("equipment"):
		return

	var equip_any: Variant = member_dict["equipment"]
	if typeof(equip_any) != TYPE_DICTIONARY:
		return
	var equip: Dictionary = equip_any

	var ev: Node = actor_inst.find_child(equipment_visuals_node_name, true, false)
	if ev == null:
		return

	# Chest
	var chest_path: String = _get_equipment_path_case_insensitive(equip, equipment_slot_chest_name)
	var chest_item: Resource = null
	if chest_path != "" and ResourceLoader.exists(chest_path):
		chest_item = ResourceLoader.load(chest_path)
	if ev.has_method("_apply_chest_item"):
		ev.call("_apply_chest_item", chest_item)

	# Back
	var back_path: String = _get_equipment_path_case_insensitive(equip, equipment_slot_back_name)
	var back_item: Resource = null
	if back_path != "" and ResourceLoader.exists(back_path):
		back_item = ResourceLoader.load(back_path)
	if ev.has_method("_apply_back_item"):
		ev.call("_apply_back_item", back_item)

func _get_equipment_path_case_insensitive(equip: Dictionary, slot_name: String) -> String:
	if equip.is_empty():
		return ""
	var want: String = slot_name.strip_edges().to_lower()
	if want == "":
		return ""

	if equip.has(slot_name):
		return str(equip[slot_name]).strip_edges()

	for k_any in equip.keys():
		var k: String = str(k_any).strip_edges()
		if k.to_lower() == want:
			return str(equip[k_any]).strip_edges()

	return ""

func _apply_player_customization_to_actor_instance(actor_inst: Node, payload: Dictionary) -> void:
	if actor_inst == null:
		return
	if payload.is_empty():
		return
	if not payload.has("player_customization"):
		return

	var pc_any: Variant = payload["player_customization"]
	if typeof(pc_any) != TYPE_DICTIONARY:
		return
	var pc: Dictionary = pc_any

	var gender_str: String = str(pc.get("gender", "male")).strip_edges().to_lower()
	var gender_folder: String = "Male"
	if gender_str == "female":
		gender_folder = "Female"

	var hair_id: String = str(pc.get("hair_id", "")).strip_edges()
	if hair_id == "":
		hair_id = "Short"

	var vr: Node = _find_visual_root(actor_inst)
	if vr == null:
		return

	var body: AnimatedSprite2D = vr.get_node_or_null("BodySprite") as AnimatedSprite2D
	var armor: AnimatedSprite2D = vr.get_node_or_null("ArmorSprite") as AnimatedSprite2D
	var hair: AnimatedSprite2D = vr.get_node_or_null("HairSprite") as AnimatedSprite2D
	var hair_behind: AnimatedSprite2D = vr.get_node_or_null("HairBehindSprite") as AnimatedSprite2D

	# Ensure EquipmentVisuals uses correct gender for later equipment swaps.
	var eqv: Node = actor_inst.find_child(equipment_visuals_node_name, true, false)
	if eqv != null and ("gender_folder" in eqv):
		if gender_folder == "Female":
			eqv.set("gender_folder", StringName("female"))
		else:
			eqv.set("gender_folder", StringName("male"))

	var root_dir: String = "res://assets/sprites/characters/%s" % gender_folder

	if body != null:
		var body_frames: SpriteFrames = _load_frames_ci("%s/BodySprites" % root_dir, "Body")
		if body_frames != null:
			body.sprite_frames = body_frames

	if armor != null:
		var cloth_frames: SpriteFrames = _load_frames_ci("%s/ArmorSprites" % root_dir, "Cloth")
		if cloth_frames != null:
			armor.sprite_frames = cloth_frames

	if hair != null:
		var hair_frames: SpriteFrames = _load_frames_ci("%s/HairSprites" % root_dir, hair_id)
		if hair_frames != null:
			hair.sprite_frames = hair_frames

	# Important: if no behind frames exist, hide the behind layer so it doesn't keep some default (e.g. Braids).
	if hair_behind != null:
		var behind_id: String = hair_id + "_behind"
		var behind_frames: SpriteFrames = _load_frames_ci("%s/HairSprites" % root_dir, behind_id)
		if behind_frames != null:
			hair_behind.visible = true
			hair_behind.sprite_frames = behind_frames
		else:
			hair_behind.visible = false

func _load_frames_ci(dir_path: String, base_name: String) -> SpriteFrames:
	if dir_path.strip_edges() == "":
		return null
	if base_name.strip_edges() == "":
		return null

	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return null

	var want: String = base_name.to_lower()

	da.list_dir_begin()
	var fn: String = da.get_next()
	while fn != "":
		if not da.current_is_dir():
			var lower: String = fn.to_lower()
			var ok: bool = lower.ends_with(".res") or lower.ends_with(".tres")
			if ok:
				var base: String = fn.get_basename()
				if base.to_lower() == want:
					var full_path: String = "%s/%s" % [dir_path, fn]
					if ResourceLoader.exists(full_path):
						var r: Resource = load(full_path)
						return r as SpriteFrames
		fn = da.get_next()
	da.list_dir_end()

	return null

func _find_visual_root(root: Node) -> Node:
	if root == null:
		return null

	var direct: Node = root.get_node_or_null(NodePath(visualroot_node_name))
	if direct != null:
		return direct

	return root.find_child(visualroot_node_name, true, false)

func _disable_processing_recursive(root: Node) -> void:
	if root == null:
		return
	root.process_mode = Node.PROCESS_MODE_DISABLED
	var i: int = 0
	while i < root.get_child_count():
		var c: Node = root.get_child(i)
		if c != null:
			_disable_processing_recursive(c)
		i += 1

func _hide_named_nodes_recursive(root: Node, names_to_hide: PackedStringArray) -> void:
	if root == null:
		return

	var nm: String = root.name
	var i: int = 0
	while i < names_to_hide.size():
		var target: String = String(names_to_hide[i])
		if target != "" and nm == target:
			var canvas: CanvasItem = root as CanvasItem
			if canvas != null:
				canvas.visible = false
			break
		i += 1

	var j: int = 0
	while j < root.get_child_count():
		var c: Node = root.get_child(j)
		if c != null:
			_hide_named_nodes_recursive(c, names_to_hide)
		j += 1

func _force_animation_on_all_animated_sprites(root: Node, desired_anim_name: String) -> void:
	if root == null:
		return

	var desired_norm: String = desired_anim_name.strip_edges().to_lower()
	if desired_norm == "":
		return

	var q: Array[Node] = []
	q.append(root)

	while q.size() > 0:
		var n: Node = q.pop_front()
		var aspr: AnimatedSprite2D = n as AnimatedSprite2D
		if aspr != null:
			var frames: SpriteFrames = aspr.sprite_frames
			if frames != null:
				var chosen: String = _find_anim_name_case_insensitive(frames, desired_norm)
				if chosen != "":
					aspr.animation = chosen
					aspr.frame = 0
					aspr.play()

		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1

func _find_anim_name_case_insensitive(sf: SpriteFrames, desired_name_or_norm: String) -> String:
	if sf == null:
		return ""
	var want: String = desired_name_or_norm.strip_edges().to_lower()
	if want == "":
		return ""
	var names: PackedStringArray = sf.get_animation_names()
	var i: int = 0
	while i < names.size():
		var nm: String = String(names[i]).strip_edges()
		if nm.to_lower() == want:
			return nm
		i += 1
	return ""

func _build_empty_member_box() -> Control:
	var box: Control = Control.new()
	box.custom_minimum_size = Vector2(float(portrait_box_width_px), float(portrait_box_height_px))
	box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return box

func _extract_party_members_ordered_marked(payload: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not payload.has("party"):
		return out

	var party_any: Variant = payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return out
	var party: Dictionary = party_any

	if not party.has("members"):
		return out

	var members_any: Variant = party["members"]
	if typeof(members_any) != TYPE_ARRAY:
		return out
	var members: Array = members_any

	var controlled_idx: int = 0
	if party.has("controlled_index"):
		controlled_idx = int(party["controlled_index"])
	if controlled_idx < 0:
		controlled_idx = 0
	if controlled_idx >= members.size():
		controlled_idx = 0

	var count: int = members.size()
	var step: int = 0
	while step < count and out.size() < portrait_max_members:
		var idx: int = controlled_idx + step
		if idx >= count:
			idx -= count

		var m_any: Variant = members[idx]
		if typeof(m_any) == TYPE_DICTIONARY:
			var md: Dictionary = (m_any as Dictionary).duplicate(true)
			md["__is_leader"] = (idx == controlled_idx)
			out.append(md)
		step += 1

	return out

# ---------------------------------------------------------------------
# Legacy idle-frame cache (kept)
# ---------------------------------------------------------------------
func _get_idle_frame_for_scene(scene_path: String) -> Texture2D:
	if _scene_idle_frame_cache.has(scene_path):
		var v_any: Variant = _scene_idle_frame_cache[scene_path]
		return v_any as Texture2D

	var tex: Texture2D = _load_idle_frame_for_scene(scene_path)
	_scene_idle_frame_cache[scene_path] = tex
	return tex

func _load_idle_frame_for_scene(scene_path: String) -> Texture2D:
	if scene_path == "":
		return null
	if not ResourceLoader.exists(scene_path):
		return null

	var ps_any: Resource = ResourceLoader.load(scene_path)
	var ps: PackedScene = ps_any as PackedScene
	if ps == null:
		return null

	var inst: Node = ps.instantiate()
	if inst == null:
		return null

	var sprite: AnimatedSprite2D = _find_actor_animated_sprite(inst)
	if sprite == null:
		inst.queue_free()
		return null

	var sf: SpriteFrames = sprite.sprite_frames
	if sf == null:
		inst.queue_free()
		return null

	var anim_name: String = _pick_idle_anim_name(sf)
	if anim_name == "":
		inst.queue_free()
		return null

	var count: int = sf.get_frame_count(anim_name)
	if count <= 0:
		inst.queue_free()
		return null

	var tex: Texture2D = sf.get_frame_texture(anim_name, 0)
	inst.queue_free()
	return tex

func _find_actor_animated_sprite(inst: Node) -> AnimatedSprite2D:
	if inst == null:
		return null

	var bridge: Node = inst.find_child("AnimationBridge", true, false)
	if bridge != null and ("sprite_path" in bridge):
		var sp_any: Variant = bridge.get("sprite_path")
		if typeof(sp_any) == TYPE_NODE_PATH:
			var np: NodePath = sp_any
			if not np.is_empty():
				var n: Node = inst.get_node_or_null(np)
				var as2d: AnimatedSprite2D = n as AnimatedSprite2D
				if as2d != null:
					return as2d

	var by_name: Node = inst.find_child("AnimatedSprite2D", true, false)
	var by_name_as: AnimatedSprite2D = by_name as AnimatedSprite2D
	if by_name_as != null:
		return by_name_as

	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n2: Node = stack.pop_back()
		var cand: AnimatedSprite2D = n2 as AnimatedSprite2D
		if cand != null:
			return cand
		var children: Array[Node] = n2.get_children()
		var i: int = 0
		while i < children.size():
			var ch: Node = children[i]
			if ch != null:
				stack.append(ch)
			i += 1

	return null

func _pick_idle_anim_name(sf: SpriteFrames) -> String:
	if sf == null:
		return ""

	# Prefer idle_side case-insensitive.
	var idle_side_ci: String = _find_anim_name_case_insensitive(sf, prefer_idle_side_name)
	if idle_side_ci != "":
		return idle_side_ci

	# Keep old preference logic as fallback if idle_side doesn't exist.
	if portrait_prefer_idle_right:
		var idle_right_ci: String = _find_anim_name_case_insensitive(sf, "idle_right")
		if idle_right_ci != "":
			return idle_right_ci
	else:
		var idle_right_ci2: String = _find_anim_name_case_insensitive(sf, "idle_right")
		if idle_right_ci2 != "":
			return idle_right_ci2

	var idle_left_ci: String = _find_anim_name_case_insensitive(sf, "idle_left")
	if idle_left_ci != "":
		return idle_left_ci

	var idle_down_ci: String = _find_anim_name_case_insensitive(sf, "idle_down")
	if idle_down_ci != "":
		return idle_down_ci

	var idle_up_ci: String = _find_anim_name_case_insensitive(sf, "idle_up")
	if idle_up_ci != "":
		return idle_up_ci

	var anims: PackedStringArray = sf.get_animation_names()
	var i: int = 0
	while i < anims.size():
		var a: String = String(anims[i])
		if a.to_lower().begins_with("idle"):
			return a
		i += 1

	return ""

func _apply_ellipsis_label(label: Label) -> void:
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

# ---------------------------------------------------------------------
# 4-line text (unchanged from your file)
# ---------------------------------------------------------------------
func _get_slot_name_line(slot_index: int) -> String:
	if _save_sys == null:
		return "(SaveSys missing)"
	if not _save_sys.slot_exists(slot_index):
		return "Empty Slot %d" % slot_index

	var meta: Dictionary = _save_sys.get_slot_meta(slot_index)

	var who: String = "Slot %d" % slot_index
	if meta.has("leader_name"):
		var ln: String = str(meta["leader_name"]).strip_edges()
		if ln != "":
			who = ln

	var updated_at: String = ""
	if meta.has("updated_at"):
		updated_at = str(meta["updated_at"]).strip_edges()

	if updated_at != "":
		return "%s  •  %s" % [who, updated_at]

	return who

func _get_slot_class_line(slot_index: int, payload: Dictionary) -> String:
	if _save_sys == null:
		return ""
	if not _save_sys.slot_exists(slot_index):
		return "—"

	var meta: Dictionary = _save_sys.get_slot_meta(slot_index)

	var class_str: String = ""
	if meta.has("leader_class"):
		class_str = str(meta["leader_class"]).strip_edges()
	elif meta.has("leader_class_title"):
		class_str = str(meta["leader_class_title"]).strip_edges()

	if class_str == "":
		class_str = _derive_leader_class_title(payload).strip_edges()

	if class_str == "":
		return "—"

	return class_str

func _get_slot_level_line(slot_index: int) -> String:
	if _save_sys == null:
		return ""
	if not _save_sys.slot_exists(slot_index):
		return ""

	var meta: Dictionary = _save_sys.get_slot_meta(slot_index)

	if meta.has("leader_level"):
		var lv: int = int(meta["leader_level"])
		if lv > 0:
			return "Lv " + str(lv)

	return ""

func _derive_leader_class_title(payload: Dictionary) -> String:
	if not payload.has("party"):
		return ""
	var party_any: Variant = payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return ""
	var party: Dictionary = party_any

	if not party.has("members"):
		return ""
	var members_any: Variant = party["members"]
	if typeof(members_any) != TYPE_ARRAY:
		return ""
	var members: Array = members_any
	if members.is_empty():
		return ""

	var controlled_index: int = 0
	if party.has("controlled_index"):
		controlled_index = int(party["controlled_index"])
	if controlled_index < 0 or controlled_index >= members.size():
		controlled_index = 0

	var leader_any: Variant = members[controlled_index]
	if typeof(leader_any) != TYPE_DICTIONARY:
		return ""
	var leader: Dictionary = leader_any

	if not leader.has("scene_path"):
		return ""
	var scene_path: String = str(leader["scene_path"]).strip_edges()
	if scene_path == "":
		return ""

	if _scene_class_title_cache.has(scene_path):
		var cached_any: Variant = _scene_class_title_cache[scene_path]
		return str(cached_any)

	var title: String = _load_class_title_for_scene(scene_path)
	_scene_class_title_cache[scene_path] = title
	return title

func _load_class_title_for_scene(scene_path: String) -> String:
	if scene_path == "":
		return ""
	if not ResourceLoader.exists(scene_path):
		return ""

	var ps_any: Resource = ResourceLoader.load(scene_path)
	var ps: PackedScene = ps_any as PackedScene
	if ps == null:
		return ""

	var inst: Node = ps.instantiate()
	if inst == null:
		return ""

	var lvl: Node = inst.get_node_or_null("LevelComponent")
	if lvl == null:
		var f_lvl: Node = inst.find_child("LevelComponent", true, false)
		if f_lvl != null:
			lvl = f_lvl

	var out: String = ""
	if lvl != null and ("class_def" in lvl):
		var cd_any: Variant = lvl.get("class_def")
		var cd: Resource = cd_any as Resource
		if cd != null and ("class_title" in cd):
			out = str(cd.get("class_title")).strip_edges()

	if out == "":
		var stats: Node = inst.get_node_or_null("StatsComponent")
		if stats == null:
			var f_stats: Node = inst.find_child("StatsComponent", true, false)
			if f_stats != null:
				stats = f_stats
		if stats != null:
			if stats.has_method("get_class_def"):
				var cd2_any: Variant = stats.call("get_class_def")
				var cd2: Resource = cd2_any as Resource
				if cd2 != null and ("class_title" in cd2):
					out = str(cd2.get("class_title")).strip_edges()
			elif ("class_def" in stats):
				var cd3_any: Variant = stats.get("class_def")
				var cd3: Resource = cd3_any as Resource
				if cd3 != null and ("class_title" in cd3):
					out = str(cd3.get("class_title")).strip_edges()

	inst.queue_free()
	return out

func _get_slot_sub_line(slot_index: int) -> String:
	if _save_sys == null:
		return ""
	if not _save_sys.slot_exists(slot_index):
		return "—"

	var meta: Dictionary = _save_sys.get_slot_meta(slot_index)

	var story_line: String = ""
	if meta.has("story_display"):
		story_line = str(meta["story_display"]).strip_edges()

	var area_line: String = ""
	if show_area_path and meta.has("area_path"):
		area_line = _shorten_area_path(str(meta["area_path"]).strip_edges())

	var entry_tag: String = ""
	if meta.has("entry_tag"):
		entry_tag = str(meta["entry_tag"]).strip_edges()

	var base: String = ""
	if story_line != "":
		base = story_line
	elif area_line != "":
		base = area_line

	if story_line != "" and area_line != "":
		base = "%s  •  %s" % [story_line, area_line]

	if base != "" and entry_tag != "":
		return "%s  •  %s" % [base, entry_tag]

	return base

func _shorten_area_path(area_path: String) -> String:
	if area_path == "":
		return ""
	var s: String = area_path
	if s.begins_with("res://"):
		s = s.substr(6, s.length() - 6)
	var slash_index: int = s.rfind("/")
	if slash_index >= 0 and slash_index + 1 < s.length():
		s = s.substr(slash_index + 1, s.length() - (slash_index + 1))
	if s.ends_with(".tscn"):
		s = s.substr(0, s.length() - 5)
	return s

func _get_payload_for_slot(slot_index: int) -> Dictionary:
	if _slot_payload_cache.has(slot_index):
		var v_any: Variant = _slot_payload_cache[slot_index]
		if typeof(v_any) == TYPE_DICTIONARY:
			return v_any as Dictionary
	var payload: Dictionary = _read_payload_file_for_slot(slot_index)
	_slot_payload_cache[slot_index] = payload
	return payload

func _read_payload_file_for_slot(slot_index: int) -> Dictionary:
	var out: Dictionary = {}
	var path: String = "%s/%s%d%s" % [
		SaveSystem.SAVE_DIR,
		SaveSystem.SAVE_FILE_PREFIX,
		slot_index,
		SaveSystem.SAVE_FILE_SUFFIX
	]
	if not FileAccess.file_exists(path):
		return out

	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out

	var content: String = f.get_as_text()
	f.close()

	var json: JSON = JSON.new()
	var err: int = json.parse(content)
	if err != OK:
		return out

	var data_any: Variant = json.get_data()
	if typeof(data_any) != TYPE_DICTIONARY:
		return out

	return data_any as Dictionary

func _on_slot_pressed(slot_index: int) -> void:
	_set_selected_slot(slot_index, true)

	if _save_sys == null:
		push_warning("[SaveSelectScreen] SaveSys not found; cannot use slot.")
		return

	if intent == SaveSelectIntent.SAVE:
		_save_sys.set_current_slot(slot_index)

		var saved_ok: bool = false

		if _save_sys.has_method("save_game_to_slot"):
			_save_sys.call("save_game_to_slot", slot_index)
			saved_ok = true
		else:
			if _save_sys.has_method("build_runtime_payload"):
				var payload_any: Variant = _save_sys.call("build_runtime_payload", {})
				if typeof(payload_any) == TYPE_DICTIONARY:
					var payload: Dictionary = payload_any as Dictionary
					if not payload.is_empty():
						_save_sys.save_to_slot(slot_index, payload)
						saved_ok = true

		if not saved_ok:
			push_warning("[SaveSelectScreen] SAVE failed: SaveSys missing save_game_to_slot/build_runtime_payload.")
			return

		_slot_payload_cache.clear()
		_scene_class_title_cache.clear()
		_rebuild_rows()

		slot_action_completed.emit(int(intent), slot_index)

		if close_after_action:
			if overlay_mode:
				_request_close()
			else:
				_return_after_save_scene()
		return

	if not _save_sys.slot_exists(slot_index):
		return

	var payload2: Dictionary = _save_sys.load_from_slot(slot_index)
	if payload2.is_empty():
		push_warning("[SaveSelectScreen] Slot %d load returned empty payload." % slot_index)
		return

	_save_sys.set_current_slot(slot_index)
	slot_action_completed.emit(int(intent), slot_index)

	if overlay_mode:
		if close_after_action:
			_request_close()
		return

	if game_scene_path == "":
		push_warning("[SaveSelectScreen] game_scene_path empty; cannot start.")
		return

	var err2: int = get_tree().change_scene_to_file(game_scene_path)
	if err2 != OK:
		push_error("[SaveSelectScreen] Failed to change scene to: %s" % game_scene_path)

func _return_after_save_scene() -> void:
	if return_scene_path != "":
		var errx: int = get_tree().change_scene_to_file(return_scene_path)
		if errx != OK:
			push_error("[SaveSelectScreen] Failed to return to: %s" % return_scene_path)
		return

	_go_back()

func _go_back() -> void:
	if title_scene_path == "":
		return
	var err: int = get_tree().change_scene_to_file(title_scene_path)
	if err != OK:
		push_error("[SaveSelectScreen] Failed to change back to: %s" % title_scene_path)

func _request_close() -> void:
	close_requested.emit()
	queue_free()

func _clear_children(parent: Node) -> void:
	var children: Array = parent.get_children()
	for child_any in children:
		var child: Node = child_any as Node
		if child != null:
			child.queue_free()
