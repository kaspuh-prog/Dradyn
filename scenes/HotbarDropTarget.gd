extends Control
class_name HotbarDropTarget
# Godot 4.5 — fully typed, no ternaries.

@export var debug_logs: bool = true

var _hotbar: Hotbar

func _dbg(msg: String) -> void:
	if debug_logs:
		print("[HotbarDropTarget] ", msg)

func _ready() -> void:
	_hotbar = get_parent() as Hotbar
	if _hotbar == null:
		push_warning("HotbarDropTarget: parent is not Hotbar")

	# Fill the hotbar’s rect
	anchors_preset = Control.PRESET_FULL_RECT
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

	# IMPORTANT: allow events to continue to Hotbar so RMB reaches it.
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_process_unhandled_input(true)

func _gui_input(event: InputEvent) -> void:
	# We keep this lightweight; PASS allows Hotbar to receive RMB normally.
	# If you ever want to intercept RMB here, forward it explicitly:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		_forward_rmb_to_hotbar(mb)

func _unhandled_input(event: InputEvent) -> void:
	# Safety net in case a parent eats the GUI event chain.
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		_dbg("RMB(unhandled) forwarding to Hotbar")
		_forward_rmb_to_hotbar(mb)
		accept_event()

func _forward_rmb_to_hotbar(mb: InputEventMouseButton) -> void:
	if _hotbar == null:
		return
	var inv: Transform2D = _hotbar.get_global_transform_with_canvas().affine_inverse()
	var local_on_hotbar: Vector2 = inv * mb.position
	var idx: int = _hotbar._slot_at(local_on_hotbar)
	if idx >= 0:
		_dbg("Forwarding RMB clear to slot " + str(idx))
		_hotbar._clear(idx)

# ---------------------------
# Godot 4 DnD virtuals
# ---------------------------
func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	return can_drop_data(at_position, data)

func _drop_data(at_position: Vector2, data: Variant) -> void:
	drop_data(at_position, data)

# Bridge to Hotbar’s screen-space helpers
func can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if _hotbar == null:
		return false
	var screen_pos: Vector2 = get_global_transform_with_canvas() * at_position
	return _hotbar.can_drop_payload_at_screen_pos(screen_pos, data)

func drop_data(at_position: Vector2, data: Variant) -> void:
	if _hotbar == null:
		return
	var screen_pos: Vector2 = get_global_transform_with_canvas() * at_position
	_hotbar.try_assign_at_screen_pos(screen_pos, data)
