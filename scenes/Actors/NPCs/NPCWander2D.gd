extends Node
class_name NPCWander2D
# Godot 4.5 — typed, no ternaries.
# Reusable lightweight wander/avoid component for Node2D NPCs (including NonCombatNPC root).
# - Moves a target Node2D by setting global_position (no CharacterBody2D required).
# - Uses ray + shape queries to avoid walking into colliders.
# - Leashed to an anchor point so NPCs roam in a local radius.
# - Drives AnimationBridge locomotion (walk/idle) if present.

@export_group("Wander")
@export var enabled: bool = true
@export var target_path: NodePath = NodePath("") # if empty, uses parent Node2D
@export var roam_radius_px: float = 64.0
@export var move_speed_px_per_sec: float = 18.0
@export var walk_duration_min_sec: float = 0.9
@export var walk_duration_max_sec: float = 2.2
@export var idle_duration_min_sec: float = 0.4
@export var idle_duration_max_sec: float = 1.2
@export var anchor_at_ready: bool = true

@export_group("Avoidance")
@export var collision_mask: int = 1
@export var lookahead_px: float = 14.0
@export var body_radius_px: float = 6.0
@export var nudge_on_hit_px: float = 4.0
@export var max_slide_angle_deg: float = 70.0 # if too shallow, we pick a new random direction
@export var exclude_self_from_queries: bool = true

@export_group("Animation")
@export var drive_animation_bridge: bool = true
@export var animation_bridge_path: NodePath = NodePath("../AnimationBridge")
@export var animation_moving_epsilon_px: float = 0.25

@export_group("Debug")
@export var debug_logs: bool = false

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _target: Node2D
var _anchor: Vector2

var _dir: Vector2 = Vector2.RIGHT
var _state: int = 0 # 0=idle, 1=walk
var _state_time_left: float = 0.0

var _exclude_rids: Array[RID] = []

var _anim_bridge: AnimationBridge = null
var _facing_dir: Vector2 = Vector2.DOWN

func _ready() -> void:
	_rng.randomize()
	_target = _resolve_target()
	if _target == null:
		if debug_logs:
			push_warning("[NPCWander2D] No target Node2D found. Disabling.")
		enabled = false
		return

	if anchor_at_ready:
		_anchor = _target.global_position
	else:
		_anchor = _target.global_position

	_rebuild_excludes()
	_resolve_animation_bridge()

	_enter_idle()
	_push_anim_state(false)

func _physics_process(delta: float) -> void:
	if not enabled:
		return
	if _target == null:
		return

	_state_time_left -= delta
	if _state_time_left <= 0.0:
		if _state == 0:
			_enter_walk()
		else:
			_enter_idle()

	if _state == 1:
		_step_walk(delta)
	else:
		_push_anim_state(false)

func set_anchor_world(pos: Vector2) -> void:
	_anchor = pos

func reset_anchor_to_current() -> void:
	if _target != null:
		_anchor = _target.global_position

func set_enabled(on: bool) -> void:
	enabled = on
	if not enabled:
		_state_time_left = 0.0
	_state = 0
	_enter_idle()
	_push_anim_state(false)

# -----------------------
# Internals
# -----------------------

func _resolve_target() -> Node2D:
	if target_path != NodePath(""):
		var n: Node = get_node_or_null(target_path)
		if n is Node2D:
			return n as Node2D
		return null

	var p: Node = get_parent()
	if p is Node2D:
		return p as Node2D
	return null

func _resolve_animation_bridge() -> void:
	_anim_bridge = null
	if not drive_animation_bridge:
		return

	# Preferred: explicit path (default assumes Wander is a child node next to AnimationBridge).
	if animation_bridge_path != NodePath(""):
		var n: Node = get_node_or_null(animation_bridge_path)
		if n is AnimationBridge:
			_anim_bridge = n as AnimationBridge

	# Fallback: search up/down locally for any AnimationBridge.
	if _anim_bridge == null:
		var parent: Node = get_parent()
		if parent != null:
			var kids: Array[Node] = parent.get_children()
			var i: int = 0
			while i < kids.size():
				var k: Node = kids[i]
				if k is AnimationBridge:
					_anim_bridge = k as AnimationBridge
					break
				i += 1

	if debug_logs:
		if _anim_bridge == null:
			print("[NPCWander2D] No AnimationBridge found (drive_animation_bridge=true).")
		else:
			print("[NPCWander2D] AnimationBridge bound: ", _anim_bridge.get_path())

func _enter_idle() -> void:
	_state = 0
	_state_time_left = _rng.randf_range(idle_duration_min_sec, idle_duration_max_sec)

func _enter_walk() -> void:
	_state = 1
	_state_time_left = _rng.randf_range(walk_duration_min_sec, walk_duration_max_sec)
	_dir = _pick_new_dir()

func _pick_new_dir() -> Vector2:
	var angle: float = _rng.randf_range(0.0, TAU)
	var d: Vector2 = Vector2.RIGHT.rotated(angle).normalized()
	if d.length() < 0.001:
		d = Vector2.RIGHT
	return d

func _step_walk(delta: float) -> void:
	if _dir.length() < 0.001:
		_dir = _pick_new_dir()

	var pos: Vector2 = _target.global_position

	# Leash to anchor: if drifting out of radius, steer back in.
	var to_anchor: Vector2 = _anchor - pos
	var dist_to_anchor: float = to_anchor.length()
	if dist_to_anchor > roam_radius_px:
		_dir = to_anchor.normalized()

	# Ray lookahead: if wall ahead, try sliding along normal.
	var ray_res: Dictionary = _raycast(pos, _dir, lookahead_px)
	if not ray_res.is_empty():
		var hit_normal: Vector2 = Vector2.ZERO
		if ray_res.has("normal"):
			hit_normal = ray_res["normal"]

		var slid: Vector2 = _dir.slide(hit_normal).normalized()
		if slid.length() < 0.001:
			_dir = _pick_new_dir()
		else:
			var ang: float = rad_to_deg(_dir.angle_to(slid))
			if absf(ang) > max_slide_angle_deg:
				_dir = _pick_new_dir()
			else:
				_dir = slid

		# Optional small nudge away from the wall
		if nudge_on_hit_px > 0.0:
			pos += hit_normal * nudge_on_hit_px
			_target.global_position = pos

	# Proposed movement step.
	var step: Vector2 = _dir * move_speed_px_per_sec * delta
	if step.length() < 0.001:
		_push_anim_state(false)
		return

	var next_pos: Vector2 = pos + step

	# Shape check at next position: if occupied, bail and idle a bit.
	if _shape_blocked(next_pos):
		if debug_logs:
			print("[NPCWander2D] blocked; choosing new direction")
		_dir = _pick_new_dir()
		_enter_idle()
		_push_anim_state(false)
		return

	_target.global_position = next_pos

	# Determine whether we actually moved enough to count as "moving" for animations.
	var moved_px: float = (next_pos - pos).length()
	var moving_eff: bool = moved_px >= animation_moving_epsilon_px

	if _dir.length() > 0.001:
		_facing_dir = _dir.normalized()

	_push_anim_state(moving_eff)

func _push_anim_state(moving: bool) -> void:
	if not drive_animation_bridge:
		return
	if _anim_bridge == null:
		return

	# Always send facing seed, even when idle, so the idle anim faces the last direction.
	var dir_to_send: Vector2 = _facing_dir
	if dir_to_send.length() <= 0.001:
		dir_to_send = Vector2.DOWN
		_facing_dir = dir_to_send

	_anim_bridge.set_movement(dir_to_send, moving)

func _space_state() -> PhysicsDirectSpaceState2D:
	# Node doesn't have get_world_2d(); the target (Node2D/CanvasItem) does.
	var w: World2D = _target.get_world_2d()
	return w.direct_space_state

func _raycast(from_pos: Vector2, dir: Vector2, dist: float) -> Dictionary:
	var to_pos: Vector2 = from_pos + dir.normalized() * dist

	var q: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.new()
	q.from = from_pos
	q.to = to_pos
	q.collision_mask = collision_mask
	q.collide_with_areas = true
	q.collide_with_bodies = true

	if exclude_self_from_queries:
		q.exclude = _exclude_rids

	return _space_state().intersect_ray(q)

func _shape_blocked(world_pos: Vector2) -> bool:
	var shape: CircleShape2D = CircleShape2D.new()
	shape.radius = body_radius_px

	var q: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()
	q.shape = shape
	q.transform = Transform2D(0.0, world_pos)
	q.collision_mask = collision_mask
	q.collide_with_areas = true
	q.collide_with_bodies = true

	if exclude_self_from_queries:
		q.exclude = _exclude_rids

	var hits: Array[Dictionary] = _space_state().intersect_shape(q, 1)
	return hits.size() > 0

func _rebuild_excludes() -> void:
	_exclude_rids.clear()
	if not exclude_self_from_queries:
		return
	if _target == null:
		return
	_collect_collision_rids(_target)

func _collect_collision_rids(n: Node) -> void:
	if n is CollisionObject2D:
		var co: CollisionObject2D = n as CollisionObject2D
		_exclude_rids.append(co.get_rid())

	var kids: Array[Node] = n.get_children()
	var i: int = 0
	while i < kids.size():
		_collect_collision_rids(kids[i])
		i += 1
