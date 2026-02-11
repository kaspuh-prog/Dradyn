extends CharacterBody2D
class_name SummonedAI
# Godot 4.5 — fully typed, no ternaries.

enum PetMode {
	AGGRESSIVE = 0,
	DEFENSIVE = 1,
	PASSIVE = 2,
	SUPPORT = 3
}

# ----------------------------
# Collision policy (match PartyManager companion treatment)
# ----------------------------
@export var configure_collision_in_code: bool = true
const LBIT_WORLD: int = 1
const LBIT_ENEMY: int = 2
const LBIT_ALLY: int = 3

# ----------------------------
# Navigation (optional locomotion)
# ----------------------------
@export var use_navigation_agent: bool = true
@export var nav_repath_interval_sec: float = 0.15
@export var nav_goal_update_dist_px: float = 10.0
@export var nav_min_next_point_dist_px: float = 1.0

# These help “corner snagging” by letting the agent advance waypoints sooner.
@export var nav_path_desired_distance_px: float = 16.0
@export var nav_target_desired_distance_px: float = 10.0
@export var nav_path_max_distance_px: float = 80.0

# ----------------------------
# Tuning (AI-owned)
# ----------------------------
@export var leash_distance_px: float = 220.0
@export var follow_stop_distance_px: float = 22.0
@export var follow_resume_distance_px: float = 34.0

@export var aggro_radius_px: float = 140.0
@export var defend_radius_px: float = 25.0

@export var attack_range_px: float = 26.0
@export var think_interval_sec: float = 0.12

# Defensive “recent attacker” memory.
@export var retaliate_memory_sec: float = 3.0

@export var debug_logs: bool = false

# ----------------------------
# Runtime state
# ----------------------------
var mode: int = PetMode.AGGRESSIVE

var summoner: Node2D = null
var current_target: Node2D = null

var _stats: Node = null
var _status: Node = null
var _bridge: Node = null
var _sprite: AnimatedSprite2D = null

var _ability_sys: Node = null

var _follow_should_move: bool = true
var _next_think_time_sec: float = 0.0

# Remember last facing so idle stays consistent.
var _last_facing_dir: Vector2 = Vector2.DOWN

# attacker -> last_seen_time
var _recent_attackers: Dictionary = {}

# Navigation agent state
var _nav_agent: NavigationAgent2D = null
var _last_nav_goal: Vector2 = Vector2.ZERO
var _has_last_nav_goal: bool = false
var _next_nav_repath_time_sec: float = 0.0

# Death latch (prevents walk/idle from overriding death anim)
var _dead_latched: bool = false
var _death_anim_started: bool = false

# ----------------------------
# Lifecycle
# ----------------------------
func _ready() -> void:
	_stats = get_node_or_null("StatsComponent")
	_status = get_node_or_null("StatusConditions")
	_bridge = get_node_or_null("AnimationBridge")
	_sprite = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D

	_nav_agent = get_node_or_null("NavAgent") as NavigationAgent2D
	if _nav_agent == null:
		_nav_agent = get_node_or_null("NavigationAgent2D") as NavigationAgent2D

	if _nav_agent != null and is_instance_valid(_nav_agent):
		_nav_agent.path_desired_distance = nav_path_desired_distance_px
		_nav_agent.target_desired_distance = nav_target_desired_distance_px
		_nav_agent.path_max_distance = nav_path_max_distance_px

	# Apply ally collision policy so the summon doesn't body-block the player/party.
	if configure_collision_in_code:
		_configure_as_ally_collision(self)

	# Make enemies consider the summon a valid target + allow threat generation.
	if not is_in_group("PartyMembers"):
		add_to_group("PartyMembers")

	_ability_sys = get_node_or_null("/root/AbilitySys")

	mode = _clamp_mode(mode)

	_next_think_time_sec = 0.0

	# If the pet spawns already dead, latch + play death.
	if _is_dead():
		_enter_dead_state()
	else:
		_update_anim(_last_facing_dir, false)

func _physics_process(delta: float) -> void:
	var dead_now: bool = _is_dead()

	if dead_now:
		if not _dead_latched:
			_enter_dead_state()

		velocity = Vector2.ZERO
		_push_velocity_to_nav_agent()
		move_and_slide()
		return
	else:
		# If anything revives it, resume normal animation driving.
		if _dead_latched:
			_exit_dead_state()

	var now: float = Time.get_ticks_msec() / 1000.0
	if now >= _next_think_time_sec:
		_next_think_time_sec = now + think_interval_sec
		_think(now)

	_move_step(delta)

# ----------------------------
# Death handling
# ----------------------------
func _enter_dead_state() -> void:
	_dead_latched = true
	_death_anim_started = false

	current_target = null
	_recent_attackers.clear()

	_has_last_nav_goal = false

	# Stop any locomotion immediately.
	velocity = Vector2.ZERO
	_push_velocity_to_nav_agent()

	_play_death_animation()

func _exit_dead_state() -> void:
	_dead_latched = false
	_death_anim_started = false

	# Resume consistent idle immediately.
	_update_anim(_last_facing_dir, false)

func _play_death_animation() -> void:
	if _death_anim_started:
		return
	_death_anim_started = true

	# Prefer AnimationBridge if present (it expects an anim named "death").
	if _bridge != null and is_instance_valid(_bridge):
		if _bridge.has_method("play_death"):
			_bridge.call("play_death")
			return

	# Fallback: play "death" directly on AnimatedSprite2D if it exists.
	if _sprite == null or not is_instance_valid(_sprite):
		return
	if _sprite.sprite_frames == null:
		return
	if _sprite.sprite_frames.has_animation("death"):
		if _sprite.animation != "death":
			_sprite.play("death")

# ----------------------------
# Public API
# ----------------------------
func set_summoner(p_summoner: Node2D) -> void:
	if summoner == p_summoner:
		return

	_disconnect_summoner_signals()

	summoner = p_summoner
	_recent_attackers.clear()

	_has_last_nav_goal = false

	_connect_summoner_signals()

func set_pet_mode(p_mode: int) -> void:
	mode = _clamp_mode(p_mode)
	if debug_logs:
		print("[SummonedAI] set_pet_mode=", mode, " pet=", name)

func on_owner_pet_mode_changed(p_mode: int) -> void:
	set_pet_mode(p_mode)

func get_pet_mode() -> int:
	return mode

func clear_target() -> void:
	current_target = null

# ----------------------------
# Think / Decide
# ----------------------------
func _think(now: float) -> void:
	_cleanup_recent_attackers(now)

	if summoner == null or not is_instance_valid(summoner):
		current_target = null
		return

	# Leash check: if too far, always return to summoner.
	var dist_to_owner: float = global_position.distance_to(summoner.global_position)
	if dist_to_owner > leash_distance_px:
		current_target = null
		_follow_should_move = true
		return

	if mode == PetMode.PASSIVE:
		current_target = null
		return

	if mode == PetMode.SUPPORT:
		current_target = null
		return

	if mode == PetMode.AGGRESSIVE:
		current_target = _pick_enemy_in_radius(global_position, aggro_radius_px)
		return

	if mode == PetMode.DEFENSIVE:
		var threat: Node2D = _pick_enemy_in_radius(summoner.global_position, defend_radius_px)
		if threat != null:
			current_target = threat
			return

		var retaliate: Node2D = _pick_recent_attacker(now)
		if retaliate != null:
			current_target = retaliate
			return

		current_target = null
		return

# ----------------------------
# Movement / Combat step
# ----------------------------
func _move_step(_delta: float) -> void:
	var desired_dir: Vector2 = Vector2.ZERO
	var moving: bool = false

	if summoner == null or not is_instance_valid(summoner):
		velocity = Vector2.ZERO
		_push_velocity_to_nav_agent()
		move_and_slide()
		_update_anim(_last_facing_dir, false)
		return

	var now: float = Time.get_ticks_msec() / 1000.0

	# If we have a target, chase/attack.
	if current_target != null and is_instance_valid(current_target):
		var to_tgt: Vector2 = current_target.global_position - global_position
		var d: float = to_tgt.length()

		if to_tgt.length() > 0.001:
			_last_facing_dir = to_tgt.normalized()

		if d <= attack_range_px:
			velocity = Vector2.ZERO
			_push_velocity_to_nav_agent()
			move_and_slide()
			_update_anim(_last_facing_dir, false)
			_try_basic_attack(current_target, to_tgt)
			return

		desired_dir = _nav_dir_to(current_target.global_position, now)
		if desired_dir.length() > 0.001:
			moving = true

	# Otherwise follow summoner.
	if not moving:
		var to_owner: Vector2 = summoner.global_position - global_position
		var dist: float = to_owner.length()

		if to_owner.length() > 0.001:
			_last_facing_dir = to_owner.normalized()

		if _follow_should_move:
			if dist <= follow_stop_distance_px:
				_follow_should_move = false
		else:
			if dist >= follow_resume_distance_px:
				_follow_should_move = true

		if _follow_should_move:
			desired_dir = _nav_dir_to(summoner.global_position, now)
			if desired_dir.length() > 0.001:
				moving = true

	var speed: float = _get_move_speed()
	if moving:
		velocity = desired_dir * speed
	else:
		velocity = Vector2.ZERO

	_push_velocity_to_nav_agent()
	move_and_slide()
	_update_anim(_last_facing_dir, moving)

func _push_velocity_to_nav_agent() -> void:
	# Keeping the agent updated with current velocity helps its internal logic,
	# and is required for avoidance workflows. :contentReference[oaicite:1]{index=1}
	if _nav_agent == null:
		return
	if not is_instance_valid(_nav_agent):
		return
	_nav_agent.velocity = velocity

func _nav_dir_to(goal_pos: Vector2, now: float) -> Vector2:
	var direct: Vector2 = goal_pos - global_position
	if direct.length() <= 0.001:
		return Vector2.ZERO

	if not use_navigation_agent:
		return direct.normalized()

	if _nav_agent == null or not is_instance_valid(_nav_agent):
		return direct.normalized()

	var need_set: bool = false
	if not _has_last_nav_goal:
		need_set = true
	else:
		var d2: float = _last_nav_goal.distance_squared_to(goal_pos)
		var thresh: float = nav_goal_update_dist_px * nav_goal_update_dist_px
		if d2 >= thresh:
			need_set = true

	if now >= _next_nav_repath_time_sec:
		need_set = true

	if need_set:
		_nav_agent.target_position = goal_pos
		_last_nav_goal = goal_pos
		_has_last_nav_goal = true
		_next_nav_repath_time_sec = now + nav_repath_interval_sec

	# IMPORTANT: Do NOT fall back to direct steering if the agent has no path yet.
	# When the path is empty, get_next_path_position() returns the parent position. :contentReference[oaicite:2]{index=2}
	var next_pos: Vector2 = _nav_agent.get_next_path_position()
	var to_next: Vector2 = next_pos - global_position

	if to_next.length() <= nav_min_next_point_dist_px:
		if debug_logs:
			var pl: float = _nav_agent.get_path_length()
			var reach: bool = _nav_agent.is_target_reachable()
			var fin: bool = _nav_agent.is_navigation_finished()
			print("[SummonedAI] nav stalled pl=", pl, " reachable=", reach, " finished=", fin, " goal=", goal_pos, " next=", next_pos)
		# Pause briefly while path is syncing/calculating instead of ramming walls.
		return Vector2.ZERO

	return to_next.normalized()

# ----------------------------
# Attack (basic)
# ----------------------------
func _try_basic_attack(target: Node2D, aim_vec: Vector2) -> void:
	if mode == PetMode.PASSIVE:
		return
	if mode == PetMode.SUPPORT:
		return

	if _ability_sys == null or not is_instance_valid(_ability_sys):
		if debug_logs:
			print("[SummonedAI] no AbilitySys for pet=", name)
		return
	if not _ability_sys.has_method("request_cast"):
		if debug_logs:
			print("[SummonedAI] AbilitySys missing request_cast for pet=", name)
		return

	var aim_dir: Vector2 = _last_facing_dir
	if aim_vec.length() > 0.001:
		aim_dir = aim_vec.normalized()

	var ctx: Dictionary = {
		"target": target,
		"aim_dir": aim_dir
	}

	if debug_logs:
		print("[SummonedAI] request_cast attack pet=", name, " target=", target.name)

	_ability_sys.call("request_cast", self, "attack", ctx)

# ----------------------------
# Targeting helpers
# ----------------------------
func _pick_enemy_in_radius(center: Vector2, radius_px: float) -> Node2D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null

	var best: Node2D = null
	var best_d2: float = 0.0

	var groups: PackedStringArray = PackedStringArray(["Enemies", "Enemy"])
	var gi: int = 0
	while gi < groups.size():
		var arr: Array = tree.get_nodes_in_group(groups[gi])
		var i: int = 0
		while i < arr.size():
			var n_any: Variant = arr[i]
			i += 1

			if n_any == null:
				continue
			if not (n_any is Node2D):
				continue
			var n: Node2D = n_any as Node2D
			if n == null:
				continue
			if not is_instance_valid(n):
				continue
			if n.is_queued_for_deletion():
				continue
			if _is_node_dead(n):
				continue

			var d2: float = center.distance_squared_to(n.global_position)
			if d2 > radius_px * radius_px:
				continue

			if best == null:
				best = n
				best_d2 = d2
			else:
				if d2 < best_d2:
					best = n
					best_d2 = d2

		gi += 1

	return best

# ----------------------------
# Defensive retaliation memory (summoner damaged)
# ----------------------------
func _connect_summoner_signals() -> void:
	if summoner == null:
		return
	if not is_instance_valid(summoner):
		return

	var s_stats: Node = null
	if summoner.has_method("get_stats"):
		var v: Variant = summoner.call("get_stats")
		if v is Node:
			s_stats = v as Node
	if s_stats == null and summoner.has_node("StatsComponent"):
		s_stats = summoner.get_node("StatsComponent")

	if s_stats == null:
		return

	if s_stats.has_signal("damage_threat"):
		var c: Callable = Callable(self, "_on_summoner_damage_threat")
		if not s_stats.is_connected("damage_threat", c):
			s_stats.connect("damage_threat", c)

func _disconnect_summoner_signals() -> void:
	if summoner == null:
		return
	if not is_instance_valid(summoner):
		return

	var s_stats: Node = null
	if summoner.has_method("get_stats"):
		var v: Variant = summoner.call("get_stats")
		if v is Node:
			s_stats = v as Node
	if s_stats == null and summoner.has_node("StatsComponent"):
		s_stats = summoner.get_node("StatsComponent")

	if s_stats == null:
		return

	var c: Callable = Callable(self, "_on_summoner_damage_threat")
	if s_stats.has_signal("damage_threat"):
		if s_stats.is_connected("damage_threat", c):
			s_stats.disconnect("damage_threat", c)

func _on_summoner_damage_threat(
	amount: float,
	_dmg_type: String,
	source_node: Node,
	_ability_id: String,
	_ability_type: String
) -> void:
	if amount <= 0.0:
		return
	if source_node == null:
		return
	if not is_instance_valid(source_node):
		return
	if not (source_node is Node2D):
		return

	var now: float = Time.get_ticks_msec() / 1000.0
	_recent_attackers[source_node] = now

func _cleanup_recent_attackers(now: float) -> void:
	if _recent_attackers.is_empty():
		return

	var to_remove: Array = []
	for k in _recent_attackers.keys():
		var last_any: Variant = _recent_attackers[k]
		var last_t: float = 0.0
		if typeof(last_any) == TYPE_FLOAT or typeof(last_any) == TYPE_INT:
			last_t = float(last_any)
		if now - last_t > retaliate_memory_sec:
			to_remove.append(k)

	var i: int = 0
	while i < to_remove.size():
		_recent_attackers.erase(to_remove[i])
		i += 1

func _pick_recent_attacker(now: float) -> Node2D:
	if _recent_attackers.is_empty():
		return null

	var best: Node2D = null
	var best_age: float = 999999.0

	for k in _recent_attackers.keys():
		if not (k is Node2D):
			continue
		var n: Node2D = k as Node2D
		if n == null:
			continue
		if not is_instance_valid(n):
			continue
		if _is_node_dead(n):
			continue

		var last_any: Variant = _recent_attackers[k]
		var last_t: float = 0.0
		if typeof(last_any) == TYPE_FLOAT or typeof(last_any) == TYPE_INT:
			last_t = float(last_any)

		var age: float = now - last_t
		if age < 0.0:
			age = 0.0

		if age <= retaliate_memory_sec:
			if best == null:
				best = n
				best_age = age
			else:
				if age < best_age:
					best = n
					best_age = age

	return best

# ----------------------------
# Stats / Dead checks
# ----------------------------
func _get_move_speed() -> float:
	if _stats != null and is_instance_valid(_stats):
		if _stats.has_method("get_final_stat"):
			var v: Variant = _stats.call("get_final_stat", "MoveSpeed")
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				var spd: float = float(v)
				if spd > 0.0:
					return spd
	return 70.0

func _is_dead() -> bool:
	if _status != null and is_instance_valid(_status):
		if _status.has_method("is_dead"):
			var v: Variant = _status.call("is_dead")
			if typeof(v) == TYPE_BOOL:
				return bool(v)

	if _stats != null and is_instance_valid(_stats):
		if _stats.has_method("is_dead"):
			var v2: Variant = _stats.call("is_dead")
			if typeof(v2) == TYPE_BOOL:
				return bool(v2)

	return false

func _is_node_dead(n: Node) -> bool:
	if n == null:
		return true
	if not is_instance_valid(n):
		return true

	var st: Node = null
	if n.has_node("StatusConditions"):
		st = n.get_node("StatusConditions")
	if st != null and st.has_method("is_dead"):
		var v: Variant = st.call("is_dead")
		if typeof(v) == TYPE_BOOL:
			return bool(v)

	var sc: Node = null
	if n.has_node("StatsComponent"):
		sc = n.get_node("StatsComponent")
	if sc != null and sc.has_method("is_dead"):
		var v2: Variant = sc.call("is_dead")
		if typeof(v2) == TYPE_BOOL:
			return bool(v2)

	return false

func _clamp_mode(m: int) -> int:
	if m < 0:
		return PetMode.AGGRESSIVE
	if m > 3:
		return PetMode.SUPPORT
	return m

# ----------------------------
# Animation driving
# ----------------------------
func _update_anim(dir: Vector2, moving: bool) -> void:
	if _dead_latched:
		return

	var d: Vector2 = dir
	if d.length() > 0.001:
		d = d.normalized()
	else:
		d = _last_facing_dir

	if d.length() <= 0.001:
		d = Vector2.DOWN

	_last_facing_dir = d

	if _bridge != null and is_instance_valid(_bridge):
		if _bridge.has_method("set_facing"):
			_bridge.call("set_facing", d)
		if _bridge.has_method("set_movement"):
			_bridge.call("set_movement", d, moving)
			return

	if _sprite == null or not is_instance_valid(_sprite):
		return
	if _sprite.sprite_frames == null:
		return

	var face: String = "down"
	if absf(d.x) >= absf(d.y):
		face = "side"
		_sprite.flip_h = (d.x < 0.0)
	else:
		if d.y < 0.0:
			face = "up"
			_sprite.flip_h = false
		else:
			face = "down"
			_sprite.flip_h = false

	var prefix: String = "idle_"
	if moving:
		prefix = "walk_"

	var anim_name: String = prefix + face
	if _sprite.sprite_frames.has_animation(anim_name):
		if _sprite.animation != anim_name:
			_sprite.play(anim_name)

# ----------------------------
# Collision helper
# ----------------------------
func _configure_as_ally_collision(body: CollisionObject2D) -> void:
	var i: int = 1
	while i <= 32:
		body.set_collision_layer_value(i, false)
		body.set_collision_mask_value(i, false)
		i += 1

	body.set_collision_layer_value(LBIT_ALLY, true)
	body.set_collision_mask_value(LBIT_WORLD, true)

	body.set_collision_mask_value(LBIT_ALLY, false)
	body.set_collision_mask_value(LBIT_ENEMY, false)
