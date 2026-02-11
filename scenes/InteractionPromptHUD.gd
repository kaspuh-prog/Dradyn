extends Control
class_name InteractionPromptHUD

@export var refresh_hz: float = 12.0

@export_group("Text")
@export var text_suffix: String = " (Press E)"
@export var add_question_mark: bool = true

@export var prompt_font: Font = preload("res://assets/fonts/Raleway-SemiBold.ttf")
@export var prompt_font_size: int = 5
@export var prompt_font_color: Color = Color("#40221c")
@export var prompt_outline_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var prompt_outline_size: int = 0

@export_group("Background")
@export var menu_bg_texture: Texture2D = preload("res://ui/styles/MenuBG.png")
@export var corner_px: int = 16
@export var padding_px: Vector2 = Vector2(12.0, 10.0)
@export var axis_tile: bool = true
@export var draw_center_bg: bool = true

@export_group("Positioning")
@export var follow_controlled: bool = true
@export var world_offset_px: Vector2 = Vector2(0.0, -48.0)
@export var fallback_screen_anchor: Vector2 = Vector2(0.5, 0.75)

@export_group("Behavior")
@export var hide_when_ui_blocking: bool = true
@export var min_show_seconds: float = 0.05
@export var hide_after_interact_ms: int = 120

var _bg: NinePatchRect = null
var _margin: MarginContainer = null
var _label: Label = null
var _timer: Timer = null

var _party: Node = null
var _interaction_sys: Node = null

var _last_visible_at_sec: float = 0.0
var _force_hidden_until_msec: int = 0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT)

	_build_ui()
	_resolve_autoloads()
	_try_connect_interaction_signals()

	var hz: float = refresh_hz
	if hz <= 0.0:
		hz = 12.0

	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = 1.0 / hz
	add_child(_timer)
	_timer.timeout.connect(_on_tick)
	_timer.start()

	_on_tick()

func _build_ui() -> void:
	_bg = NinePatchRect.new()
	_bg.name = "BG"
	_bg.visible = false
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.texture = menu_bg_texture
	_bg.draw_center = draw_center_bg

	# No fading / alpha modulation
	_bg.modulate = Color(1.0, 1.0, 1.0, 1.0)

	var c: int = corner_px
	if c < 0:
		c = 0

	_bg.patch_margin_left = c
	_bg.patch_margin_top = c
	_bg.patch_margin_right = c
	_bg.patch_margin_bottom = c

	if axis_tile:
		_bg.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
		_bg.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE

	add_child(_bg)

	_margin = MarginContainer.new()
	_margin.name = "Margin"
	_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_margin.offset_left = 0.0
	_margin.offset_top = 0.0
	_margin.offset_right = 0.0
	_margin.offset_bottom = 0.0
	_bg.add_child(_margin)

	var pad_x: int = int(padding_px.x)
	var pad_y: int = int(padding_px.y)
	if pad_x < 0:
		pad_x = 0
	if pad_y < 0:
		pad_y = 0

	_margin.add_theme_constant_override("margin_left", pad_x)
	_margin.add_theme_constant_override("margin_right", pad_x)
	_margin.add_theme_constant_override("margin_top", pad_y)
	_margin.add_theme_constant_override("margin_bottom", pad_y)

	_label = Label.new()
	_label.name = "Label"
	_label.text = ""
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	if prompt_font != null:
		_label.add_theme_font_override("font", prompt_font)

	var fs: int = prompt_font_size
	if fs <= 0:
		fs = 6
	_label.add_theme_font_size_override("font_size", fs)

	_label.add_theme_color_override("font_color", prompt_font_color)
	_label.add_theme_color_override("font_outline_color", prompt_outline_color)

	var osz: int = prompt_outline_size
	if osz < 0:
		osz = 0
	_label.add_theme_constant_override("outline_size", osz)

	_margin.add_child(_label)

func _resolve_autoloads() -> void:
	var root: Viewport = get_tree().root
	if root == null:
		return

	_party = root.get_node_or_null("Party")

	_interaction_sys = root.get_node_or_null("InteractionSys")
	if _interaction_sys == null:
		_interaction_sys = root.get_node_or_null("InteractionSystem")

func _try_connect_interaction_signals() -> void:
	if _interaction_sys == null:
		return

	if _interaction_sys.has_signal("interaction_started"):
		if not _interaction_sys.is_connected("interaction_started", Callable(self, "_on_interaction_started")):
			_interaction_sys.connect("interaction_started", Callable(self, "_on_interaction_started"))

func _on_interaction_started(actor: Node, target: Node) -> void:
	# Hide immediately upon successful interact, and suppress for a brief moment
	_bg.visible = false
	var ms: int = hide_after_interact_ms
	if ms < 0:
		ms = 0
	_force_hidden_until_msec = Time.get_ticks_msec() + ms

func _on_tick() -> void:
	if _bg == null or _label == null:
		return

	if _party == null or _interaction_sys == null:
		_resolve_autoloads()
		_try_connect_interaction_signals()

	var now_msec: int = Time.get_ticks_msec()
	if now_msec < _force_hidden_until_msec:
		_hide_if_allowed()
		return

	if hide_when_ui_blocking and _is_ui_blocking_input():
		_hide_if_allowed()
		return

	if _party == null or _interaction_sys == null:
		_hide_if_allowed()
		return

	if not _party.has_method("get_controlled"):
		_hide_if_allowed()
		return

	if not _interaction_sys.has_method("find_best_target"):
		_hide_if_allowed()
		return

	var controlled_any: Variant = _party.call("get_controlled")
	var controlled: Node = null
	if controlled_any is Node:
		controlled = controlled_any as Node

	if controlled == null:
		_hide_if_allowed()
		return

	var best_any: Variant = _interaction_sys.call("find_best_target", controlled, Vector2.ZERO)
	var best: Node = null
	if best_any is Node:
		best = best_any as Node

	if best == null:
		_hide_if_allowed()
		return

	var prompt: String = ""
	if best.has_method("get_interact_prompt"):
		var p_any: Variant = best.call("get_interact_prompt")
		prompt = String(p_any)

	prompt = prompt.strip_edges()
	if prompt == "":
		_hide_if_allowed()
		return

	var msg: String = prompt
	if add_question_mark:
		if not msg.ends_with("?"):
			msg += "?"
	msg += text_suffix

	_label.text = msg

	_update_bg_size()
	_position_bg(controlled)

	var now_sec: float = float(now_msec) / 1000.0
	_last_visible_at_sec = now_sec
	_bg.visible = true

func _update_bg_size() -> void:
	var label_min: Vector2 = _label.get_combined_minimum_size()

	var pad_x: float = float(int(padding_px.x))
	var pad_y: float = float(int(padding_px.y))
	if pad_x < 0.0:
		pad_x = 0.0
	if pad_y < 0.0:
		pad_y = 0.0

	var desired: Vector2 = Vector2(label_min.x + (pad_x * 2.0), label_min.y + (pad_y * 2.0))
	_bg.size = desired

func _hide_if_allowed() -> void:
	var now_sec: float = float(Time.get_ticks_msec()) / 1000.0
	if _bg.visible:
		var min_sec: float = min_show_seconds
		if min_sec < 0.0:
			min_sec = 0.0
		if now_sec - _last_visible_at_sec < min_sec:
			return

	_bg.visible = false

func _position_bg(controlled: Node) -> void:
	var vp: Viewport = get_viewport()
	if vp == null:
		return

	var sz: Vector2 = _bg.size
	if sz.x <= 0.0 or sz.y <= 0.0:
		sz = _bg.get_combined_minimum_size()

	var desired: Vector2 = Vector2(vp.size.x * fallback_screen_anchor.x, vp.size.y * fallback_screen_anchor.y)

	if follow_controlled:
		var n2: Node2D = controlled as Node2D
		if n2 != null:
			var world_pt: Vector2 = n2.global_position + world_offset_px
			var canvas_xform: Transform2D = vp.get_canvas_transform()
			desired = canvas_xform * world_pt

	_bg.position = desired - (sz * 0.5)

func _is_ui_blocking_input() -> bool:
	# 1) Ask HUDLayer if it knows about any modal UI
	var parent_node: Node = get_parent()
	if parent_node != null and parent_node.has_method("is_ui_blocking_input"):
		var any: Variant = parent_node.call("is_ui_blocking_input")
		if typeof(any) == TYPE_BOOL and bool(any):
			return true

	# 2) Explicitly hide while our known “interaction windows” are open
	#    (Talk/Inn DialogueBox + MerchantMenu), since those may not claim focus.
	if parent_node != null:
		if _is_control_visible(parent_node.get_node_or_null("TalkController/DialogueBox")):
			return true
		if _is_control_visible(parent_node.get_node_or_null("InnController/DialogueBox")):
			return true
		if _is_control_visible(parent_node.get_node_or_null("MerchantController/MerchantMenu")):
			return true
		if _is_control_visible(parent_node.get_node_or_null("SavePointController/DialogueBox")):
			return true

	# 3) Fallback: any focused control
	var vp: Viewport = get_viewport()
	if vp != null:
		var f: Control = vp.gui_get_focus_owner()
		if f != null:
			return true

	return false

func _is_control_visible(n: Node) -> bool:
	var c: Control = n as Control
	if c == null:
		return false
	if not c.is_inside_tree():
		return false
	return c.visible
