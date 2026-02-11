extends Control
class_name LockpickMinigame
# Godot 4.5 — fully typed, no ternaries.
# v1 rules:
# - Gold fixed height, moves within lane (ping-pong + smoothstep).
# - RedBack fixed height, moves within gold (ping-pong + smoothstep).
# - RedFront is child of RedBack (lip overlay).
# - Success check uses ONLY the middle band of RedBack.
# - PickTip stops 1px left of the completed lane right edge.
# - Final success: push +8px, play Unlocking, play click SFX, then emit succeeded.
# - Optionally auto-close (hide + queue_free).

signal succeeded
signal cancelled
signal failed_lane(active_lane_index: int, fallback_lanes: int)
signal lane_set(lane_index: int)
signal lane_activated(lane_index: int)

enum State {
	IDLE,
	MOVING_PICK,
	ACTIVE,
	FINISHING,
	SUCCESS,
	CANCELLED
}

class LaneRuntime:
	var lane: Control
	var gold: NinePatchRect

	var red_back: NinePatchRect = null
	var red_front: NinePatchRect = null

	var configured: bool = false
	var is_set: bool = false

	# Gold motion (inside lane)
	var gold_t: float = 0.0
	var gold_dir: int = 1
	var gold_period_sec: float = 1.0
	var gold_max_y: float = 0.0

	# Red motion (inside gold)
	var red_t: float = 0.0
	var red_dir: int = 1
	var red_period_sec: float = 0.8
	var red_max_y: float = 0.0

	func _init(lane_in: Control, gold_in: NinePatchRect) -> void:
		lane = lane_in
		gold = gold_in


@export_group("Input")
@export var action_set: StringName = &"ui_accept"
@export var action_cancel: StringName = &"ui_cancel"

@export_group("Wiring")
@export var lanes_root_path: NodePath = NodePath("Panel/LockViewport/LanesRoot")
@export var pick_path: NodePath = NodePath("Panel/LockViewport/Pick")
@export var pick_tip_path: NodePath = NodePath("Panel/LockViewport/Pick/Picktip")
@export var lock_body_path: NodePath = NodePath("Panel/LockViewport/LockBody")
@export var unlock_click_path: NodePath = NodePath("Panel/LockViewport/UnlockClick")

@export_group("Lane Prefab Paths")
@export var gold_path_in_lane: NodePath = NodePath("LaneBar/Gold")
@export var red_back_path_in_gold: NodePath = NodePath("RedBack")
@export var red_front_path_in_red_back: NodePath = NodePath("RedFront")
@export var legacy_red_path_in_gold: NodePath = NodePath("Red")

@export_group("Layout / Movement Rules")
@export var start_pick_pos: Vector2 = Vector2(6.0, 148.0)
@export var final_push_px: float = 8.0
@export var pick_move_time_sec: float = 0.12
@export var pick_stop_left_of_right_edge_px: float = 1.0

@export_group("Difficulty - Lanes")
@export_range(3, 6, 1) var lane_count: int = 4

@export_group("Motion - Gold (ping-pong)")
@export var gold_period_min_sec: float = 0.65
@export var gold_period_max_sec: float = 1.10

@export_group("Motion - Red (ping-pong inside Gold)")
@export var red_period_min_sec: float = 0.55
@export var red_period_max_sec: float = 0.95

@export_group("Fixed Sizes")
@export var gold_fixed_height_px: float = 32.0
@export var red_fixed_height_px: float = 12.0

@export_group("Red Placement Limits")
@export var red_inset_from_gold_edge_px: float = 1.0

@export_group("Alignment")
@export var alignment_tolerance_px: float = 1.0

@export_group("Success Band")
# Only the CENTER of RedBack counts.
# This is an inset from top and bottom of red (in pixels).
# With red_fixed_height_px = 12, a value of 2 means only the middle 8px is valid.
@export var red_success_inset_px: float = 2.0

@export_group("Fallback")
@export var fallback_min_lanes: int = 1
@export var fallback_max_lanes: int = 2
@export_range(0.0, 1.0, 0.01) var fallback_two_lane_chance: float = 0.35

@export_group("Visual Rules")
@export var red_alpha_when_set: float = 1.0 # legacy; alpha is forced to 1.0 in script

@export_group("Auto Close")
@export var auto_close_on_success: bool = true
@export var auto_close_on_cancel: bool = true

@export_group("Debug")
@export var debug_log: bool = false


var _state: State = State.IDLE

var _lanes_root: Control = null
var _pick: Control = null
var _pick_tip: Control = null
var _lock_body: AnimatedSprite2D = null
var _unlock_click: AudioStreamPlayer = null

var _lanes: Array[LaneRuntime] = []
var _active_lane: int = 0

var _pick_tween: Tween = null
var _start_tip_global_x: float = 0.0


func _ready() -> void:
	_lanes_root = get_node_or_null(lanes_root_path) as Control
	_pick = get_node_or_null(pick_path) as Control
	_pick_tip = get_node_or_null(pick_tip_path) as Control
	_lock_body = get_node_or_null(lock_body_path) as AnimatedSprite2D
	_unlock_click = get_node_or_null(unlock_click_path) as AudioStreamPlayer

	if _lanes_root == null:
		push_warning("[LockpickMinigame] Missing lanes_root: " + String(lanes_root_path))
		return
	if _pick == null:
		push_warning("[LockpickMinigame] Missing pick: " + String(pick_path))
		return
	if _pick_tip == null:
		push_warning("[LockpickMinigame] Missing pick_tip: " + String(pick_tip_path))
		return

	_collect_lanes()
	_apply_layering_rules()

	if _lock_body != null:
		_lock_body.animation_finished.connect(_on_lock_body_animation_finished)
		if _lock_body.sprite_frames != null:
			if _lock_body.sprite_frames.has_animation("Locked"):
				_lock_body.play("Locked")

	_reset_minigame()


func _process(delta: float) -> void:
	if _state == State.CANCELLED:
		return
	if _state == State.SUCCESS:
		return

	if Input.is_action_just_pressed(action_cancel):
		_cancel()
		return

	if _state == State.MOVING_PICK:
		return
	if _state == State.FINISHING:
		return

	if _state == State.ACTIVE:
		_update_active_lane_motion(delta)
		if Input.is_action_just_pressed(action_set):
			_try_set_active_lane()


func _collect_lanes() -> void:
	_lanes.clear()

	var child_count: int = _lanes_root.get_child_count()
	var i: int = 0
	while i < child_count:
		var n: Node = _lanes_root.get_child(i)
		if n is Control:
			var lane: Control = n as Control
			var gold_node: Node = lane.get_node_or_null(gold_path_in_lane)

			if gold_node is NinePatchRect:
				var gold: NinePatchRect = gold_node as NinePatchRect
				var lr: LaneRuntime = LaneRuntime.new(lane, gold)

				var rb: Node = gold.get_node_or_null(red_back_path_in_gold)
				if rb is NinePatchRect:
					lr.red_back = rb as NinePatchRect

				if lr.red_back != null:
					var rf: Node = lr.red_back.get_node_or_null(red_front_path_in_red_back)
					if rf is NinePatchRect:
						lr.red_front = rf as NinePatchRect

				if lr.red_back == null:
					var legacy: Node = gold.get_node_or_null(legacy_red_path_in_gold)
					if legacy is NinePatchRect:
						lr.red_back = legacy as NinePatchRect

				if lr.red_back != null:
					_lanes.append(lr)
		i += 1

	if debug_log:
		print("[LockpickMinigame] lanes collected: ", _lanes.size())


func _apply_layering_rules() -> void:
	# LaneBar < Gold < RedBack < Pick < RedFront
	# IMPORTANT: Keep z_as_relative TRUE so the parent z_index lifts the entire minigame in HUD.
	_pick.z_as_relative = true
	_pick.z_index = 3

	var i: int = 0
	while i < _lanes.size():
		var lr: LaneRuntime = _lanes[i]

		lr.gold.z_as_relative = true
		lr.gold.z_index = 1

		if lr.red_back != null:
			lr.red_back.z_as_relative = true
			lr.red_back.z_index = 0

		if lr.red_front != null:
			lr.red_front.z_as_relative = true
			lr.red_front.z_index = 4

		i += 1


func _reset_minigame() -> void:
	if _lanes.size() <= 0:
		push_warning("[LockpickMinigame] No usable lanes found. Check prefab paths.")
		return

	_state = State.IDLE
	_active_lane = 0

	if lane_count < 3:
		lane_count = 3
	if lane_count > 6:
		lane_count = 6
	if lane_count > _lanes.size():
		lane_count = _lanes.size()

	_pick.position = start_pick_pos
	_start_tip_global_x = _pick_tip.global_position.x

	var i: int = 0
	while i < _lanes.size():
		var lr: LaneRuntime = _lanes[i]

		if i < lane_count:
			lr.lane.visible = true
		else:
			lr.lane.visible = false

		lr.configured = false
		lr.is_set = false
		lr.gold.visible = false
		_set_red_alpha(lr, 1.0)
		i += 1

	if _lock_body != null:
		if _lock_body.sprite_frames != null:
			if _lock_body.sprite_frames.has_animation("Locked"):
				_lock_body.play("Locked")

	_activate_lane(0)
	_move_pick_to_progress(0)


func _activate_lane(lane_index: int) -> void:
	if lane_index < 0:
		return
	if lane_index >= lane_count:
		return

	_active_lane = lane_index

	var i: int = 0
	while i < lane_count:
		var lr_vis: LaneRuntime = _lanes[i]
		if i <= _active_lane:
			lr_vis.gold.visible = true
		else:
			lr_vis.gold.visible = false
		i += 1

	var lr: LaneRuntime = _lanes[_active_lane]
	if lr.configured == false:
		_configure_lane(lr)

	_set_red_alpha(lr, 1.0)

	lane_activated.emit(_active_lane)
	_state = State.ACTIVE


func _configure_lane(lr: LaneRuntime) -> void:
	lr.gold.size = Vector2(lr.gold.size.x, gold_fixed_height_px)

	if lr.red_back != null:
		lr.red_back.size = Vector2(lr.red_back.size.x, red_fixed_height_px)
	if lr.red_front != null:
		lr.red_front.size = Vector2(lr.red_front.size.x, red_fixed_height_px)

	var lane_h: float = lr.lane.size.y
	lr.gold_max_y = maxf(0.0, lane_h - gold_fixed_height_px)

	var red_h: float = red_fixed_height_px
	var min_red_y: float = red_inset_from_gold_edge_px
	var max_red_y: float = gold_fixed_height_px - red_h - red_inset_from_gold_edge_px
	if max_red_y < min_red_y:
		max_red_y = min_red_y
	lr.red_max_y = max_red_y

	lr.gold_t = randf()
	lr.gold_dir = 1
	lr.gold_period_sec = randf_range(gold_period_min_sec, gold_period_max_sec)
	if lr.gold_period_sec < 0.05:
		lr.gold_period_sec = 0.05

	lr.red_t = randf()
	lr.red_dir = 1
	lr.red_period_sec = randf_range(red_period_min_sec, red_period_max_sec)
	if lr.red_period_sec < 0.05:
		lr.red_period_sec = 0.05

	lr.gold.position = Vector2(lr.gold.position.x, _curve01_to_y(lr.gold_t, lr.gold_max_y))

	if lr.red_back != null:
		var red_y: float = _curve01_to_y(lr.red_t, lr.red_max_y)
		lr.red_back.position = Vector2(lr.red_back.position.x, red_y)

	lr.configured = true


func _update_active_lane_motion(delta: float) -> void:
	if _active_lane < 0:
		return
	if _active_lane >= lane_count:
		return

	var lr: LaneRuntime = _lanes[_active_lane]
	if lr.gold.visible == false:
		return
	if lr.configured == false:
		return

	var gold_step: float = delta / lr.gold_period_sec
	var gold_t_new: float = lr.gold_t + float(lr.gold_dir) * gold_step
	if gold_t_new >= 1.0:
		gold_t_new = 1.0
		lr.gold_dir = -1
	elif gold_t_new <= 0.0:
		gold_t_new = 0.0
		lr.gold_dir = 1
	lr.gold_t = gold_t_new
	lr.gold.position = Vector2(lr.gold.position.x, _curve01_to_y(lr.gold_t, lr.gold_max_y))

	if lr.red_back != null:
		var red_step: float = delta / lr.red_period_sec
		var red_t_new: float = lr.red_t + float(lr.red_dir) * red_step
		if red_t_new >= 1.0:
			red_t_new = 1.0
			lr.red_dir = -1
		elif red_t_new <= 0.0:
			red_t_new = 0.0
			lr.red_dir = 1
		lr.red_t = red_t_new

		var red_y: float = _curve01_to_y(lr.red_t, lr.red_max_y)
		lr.red_back.position = Vector2(lr.red_back.position.x, red_y)


func _curve01_to_y(t: float, max_y: float) -> float:
	var p: float = t * t * (3.0 - (2.0 * t))
	return p * max_y


func _try_set_active_lane() -> void:
	if _state != State.ACTIVE:
		return

	var ok: bool = _is_pick_tip_inside_red_middle_band()
	if ok:
		_on_lane_success()
	else:
		_on_lane_fail()


func _is_pick_tip_inside_red_middle_band() -> bool:
	if _active_lane < 0:
		return false
	if _active_lane >= lane_count:
		return false

	var lr: LaneRuntime = _lanes[_active_lane]
	if lr.red_back == null:
		return false

	var pick_tip_y: float = _pick_tip.global_position.y

	var red_top: float = lr.red_back.global_position.y
	var red_bottom: float = lr.red_back.global_position.y + lr.red_back.size.y

	var inset: float = red_success_inset_px
	var max_inset: float = (lr.red_back.size.y * 0.5) - 1.0
	if max_inset < 0.0:
		max_inset = 0.0
	inset = clampf(inset, 0.0, max_inset)

	var band_top: float = red_top + inset - alignment_tolerance_px
	var band_bottom: float = red_bottom - inset + alignment_tolerance_px

	if pick_tip_y >= band_top and pick_tip_y <= band_bottom:
		return true

	return false


func _on_lane_success() -> void:
	if _active_lane < 0:
		return
	if _active_lane >= lane_count:
		return

	var lr_done: LaneRuntime = _lanes[_active_lane]
	lr_done.is_set = true

	# No red fading in v1 (layering handles the “set” look).
	_set_red_alpha(lr_done, red_alpha_when_set)

	lane_set.emit(_active_lane)

	var next_lane: int = _active_lane + 1
	if next_lane >= lane_count:
		_start_finish_sequence()
		return

	_activate_lane(next_lane)
	_move_pick_to_progress(next_lane)


func _on_lane_fail() -> void:
	var fallback: int = fallback_min_lanes
	var roll: float = randf()

	if fallback_max_lanes > fallback_min_lanes:
		if roll <= fallback_two_lane_chance:
			fallback = fallback_max_lanes

	fallback = clampi(fallback, 0, 6)

	var new_lane: int = _active_lane - fallback
	if new_lane < 0:
		new_lane = 0

	failed_lane.emit(_active_lane, fallback)

	var i: int = new_lane
	while i < lane_count:
		var lr: LaneRuntime = _lanes[i]
		lr.is_set = false
		lr.configured = false
		_set_red_alpha(lr, 1.0)
		i += 1

	_activate_lane(new_lane)
	_move_pick_to_progress(new_lane)


func _move_pick_to_progress(completed_count: int) -> void:
	if _pick_tween != null:
		_pick_tween.kill()
		_pick_tween = null

	var target_tip_global_x: float = _start_tip_global_x

	if completed_count > 0:
		var last_lane_index: int = completed_count - 1
		if last_lane_index >= 0 and last_lane_index < lane_count:
			var lane_node: Control = _lanes[last_lane_index].lane
			target_tip_global_x = lane_node.global_position.x + lane_node.size.x - pick_stop_left_of_right_edge_px

	var tip_local_x: float = _pick_tip.position.x
	var target_pick_global_x: float = target_tip_global_x - tip_local_x

	_state = State.MOVING_PICK

	_pick_tween = create_tween()
	_pick_tween.set_trans(Tween.TRANS_SINE)
	_pick_tween.set_ease(Tween.EASE_OUT)
	_pick_tween.tween_property(_pick, "global_position:x", target_pick_global_x, pick_move_time_sec)
	_pick_tween.finished.connect(_on_pick_move_finished)


func _on_pick_move_finished() -> void:
	_pick_tween = null
	if _state == State.MOVING_PICK:
		_state = State.ACTIVE


func _start_finish_sequence() -> void:
	_state = State.FINISHING

	var last_lane_index: int = lane_count - 1
	var last_right_x: float = _start_tip_global_x
	if last_lane_index >= 0 and last_lane_index < lane_count:
		var last_lane: Control = _lanes[last_lane_index].lane
		last_right_x = last_lane.global_position.x + last_lane.size.x - pick_stop_left_of_right_edge_px

	var target_tip_global_x: float = last_right_x + final_push_px
	var tip_local_x: float = _pick_tip.position.x
	var target_pick_global_x: float = target_tip_global_x - tip_local_x

	if _pick_tween != null:
		_pick_tween.kill()
		_pick_tween = null

	_pick_tween = create_tween()
	_pick_tween.set_trans(Tween.TRANS_SINE)
	_pick_tween.set_ease(Tween.EASE_OUT)
	_pick_tween.tween_property(_pick, "global_position:x", target_pick_global_x, pick_move_time_sec)
	_pick_tween.finished.connect(_on_finish_pick_push_done)


func _on_finish_pick_push_done() -> void:
	_pick_tween = null

	if _unlock_click != null:
		_unlock_click.play()

	if _lock_body != null:
		if _lock_body.sprite_frames != null:
			if _lock_body.sprite_frames.has_animation("Unlocking"):
				_lock_body.play("Unlocking")
				return

	_finish_success_now()


func _on_lock_body_animation_finished() -> void:
	if _lock_body == null:
		return

	if _lock_body.animation == "Unlocking":
		if _lock_body.sprite_frames != null:
			if _lock_body.sprite_frames.has_animation("Unlocked"):
				_lock_body.play("Unlocked")
		_finish_success_now()


func _finish_success_now() -> void:
	_state = State.SUCCESS
	succeeded.emit()

	if auto_close_on_success:
		hide()
		queue_free()


func _set_red_alpha(lr: LaneRuntime, a: float) -> void:
	# NOTE: Lockpick v1 no longer fades RedBack/RedFront.
	# We keep this helper (and the export that calls it) for compatibility, but force alpha to 1.0.
	var aa: float = 1.0

	if lr.red_back != null:
		var c1: Color = lr.red_back.modulate
		c1.a = aa
		lr.red_back.modulate = c1

	if lr.red_front != null:
		var c2: Color = lr.red_front.modulate
		c2.a = aa
		lr.red_front.modulate = c2


func _cancel() -> void:
	_state = State.CANCELLED
	cancelled.emit()

	if auto_close_on_cancel:
		hide()
		queue_free()
