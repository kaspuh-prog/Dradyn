extends CharacterBody2D
class_name EnemyBase

# --- Nodes ---
@onready var stats: Node = $StatsComponent
var anim: AnimatedSprite2D = null
var sprite_anchor: Node2D = null

# --- Exports ---
@export var enemy_name: String = "Enemy"
@export var detection_radius: float = 200.0

# Attack geometry / timing
@export var attack_range: float = 32.0
@export var attack_arc_deg: float = 70.0
@export var attack_forward_offset: float = 8.0
@export var attack_cooldown_sec: float = 0.9
@export var attack_hit_frame: int = 2

# Animation names
@export var anim_idle_prefix: String = "idle"
@export var anim_walk_prefix: String = "walk"
@export var anim_attack_prefix: String = "attackspear"

# Behavior tuning
@export var stop_buffer_px: float = 2.0            # small cushion inside range to stop sooner
@export var debug_prints: bool = false

# Damage shaping
@export var noncrit_variance: float = 0.15
@export var crit_multiplier: float = 1.5

# --- Signals ---
signal damaged(enemy: EnemyBase, amount: float, dmg_type: String, source: String)
signal died(enemy: EnemyBase)

# --- Runtime ---
var _target: Node2D = null
var _is_attacking: bool = false
var _attack_pending: bool = false
var _cooldown_timer: float = 0.0
var _attack_anim_name: String = ""
var _post_cooldown: float = 0.0
var _party_mgr: Node = null

enum Facing { DOWN, UP, SIDE }
var _facing: int = Facing.DOWN
var _facing_left: bool = false

# RNG + attack ids
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _attack_seq: int = 0
var _current_attack_id: int = -1

func _ready() -> void:
	_rng.randomize()
	add_to_group("Enemies")

	# Resolve optional children
	anim = get_node_or_null("Anim") as AnimatedSprite2D
	var maybe_anchor: Node = get_node_or_null("Sprite")
	if maybe_anchor != null and maybe_anchor is Node2D:
		sprite_anchor = maybe_anchor as Node2D
	else:
		sprite_anchor = self

	if stats == null:
		push_warning("[EnemyBase] StatsComponent missing under " + name)
	else:
		if stats.has_signal("died") and not stats.is_connected("died", Callable(self, "_on_died")):
			stats.connect("died", Callable(self, "_on_died"))
		if stats.has_signal("damage_taken") and not stats.is_connected("damage_taken", Callable(self, "_on_damage_taken")):
			stats.connect("damage_taken", Callable(self, "_on_damage_taken"))

	# Damage numbers
	get_tree().call_group("DamageNumberSpawners", "register_emitter", stats, sprite_anchor)

	# Anim signals
	if anim != null:
		if not anim.is_connected("frame_changed", Callable(self, "_on_anim_frame_changed")):
			anim.connect("frame_changed", Callable(self, "_on_anim_frame_changed"))
		if not anim.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
			anim.connect("animation_finished", Callable(self, "_on_anim_finished"))

	# Cache PartyManager, if present
	_party_mgr = get_tree().get_first_node_in_group("PartyManager")

func _physics_process(delta: float) -> void:
	_cooldown_timer = maxf(0.0, _cooldown_timer - delta)
	_acquire_target()
	_run_ai(delta)
	_update_anim()

# ---------------- Targeting ----------------
func _acquire_target() -> void:
	# 1) PartyManager controlled
	if _party_mgr != null and _party_mgr.has_method("get_controlled"):
		var c = _party_mgr.call("get_controlled")
		if c is Node2D:
			var p: Node2D = c
			if global_position.distance_to(p.global_position) <= detection_radius:
				_target = p
				return

	# 2) PartyLeader group
	var leader = get_tree().get_first_node_in_group("PartyLeader")
	if leader is Node2D:
		var l2: Node2D = leader
		if global_position.distance_to(l2.global_position) <= detection_radius:
			_target = l2
			return

	# 3) Nearest PartyMembers
	var nearest: Node2D = null
	var best_d2: float = detection_radius * detection_radius
	var list: Array = get_tree().get_nodes_in_group("PartyMembers")
	for m in list:
		if m is Node2D:
			var n2: Node2D = m
			var d2: float = (n2.global_position - global_position).length_squared()
			if d2 <= best_d2:
				best_d2 = d2
				nearest = n2
	_target = nearest

# ---------------- Helpers: cone/aim ----------------
func _facing_vector() -> Vector2:
	match _facing:
		Facing.UP:   return Vector2.UP
		Facing.DOWN: return Vector2.DOWN
		_:           return Vector2.LEFT if _facing_left else Vector2.RIGHT

func _attack_origin() -> Vector2:
	var aim: Vector2 = _facing_vector().normalized()
	return global_position + aim * attack_forward_offset

func _in_attack_cone(target_pos: Vector2) -> bool:
	var aim: Vector2 = _facing_vector()
	if aim == Vector2.ZERO:
		aim = Vector2.DOWN
	var origin: Vector2 = _attack_origin()
	var to: Vector2 = target_pos - origin
	var dist: float = to.length()
	if dist > attack_range + stop_buffer_px:
		return false
	var denom: float = maxf(0.001, dist)
	var dir: Vector2 = to / denom
	var dot_val: float = clampf(aim.normalized().dot(dir), -1.0, 1.0)
	var ang: float = acos(dot_val)
	return ang <= deg_to_rad(attack_arc_deg * 0.5)

# ---------------- AI ----------------
func _run_ai(_delta: float) -> void:
	var ms: float = 90.0
	if stats != null and stats.has_method("get_final_stat"):
		var val = stats.call("get_final_stat", "MoveSpeed")
		if typeof(val) == TYPE_INT or typeof(val) == TYPE_FLOAT:
			var f: float = float(val)
			if f > 0.0:
				ms = f

	if _is_attacking:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if _target != null and is_instance_valid(_target):
		var to_tgt: Vector2 = _target.global_position - global_position
		_set_facing_from_vector(to_tgt)

		# If the target is inside the attack cone, stop and attack.
		if _in_attack_cone(_target.global_position):
			velocity = Vector2.ZERO
			move_and_slide()
			_start_attack()
		else:
			# Otherwise, keep approaching the target.
			var dist: float = to_tgt.length()
			var denom: float = maxf(0.001, dist)
			var dir: Vector2 = to_tgt / denom
			velocity = dir * ms
			move_and_slide()
	else:
		velocity = Vector2.ZERO
		move_and_slide()

# ---------------- Attack ----------------
func _start_attack() -> void:
	if _is_attacking:
		return
	if _cooldown_timer > 0.0:
		return

	_is_attacking = true
	_attack_pending = true

	_attack_seq += 1
	_current_attack_id = _attack_seq

	_attack_anim_name = _compose_anim(anim_attack_prefix)

	_post_cooldown = attack_cooldown_sec
	if anim != null:
		var frames: SpriteFrames = anim.sprite_frames
		var has_anim: bool = false
		if frames != null:
			has_anim = frames.has_animation(_attack_anim_name)
			if has_anim:
				var cnt: int = frames.get_frame_count(_attack_anim_name)
				var fps: float = frames.get_animation_speed(_attack_anim_name)
				if fps <= 0.0:
					fps = 10.0
				var clip: float = float(cnt) / fps
				var remain: float = attack_cooldown_sec - clip
				if remain < 0.0:
					remain = 0.0
				_post_cooldown = remain
				frames.set_animation_loop(_attack_anim_name, false)

		if has_anim:
			anim.play(_attack_anim_name)
			anim.frame = 0
		else:
			if debug_prints:
				print("[EnemyBase] Missing anim: ", _attack_anim_name)
			_do_attack_hit()
			_is_attacking = false
			_cooldown_timer = attack_cooldown_sec
	else:
		_do_attack_hit()
		_is_attacking = false
		_cooldown_timer = attack_cooldown_sec

func _do_attack_hit() -> void:
	if _target == null or not is_instance_valid(_target):
		return

	# Safety: only hit if the target is still in our cone right now.
	if not _in_attack_cone(_target.global_position):
		if debug_prints:
			print("[EnemyBase] Hit skipped (target left cone).")
		return

	var did_crit: bool = _roll_crit(stats)
	var amt: float = _roll_noncrit_amount(stats)
	if did_crit:
		amt *= crit_multiplier

	var t_stats: Node = _find_stats_component(_target)
	if t_stats == null:
		if debug_prints:
			print("[EnemyBase] Target has no StatsComponent")
		return

	var packet := {
		"amount": amt,
		"source": enemy_name,
		"is_crit": did_crit,
		"attack_id": _current_attack_id
	}
	t_stats.apply_damage_packet(packet)

# ---------------- Anim events ----------------
func _on_anim_frame_changed() -> void:
	if not _is_attacking:
		return
	if anim == null:
		return
	if anim.animation == _attack_anim_name and anim.frame == attack_hit_frame:
		if _attack_pending:
			_attack_pending = false
			_do_attack_hit()

func _on_anim_finished() -> void:
	if _is_attacking and anim != null and anim.animation == _attack_anim_name:
		_is_attacking = false
		_cooldown_timer = _post_cooldown
		var idle_name: String = _compose_anim(anim_idle_prefix)
		anim.play(idle_name)

# ---------------- Damage relays ----------------
func _on_damage_taken(amount: float, dmg_type: String, source: String) -> void:
	emit_signal("damaged", self, amount, dmg_type, source)

func _on_died() -> void:
	emit_signal("died", self)
	queue_free()

# ---------------- Anim helpers ----------------
func _compose_anim(prefix: String) -> String:
	if _facing == Facing.DOWN:
		return prefix + "_down"
	elif _facing == Facing.UP:
		return prefix + "_up"
	else:
		return prefix + "_side"

func _set_facing_from_vector(v: Vector2) -> void:
	if absf(v.x) > absf(v.y):
		_facing = Facing.SIDE
		_facing_left = (v.x < 0.0)
		if anim != null:
			anim.flip_h = _facing_left
	else:
		if v.y < 0.0:
			_facing = Facing.UP
		else:
			_facing = Facing.DOWN
		if anim != null:
			anim.flip_h = false

func _update_anim() -> void:
	if anim == null or _is_attacking:
		return
	var next_name: String = ""
	if velocity.length() > 1.0:
		next_name = _compose_anim(anim_walk_prefix)
	else:
		next_name = _compose_anim(anim_idle_prefix)
	if anim.animation != next_name or not anim.is_playing():
		anim.play(next_name)

# ---------------- RNG helpers ----------------
func _roll_noncrit_amount(attacker_stats: Node) -> float:
	var atk: float = 10.0
	if attacker_stats != null and attacker_stats.has_method("get_final_stat"):
		var v = attacker_stats.call("get_final_stat", "Attack")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			atk = float(v)
	var spread: float = clampf(noncrit_variance, 0.0, 0.95)
	var mult: float = 1.0
	if spread > 0.0:
		mult = _rng.randf_range(1.0 - spread, 1.0 + spread)
	return atk * mult

func _roll_crit(attacker_stats: Node) -> bool:
	var cc: float = 0.0
	if attacker_stats != null and attacker_stats.has_method("get_final_stat"):
		var v = attacker_stats.call("get_final_stat", "CritChance")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			cc = float(v)
	if cc > 1.0:
		cc *= 0.01
	cc = clampf(cc, 0.0, 0.95)
	return _rng.randf() < cc

# ---------------- Utils ----------------
func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var by_name: Node = root.find_child("StatsComponent", true, false)
	if by_name != null:
		return by_name
	if root.has_method("apply_damage_packet"):
		return root
	return null
