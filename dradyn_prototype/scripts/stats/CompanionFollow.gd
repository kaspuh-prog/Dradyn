@icon("res://icon.svg")
extends Node
class_name CompanionFollow

## Child of your companion CharacterBody2D (or Node2D). Auto-adds NavigationAgent2D.

# ---------- Target / Party wiring ----------
@export var use_party_autoload: bool = true
@export var target_path: NodePath

# ---------- Formation / distances ----------
@export var formation_slot: int = 0
@export var formation_radius: float = 40.0
@export var stop_distance: float = 24.0
@export var leash_distance: float = 220.0
@export var teleport_threshold: float = 900.0
@export var allow_teleport_catchup: bool = true

# ---------- Movement / speeds ----------
@export var base_move_speed: float = 120.0
@export var catchup_speed_multiplier: float = 1.65
@export var slow_arrive_factor: float = 0.2
@export var accel: float = 800.0
@export var deccel: float = 1200.0

# ---------- Navigation ----------
@export var repath_interval: float = 0.15
@export var path_goal_tolerance: float = 8.0
@export var enable_avoidance: bool = true
@export var max_neighbors: int = 8

# ---------- Optional Stats hook ----------
@export var stats_component_path: NodePath

# ---------- State ----------
var follow_enabled: bool = true
var _owns_motion: bool = false
var _body: Node2D
var _agent: NavigationAgent2D
var _target: Node2D
var _repath_t: float = 0.0

func _ready() -> void:
	_body = get_parent() as Node2D
	if _body == null:
		push_error("CompanionFollow must be a child of a Node2D/CharacterBody2D.")
		set_physics_process(false)
		return

	# If accidentally on the leader, start disabled
	if _body.is_in_group("player_controlled"):
		follow_enabled = false
		_owns_motion = false

	# Ensure we have a NavigationAgent2D (avoid ?: that yields Variant)
	if has_node("NavigationAgent2D"):
		_agent = get_node("NavigationAgent2D") as NavigationAgent2D
	else:
		_agent = NavigationAgent2D.new()
		add_child(_agent)
		_agent.name = "NavigationAgent2D"

	# Configure agent
	_agent.avoidance_enabled = enable_avoidance
	_agent.max_neighbors = max_neighbors
	_agent.path_max_distance = 2000.0
	_agent.radius = 8.0
	_agent.target_desired_distance = path_goal_tolerance

	# Seed target
	if target_path != NodePath(""):
		_target = get_node_or_null(target_path) as Node2D
	elif use_party_autoload:
		var pm: Node = get_node_or_null("/root/Party")
		if pm:
			# pm should be PartyManager with this signal signature
			pm.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
			_on_party_controlled_changed((pm as Object).callv("get_controlled", []) as Node)
		else:
			_target = null

	set_physics_process(true)

# --- Ownership API (called by Player/PartyManager) -----------------
func set_motion_ownership(v: bool) -> void:
	_owns_motion = v

func enable_follow(v: bool) -> void:
	follow_enabled = v

# --- Party signal --------------------------------------------------
func _on_party_controlled_changed(now: Node) -> void:
	if now and now != _body:
		set_follow_target(now)

# --- Public API ----------------------------------------------------
func set_follow_target(node: Node) -> void:
	_target = node as Node2D
	if _target:
		_agent.set_target_position(_desired_goal_position())

# --- Physics -------------------------------------------------------
func _physics_process(delta: float) -> void:
	if not follow_enabled or _target == null:
		_stop_motion(delta)
		return

	var my_pos: Vector2 = _body.global_position
	var tgt_pos: Vector2 = _target.global_position
	var dist: float = my_pos.distance_to(tgt_pos)

	# Emergency catch-up to keep party cohesive
	if allow_teleport_catchup and dist > teleport_threshold:
		_snap_near_target()
		return

	# Desired slot around target
	var goal: Vector2 = _desired_goal_position()

	# Refresh path periodically or if target moved a lot
	_repath_t -= delta
	if _repath_t <= 0.0 or _agent.distance_to_target() > 2.0 * path_goal_tolerance:
		_agent.set_target_position(goal)
		_repath_t = repath_interval

	# If already at goal, hover/arrive
	if my_pos.distance_to(goal) <= stop_distance:
		_arrive(delta)
		return

	# Otherwise, steer along path (delta-safe smoothing)
	var next_point: Vector2 = _agent.get_next_path_position()
	var dir: Vector2 = (next_point - my_pos)
	var dlen: float = dir.length()
	if dlen > 0.001:
		dir = dir / dlen
	else:
		dir = Vector2.ZERO

	var speed: float = _get_movespeed()
	if dist > leash_distance:
		speed *= catchup_speed_multiplier

	_move_smooth(dir, speed, delta)

# --- Helpers -------------------------------------------------------
func _get_movespeed() -> float:
	if stats_component_path != NodePath(""):
		var sc: Object = _body.get_node_or_null(stats_component_path)
		if sc and sc.has_method("get_final_stat"):
			return float(sc.call("get_final_stat", "MoveSpeed"))
	return base_move_speed

func _arrive(delta: float) -> void:
	if _body is CharacterBody2D:
		var b: CharacterBody2D = _body as CharacterBody2D
		var t: float = clamp(slow_arrive_factor * delta * 5.0, 0.0, 1.0)
		b.velocity = b.velocity.lerp(Vector2.ZERO, t)
		if _owns_motion:
			b.move_and_slide()
	else:
		var p: Vector2 = _desired_goal_position()
		_body.global_position = _body.global_position.lerp(p, clamp(slow_arrive_factor * delta * 5.0, 0.0, 1.0))

func _move_smooth(dir: Vector2, speed: float, delta: float) -> void:
	if _body is CharacterBody2D:
		var b: CharacterBody2D = _body as CharacterBody2D
		var desired: Vector2 = dir * speed
		var ramp: float = (accel if desired.length() > b.velocity.length() else deccel)
		b.velocity = b.velocity.move_toward(desired, ramp * delta)
		if _owns_motion:
			b.move_and_slide()
	else:
		_body.global_position += dir * speed * delta

func _stop_motion(delta: float) -> void:
	if _body is CharacterBody2D:
		var b: CharacterBody2D = _body as CharacterBody2D
		b.velocity = b.velocity.move_toward(Vector2.ZERO, deccel * delta)
		if _owns_motion and b.velocity.length() > 0.1:
			b.move_and_slide()

func _snap_near_target() -> void:
	if _target == null:
		return
	var offset: Vector2 = _slot_offset()
	_body.global_position = _target.global_position + offset
	if _body is CharacterBody2D:
		var b: CharacterBody2D = _body as CharacterBody2D
		b.velocity = Vector2.ZERO
	_agent.set_target_position(_desired_goal_position())

func _desired_goal_position() -> Vector2:
	if _target == null:
		return _body.global_position
	return _target.global_position + _slot_offset()

func _slot_offset() -> Vector2:
	# 4-slot ring by default; change multiplier for more/less slots
	var angle: float = float(formation_slot) * TAU * 0.25
	return Vector2.RIGHT.rotated(angle) * formation_radius
