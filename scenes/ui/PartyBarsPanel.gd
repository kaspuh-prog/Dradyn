extends Control
class_name PartyBarsPanel

@export var texture_frame: Texture2D
@export var texture_under: Texture2D          # BarNoFill.png (256×32)
@export var texture_hp_fill: Texture2D        # FilledHP.png  (256×32)
@export var texture_mp_fill: Texture2D        # FilledMP.png  (256×32)
@export var texture_end_fill: Texture2D       # FilledEND.png (256×32)

const FRAME_SIZE: Vector2i = Vector2i(256, 128)
const HEADER_HEIGHT: int = 32
const PANEL_SIZE: Vector2i = Vector2i(FRAME_SIZE.x, FRAME_SIZE.y + HEADER_HEIGHT)

const HOLE_TOP_HP: int = 24
const HOLE_TOP_MP: int = 56
const HOLE_TOP_END: int = 88
const BAR_DRAW_TOP_IN_SPRITE: int = 8

const REL_HP_Y: int = HOLE_TOP_HP - BAR_DRAW_TOP_IN_SPRITE
const REL_MP_Y: int = HOLE_TOP_MP - BAR_DRAW_TOP_IN_SPRITE
const REL_END_Y: int = HOLE_TOP_END - BAR_DRAW_TOP_IN_SPRITE

const BUFF_ICON_SIZE: Vector2i = Vector2i(16, 16)
const BUFF_COLS: int = 6
const BUFF_ROWS: int = 2
const BUFF_AREA_SIZE: Vector2i = Vector2i(
	BUFF_ICON_SIZE.x * BUFF_COLS,
	BUFF_ICON_SIZE.y * BUFF_ROWS
)

const NAME_BUFF_STRIP_HEIGHT: int = HEADER_HEIGHT
const NAME_STRIP_Y: int = 0

const BUFF_SCAN_INTERVAL: float = 0.5

@onready var _bars_root: Control = $"Bars"
@onready var _hp: TextureProgressBar = $"Bars/HpBar"
@onready var _mp: TextureProgressBar = $"Bars/MpBar"
@onready var _end: TextureProgressBar = $"Bars/EndBar"
@onready var _frame: TextureRect = $"Frame"

var _name_label: Label = null
var _name_highlight: ColorRect = null
var _name_bg: ColorRect = null
var _buffs_box: Control = null

var _buff_slots: Array[Control] = []

var _stats: Node = null
var AbilitySys: Node = null

var _buff_scan_accum: float = 0.0

var _hovered_slot: Control = null
var _buff_tooltip: Control = null
var _buff_tooltip_bg: ColorRect = null
var _buff_tooltip_name: Label = null
var _buff_tooltip_timer: Label = null

func _ready() -> void:
	AbilitySys = get_node_or_null("/root/AbilitySys")

	_setup_root()
	_setup_frame()
	_setup_bars_container()
	_setup_bar_exact(_hp, REL_HP_Y, texture_hp_fill)
	_setup_bar_exact(_mp, REL_MP_Y, texture_mp_fill)
	_setup_bar_exact(_end, REL_END_Y, texture_end_fill)
	_setup_name_background()
	_setup_name_highlight()
	_setup_name_label()
	_setup_buffs_box()
	_setup_buff_tooltip()

	set_process(true)

func _process(delta: float) -> void:
	if _stats != null:
		_buff_scan_accum += delta
		if _buff_scan_accum >= BUFF_SCAN_INTERVAL:
			_buff_scan_accum = 0.0
			_refresh_buffs_icons_only()

	if _hovered_slot != null:
		_update_hover_tooltip_timer()

func _setup_root() -> void:
	anchors_preset = Control.PRESET_TOP_LEFT
	clip_contents = false
	set_deferred("custom_minimum_size", Vector2(PANEL_SIZE))
	size = Vector2(PANEL_SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_as_relative = false
	z_index = 0

func _setup_frame() -> void:
	if _frame == null:
		return

	_frame.texture = texture_frame
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.anchors_preset = Control.PRESET_TOP_LEFT
	_frame.position = Vector2(0, HEADER_HEIGHT)
	_frame.size = Vector2(FRAME_SIZE)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.z_as_relative = false
	_frame.z_index = 1

func _setup_bars_container() -> void:
	if _bars_root == null:
		return
	_bars_root.anchors_preset = Control.PRESET_TOP_LEFT
	_bars_root.position = Vector2(0, 0)
	_bars_root.size = Vector2(PANEL_SIZE)
	_bars_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars_root.z_as_relative = false
	_bars_root.z_index = 0

func _setup_bar_exact(bar: TextureProgressBar, rel_top_y: int, fill_tex: Texture2D) -> void:
	if bar == null:
		return

	var sprite_w: int = FRAME_SIZE.x
	var sprite_h: int = 32
	if texture_under != null:
		sprite_w = texture_under.get_width()
		sprite_h = texture_under.get_height()

	bar.anchors_preset = Control.PRESET_TOP_LEFT
	var final_y: int = HEADER_HEIGHT + rel_top_y
	bar.position = Vector2(0, final_y)
	bar.size = Vector2(sprite_w, sprite_h)

	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 100.0
	bar.step = 1.0
	bar.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT

	bar.texture_under = texture_under
	bar.texture_progress = fill_tex

	bar.nine_patch_stretch = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.z_as_relative = false
	bar.z_index = 0

func _setup_name_background() -> void:
	if _name_bg != null:
		return

	var left_padding: float = 8.0
	var gap_between: float = 8.0
	var right_padding: float = 8.0

	var name_width: float = float(FRAME_SIZE.x) - float(BUFF_AREA_SIZE.x) - (left_padding + gap_between + right_padding)

	var bg := ColorRect.new()
	bg.name = "NameBackground"
	bg.color = Color(217.0 / 255.0, 160.0 / 255.0, 102.0 / 255.0, 1.0)
	bg.anchors_preset = Control.PRESET_TOP_LEFT

	var bg_pos_x: float = left_padding - 2.0
	var bg_pos_y: float = float(NAME_STRIP_Y) + 4.0
	var bg_width: float = name_width + 4.0
	var bg_height: float = float(NAME_BUFF_STRIP_HEIGHT) - 8.0

	bg.position = Vector2(bg_pos_x, bg_pos_y)
	bg.size = Vector2(bg_width, bg_height)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_as_relative = false
	bg.z_index = 18

	add_child(bg)
	_name_bg = bg

func _setup_name_label() -> void:
	if _name_label != null:
		return

	var left_padding: float = 8.0
	var gap_between: float = 8.0
	var right_padding: float = 8.0

	var name_width: float = float(FRAME_SIZE.x) - float(BUFF_AREA_SIZE.x) - (left_padding + gap_between + right_padding)

	var label := Label.new()
	label.name = "NameLabel"
	label.text = "Name"
	label.anchors_preset = Control.PRESET_TOP_LEFT

	label.position = Vector2(left_padding, float(NAME_STRIP_Y))
	label.size = Vector2(name_width, float(NAME_BUFF_STRIP_HEIGHT))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.clip_text = true
	label.z_as_relative = false
	label.z_index = 20

	var name_color := Color(64.0 / 255.0, 34.0 / 255.0, 28.0 / 255.0, 1.0)
	label.add_theme_color_override("font_color", name_color)

	add_child(label)
	_name_label = label

func _setup_name_highlight() -> void:
	if _name_highlight != null:
		return

	var rect := ColorRect.new()
	rect.name = "NameGlow"
	rect.color = Color(1.0, 0.93, 0.7, 0.55)
	rect.anchors_preset = Control.PRESET_TOP_LEFT
	rect.position = Vector2(0, float(NAME_STRIP_Y))
	rect.size = Vector2(FRAME_SIZE.x, float(NAME_BUFF_STRIP_HEIGHT))
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	rect.z_as_relative = false
	rect.z_index = 17

	add_child(rect)
	_name_highlight = rect

func _setup_buffs_box() -> void:
	if _buffs_box != null:
		return

	var right_padding: float = 8.0
	var buffs_size: Vector2 = Vector2(BUFF_AREA_SIZE)
	var buffs_pos_x: float = float(FRAME_SIZE.x) - buffs_size.x - right_padding

	var box := Control.new()
	box.name = "BuffsBox"
	box.anchors_preset = Control.PRESET_TOP_LEFT
	box.position = Vector2(buffs_pos_x, float(NAME_STRIP_Y))
	box.size = Vector2(buffs_size.x, buffs_size.y)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.z_as_relative = false
	box.z_index = 20

	var bg := ColorRect.new()
	bg.name = "BuffsBackground"
	bg.color = Color(0.1, 0.1, 0.1, 0.7)
	bg.anchors_preset = Control.PRESET_FULL_RECT
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_as_relative = false
	bg.z_index = 0
	box.add_child(bg)

	_buff_slots.clear()

	var slot_index: int = 0
	var row: int = 0
	while row < BUFF_ROWS:
		var col: int = 0
		while col < BUFF_COLS:
			var slot := Control.new()
			slot.name = "BuffSlot_%d" % slot_index
			slot.anchors_preset = Control.PRESET_TOP_LEFT

			var pos_x: float = float(col * BUFF_ICON_SIZE.x)
			var pos_y: float = float(row * BUFF_ICON_SIZE.y)
			slot.position = Vector2(pos_x, pos_y)
			slot.size = Vector2(BUFF_ICON_SIZE.x, BUFF_ICON_SIZE.y)

			slot.mouse_filter = Control.MOUSE_FILTER_PASS
			slot.z_as_relative = false
			slot.z_index = 1

			var icon_rect := TextureRect.new()
			icon_rect.name = "Icon"
			icon_rect.anchors_preset = Control.PRESET_FULL_RECT
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_rect.z_as_relative = false
			icon_rect.z_index = 0
			slot.add_child(icon_rect)

			slot.visible = false
			slot.set_meta("mod", null)
			slot.set_meta("ability_id", "")
			slot.set_meta("ability_name", "")

			slot.mouse_entered.connect(_on_buff_slot_mouse_entered.bind(slot))
			slot.mouse_exited.connect(_on_buff_slot_mouse_exited.bind(slot))
			slot.gui_input.connect(_on_buff_slot_gui_input.bind(slot))

			box.add_child(slot)
			_buff_slots.append(slot)

			slot_index += 1
			col += 1
		row += 1

	add_child(box)
	_buffs_box = box

func _setup_buff_tooltip() -> void:
	if _buff_tooltip != null:
		return

	# Smaller tooltip so it visually matches scaled party bars.
	var root := Control.new()
	root.name = "BuffTooltip"
	root.anchors_preset = Control.PRESET_TOP_LEFT
	root.visible = false
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.z_as_relative = false
	root.z_index = 100
	root.size = Vector2(48, 18)  # smaller box

	var bg := ColorRect.new()
	bg.name = "BG"
	bg.color = Color(120.0 / 255.0, 89.0 / 255.0, 59.0 / 255.0, 1.0)  # #78593b
	bg.anchors_preset = Control.PRESET_FULL_RECT
	bg.position = Vector2(0, 0)
	bg.size = root.size
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_as_relative = false
	bg.z_index = 0
	root.add_child(bg)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.text = ""
	name_label.anchors_preset = Control.PRESET_TOP_LEFT
	name_label.position = Vector2(3, -8)
	name_label.size = Vector2(74, 10)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 4)
	name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	name_label.z_as_relative = false
	name_label.z_index = 1
	root.add_child(name_label)

	var timer_label := Label.new()
	timer_label.name = "Timer"
	timer_label.text = ""
	timer_label.anchors_preset = Control.PRESET_TOP_LEFT
	timer_label.position = Vector2(3, 0)
	timer_label.size = Vector2(74, 10)
	timer_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	timer_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	timer_label.add_theme_font_size_override("font_size", 4)
	timer_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	timer_label.z_as_relative = false
	timer_label.z_index = 1
	root.add_child(timer_label)

	# Attach tooltip to HUDLayer so it draws above PartyHUD/name strip.
	var hud_layer: Node = get_tree().get_root().get_node_or_null("GameRoot/HUDLayer")
	if hud_layer != null:
		hud_layer.add_child(root)
	else:
		add_child(root)

	_buff_tooltip = root
	_buff_tooltip_bg = bg
	_buff_tooltip_name = name_label
	_buff_tooltip_timer = timer_label

func _refresh_buffs_icons_only() -> void:
	if _stats == null:
		return
	if _buff_slots.is_empty():
		return

	var active_mods: Array = []
	var mods_array: Array = []

	if "modifiers" in _stats:
		mods_array = _stats.modifiers

	# Dedupe by ability source_id so multi-mod ability buffs show as ONE icon.
	var seen_ability_sources: Dictionary = {}

	var i: int = 0
	while i < mods_array.size():
		var m: Variant = mods_array[i]
		if m is Resource:
			if m.has_method("is_temporary"):
				var is_temp_any: Variant = m.call("is_temporary")
				var is_temp: bool = false
				if typeof(is_temp_any) == TYPE_BOOL:
					is_temp = bool(is_temp_any)

				var source_id_str: String = ""
				if "source_id" in m:
					var sid_any: Variant = m.source_id
					if typeof(sid_any) == TYPE_STRING:
						source_id_str = sid_any

				var treat_as_buff: bool = false
				if is_temp:
					treat_as_buff = true
				elif source_id_str.begins_with("ability:"):
					treat_as_buff = true

				if treat_as_buff:
					if source_id_str.begins_with("ability:"):
						if seen_ability_sources.has(source_id_str):
							i += 1
							continue
						seen_ability_sources[source_id_str] = true
					active_mods.append(m)
		i += 1

	var max_slots: int = _buff_slots.size()
	var count: int = active_mods.size()
	if count > max_slots:
		count = max_slots

	var slot_idx: int = 0
	while slot_idx < max_slots:
		var slot: Control = _buff_slots[slot_idx]
		if slot_idx < count:
			var mod: Resource = active_mods[slot_idx] as Resource
			_fill_slot_from_modifier(slot, mod)
			slot.visible = true
		else:
			_clear_slot(slot)
			slot.visible = false
		slot_idx += 1

func _fill_slot_from_modifier(slot: Control, mod: Resource) -> void:
	var icon_rect: TextureRect = slot.get_node_or_null("Icon") as TextureRect
	if icon_rect == null:
		return

	var ability_id: String = ""
	if "source_id" in mod:
		var sid_any: Variant = mod.source_id
		if typeof(sid_any) == TYPE_STRING:
			var sid: String = sid_any
			if sid.begins_with("ability:"):
				ability_id = sid.substr(8)

	var icon: Texture2D = null
	if ability_id != "" and AbilitySys != null and AbilitySys.has_method("get_ability_icon"):
		var any_icon: Variant = AbilitySys.call("get_ability_icon", ability_id)
		if any_icon is Texture2D:
			icon = any_icon as Texture2D

	icon_rect.texture = icon

	var ability_name: String = _get_ability_display_name(ability_id)
	slot.set_meta("mod", mod)
	slot.set_meta("ability_id", ability_id)
	slot.set_meta("ability_name", ability_name)

func _clear_slot(slot: Control) -> void:
	var icon_rect: TextureRect = slot.get_node_or_null("Icon") as TextureRect
	if icon_rect != null:
		icon_rect.texture = null
	slot.set_meta("mod", null)
	slot.set_meta("ability_id", "")
	slot.set_meta("ability_name", "")

func _get_ability_display_name(ability_id: String) -> String:
	if ability_id == "":
		return ""
	if AbilitySys == null:
		return ability_id

	if AbilitySys.has_method("_resolve_ability_def"):
		var any_def: Variant = AbilitySys.call("_resolve_ability_def", ability_id)
		if any_def is Resource:
			var def_res: Resource = any_def as Resource
			if "display_name" in def_res:
				var dn_any: Variant = def_res.display_name
				if typeof(dn_any) == TYPE_STRING:
					var dn: String = dn_any
					if dn != "":
						return dn
	return ability_id

func _on_buff_slot_mouse_entered(slot: Control) -> void:
	_hovered_slot = slot
	_update_hover_tooltip_full()

func _on_buff_slot_mouse_exited(slot: Control) -> void:
	if _hovered_slot == slot:
		_hovered_slot = null
	if _buff_tooltip != null:
		_buff_tooltip.visible = false

func _on_buff_slot_gui_input(event: InputEvent, slot: Control) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb == null:
		return
	if mb.pressed == false:
		return
	if mb.button_index != MOUSE_BUTTON_RIGHT:
		return

	_try_remove_buff_from_slot(slot)
	slot.accept_event()

func _try_remove_buff_from_slot(slot: Control) -> void:
	if _stats == null:
		return
	if slot == null:
		return

	var mod_any: Variant = slot.get_meta("mod")
	if not (mod_any is Resource):
		return

	var mod: Resource = mod_any as Resource

	# We prefer removing by source_id because it nukes ALL modifiers for that same ability/buff.
	var source_id_str: String = ""
	if "source_id" in mod:
		var sid_any: Variant = mod.source_id
		if typeof(sid_any) == TYPE_STRING:
			source_id_str = sid_any

	if source_id_str != "" and _stats.has_method("remove_modifiers_by_source"):
		_stats.call("remove_modifiers_by_source", source_id_str)
		_refresh_buffs_icons_only()
		if _buff_tooltip != null:
			_buff_tooltip.visible = false
		return

	# Fallback: stacking_key removal (only works if the StatModifier uses stacking_key consistently).
	if "stacking_key" in mod and _stats.has_method("remove_modifiers_by_key"):
		var sk_any: Variant = mod.get("stacking_key")
		if typeof(sk_any) == TYPE_STRING_NAME:
			var sk: StringName = sk_any
			if String(sk) != "":
				_stats.call("remove_modifiers_by_key", sk)
				_refresh_buffs_icons_only()
				if _buff_tooltip != null:
					_buff_tooltip.visible = false
				return

	# Last fallback: if it's temporary and supports expiring itself, force it expired.
	# (This is purely a safety net; source_id route is the intended one.)
	if mod.has_method("is_temporary") and mod.has_method("set_time_left"):
		var is_temp_any: Variant = mod.call("is_temporary")
		if typeof(is_temp_any) == TYPE_BOOL and bool(is_temp_any):
			mod.call("set_time_left", 0.0)
			if _stats.has_method("clear_expired_modifiers"):
				_stats.call("clear_expired_modifiers")
			_refresh_buffs_icons_only()
			if _buff_tooltip != null:
				_buff_tooltip.visible = false

func _update_hover_tooltip_full() -> void:
	if _hovered_slot == null:
		return
	if _buff_tooltip == null:
		return

	var ability_name_any: Variant = _hovered_slot.get_meta("ability_name")
	var ability_name: String = ""
	if typeof(ability_name_any) == TYPE_STRING:
		ability_name = ability_name_any

	if _buff_tooltip_name != null:
		if ability_name == "":
			_buff_tooltip_name.text = "Buff"
		else:
			_buff_tooltip_name.text = ability_name

	_update_hover_tooltip_timer()
	_position_buff_tooltip()
	_buff_tooltip.visible = true

func _update_hover_tooltip_timer() -> void:
	if _hovered_slot == null:
		return
	if _buff_tooltip_timer == null:
		return

	var mod_any: Variant = _hovered_slot.get_meta("mod")
	if not (mod_any is Resource):
		_buff_tooltip_timer.text = ""
		return

	var mod: Resource = mod_any as Resource
	var timer_text: String = ""

	if mod.has_method("is_temporary") and mod.has_method("time_left"):
		var is_temp_any: Variant = mod.call("is_temporary")
		var is_temp: bool = false
		if typeof(is_temp_any) == TYPE_BOOL:
			is_temp = bool(is_temp_any)

		if is_temp:
			var tl_any: Variant = mod.call("time_left")
			if typeof(tl_any) == TYPE_FLOAT or typeof(tl_any) == TYPE_INT:
				var tl: float = float(tl_any)
				if tl < 0.0:
					tl = 0.0
				if tl >= 60.0:
					var mins: int = int(ceil(tl / 60.0))
					timer_text = str(mins) + "m"
				else:
					var secs: int = int(ceil(tl))
					timer_text = str(secs)
		else:
			var ability_id_any: Variant = _hovered_slot.get_meta("ability_id")
			if typeof(ability_id_any) == TYPE_STRING:
				var ability_id: String = ability_id_any
				if ability_id != "":
					timer_text = "∞"

	_buff_tooltip_timer.text = timer_text

func _position_buff_tooltip() -> void:
	if _hovered_slot == null:
		return
	if _buff_tooltip == null:
		return

	var slot_global: Rect2 = _hovered_slot.get_global_rect()
	var base_pos: Vector2 = slot_global.position + Vector2(slot_global.size.x + 4.0, 0.0)
	_buff_tooltip.global_position = base_pos

func get_name_label() -> Label:
	return _name_label

func get_name_highlight() -> ColorRect:
	return _name_highlight

func get_buffs_box() -> Control:
	return _buffs_box

func set_display_name(text: String) -> void:
	if _name_label == null:
		return
	_name_label.text = text

func set_highlighted(is_highlighted: bool) -> void:
	if _name_highlight == null:
		return

	if _name_bg != null:
		var margin: float = 4.0
		var base_pos: Vector2 = _name_bg.position
		var base_size: Vector2 = _name_bg.size
		_name_highlight.position = base_pos - Vector2(margin, margin)
		_name_highlight.size = base_size + Vector2(margin * 2.0, margin * 2.0)

	_name_highlight.visible = is_highlighted

func set_stats_component(stats: Node) -> void:
	_stats = stats
	_buff_scan_accum = 0.0
	_refresh_buffs_icons_only()
