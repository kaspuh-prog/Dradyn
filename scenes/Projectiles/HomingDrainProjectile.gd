extends Projectile
class_name HomingDrainProjectile
# Godot 4.5 — fully typed, no ternaries.
# Auto-targeting, homing projectile:
# 1) Prefer TargetingSys.current_enemy_target()
# 2) Fallback to nearest valid target in hit_groups
# 3) Heal caster for a % of damage dealt (approx using packet amount)

@export var acquire_range_px: float = 520.0
@export var retarget_if_lost: bool = true

# Homing responsiveness (bigger = turns faster)
@export var turn_rate: float = 10.0

# % of damage dealt healed (0.20 = 20%)
@export var heal_ratio: float = 0.20

# If true, only drain on targets that appear "alive" (best-effort guard)
@export var require_live_target: bool = true

var _target: Node2D = null


func setup(user: Node, ability_id: String, direction: Vector2, damage_amount: float) -> void:
	super.setup(user, ability_id, direction, damage_amount)

	_target = _acquire_target_prefer_selected()
	if _target != null:
		var desired: Vector2 = (_target.global_position - global_position).normalized()
		if desired != Vector2.ZERO:
			_dir = desired
			if auto_orient:
				_apply_sprite_orientation(_dir)


func _physics_process(delta: float) -> void:
	if _target == null:
		if retarget_if_lost:
			_target = _acquire_target_prefer_selected()
	else:
		if not is_instance_valid(_target):
			_target = null

	if _target != null:
		var to_t: Vector2 = (_target.global_position - global_position)
		if to_t.length() > 0.0001:
			var desired_dir: Vector2 = to_t.normalized()
			_dir = _steer_toward(_dir, desired_dir, delta)
			if auto_orient:
				_apply_sprite_orientation(_dir)

	super._physics_process(delta)


func _try_hit(target: Node) -> void:
	if target == null:
		return

	if _caster != null:
		if target == _caster:
			return
		if ignore_group != "" and target.is_in_group(ignore_group):
			return

	var group_ok: bool = _matches_hit_groups(target)
	var stats: Node = _find_stats_component(target)
	if not group_ok and stats == null:
		return

	if require_live_target:
		if _is_target_dead_soft(target):
			return

	var heal_amount: float = _base_damage * _clamp01(heal_ratio)

	super._try_hit(target)

	if heal_amount > 0.0:
		_apply_heal_to_caster(heal_amount)


func _apply_heal_to_caster(amount: float) -> void:
	if _caster == null:
		return
	if not is_instance_valid(_caster):
		return

	var caster_stats: Node = _find_stats_component(_caster)
	if caster_stats == null:
		return

	if caster_stats.has_method("apply_heal"):
		caster_stats.call(
			"apply_heal",
			amount,
			_ability_id,
			false,
			null,
			_ability_id
		)
	elif caster_stats.has_method("change_hp"):
		caster_stats.call("change_hp", amount)


func _acquire_target_prefer_selected() -> Node2D:
	var selected: Node2D = _get_selected_enemy_target()
	if selected != null:
		if _is_valid_enemy_target(selected):
			return selected

	return _acquire_nearest_target()


func _get_selected_enemy_target() -> Node2D:
	var sys_node: Node = get_node_or_null("/root/TargetingSys")
	if sys_node == null:
		return null

	if not sys_node.has_method("current_enemy_target"):
		return null

	# IMPORTANT:
	# TargetingSys may return an Object that is already queued/freed between frames.
	# Casting a freed object triggers: "Trying to cast a freed object."
	var t_any: Variant = sys_node.call("current_enemy_target")
	if t_any == null:
		return null

	var obj: Object = t_any as Object
	if obj == null:
		return null
	if not is_instance_valid(obj):
		return null

	if obj is Node2D:
		return obj as Node2D

	return null


func _acquire_nearest_target() -> Node2D:
	var best: Node2D = null
	var best_d2: float = acquire_range_px * acquire_range_px

	var gi: int = 0
	while gi < hit_groups.size():
		var g: String = String(hit_groups[gi])
		gi += 1
		if g == "":
			continue

		var nodes: Array = get_tree().get_nodes_in_group(g)
		var i: int = 0
		while i < nodes.size():
			var n: Node = nodes[i]
			i += 1

			var n2d: Node2D = n as Node2D
			if n2d == null:
				continue

			if not _is_valid_enemy_target(n2d):
				continue

			var d2: float = global_position.distance_squared_to(n2d.global_position)
			if d2 <= best_d2:
				best_d2 = d2
				best = n2d

	return best


func _is_valid_enemy_target(n: Node2D) -> bool:
	if n == null:
		return false
	if not is_instance_valid(n):
		return false

	if _caster != null and n == _caster:
		return false

	if ignore_group != "":
		if n.is_in_group(ignore_group):
			return false

	if require_live_target:
		if _is_target_dead_soft(n):
			return false

	var group_ok: bool = _matches_hit_groups(n)
	var stats: Node = _find_stats_component(n)
	if not group_ok and stats == null:
		return false

	var d2: float = global_position.distance_squared_to(n.global_position)
	var max_d2: float = acquire_range_px * acquire_range_px
	if d2 > max_d2:
		return false

	return true


func _is_target_dead_soft(t: Node) -> bool:
	# IMPORTANT: This is "soft" and must NEVER assume any particular API exists.
	# It only uses methods/properties if they exist, otherwise returns false (treat as alive).
	if t == null:
		return true
	if not is_instance_valid(t):
		return true

	var stats: Node = _find_stats_component(t)
	if stats == null:
		return false

	# Common patterns:
	# - is_dead() -> bool
	# - get_is_dead() -> bool
	# - dead (bool)
	# - current_hp / hp (float/int)
	if stats.has_method("is_dead"):
		var v_any: Variant = stats.call("is_dead")
		if v_any is bool:
			return bool(v_any)

	if stats.has_method("get_is_dead"):
		var v2_any: Variant = stats.call("get_is_dead")
		if v2_any is bool:
			return bool(v2_any)

	if stats.has_method("get_current_hp"):
		var hp_any: Variant = stats.call("get_current_hp")
		if hp_any is int:
			return int(hp_any) <= 0
		if hp_any is float:
			return float(hp_any) <= 0.0

	# Property checks (Godot 4: Object has get() / set() for properties)
	var prop_dead: Variant = stats.get("dead")
	if prop_dead is bool:
		return bool(prop_dead)

	var prop_hp: Variant = stats.get("current_hp")
	if prop_hp is int:
		return int(prop_hp) <= 0
	if prop_hp is float:
		return float(prop_hp) <= 0.0

	var prop_hp2: Variant = stats.get("hp")
	if prop_hp2 is int:
		return int(prop_hp2) <= 0
	if prop_hp2 is float:
		return float(prop_hp2) <= 0.0

	return false


func _steer_toward(current: Vector2, desired: Vector2, delta: float) -> Vector2:
	if current == Vector2.ZERO:
		return desired
	if desired == Vector2.ZERO:
		return current

	var t: float = turn_rate * delta
	if t < 0.0:
		t = 0.0
	if t > 1.0:
		t = 1.0

	var blended: Vector2 = current.lerp(desired, t)
	if blended == Vector2.ZERO:
		return desired
	return blended.normalized()


func _clamp01(v: float) -> float:
	if v < 0.0:
		return 0.0
	if v > 1.0:
		return 1.0
	return v
