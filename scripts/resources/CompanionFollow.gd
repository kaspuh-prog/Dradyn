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

# ---------- ROLE ----------
@export var healer_mode: bool = false

# ---------- Retreat / Hold overlay ----------
@export var default_retreat_distance: float = 128.0
@export var retreat_reissue_distance_threshold: float = 24.0
@export var retreat_debounce_sec: float = 0.30
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

var _status: Node = null
var _stats_like: Node = null

# Retreat/Hold overlay state
var _retreating: bool = false
var _retreat_dest: Vector2 = Vector2.ZERO
var _retreat_time_left: float = 0.0
var _retreat_last_start_msec: int = 0
var _retreat_hold: bool = false

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
# PUBLIC API
# ---------------------------------------------------------
func set_follow_target(t: Node) -> void:
	_disconnect_follow_target()
	follow_target = t
	if follow_target != null and is_instance_valid(follow_target):
		var cb := Callable(self, "_on_follow_target_freed")
		if not follow_target.is_connected("tree_exited", cb):
			follow_target.connect("tree_exited", cb)
	following = (t != null)

func set_active(on: bool) -> void:
	_active = on
	if not _active:
		_clear_target()
		_mode = Mode.FOLLOW
		_cancel_retreat()
		_release_hold()

func set_engage_enabled(on: bool) -> void:
	engage_enabled = on
	if not engage_enabled:
		_clear_target()
		_mode = Mode.FOLLOW

func set_healer_mode(on: bool) -> void:
	healer_mode = on
	if healer_mode:
		set_engage_enabled(false)

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
	return _retreating or _retreat_hold or healer_mode

func is_retreating() -> bool: return _retreating
func is_holding() -> bool: return _retreat_hold
func get_retreat_dest() -> Vector2: return _retreat_dest

func _try_start_retreat_to(dest: Vector2, duration_sec: float) -> void:
	var now: int = Time.get_ticks_msec()
	if _retreat_hold and _retreat_dest.distance_to(dest) <= retreat_reissue_distance_threshold: return
	if _retreating and _retreat_dest.distance_to(dest) <= retreat_reissue_distance_threshold: return
	var debounce_ms: int = int(maxf(0.0, retreat_debounce_sec) * 1000.0)
	if now - _retreat_last_start_msec < debounce_ms: return
	_start_retreat_to(dest, duration_sec)
	_retreat_last_start_msec = now

func _start_retreat_to(dest: Vector2, duration_sec: float) -> void:
	_retreating = true
	_retreat_hold = false
	_retreat_dest = dest
	_retreat_time_left = maxf(0.0, duration_sec)
	_clear_target()
	_mode = Mode.RETURN

func _cancel_retreat() -> void:
	_retreating = false
	_retreat_time_left = 0.0

func _release_hold() -> void:
	_retreat_hold = false

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
		var cb := Callable(self, "_on_follow_target_freed")
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

	if _has_healer_brain(_owner_body):
		healer_mode = true
	if healer_mode:
		engage_enabled = false

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
		_clear_target()
		_mode = Mode.FOLLOW
		_cancel_retreat()
		_release_hold()

func _on_party_changed(members: Array) -> void:
	_neighbors.clear()
	var i: int = 0
	while i < members.size():
		var m: Node = members[i]
		if m != null and is_instance_valid(m) and m != _owner_body:
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
# MAIN LOOP
# ---------------------------------------------------------
func _physics_process(delta: float) -> void:
	if _owner_body == null or not _active:
		return

	# sanitize neighbors (removes freed entries that slipped in between signals)
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

	# DEAD state
	if dead_now:
		_force_return_to_leader()
		if not allow_follow_while_dead:
			_owner_body.velocity = Vector2.ZERO
			_owner_body.move_and_slide()
			_drive_walk_anim(Vector2.ZERO, false)
			return

	# Retreat overlay timer
	if _retreating:
		_retreat_time_left -= delta
		if _retreat_time_left <= 0.0:
			_cancel_retreat()

	# HOLD: freeze motion; allow casting
	if _retreat_hold:
		_owner_body.velocity = Vector2.ZERO
		_owner_body.move_and_slide()
		_drive_walk_anim(Vector2.ZERO, false)
		return

	# Update ENGAGE unless retreat/hold
	var engage_now: bool = (engage_enabled and not dead_now and not healer_mode and not _retreating and not _retreat_hold)
	_update_engage_state(delta, leader_pos, engage_now)

	var have_move: bool = false
	var target_pos: Vector2 = Vector2.ZERO

	if dead_now and _controlled is Node2D:
		target_pos = leader_pos
		have_move = true
	elif _retreating:
		target_pos = _retreat_dest
		have_move = true
	elif _mode == Mode.ENGAGE and _aggro_target != null:
		target_pos = _aggro_target.global_position
		have_move = true
	elif _mode == Mode.RETURN:
		if follow_target is Node2D and is_instance_valid(follow_target):
			target_pos = (follow_target as Node2D).global_position
			have_move = true
		elif _controlled is Node2D:
			target_pos = leader_pos
			have_move = true
	elif following and follow_target is Node2D and is_instance_valid(follow_target):
		target_pos = (follow_target as Node2D).global_position
		have_move = true

	if not have_move:
		if _mode != Mode.ENGAGE:
			_drive_walk_anim(Vector2.ZERO, false)
		return

	var self_pos: Vector2 = _owner_body.global_position
	var to_target: Vector2 = target_pos - self_pos
	var dist: float = to_target.length()

	var stop_at: float = stop_distance
	if _mode == Mode.ENGAGE:
		stop_at = attack_range
	if _retreating and stop_at < retreat_arrival_radius:
		stop_at = retreat_arrival_radius

	# Arrival
	if dist <= stop_at:
		_owner_body.velocity = Vector2.ZERO
		_owner_body.move_and_slide()
		_stuck_timer = 0.0
		if _retreating:
			_cancel_retreat()
			if hold_after_retreat:
				_retreat_hold = true
				_drive_walk_anim(Vector2.ZERO, false)
				return
			else:
				_mode = Mode.RETURN
		elif _mode == Mode.RETURN and follow_target != null:
			_mode = Mode.FOLLOW
		if _mode != Mode.ENGAGE:
			_drive_walk_anim(Vector2.ZERO, false)
		return

	var base_speed: float = _get_move_speed()
	var speed: float = base_speed

	# near-band for speed scaling
	var near_band: float = resume_distance
	if _mode == Mode.ENGAGE:
		if stop_at + 8.0 > resume_distance:
			near_band = stop_at + 8.0
		else:
			near_band = resume_distance
	if _retreating and near_band < stop_at + retreat_soft_arrival_band_px:
		near_band = stop_at + retreat_soft_arrival_band_px

	if dist < near_band:
		var band: float = near_band - stop_at
		if band < 0.001:
			band = 0.001
		var t: float = clampf((dist - stop_at) / band, 0.0, 1.0)
		var scaled: float = base_speed * maxf(min_close_speed_mul, t)
		speed = scaled

	var dir: Vector2 = to_target / maxf(0.001, dist)

	# Separation: disabled during ENGAGE, retreat, hold
	var sep: Vector2 = Vector2.ZERO
	if (_mode != Mode.ENGAGE) and not _retreating and not _retreat_hold and separation_radius > 0.0 and separation_strength > 0.0 and _neighbors.size() > 0:
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

	# Leader bubble: disabled during retreat/hold
	var bubble: Vector2 = Vector2.ZERO
	if _mode != Mode.ENGAGE and not _retreating and not _retreat_hold and _controlled is Node2D:
		var to_leader: Vector2 = self_pos - leader_pos
		var d_bub: float = to_leader.length()
		if d_bub < separation_radius:
			bubble = (to_leader / maxf(0.001, d_bub)) * 80.0 * (1.0 - (d_bub / separation_radius))

	# ------------------ FIX: disable unstick during retreat/hold ------------------
	var allow_unstick: bool = (_mode != Mode.ENGAGE) and not _retreating and not _retreat_hold
	if allow_unstick and dist < stuck_radius:
		_stuck_timer += delta
		if _stuck_timer >= stuck_time_threshold:
			var away: Vector2 = self_pos - target_pos
			if away.length() < 0.01:
				away = Vector2.RIGHT
			else:
				away = away / away.length()
			_owner_body.velocity = away * unstick_push
			_owner_body.move_and_slide()
			_drive_walk_anim(Vector2.ZERO, false)
			return
	else:
		_stuck_timer = 0.0
	# -------------------------------------------------------------------------------

	_owner_body.velocity = dir * speed + sep + bubble
	_owner_body.move_and_slide()

	var moving_now: bool = (_owner_body.velocity.length() > 0.05)
	_drive_walk_anim(dir, moving_now)

# ---------------------------------------------------------
# ENGAGE state helpers
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
	_clear_target()
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

# ---------------------------------------------------------
# Utils
# ---------------------------------------------------------
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

# ---------------------------------------------------------
# Collision / Animation bridge
# ---------------------------------------------------------
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

func _drive_walk_anim(dir: Vector2, moving: bool) -> void:
	var bridge: Node = _get_bridge()
	if bridge != null and bridge.has_method("set_movement"):
		bridge.call("set_movement", dir, moving)

func _get_bridge() -> Node:
	var root: Node = get_parent()
	if root == null:
		return null
	return root.find_child("AnimationBridge", true, false)

func _has_healer_brain(root: Node) -> bool:
	if root == null:
		return false
	var by_name: Node = root.find_child("HealerBrain", true, false)
	if by_name != null:
		return true
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		var s: Script = n.get_script()
		if s != null:
			var path: String = String(s.resource_path)
			var sname: String = String(s.resource_name)
			if path.findn("HealerBrain") >= 0 or sname.findn("HealerBrain") >= 0:
				return true
		var i: int = 0
		while i < n.get_child_count():
			stack.push_back(n.get_child(i))
			i += 1
	return false
