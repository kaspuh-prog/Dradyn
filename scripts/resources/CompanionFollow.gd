extends Node2D
class_name CompanionFollow

# ---------- Movement / Follow ----------
@export var follow_speed: float = 140.0
@export var stop_distance: float = 24.0
@export var resume_distance: float = 48.0
@export var min_close_speed_mul: float = 0.5

# ---------- Queue separation ----------
@export var separation_radius: float = 48.0
@export var separation_strength: float = 220.0

# ---------- Unstick ----------
@export var stuck_radius: float = 16.0
@export var stuck_time_threshold: float = 0.25
@export var unstick_push: float = 140.0

# ---------- ENGAGE ----------
@export var engage_enabled: bool = true
@export var engage_radius: float = 120.0
@export var engage_leash_distance: float = 280.0
@export var attack_range: float = 24.0
@export var retarget_interval: float = 0.25
@export var lose_target_cooldown: float = 0.5

# ---------- ATTACK ----------
@export var attack_cooldown_sec: float = 0.8
@export var damage_type_weights: Dictionary = {"Slash": 1.0}

# ---------- Collision policy (Ally pass-through) ----------
@export var configure_collision_in_code: bool = true
# Adjust these if your project uses different layer indices.
const LBIT_WORLD := 1
const LBIT_ENEMY := 2
const LBIT_ALLY  := 3

# ---------- Internals ----------
var _controlled: Node2D = null
var _owner_body: CharacterBody2D = null
var _active: bool = true

var follow_target: Node = null
var following: bool = true

var _neighbors: Array[CompanionFollow] = []

enum Mode { FOLLOW, ENGAGE, RETURN }
var _mode: int = Mode.FOLLOW
var _aggro_target: Node2D = null
var _retarget_accum: float = 0.0
var _lost_timer: float = 0.0
var _stuck_timer: float = 0.0
var _atk_cd: float = 0.0

# ---------------------------------------------------------
# SPEED SOURCE
# ---------------------------------------------------------
func _get_move_speed() -> float:
	if _owner_body and _owner_body.has_node("StatsComponent"):
		var stats: Node = _owner_body.get_node("StatsComponent")
		if stats:
			# Prefer final stat if available
			if stats.has_method("get_final_stat"):
				return float(stats.get_final_stat("MoveSpeed"))
			if stats.has_method("get_move_speed"):
				return float(stats.get_move_speed())
			if "move_speed" in stats:
				return float(stats.move_speed)
	if _owner_body and "move_speed" in _owner_body:
		return float(_owner_body.move_speed)
	return follow_speed

# ---------------------------------------------------------
# PUBLIC API
# ---------------------------------------------------------
func set_follow_target(t: Node) -> void:
	follow_target = t
	following = (t != null)

func set_active(on: bool) -> void:
	_active = on
	if not _active:
		_clear_target()
		_mode = Mode.FOLLOW

func set_engage_enabled(on: bool) -> void:
	engage_enabled = on
	if not engage_enabled:
		_clear_target()
		_mode = Mode.FOLLOW

# ---------------------------------------------------------
# READY / PARTY HOOK
# ---------------------------------------------------------
func _ready() -> void:
	_owner_body = get_parent() as CharacterBody2D
	if _owner_body == null:
		_owner_body = find_parent("CharacterBody2D") as CharacterBody2D
	if _owner_body == null:
		push_warning("CompanionFollow expects to be a child of a CharacterBody2D.")
	if Engine.is_editor_hint():
		return

	# Ensure party grouping for neighbor/separation logic
	if not _owner_body.is_in_group("PartyMembers"):
		_owner_body.add_to_group("PartyMembers")

	# Minimal code-side collision (no ally blocking)
	if configure_collision_in_code and _owner_body is CollisionObject2D:
		_configure_as_ally(_owner_body)

	# PartyManager (autoload) wiring
	var pm: Node = get_tree().get_first_node_in_group("PartyManager")
	if pm:
		if not pm.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
			pm.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
		if not pm.is_connected("party_changed", Callable(self, "_on_party_changed")):
			pm.connect("party_changed", Callable(self, "_on_party_changed"))
		if pm.has_method("get_controlled"):
			_on_controlled_changed(pm.get_controlled())
		if pm.has_method("get_members"):
			_on_party_changed(pm.get_members())

func _on_controlled_changed(current: Node) -> void:
	_controlled = current as Node2D
	_active = (_controlled != _owner_body)   # disable AI on the controlled actor
	if not _active:
		_clear_target()
		_mode = Mode.FOLLOW

func _on_party_changed(members: Array) -> void:
	_neighbors.clear()
	for m in members:
		if m == _owner_body:
			continue
		var cf: CompanionFollow = _find_cf(m)
		if cf != null:
			_neighbors.append(cf)

func _find_cf(root: Node) -> CompanionFollow:
	if root == null:
		return null
	if root is CompanionFollow:
		return root as CompanionFollow
	var by_name: Node = root.find_child("CompanionFollow", true, false)
	if by_name != null and by_name is CompanionFollow:
		return by_name as CompanionFollow
	for c in root.get_children():
		if c.has_method("set_follow_target"):
			return c as CompanionFollow
	return null

# ---------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _owner_body == null or not _active:
		return

	_atk_cd = maxf(0.0, _atk_cd - delta)

	var leader_pos: Vector2 = Vector2.ZERO
	if _controlled is Node2D:
		leader_pos = (_controlled as Node2D).global_position

	_update_engage_state(delta, leader_pos)

	var have_move: bool = false
	var target_pos: Vector2 = Vector2.ZERO

	if _mode == Mode.ENGAGE and _aggro_target != null:
		target_pos = _aggro_target.global_position
		have_move = true
	elif _mode == Mode.RETURN:
		if follow_target is Node2D:
			target_pos = (follow_target as Node2D).global_position
			have_move = true
		elif _controlled is Node2D:
			target_pos = leader_pos
			have_move = true
	elif following and follow_target is Node2D:
		target_pos = (follow_target as Node2D).global_position
		have_move = true

	if not have_move:
		return

	var self_pos: Vector2 = _owner_body.global_position
	var to_target: Vector2 = target_pos - self_pos
	var dist: float = to_target.length()

	var stop_at: float = stop_distance
	if _mode == Mode.ENGAGE:
		stop_at = attack_range

	if dist <= stop_at:
		_owner_body.velocity = Vector2.ZERO
		_owner_body.move_and_slide()
		_stuck_timer = 0.0
		if _mode == Mode.ENGAGE:
			_try_attack()
		if _mode == Mode.RETURN and follow_target != null:
			_mode = Mode.FOLLOW
		return

	var base_speed: float = _get_move_speed()
	var speed: float = base_speed

	var near_band: float = resume_distance
	if _mode == Mode.ENGAGE:
		if stop_at + 8.0 > resume_distance:
			near_band = stop_at + 8.0
		else:
			near_band = resume_distance

	if dist < near_band:
		var band: float = near_band - stop_at
		if band < 0.001:
			band = 0.001
		var t: float = (dist - stop_at) / band
		t = clampf(t, 0.0, 1.0)
		var scale: float = maxf(min_close_speed_mul, t)
		speed = base_speed * scale

	var dir: Vector2 = to_target / maxf(0.001, dist)

	# Separation (disabled during ENGAGE so we don't fight for the same target)
	var sep: Vector2 = Vector2.ZERO
	if _mode != Mode.ENGAGE and separation_radius > 0.0 and separation_strength > 0.0 and _neighbors.size() > 0:
		var r: float = separation_radius
		var r2: float = r * r
		for other_cf in _neighbors:
			if other_cf == null or other_cf._owner_body == null:
				continue
			if other_cf.follow_target == _owner_body:
				continue
			var op: Vector2 = other_cf._owner_body.global_position
			var dvec: Vector2 = self_pos - op
			var d2: float = dvec.length_squared()
			if d2 > 1.0 and d2 < r2:
				var d: float = sqrt(d2)
				var factor: float = 1.0 - (d / r)
				var nrm: Vector2 = dvec / maxf(0.001, d)
				sep += nrm * (separation_strength * factor)
		# soften and cap separation so it doesn't explode speed
		sep *= delta
		if sep.length() > base_speed * 0.8:
			sep = sep.normalized() * (base_speed * 0.8)

	# Small "leader bubble" so we don't sit on the leader while following/returning
	var bubble: Vector2 = Vector2.ZERO
	if _mode != Mode.ENGAGE and _controlled is Node2D:
		var to_leader: Vector2 = self_pos - leader_pos
		var d: float = to_leader.length()
		if d < separation_radius:
			bubble = (to_leader / maxf(0.001, d)) * 80.0 * (1.0 - (d / separation_radius))

	# Emergency unstick
	if dist < stuck_radius:
		_stuck_timer += delta
		if _stuck_timer >= stuck_time_threshold:
			var away: Vector2 = self_pos - target_pos
			if away.length() < 0.01:
				away = Vector2.RIGHT
			else:
				away = away / away.length()
			_owner_body.velocity = away * unstick_push
			_owner_body.move_and_slide()
			return
	else:
		_stuck_timer = 0.0

	_owner_body.velocity = dir * speed + sep + bubble
	_owner_body.move_and_slide()

# ---------------------------------------------------------
# ENGAGE state helpers
# ---------------------------------------------------------
func _update_engage_state(delta: float, leader_pos: Vector2) -> void:
	if not engage_enabled:
		_clear_target()
		_mode = Mode.FOLLOW
		return

	_retarget_accum += delta
	if _mode != Mode.ENGAGE and _retarget_accum >= retarget_interval:
		_retarget_accum = 0.0
		var best: Node2D = _find_nearest_enemy_in_radius(engage_radius)
		if best != null:
			_aggro_target = best
			_lost_timer = 0.0
			_mode = Mode.ENGAGE

	if _mode == Mode.ENGAGE:
		var invalid: bool = false
		if _aggro_target == null or not is_instance_valid(_aggro_target):
			invalid = true
		else:
			var d_to_leader: float = (_owner_body.global_position - leader_pos).length()
			if d_to_leader > engage_leash_distance:
				invalid = true
			else:
				var d_to_target: float = (_owner_body.global_position - _aggro_target.global_position).length()
				if d_to_target > engage_radius * 1.6:
					_lost_timer += delta
				else:
					_lost_timer = 0.0
				if _target_is_dead(_aggro_target):
					invalid = true
		if invalid or _lost_timer >= lose_target_cooldown:
			_clear_target()
			_mode = Mode.RETURN

func _find_nearest_enemy_in_radius(radius: float) -> Node2D:
	var best: Node2D = null
	var best_d2: float = radius * radius
	var self_pos: Vector2 = _owner_body.global_position
	for e in get_tree().get_nodes_in_group("Enemies"):
		if e is Node2D and is_instance_valid(e) and not _target_is_dead(e):
			var p: Vector2 = (e as Node2D).global_position
			var d2: float = (p - self_pos).length_squared()
			if d2 <= best_d2:
				best_d2 = d2
				best = e as Node2D
	return best

func _target_is_dead(n: Node) -> bool:
	if n == null or not is_instance_valid(n):
		return true
	var stats: Node = n.find_child("StatsComponent", true, false)
	if stats and stats.has_method("current_hp"):
		return float(stats.current_hp()) <= 0.0
	return false

func _clear_target() -> void:
	_aggro_target = null
	_lost_timer = 0.0
	_retarget_accum = 0.0

# ---------------------------------------------------------
# ATTACK helpers
# ---------------------------------------------------------
func _try_attack() -> void:
	if _atk_cd > 0.0 or _aggro_target == null or not is_instance_valid(_aggro_target):
		return
	_atk_cd = attack_cooldown_sec
	_apply_attack_hit()

func _apply_attack_hit() -> void:
	var tgt_stats := _find_stats_component(_aggro_target)
	if tgt_stats == null:
		return
	var atk: float = _get_attack_power()
	var packet := {"amount": atk, "types": damage_type_weights, "source": name}
	tgt_stats.apply_damage_packet(packet)

func _get_attack_power() -> float:
	if _owner_body and _owner_body.has_node("StatsComponent"):
		var sc := _owner_body.get_node("StatsComponent")
		if sc and sc.has_method("get_final_stat"):
			return float(sc.get_final_stat("Attack"))
	return 12.0

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var by_name := root.find_child("StatsComponent", true, false)
	if by_name:
		return by_name
	if root.has_method("apply_damage_packet"):
		return root
	return null

# ---------------------------------------------------------
# Collision: Allies pass through each other; collide with World & Enemies
# ---------------------------------------------------------
func _configure_as_ally(body: CollisionObject2D) -> void:
	# Clear everything first
	for i in range(1, 33):
		body.set_collision_layer_value(i, false)
		body.set_collision_mask_value(i, false)
	# Be ON the Ally layer
	body.set_collision_layer_value(LBIT_ALLY, true)
	# Collide with World + Enemies; NOT Ally
	body.set_collision_mask_value(LBIT_WORLD, true)
	body.set_collision_mask_value(LBIT_ENEMY, true)
	body.set_collision_mask_value(LBIT_ALLY, false)
