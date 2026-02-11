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

# ---------- Follow fan-out (prevents followers stacking) ----------
@export var follow_fan_out_enabled: bool = true
@export var follow_fan_out_lateral_px: float = 20.0
@export var follow_fan_out_back_px: float = 14.0
@export var follow_fan_out_speed_threshold: float = 0.25

# ---------- Unstick ----------
@export var stuck_radius: float = 16.0
@export var stuck_time_threshold: float = 0.25
@export var unstick_push: float = 140.0

# ---------- ENGAGE (legacy auto-aggro, now secondary to CAI-driven combat) ----------
@export var engage_enabled: bool = true
@export var engage_radius: float = 120.0
@export var engage_leash_distance: float = 280.0
@export var attack_range: float = 24.0
@export var retarget_interval: float = 0.25
@export var lose_target_cooldown: float = 0.5

# ---------- ROLE (deprecated: kept for backward compatibility only) ----------
@export var healer_mode: bool = false

# ---------- Retreat / Hold overlay ----------
@export var default_retreat_distance: float = 128.0
@export var retreat_reissue_distance_threshold: float = 24.0
@export var retreat_debounce_sec: float = 2.5
@export var hold_after_retreat: bool = true
@export var retreat_arrival_radius: float = 24.0
@export var retreat_soft_arrival_band_px: float = 12.0

# ---------- Collision policy (Ally pass-through) ----------
@export var configure_collision_in_code: bool = true
const LBIT_WORLD: int = 1
const LBIT_ENEMY: int = 2
const LBIT_ALLY: int = 3

# ---------- Status ----------
@export var allow_follow_while_dead: bool = true
@export var status_path: NodePath

# ---------- Phase 3: Combat bands & leader leash ----------
@export var leader_leash_distance: float = 100.0
@export var melee_band_radius_px: float = 40.0      # if <= 0, falls back to attack_range
@export var ranged_min_distance_px: float = 80.0
@export var ranged_max_distance_px: float = 140.0

# ---------- NEW: Combat arrival + melee slot tightening ----------
# In combat, we want to actually reach the computed combat slot (not stop 24px away from it).
@export var combat_arrival_epsilon_px: float = 2.0

# Pull melee slot slightly *inside* attack_range so CAI "contact range minus padding" can pass reliably.
@export var melee_slot_inset_px: float = 2.0

# ---------- External motion (generic: conveyors, wind, currents, etc.) ----------
# Contributors provide velocities in px/s while active.
# Companions can optionally resist external motion (usually leave at 0).
@export var external_resist: float = 0.0 # 0 = no resist; 1 = fully cancel external when self-moving
@export var external_resist_dot_threshold: float = -0.15

var _external_vel_by_id: Dictionary = {} # Dictionary[StringName, Vector2]

# ---------- Debug ----------
@export var debug_companion_follow: bool = false
@export var debug_combat_bands: bool = true
@export var debug_print_interval_ms: int = 240

# ---------- Internals ----------
var _controlled: Node2D = null
var _owner_body: CharacterBody2D = null
var _active: bool = true

var follow_target: Node = null
var following: bool = true

var _neighbors: Array[CompanionFollow] = []

enum Mode { FOLLOW, ENGAGE, RETURN }
var _mode: int = Mode.FOLLOW

# Legacy ENGAGE target (auto-aggro). Phase 3 prefers _combat_target when present.
var _aggro_target: Node2D = null
var _retarget_accum: float = 0.0
var _lost_timer: float = 0.0
var _stuck_timer: float = 0.0

var _status: Node = null
var _stats_like: Node = null

# Retreat/Hold overlay state
var _retreating: bool = false
var _retreat_dest: Vector2 = Vector2.ZERO
var _retreat_time_left: float = 0.0
var _retreat_last_start_msec: int = 0
var _retreat_hold: bool = false

# Phase 3: Combat mode + target from CAI
const COMBAT_MODE_NON_COMBAT: int = 0
const COMBAT_MODE_COMBAT: int = 1
var _combat_mode: int = COMBAT_MODE_NON_COMBAT
var _combat_target: Node2D = null
var _combat_style: StringName = &"NONE" # "MELEE" or "RANGED"

# Party ordering for fan-out
var _party_index: int = -1
var _party_member_count: int = 1

# Debug throttling
var _dbg_last_msec: int = 0


# ---------------------------------------------------------
# SPEED SOURCE
# ---------------------------------------------------------
func _get_move_speed() -> float:
	if _owner_body != null and _owner_body.has_node("StatsComponent"):
		var stats: Node = _owner_body.get_node("StatsComponent")
		if stats != null:
			if stats.has_method("get_final_stat"):
				return float(stats.get_final_stat("MoveSpeed"))
			if stats.has_method("get_move_speed"):
				return float(stats.get_move_speed())
			if "move_speed" in stats:
				return float(stats.move_speed)
	if _owner_body != null and "move_speed" in _owner_body:
		return float(_owner_body.move_speed)
	return follow_speed


# ---------------------------------------------------------
# EXTERNAL MOTION API (generic)
# ---------------------------------------------------------
func set_external_velocity(id: StringName, v: Vector2) -> void:
	_external_vel_by_id[id] = v

func clear_external_velocity(id: StringName) -> void:
	if _external_vel_by_id.has(id):
		_external_vel_by_id.erase(id)

func clear_all_external_velocity() -> void:
	_external_vel_by_id.clear()

func get_external_velocity() -> Vector2:
	var sum: Vector2 = Vector2.ZERO
	for k in _external_vel_by_id.keys():
		var vv: Variant = _external_vel_by_id[k]
		if vv is Vector2:
			sum += vv
	return sum

func _compute_external_velocity(desired_self: Vector2) -> Vector2:
	var ext: Vector2 = get_external_velocity()
	if ext == Vector2.ZERO:
		return Vector2.ZERO

	if external_resist <= 0.0:
		return ext

	if desired_self.length() <= 0.01:
		return ext

	var a: Vector2 = desired_self.normalized()
	var b: Vector2 = ext.normalized()
	var d: float = a.dot(b)

	if d < external_resist_dot_threshold:
		var t: float = clamp(external_resist, 0.0, 1.0)
		return ext * (1.0 - t)

	return ext


# ---------------------------------------------------------
# PUBLIC API
# ---------------------------------------------------------
func set_follow_target(t: Node) -> void:
	_disconnect_follow_target()
	follow_target = t
	if follow_target != null and is_instance_valid(follow_target):
		var cb: Callable = Callable(self, "_on_follow_target_freed")
		if not follow_target.is_connected("tree_exited", cb):
			follow_target.connect("tree_exited", cb)
	following = (t != null)


func set_active(on: bool) -> void:
	_active = on
	if not _active:
		clear_combat_target()
		_mode = Mode.FOLLOW
		_cancel_retreat()
		_release_hold()


func set_engage_enabled(on: bool) -> void:
	engage_enabled = on
	if not engage_enabled:
		_clear_target()
		_mode = Mode.FOLLOW


# Phase 3: healer_mode no longer affects movement. Kept only so scenes don't break.
func set_healer_mode(on: bool) -> void:
	healer_mode = on


# ---- Retreat/Hold control --------------
func request_retreat(dest: Vector2, duration_sec: float) -> void:
	_try_start_retreat_to(dest, duration_sec)


func request_evade(dest: Vector2, duration_sec: float) -> void:
	_try_start_retreat_to(dest, duration_sec)


func evade_from(away_from: Node2D, duration_sec: float) -> void:
	if _owner_body == null or away_from == null or not is_instance_valid(away_from):
		return
	var dir: Vector2 = (_owner_body.global_position - away_from.global_position).normalized()
	var dist: float = default_retreat_distance
	var dest: Vector2 = _owner_body.global_position + dir * dist
	_try_start_retreat_to(dest, duration_sec)


func release_retreat_hold() -> void:
	_release_hold()


func is_movement_suppressed() -> bool:
	return _retreating or _retreat_hold


func is_retreating() -> bool:
	return _retreating


func is_holding() -> bool:
	return _retreat_hold


func get_retreat_dest() -> Vector2:
	return _retreat_dest


func _try_start_retreat_to(dest: Vector2, duration_sec: float) -> void:
	var now: int = Time.get_ticks_msec()
	if _retreat_hold and _retreat_dest.distance_to(dest) <= retreat_reissue_distance_threshold:
		return
	if _retreating and _retreat_dest.distance_to(dest) <= retreat_reissue_distance_threshold:
		return
	var debounce_ms: int = int(maxf(0.0, retreat_debounce_sec) * 1000.0)
	if now - _retreat_last_start_msec < debounce_ms:
		return
	_start_retreat_to(dest, duration_sec)
	_retreat_last_start_msec = now


func _start_retreat_to(dest: Vector2, duration_sec: float) -> void:
	_retreating = true
	_retreat_hold = false
	_retreat_dest = dest
	_retreat_time_left = maxf(0.0, duration_sec)
	clear_combat_target()
	_mode = Mode.RETURN


func _cancel_retreat() -> void:
	_retreating = false
	_retreat_time_left = 0.0


func _release_hold() -> void:
	_retreat_hold = false


# ---------------------------------------------------------
# Phase 3: Combat target API used by CAI
# ---------------------------------------------------------
func set_combat_target(enemy: Node2D, style: StringName) -> void:
	if enemy == null or not is_instance_valid(enemy):
		clear_combat_target()
		return
	_combat_target = enemy
	_combat_style = style
	_combat_mode = COMBAT_MODE_COMBAT

	if debug_companion_follow and debug_combat_bands:
		_dbg("[CF] set_combat_target enemy=" + _node_name(enemy)
			+ " style=" + String(style)
			+ " melee_band=" + _fmt(melee_band_radius_px)
			+ " stop_distance=" + _fmt(stop_distance)
			+ " attack_range=" + _fmt(attack_range)
		)


func clear_combat_target() -> void:
	_combat_target = null
	_combat_style = &"NONE"
	_combat_mode = COMBAT_MODE_NON_COMBAT
	_clear_target() # also clear legacy _aggro_target


func _has_valid_combat_target() -> bool:
	if _combat_mode != COMBAT_MODE_COMBAT:
		return false
	if _combat_target == null or not is_instance_valid(_combat_target):
		return false
	if _target_is_dead(_combat_target):
		return false
	return true


# ---------------------------------------------------------
# TARGET LIFECYCLE GUARDS
# ---------------------------------------------------------
func _on_follow_target_freed() -> void:
	_disconnect_follow_target()
	follow_target = null
	following = false
	if _mode == Mode.FOLLOW:
		_mode = Mode.RETURN


func _disconnect_follow_target() -> void:
	if follow_target != null and is_instance_valid(follow_target):
		var cb: Callable = Callable(self, "_on_follow_target_freed")
		if follow_target.is_connected("tree_exited", cb):
			follow_target.disconnect("tree_exited", cb)


func _ensure_follow_target_valid() -> void:
	if follow_target == null:
		return
	if not is_instance_valid(follow_target):
		_on_follow_target_freed()


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

	if not _owner_body.is_in_group("PartyMembers"):
		_owner_body.add_to_group("PartyMembers")

	if configure_collision_in_code and _owner_body is CollisionObject2D:
		_configure_as_ally(_owner_body)

	var pm: Node = get_tree().get_first_node_in_group("PartyManager")
	if pm != null:
		if not pm.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
			pm.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
		if not pm.is_connected("party_changed", Callable(self, "_on_party_changed")):
			pm.connect("party_changed", Callable(self, "_on_party_changed"))
		if pm.has_method("get_controlled"):
			_on_controlled_changed(pm.get_controlled())
		if pm.has_method("get_members"):
			_on_party_changed(pm.get_members())

	_status = _resolve_status_component()
	_stats_like = _find_stats_like(_owner_body)


func _exit_tree() -> void:
	_disconnect_follow_target()


# ---------------------------------------------------------
# PARTY EVENTS
# ---------------------------------------------------------
func _on_controlled_changed(current: Node) -> void:
	_controlled = current as Node2D
	_active = (_controlled != _owner_body)
	if not _active:
		clear_combat_target()
		_mode = Mode.FOLLOW
		_cancel_retreat()
		_release_hold()


func _on_party_changed(members: Array) -> void:
	_neighbors.clear()
	_party_index = -1
	_party_member_count = max(1, members.size())

	var i: int = 0
	while i < members.size():
		var m: Node = members[i]
		if m != null and is_instance_valid(m):
			if m == _owner_body:
				_party_index = i
			else:
				var cf: CompanionFollow = _find_cf(m)
				if cf != null and is_instance_valid(cf) and cf._owner_body != null and is_instance_valid(cf._owner_body):
					_neighbors.append(cf)
		i += 1


func _find_cf(root: Node) -> CompanionFollow:
	if root == null or not is_instance_valid(root):
		return null
	if root is CompanionFollow:
		return root as CompanionFollow
	var by_name: Node = root.find_child("CompanionFollow", true, false)
	if by_name != null and is_instance_valid(by_name) and by_name is CompanionFollow:
		return by_name as CompanionFollow
	var i: int = 0
	while i < root.get_child_count():
		var ch: Node = root.get_child(i)
		if ch != null and is_instance_valid(ch) and ch.has_method("set_follow_target"):
			return ch as CompanionFollow
		i += 1
	return null


# ---------------------------------------------------------
# FOLLOW FAN-OUT OFFSET (NEW)
# ---------------------------------------------------------
func _compute_follow_fan_out_offset(target: Node2D) -> Vector2:
	if not follow_fan_out_enabled:
		return Vector2.ZERO
	if target == null or not is_instance_valid(target):
		return Vector2.ZERO

	# Gather neighbors that share this exact follow target.
	var shared: Array[CompanionFollow] = []
	var i: int = 0
	while i < _neighbors.size():
		var cf: CompanionFollow = _neighbors[i]
		if cf != null and is_instance_valid(cf):
			if cf.follow_target == target:
				shared.append(cf)
		i += 1

	# Always include self, because we are computing OUR offset for this target.
	shared.append(self)

	# Need at least 2 to fan out.
	if shared.size() < 2:
		return Vector2.ZERO

	# Determine a stable "rank" among the shared followers.
	# Prefer party index ordering when available; fallback to node name.
	var my_party_index: int = _party_index
	var rank: int = 0

	var k: int = 0
	while k < shared.size():
		var other: CompanionFollow = shared[k]
		if other == null or not is_instance_valid(other):
			k += 1
			continue
		if other == self:
			k += 1
			continue

		var other_idx: int = other._party_index
		if my_party_index >= 0 and other_idx >= 0:
			if other_idx < my_party_index:
				rank += 1
		else:
			if other.name < self.name:
				rank += 1
		k += 1

	var count: int = shared.size()
	var center: float = (float(count) - 1.0) * 0.5
	var lateral_slot: float = float(rank) - center

	# Determine target forward direction from its velocity if possible.
	var forward: Vector2 = Vector2.DOWN
	if target is CharacterBody2D:
		var tb: CharacterBody2D = target as CharacterBody2D
		if tb.velocity.length() > follow_fan_out_speed_threshold:
			forward = tb.velocity.normalized()

	var lateral: Vector2 = Vector2(-forward.y, forward.x)

	# Lateral spread + slight backward "V" shape.
	var back_mag: float = absf(lateral_slot) * follow_fan_out_back_px
	var back: Vector2 = -forward * back_mag
	var side: Vector2 = lateral * (lateral_slot * follow_fan_out_lateral_px)

	return side + back


# ---------------------------------------------------------
# MAIN LOOP
# ---------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _owner_body == null or not _active:
		return

	# sanitize neighbors
	var j: int = _neighbors.size() - 1
	while j >= 0:
		var cf: CompanionFollow = _neighbors[j]
		if cf == null or not is_instance_valid(cf) or cf._owner_body == null or not is_instance_valid(cf._owner_body):
			_neighbors.remove_at(j)
		j -= 1

	_ensure_follow_target_valid()

	var dead_now: bool = _is_dead()

	var leader_pos: Vector2 = Vector2.ZERO
	if _controlled is Node2D:
		leader_pos = (_controlled as Node2D).global_position

	# Phase 3: leader leash – break combat if too far from leader (unless retreat/hold)
	if not _retreating and not _retreat_hold and _controlled is Node2D and leader_leash_distance > 0.0:
		var dist_to_leader: float = (_owner_body.global_position - leader_pos).length()
		if dist_to_leader > leader_leash_distance:
			if debug_companion_follow and debug_combat_bands:
				_dbg("[CF] leader leash break dist=" + _fmt(dist_to_leader) + " leash=" + _fmt(leader_leash_distance))
			clear_combat_target()
			_force_return_to_leader()

	# If combat target died or became invalid, drop back to NonCombat.
	if _combat_mode == COMBAT_MODE_COMBAT and not _has_valid_combat_target():
		clear_combat_target()

	# DEAD state
	if dead_now:
		_force_return_to_leader()
		if not allow_follow_while_dead:
			var ext_dead: Vector2 = _compute_external_velocity(Vector2.ZERO)
			_owner_body.velocity = ext_dead
			_owner_body.move_and_slide()
			_drive_walk_anim(Vector2.ZERO, false)
			return

	# Retreat overlay timer
	if _retreating:
		_retreat_time_left -= delta
		if _retreat_time_left <= 0.0:
			_cancel_retreat()

	# HOLD: freeze self-motion; allow external motion (conveyor/wind) to move us.
	if _retreat_hold:
		var ext_hold: Vector2 = _compute_external_velocity(Vector2.ZERO)
		_owner_body.velocity = ext_hold
		_owner_body.move_and_slide()
		_drive_walk_anim(Vector2.ZERO, false)
		return

	var engage_now: bool = (engage_enabled and not dead_now and not _retreating and not _retreat_hold)
	if engage_now and not _has_valid_combat_target():
		_update_engage_state(delta, leader_pos, true)
	else:
		if _has_valid_combat_target():
			_mode = Mode.ENGAGE
		else:
			if _mode == Mode.ENGAGE:
				_mode = Mode.FOLLOW

	var have_move: bool = false
	var target_pos: Vector2 = Vector2.ZERO

	if dead_now and _controlled is Node2D:
		var ld0: Node2D = _controlled as Node2D
		target_pos = ld0.global_position + _compute_follow_fan_out_offset(ld0)
		have_move = true
	elif _retreating:
		target_pos = _retreat_dest
		have_move = true
	elif _has_valid_combat_target():
		target_pos = _compute_combat_position(leader_pos)
		have_move = true
	elif _mode == Mode.ENGAGE and _aggro_target != null:
		target_pos = _aggro_target.global_position
		have_move = true
	elif _mode == Mode.RETURN:
		if follow_target is Node2D and is_instance_valid(follow_target):
			var ft0: Node2D = follow_target as Node2D
			target_pos = ft0.global_position + _compute_follow_fan_out_offset(ft0)
			have_move = true
		elif _controlled is Node2D:
			var ld1: Node2D = _controlled as Node2D
			target_pos = ld1.global_position + _compute_follow_fan_out_offset(ld1)
			have_move = true
	elif following and follow_target is Node2D and is_instance_valid(follow_target):
		var ft1: Node2D = follow_target as Node2D
		target_pos = ft1.global_position + _compute_follow_fan_out_offset(ft1)
		have_move = true

	if not have_move:
		if _mode != Mode.ENGAGE:
			var ext_idle: Vector2 = _compute_external_velocity(Vector2.ZERO)
			_owner_body.velocity = ext_idle
			_owner_body.move_and_slide()
			_drive_walk_anim(Vector2.ZERO, false)
		return

	var self_pos: Vector2 = _owner_body.global_position
	var to_target: Vector2 = target_pos - self_pos
	var dist: float = to_target.length()

	# Stop distance policy:
	# - FOLLOW: stop_distance
	# - ENGAGE legacy: attack_range
	# - COMBAT target: a small epsilon so we actually reach the combat slot (and satisfy CAI melee gate)
	var stop_at: float = stop_distance
	if _has_valid_combat_target():
		stop_at = maxf(0.5, combat_arrival_epsilon_px)
	elif _mode == Mode.ENGAGE and _aggro_target != null:
		stop_at = attack_range
	if _retreating and stop_at < retreat_arrival_radius:
		stop_at = retreat_arrival_radius

	if debug_companion_follow and debug_combat_bands and _has_valid_combat_target():
		var d_enemy: float = (_owner_body.global_position - _combat_target.global_position).length()
		var band: float = melee_band_radius_px
		if band <= 0.0:
			band = attack_range
		_dbg("[CF][COMBAT] style=" + String(_combat_style)
			+ " d_to_target_pos=" + _fmt(dist)
			+ " stop_at=" + _fmt(stop_at)
			+ " d_to_enemy=" + _fmt(d_enemy)
			+ " melee_band=" + _fmt(band)
			+ " target_pos=" + _fmt_vec(target_pos)
		)

	# Arrival
	if dist <= stop_at:
		var ext_stop: Vector2 = _compute_external_velocity(Vector2.ZERO)
		_owner_body.velocity = ext_stop
		_owner_body.move_and_slide()
		_stuck_timer = 0.0

		var facing_dir_at_stop: Vector2 = _get_facing_dir(self_pos, Vector2.ZERO)

		if debug_companion_follow and debug_combat_bands and _has_valid_combat_target():
			var d_enemy2: float = (_owner_body.global_position - _combat_target.global_position).length()
			_dbg("[CF][ARRIVE] stop_at=" + _fmt(stop_at) + " d_to_enemy_now=" + _fmt(d_enemy2))

		if _retreating:
			_cancel_retreat()
			if hold_after_retreat:
				_retreat_hold = true
				_drive_walk_anim(facing_dir_at_stop, false)
				return
			else:
				_mode = Mode.RETURN
		elif _mode == Mode.RETURN and follow_target != null:
			_mode = Mode.FOLLOW

		_drive_walk_anim(facing_dir_at_stop, false)
		return

	var base_speed: float = _get_move_speed()
	var speed: float = base_speed

	var near_band: float = resume_distance
	if _mode == Mode.ENGAGE or _has_valid_combat_target():
		if stop_at + 8.0 > resume_distance:
			near_band = stop_at + 8.0
		else:
			near_band = resume_distance
	if _retreating and near_band < stop_at + retreat_soft_arrival_band_px:
		near_band = stop_at + retreat_soft_arrival_band_px

	if dist < near_band:
		var band2: float = near_band - stop_at
		if band2 < 0.001:
			band2 = 0.001
		var t: float = clampf((dist - stop_at) / band2, 0.0, 1.0)
		var scaled: float = base_speed * maxf(min_close_speed_mul, t)
		speed = scaled

	var dir: Vector2 = to_target / maxf(0.001, dist)

	var sep: Vector2 = Vector2.ZERO
	if not _retreating and not _retreat_hold and separation_radius > 0.0 and separation_strength > 0.0 and _neighbors.size() > 0:
		var r: float = separation_radius
		var r2: float = r * r
		var k: int = 0
		while k < _neighbors.size():
			var other_cf: CompanionFollow = _neighbors[k]
			if other_cf != null and is_instance_valid(other_cf) and other_cf._owner_body != null and is_instance_valid(other_cf._owner_body):
				if other_cf.follow_target != _owner_body:
					var op: Vector2 = other_cf._owner_body.global_position
					var dvec: Vector2 = self_pos - op
					var d2: float = dvec.length_squared()
					if d2 > 1.0 and d2 < r2:
						var d: float = sqrt(d2)
						var factor: float = 1.0 - (d / r)
						var nrm: Vector2 = dvec / maxf(0.001, d)
						sep += nrm * (separation_strength * factor)
			k += 1
		sep *= delta
		if sep.length() > base_speed * 0.8:
			sep = sep.normalized() * (base_speed * 0.8)

	var bubble: Vector2 = Vector2.ZERO
	if not _retreating and not _retreat_hold and _controlled is Node2D:
		var to_leader: Vector2 = self_pos - leader_pos
		var d_bub: float = to_leader.length()
		if d_bub < separation_radius:
			bubble = (to_leader / maxf(0.001, d_bub)) * 80.0 * (1.0 - (d_bub / separation_radius))

	var allow_unstick: bool = not _retreating and not _retreat_hold
	if allow_unstick and dist < stuck_radius:
		_stuck_timer += delta
		if _stuck_timer >= stuck_time_threshold:
			var away: Vector2 = self_pos - target_pos
			if away.length() < 0.01:
				away = Vector2.RIGHT
			else:
				away = away / away.length()
			var desired_unstick: Vector2 = away * unstick_push
			var ext_unstick: Vector2 = _compute_external_velocity(desired_unstick)
			_owner_body.velocity = desired_unstick + ext_unstick
			_owner_body.move_and_slide()
			_drive_walk_anim(Vector2.ZERO, false)
			return
	else:
		_stuck_timer = 0.0

	var desired_self: Vector2 = dir * speed + sep + bubble
	var ext: Vector2 = _compute_external_velocity(desired_self)

	_owner_body.velocity = desired_self + ext
	_owner_body.move_and_slide()

	var moving_now: bool = (_owner_body.velocity.length() > 0.05)
	var facing_dir: Vector2 = _get_facing_dir(self_pos, dir)
	_drive_walk_anim(facing_dir, moving_now)


# ---------------------------------------------------------
# Phase 3: Combat position helpers
# ---------------------------------------------------------
func _compute_combat_position(leader_pos: Vector2) -> Vector2:
	if not _has_valid_combat_target():
		return _owner_body.global_position
	var enemy_pos: Vector2 = _combat_target.global_position

	if _combat_style == StringName("MELEE"):
		return _compute_melee_slot_position(enemy_pos)
	elif _combat_style == StringName("RANGED"):
		return _compute_ranged_band_position(enemy_pos, leader_pos)
	else:
		return enemy_pos


func _compute_melee_slot_position(enemy_pos: Vector2) -> Vector2:
	var radius: float = melee_band_radius_px
	if radius <= 0.0:
		radius = attack_range
	if radius <= 0.0:
		radius = 32.0

	# Tighten melee slot so we don't "hover" outside CAI's melee-contact gate.
	# If melee_band_radius is larger than (attack_range - inset), clamp it down.
	var inset: float = melee_slot_inset_px
	if inset < 0.0:
		inset = 0.0

	var desired: float = attack_range
	if desired <= 0.0:
		desired = radius

	desired = desired - inset
	if desired < 8.0:
		desired = 8.0

	if radius > desired:
		radius = desired

	var angle: float = 0.0
	var count: int = max(1, _party_member_count)

	if _party_index >= 0:
		angle = TAU * float(_party_index) / float(count)
	else:
		var from_enemy: Vector2 = _owner_body.global_position - enemy_pos
		if _controlled is Node2D:
			from_enemy = (_controlled as Node2D).global_position - enemy_pos
		if from_enemy.length() > 0.001:
			angle = from_enemy.angle()
		else:
			angle = 0.0

	if debug_companion_follow and debug_combat_bands:
		_dbg("[CF][MELEE_SLOT] radius=" + _fmt(radius) + " angle=" + _fmt(angle) + " party_idx=" + str(_party_index) + "/" + str(count))

	return enemy_pos + Vector2(cos(angle), sin(angle)) * radius


func _compute_ranged_band_position(enemy_pos: Vector2, leader_pos: Vector2) -> Vector2:
	var min_d: float = max(8.0, ranged_min_distance_px)
	var max_d: float = max(min_d + 4.0, ranged_max_distance_px)
	var desired_dist: float = (min_d + max_d) * 0.5

	var base_dir: Vector2 = leader_pos - enemy_pos
	if base_dir.length() < 0.001:
		base_dir = _owner_body.global_position - enemy_pos
	if base_dir.length() < 0.001:
		base_dir = Vector2.LEFT
	base_dir = base_dir.normalized()

	var base_angle: float = base_dir.angle()

	var offset: float = 0.0
	if _party_index > 0:
		var idx: float = float(_party_index)
		var side: float = 1.0
		if int(idx) % 2 != 0:
			side = -1.0
		var step: float = ceil(idx * 0.5) * 0.35
		offset = side * step

	var dir: Vector2 = Vector2.from_angle(base_angle + offset).normalized()
	return enemy_pos + dir * desired_dist


# ---------------------------------------------------------
# ENGAGE state helpers (legacy auto-aggro)
# ---------------------------------------------------------
func _update_engage_state(delta: float, leader_pos: Vector2, engage_now: bool) -> void:
	if _is_dead():
		_force_return_to_leader()
		return

	if not engage_now:
		_clear_target()
		if _mode != Mode.RETURN:
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

func _force_return_to_leader() -> void:
	clear_combat_target()
	_retarget_accum = 0.0
	_lost_timer = 0.0
	_mode = Mode.RETURN
	if _controlled != null:
		set_follow_target(_controlled)
	_cancel_retreat()
	_release_hold()

func _find_nearest_enemy_in_radius(radius: float) -> Node2D:
	var best: Node2D = null
	var best_d2: float = radius * radius
	var self_pos: Vector2 = _owner_body.global_position
	var list: Array = get_tree().get_nodes_in_group("Enemies")
	var i: int = 0
	while i < list.size():
		var e: Node = list[i]
		if e is Node2D and is_instance_valid(e) and not _target_is_dead(e):
			var p: Vector2 = (e as Node2D).global_position
			var d2: float = (p - self_pos).length_squared()
			if d2 <= best_d2:
				best_d2 = d2
				best = e as Node2D
		i += 1
	return best

func _target_is_dead(n: Node) -> bool:
	if n == null or not is_instance_valid(n):
		return true
	if n.has_method("is_dead"):
		var v: Variant = n.call("is_dead")
		if typeof(v) == TYPE_BOOL and bool(v):
			return true
	var sc: Node = n.find_child("StatusConditions", true, false)
	if sc != null and sc.has_method("is_dead"):
		return bool(sc.call("is_dead"))
	var stats: Node = n.find_child("StatsComponent", true, false)
	if stats != null and stats.has_method("current_hp"):
		var ch: Variant = stats.call("current_hp")
		if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
			return true
	if stats != null and stats.has_method("get_hp"):
		var gh: Variant = stats.call("get_hp")
		if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
			return true
	if "dead" in n:
		var flag: Variant = n.get("dead")
		if typeof(flag) == TYPE_BOOL and bool(flag):
			return true
	return false

func _clear_target() -> void:
	_aggro_target = null
	_lost_timer = 0.0
	_retarget_accum = 0.0

func _resolve_status_component() -> Node:
	if status_path != NodePath():
		var n: Node = get_node_or_null(status_path)
		if n != null:
			return n
	var root: Node = get_parent()
	if root != null:
		var sc: Node = root.find_child("StatusConditions", true, false)
		if sc != null:
			return sc
	return null

func _find_stats_like(root: Node) -> Node:
	if root == null:
		return null
	var by_name: Node = root.find_child("StatsComponent", true, false)
	if by_name != null:
		return by_name
	if root.has_signal("hp_changed"):
		return root
	var i: int = 0
	while i < root.get_child_count():
		var ch: Node = root.get_child(i)
		var s: Node = _find_stats_like(ch)
		if s != null:
			return s
		i += 1
	return null

func _is_dead() -> bool:
	if _owner_body != null and _owner_body.has_method("is_dead"):
		var dv: Variant = _owner_body.call("is_dead")
		if typeof(dv) == TYPE_BOOL and bool(dv):
			return true
	if _owner_body != null and "dead" in _owner_body:
		var df: Variant = _owner_body.get("dead")
		if typeof(df) == TYPE_BOOL and bool(df):
			return true
	if _status != null and _status.has_method("is_dead"):
		var sv: Variant = _status.call("is_dead")
		if typeof(sv) == TYPE_BOOL and bool(sv):
			return true
	if _stats_like != null:
		if _stats_like.has_method("get_hp"):
			var gh: Variant = _stats_like.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true
		if _stats_like.has_method("current_hp"):
			var ch: Variant = _stats_like.call("current_hp")
			if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
				return true
	return false

func _configure_as_ally(body: CollisionObject2D) -> void:
	var i: int = 1
	while i <= 32:
		body.set_collision_layer_value(i, false)
		body.set_collision_mask_value(i, false)
		i += 1
	body.set_collision_layer_value(LBIT_ALLY, true)
	body.set_collision_mask_value(LBIT_WORLD, true)
	body.set_collision_mask_value(LBIT_ENEMY, false)
	body.set_collision_mask_value(LBIT_ALLY, false)

func has_variable(name: StringName) -> bool:
	var plist: Array = get_property_list()
	var i: int = 0
	while i < plist.size():
		var p: Dictionary = plist[i]
		if p.has("name") and StringName(p["name"]) == name:
			return true
		i += 1
	return false

func get_variable(name: StringName) -> Variant:
	if has_variable(name):
		return get(String(name))
	return null

func set_variable(name: StringName, value: Variant) -> void:
	if has_variable(name):
		set(String(name), value)

func _get_facing_dir(self_pos: Vector2, move_dir: Vector2) -> Vector2:
	var dir: Vector2 = move_dir
	if dir.length() > 0.01:
		return dir.normalized()

	if _has_valid_combat_target():
		var to_enemy: Vector2 = _combat_target.global_position - self_pos
		if to_enemy.length() > 0.01:
			return to_enemy.normalized()
	elif _mode == Mode.ENGAGE and _aggro_target != null and is_instance_valid(_aggro_target):
		var to_aggro: Vector2 = _aggro_target.global_position - self_pos
		if to_aggro.length() > 0.01:
			return to_aggro.normalized()

	return Vector2.DOWN

func _drive_walk_anim(dir: Vector2, moving: bool) -> void:
	var bridge: Node = _get_bridge()
	if bridge != null and bridge.has_method("set_movement"):
		bridge.call("set_movement", dir, moving)

func _get_bridge() -> Node:
	var root: Node = get_parent()
	if root == null:
		return null
	return root.find_child("AnimationBridge", true, false)

# ---------------- Debug helpers ----------------
func _dbg(msg: String) -> void:
	var now: int = Time.get_ticks_msec()
	if debug_print_interval_ms > 0:
		if now - _dbg_last_msec < debug_print_interval_ms:
			return
	_dbg_last_msec = now
	var who: String = "null"
	if _owner_body != null and is_instance_valid(_owner_body):
		who = _owner_body.name
	print_rich(msg + " user=" + who)

func _node_name(n: Node) -> String:
	if n == null:
		return "null"
	if not is_instance_valid(n):
		return "freed"
	return n.name

func _fmt(v: float) -> String:
	return String.num(v, 2)

func _fmt_vec(v: Vector2) -> String:
	return "(" + String.num(v.x, 1) + "," + String.num(v.y, 1) + ")"
