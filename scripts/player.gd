extends CharacterBody2D

# --- References ---
@onready var stats: Node = $StatsComponent
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

# --- Config / Exports ---
@export var is_leader: bool = false : set = _set_is_leader, get = _get_is_leader
@export var sprint_mul: float = 1.35
@export var stamina_cost_per_second: float = 2.0
@export var sprint_step_cost: float = 0.2
@export var accel_lerp: float = 0.18
@export var resume_sprint_end: float = 1.0

@export var attack_cooldown_sec: float = 0.5
@export var attack_queue_buffer_sec: float = 0.16
@export var attack_hit_frame: int = 2
@export var melee_range: float = 28.0
@export var melee_arc_deg: float = 70.0
@export var melee_forward_offset: float = 8.0

# NEW: damage shaping
@export var noncrit_variance: float = 0.15     # ±15% spread
@export var crit_multiplier: float = 1.5

const SPRINT_ACTION := "sprint"
const SPRINT_ACTION_ALT := "ui_sprint"
const ATTACK_ACTION := "attack"

var _party: Node = null
var _registered: bool = false
var _is_leader_cache: bool = false
var _sprinting: bool = false

const SPEED_FALLBACK: float = 96.0

# --- State ---
var controlled: bool = false
var last_move_dir: Vector2 = Vector2.DOWN

var _attacking: bool = false
var _attack_cd: float = 0.0
var _attack_anim_name: String = ""
var _attack_hit_pending: bool = false
var _attack_post_cd: float = 0.0
var _attack_buffer: float = 0.0

# NEW: per-actor RNG + dedupe ids
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _attack_seq: int = 0
var _current_attack_id: int = -1

# NEW: guard to avoid double registration
var _damage_numbers_registered: bool = false

# -------------------- Lifecycle --------------------
func _ready() -> void:
	_rng.randomize()

	if is_instance_valid(sprite):
		sprite.frame_changed.connect(Callable(self, "_on_sprite_frame_changed"))
		sprite.animation_finished.connect(Callable(self, "_on_sprite_animation_finished"))

	# Defer registration so DamageNumberLayer (CanvasLayer) is surely in the tree
	call_deferred("_register_damage_numbers")

	_party = get_node_or_null("/root/Party")
	if _party != null and _party.has_signal("controlled_changed"):
		_party.controlled_changed.connect(_on_controlled_changed)
	elif _party == null:
		push_warning("[Player] /root/Party not found — defaulting to controlled=true")
		controlled = true

	call_deferred("_join_party")

func _join_party() -> void:
	if _registered:
		return
	if _party == null:
		_party = get_node_or_null("/root/Party")
		if _party == null:
			return
		if _party.has_signal("controlled_changed"):
			_party.controlled_changed.connect(_on_controlled_changed)

	if stats == null:
		push_warning("[Player] StatsComponent missing under " + name)

	_party.call("add_member", self, is_leader)
	_registered = true

# Registers this actor as a damage-number emitter (once).
func _register_damage_numbers() -> void:
	if _damage_numbers_registered:
		return
	if stats == null:
		return
	var anchor: Node2D = null
	if is_instance_valid(sprite):
		anchor = sprite
	else:
		anchor = self
	get_tree().call_group("DamageNumberSpawners", "register_emitter", stats, anchor)
	_damage_numbers_registered = true

# -------------------- Leader <-> Control link --------------------
func _set_is_leader(v: bool) -> void:
	_is_leader_cache = v
	if v and _party != null and _party.has_method("set_controlled"):
		_party.call("set_controlled", self)

func _get_is_leader() -> bool:
	return _is_leader_cache

func set_controlled(v: bool) -> void:
	controlled = v
	set_process_input(v)
	print("[", name, "] controlled=", v)

func _on_controlled_changed(current: Node) -> void:
	_is_leader_cache = (current == self)
	if controlled:
		modulate = Color(1, 1, 1, 1)
	else:
		modulate = Color(0.82, 0.82, 0.82, 1)

# -------------------- Movement / Sprint --------------------
func _physics_process(delta: float) -> void:
	_attack_cd = max(0.0, _attack_cd - delta)
	if _attack_buffer > 0.0:
		_attack_buffer = max(0.0, _attack_buffer - delta)

	var dir: Vector2 = Vector2.ZERO

	if controlled:
		# Attack input
		if Input.is_action_just_pressed(ATTACK_ACTION):
			if _attacking or _attack_cd > 0.0:
				_attack_buffer = attack_queue_buffer_sec
			else:
				_start_attack()
				return

		# Movement input
		dir = Vector2(
			Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
			Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
		)
		if dir.length_squared() > 1.0:
			dir = dir.normalized()

		_sprinting = _is_sprint_pressed() and dir != Vector2.ZERO

		if _sprinting and stats != null and stats.has_method("spend_end"):
			var drain: float = stamina_cost_per_second * delta
			var ok: bool = stats.call("spend_end", drain)
			if not ok:
				_sprinting = false

		var base_speed: float = SPEED_FALLBACK
		if stats != null and stats.has_method("get_final_stat"):
			var v_any: Variant = stats.call("get_final_stat", "MoveSpeed")
			if typeof(v_any) == TYPE_INT or typeof(v_any) == TYPE_FLOAT:
				var v_f: float = float(v_any)
				if v_f > 0.0:
					base_speed = v_f

		var target_speed: float = base_speed
		if _sprinting:
			target_speed *= sprint_mul

		var desired: Vector2 = dir * target_speed
		velocity = velocity.lerp(desired, accel_lerp)
		move_and_slide()

		if sprite != null:
			if _sprinting:
				sprite.speed_scale = 1.25
			else:
				sprite.speed_scale = 1.0
	else:
		if sprite != null:
			sprite.speed_scale = 1.0

	_update_animation()

	# Buffered re-attack as soon as allowed
	if not _attacking and _attack_cd <= 0.0 and _attack_buffer > 0.0:
		_attack_buffer = 0.0
		_start_attack()

func _is_sprint_pressed() -> bool:
	if InputMap.has_action(SPRINT_ACTION) and Input.is_action_pressed(SPRINT_ACTION):
		return true
	if InputMap.has_action(SPRINT_ACTION_ALT) and Input.is_action_pressed(SPRINT_ACTION_ALT):
		return true
	return false

# -------------------- Animation --------------------
func _update_animation() -> void:
	if not is_instance_valid(sprite):
		return
	if _attacking:
		return

	var v: Vector2 = velocity
	var speed: float = v.length()
	var moving: bool = speed > 1.0
	if moving:
		last_move_dir = v / max(speed, 0.001)

	var use_side: bool = absf(last_move_dir.x) >= absf(last_move_dir.y)
	var anim_name: String = ""
	var flip_h: bool = false

	if moving:
		if use_side:
			anim_name = "walk_side"
			flip_h = last_move_dir.x < 0.0
		else:
			if last_move_dir.y < 0.0:
				anim_name = "walk_up"
			else:
				anim_name = "walk_down"
	else:
		if use_side:
			anim_name = "idle_side"
			flip_h = last_move_dir.x < 0.0
		else:
			if last_move_dir.y < 0.0:
				anim_name = "idle_up"
			else:
				anim_name = "idle_down"

	if sprite.animation != anim_name:
		sprite.flip_h = flip_h
		sprite.play(anim_name)
	elif anim_name.ends_with("_side"):
		sprite.flip_h = flip_h

# -------------------- Attack --------------------
func _start_attack() -> void:
	if _attacking:
		return
	if _attack_cd > 0.0:
		return

	_attacking = true
	_attack_anim_name = ""
	_attack_hit_pending = true

	_attack_seq += 1
	_current_attack_id = _attack_seq

	# Choose anim by facing
	var use_side: bool = absf(last_move_dir.x) >= absf(last_move_dir.y)
	var anim_name: String = ""
	var flip_h: bool = false
	if use_side:
		anim_name = "attack1_side"
		flip_h = last_move_dir.x < 0.0
	else:
		if last_move_dir.y < 0.0:
			anim_name = "attack1_up"
		else:
			anim_name = "attack1_down"

	_attack_anim_name = anim_name

	if sprite != null:
		var frames: SpriteFrames = sprite.sprite_frames
		if frames != null and frames.has_animation(anim_name):
			frames.set_animation_loop(anim_name, false)
		sprite.flip_h = flip_h
		sprite.frame = 0
		sprite.play(anim_name)

func _finish_attack() -> void:
	_attacking = false
	_attack_cd = _attack_post_cd
	_attack_anim_name = ""
	if _attack_buffer > 0.0 and _attack_cd <= 0.0:
		_attack_buffer = 0.0
		_start_attack()
	else:
		_update_animation()

# --- RNG helpers ---
func _roll_noncrit_amount(attacker_stats: Node) -> float:
	var atk: float = 10.0
	if attacker_stats != null and attacker_stats.has_method("get_final_stat"):
		var v = attacker_stats.call("get_final_stat", "Attack")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			atk = float(v)
	var spread: float = clamp(noncrit_variance, 0.0, 0.95)
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
		cc = cc * 0.01
	cc = clamp(cc, 0.0, 0.95)
	return _rng.randf() < cc

# --- Signals from sprite ---
func _on_sprite_frame_changed() -> void:
	if not is_instance_valid(sprite):
		return

	# Sprint stamina footstep drain
	if _sprinting and controlled and sprint_step_cost > 0.0:
		var anim: String = sprite.animation
		if anim.begins_with("walk_"):
			var f: int = sprite.frame
			if f == 0 or f == 3:
				if stats != null and stats.has_method("spend_end"):
					stats.call("spend_end", sprint_step_cost)

	# Trigger the actual hit on the configured frame
	if _attacking and _attack_hit_pending and _attack_anim_name != "" and sprite.animation == _attack_anim_name:
		if sprite.frame == attack_hit_frame:
			_attack_hit_pending = false
			_player_do_attack_hit()

	# Fallback: finish attack automatically on the last frame even if something goes off
	if _attacking and _attack_anim_name != "" and sprite.animation == _attack_anim_name:
		var frames: SpriteFrames = sprite.sprite_frames
		if frames != null and frames.has_animation(_attack_anim_name):
			var last: int = frames.get_frame_count(_attack_anim_name) - 1
			if sprite.frame >= last:
				_finish_attack()

func _on_sprite_animation_finished() -> void:
	if _attacking and _attack_anim_name != "" and sprite != null:
		if sprite.animation == _attack_anim_name:
			_finish_attack()

# --- Do the melee hit (arc/angle gate) ---
func _player_do_attack_hit() -> void:
	var aim: Vector2 = last_move_dir
	if aim == Vector2.ZERO:
		aim = Vector2.DOWN
	var origin: Vector2 = global_position + aim.normalized() * melee_forward_offset
	var half_angle_rad: float = deg_to_rad(melee_arc_deg * 0.5)

	# Build the packet once per swing
	var did_crit: bool = _roll_crit(stats)
	var amt: float = _roll_noncrit_amount(stats)
	if did_crit:
		amt = amt * crit_multiplier

	var packet := {
		"amount": amt,
		"source": name,
		"is_crit": did_crit,
		"attack_id": _current_attack_id
	}

	# Find enemies in arc
	var enemies := get_tree().get_nodes_in_group("Enemies")
	for e in enemies:
		if not (e is Node2D):
			continue
		var n2: Node2D = e
		var to: Vector2 = n2.global_position - origin
		var dist: float = to.length()
		if dist > melee_range:
			continue
		var dir: Vector2 = to / max(0.001, dist)
		var dot: float = aim.normalized().dot(dir)
		if dot > 1.0:
			dot = 1.0
		if dot < -1.0:
			dot = -1.0
		var ang: float = acos(dot)
		if ang > half_angle_rad:
			continue

		var t_stats := _find_stats_component(n2)
		if t_stats != null:
			t_stats.apply_damage_packet(packet)

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var by_name: Node = root.find_child("StatsComponent", true, false)
	if by_name != null:
		return by_name
	if root.has_method("apply_damage_packet"):
		return root
	return null
