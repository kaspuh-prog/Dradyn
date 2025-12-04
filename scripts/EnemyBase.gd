extends CharacterBody2D
class_name EnemyBase

# --- Nodes ---
@onready var stats: Node = $StatsComponent
var anim: AnimatedSprite2D = null
var sprite_anchor: Node2D = null

# --- Collision layers (bit indices) ---
const LBIT_WORLD: int = 1
const LBIT_ENEMY: int = 2
const LBIT_ALLY: int = 3

# --- Exports ---
@export var enemy_name: String = "Enemy"
@export var detection_radius: float = 200.0
@export var hp_tie_epsilon: float = 0.02
@export var dist_tie_epsilon_px: float = 12.0
@export var randomize_tie_choice: bool = true

# Attack geometry / timing (legacy melee support)
@export var attack_range: float = 32.0
@export var attack_arc_deg: float = 70.0
@export var attack_forward_offset: float = 8.0
@export var attack_cooldown_sec: float = 0.9
@export var attack_hit_frame: int = 2

# Animation names
@export var anim_idle_prefix: String = "idle"
@export var anim_walk_prefix: String = "walk"
@export var anim_attack_prefix: String = "attack"

# Cast (heal/buffs/projectile) animation
@export var anim_cast_prefix: String = "cast"
@export var cast_hit_frame: int = 3

# Death VFX (SpriteFrames or file path)
@export var death_vfx_frames: SpriteFrames
@export_file("*.tres") var death_vfx_frames_path: String = ""
@export var death_vfx_anim: String = "poof"
@export var death_vfx_scale: float = 1.0
@export var death_vfx_offset: Vector2 = Vector2(-3, -15)
@export var death_vfx_lifetime_sec: float = 0.0

# Behavior tuning
@export var stop_buffer_px: float = 2.0
@export var debug_prints: bool = false

# Damage shaping
@export var noncrit_variance: float = 0.15
@export var crit_multiplier: float = 1.5

# Deprecated: abilities are sourced from KnownAbilities (component) now.
@export var known_abilities: PackedStringArray = []

# Targeting mode (party-wide)
enum TargetMode { SMART, NEAREST }
@export var target_mode: int = TargetMode.SMART

# Ranged spacing (active when no melee in kit)
@export var ranged_hold_min_px: float = 72.0
@export var ranged_hold_max_px: float = 160.0

# Melee spacing (for melee enemies; avoids overlapping the target)
@export var melee_hold_min_px: float = 14.0
@export var melee_hold_max_px: float = 26.0

# --- Signals ---
signal damaged(enemy: EnemyBase, amount: float, dmg_type: String, source: String)
signal died(enemy: EnemyBase)

# --- Runtime ---
var _target: Node2D = null
var _is_attacking: bool = false
var _is_casting: bool = false
var _attack_pending: bool = false
var _cooldown_timer: float = 0.0
var _attack_anim_name: String = ""
var _cast_anim_name: String = ""
var _post_cooldown: float = 0.0
var _party_mgr: Node = null
var _on_hit_cb: Callable = Callable()
var _on_cast_cb: Callable = Callable()

# Derived Attack Speed total cooldown (computed from stats)
var _attack_total_cd: float = 0.9

enum Facing { DOWN, UP, SIDE }
var _facing: int = Facing.DOWN
var _facing_left: bool = false

# RNG + attack ids
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _attack_seq: int = 0
var _current_attack_id: int = -1

# Ability plumbing
var _abilitysys: Node = null
var _known_abilities_node: Node = null   # child "KnownAbilities" component
var _has_melee_in_kit_flag: bool = true  # computed at ready

# Link to EnemyAbilityAI if present (used for non-thrashy facing)
var _enemy_ai: Node = null

# NEW: time-based action lock for cast/projectile animations
var _action_anim_until_msec: int = 0

# NEW: hit frame for current cast animation
var _pending_cast_hit_frame: int = 0

func _ready() -> void:
	_rng.randomize()
	add_to_group("Enemies")
	_configure_as_enemy(self)

	# Resolve children
	anim = get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	var maybe_anchor: Node = get_node_or_null("Sprite")
	if maybe_anchor != null and maybe_anchor is Node2D:
		sprite_anchor = maybe_anchor as Node2D
	else:
		sprite_anchor = self

	_enemy_ai = get_node_or_null("EnemyAbilityAI")

	if stats == null:
		push_warning("[EnemyBase] StatsComponent missing under " + name)
	else:
		if stats.has_signal("died") and not stats.is_connected("died", Callable(self, "_on_died")):
			stats.connect("died", Callable(self, "_on_died"))
		if stats.has_signal("damage_taken") and not stats.is_connected("damage_taken", Callable(self, "_on_damage_taken")):
			stats.connect("damage_taken", Callable(self, "_on_damage_taken"))

	get_tree().call_group("DamageNumberSpawners", "register_emitter", stats, sprite_anchor)

	if anim != null:
		if not anim.is_connected("frame_changed", Callable(self, "_on_anim_frame_changed")):
			anim.connect("frame_changed", Callable(self, "_on_anim_frame_changed"))
		# Extra frame listener used for cast hit-frame timing.
		if not anim.is_connected("frame_changed", Callable(self, "_on_cast_frame_changed")):
			anim.connect("frame_changed", Callable(self, "_on_cast_frame_changed"))
		if not anim.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
			anim.connect("animation_finished", Callable(self, "_on_anim_finished"))

	_party_mgr = get_tree().get_first_node_in_group("PartyManager")
	_abilitysys = get_node_or_null("/root/AbilitySys")
	_known_abilities_node = _resolve_known_abilities_node()
	_has_melee_in_kit_flag = _compute_has_melee_in_kit()

	_init_attack_speed_hooks()

func _physics_process(delta: float) -> void:
	_cooldown_timer = maxf(0.0, _cooldown_timer - delta)
	_acquire_target()
	_run_ai(delta)
	_update_anim()

# ---------------- AbilitySystem integration ----------------
func is_action_locked() -> bool:
	if _is_attacking:
		return true
	if _is_casting:
		return true
	if Time.get_ticks_msec() < _action_anim_until_msec:
		return true
	return false

func lock_action(seconds: float) -> void:
	var ms: int = int(max(0.0, seconds) * 1000.0)
	lock_action_for(ms)

func lock_action_for(ms: int) -> void:
	var now: int = Time.get_ticks_msec()
	var until: int = now + max(0, ms)
	if until > _action_anim_until_msec:
		_action_anim_until_msec = until

func unlock_action() -> void:
	_action_anim_until_msec = 0

func has_ability(ability_id: String) -> bool:
	if ability_id == "":
		return false
	var kac: Node = _resolve_known_abilities_node()
	if kac != null:
		if kac.has_method("has_ability"):
			var v: Variant = kac.call("has_ability", ability_id)
			if typeof(v) == TYPE_BOOL:
				return bool(v)
		if "known_abilities" in kac:
			var arr_any: Variant = kac.get("known_abilities")
			if typeof(arr_any) == TYPE_PACKED_STRING_ARRAY:
				var arr: PackedStringArray = arr_any
				return arr.has(ability_id)
	return false

# ---------------- Attack Speed (derived) ----------------
func _init_attack_speed_hooks() -> void:
	if stats != null:
		_recalc_attack_cooldown()
		if stats.has_signal("stat_changed"):
			stats.stat_changed.connect(_on_stat_changed_for_attack_speed)
		if stats.has_signal("attack_speed_changed"):
			stats.attack_speed_changed.connect(_on_attack_speed_changed)
	else:
		_attack_total_cd = attack_cooldown_sec

func _on_attack_speed_changed(delay_sec: float, _mul: float, _aps: float) -> void:
	_attack_total_cd = delay_sec

func _recalc_attack_cooldown() -> void:
	var r: Dictionary = DerivedFormulas.calc_attack_speed(stats)
	_attack_total_cd = float(r["attack_delay_sec"])

func _on_stat_changed_for_attack_speed(stat_name: String, _final_value: float) -> void:
	if stat_name == "AGI" or stat_name == "STR" or stat_name == "WeaponWeight" or stat_name == "BaseAttackDelay":
		_recalc_attack_cooldown()

# ---------------- Targeting ----------------
func _acquire_target() -> void:
	var candidates: Array = _gather_party_candidates()
	var in_range: Array = []
	var r2: float = detection_radius * detection_radius

	for n in candidates:
		if n == null or not is_instance_valid(n):
			continue
		if not _candidate_is_attackable(n):
			continue
		var d2: float = (n.global_position - global_position).length_squared()
		if d2 <= r2:
			in_range.append(n)

	var chosen: Node2D = null
	if in_range.size() > 0:
		if target_mode == TargetMode.SMART:
			chosen = _choose_smart_target(in_range)
		else:
			var best_d2: float = r2
			for n2 in in_range:
				var dd2: float = (n2.global_position - global_position).length_squared()
				if dd2 <= best_d2:
					best_d2 = dd2
					chosen = n2 as Node2D

	if chosen == self:
		chosen = null

	_target = chosen

func _gather_party_candidates() -> Array:
	var out: Array = []
	if _party_mgr != null and _party_mgr.has_method("get_members"):
		var arr_any: Variant = _party_mgr.call("get_members")
		if typeof(arr_any) == TYPE_ARRAY:
			var arr: Array = arr_any
			for m in arr:
				if m is Node2D:
					out.append(m)
	if out.is_empty():
		var list: Array = get_tree().get_nodes_in_group("PartyMembers")
		for m in list:
			if m is Node2D:
				out.append(m as Node2D)
	return out

func _has_prop(obj: Object, prop_name: String) -> bool:
	var plist: Array = obj.get_property_list()
	var i: int = 0
	while i < plist.size():
		var p: Dictionary = plist[i]
		if typeof(p) == TYPE_DICTIONARY:
			var nm: String = String(p.get("name", ""))
			if nm == prop_name:
				return true
		i += 1
	return false

func _candidate_is_attackable(n: Node2D) -> bool:
	# Previously: returned true if no StatsComponent was found.
	# New: require a stats/damage interface AND verify the target is alive.
	var st: Node = _find_stats_component(n)
	if st == null:
		return false

	# If the stats node exposes is_dead(), trust it.
	if st.has_method("is_dead"):
		var dead_any: Variant = st.call("is_dead")
		if typeof(dead_any) == TYPE_BOOL and bool(dead_any):
			return false

	# Otherwise fall back to current_hp > 0 check.
	var cur: float = 1.0
	if st.has_method("current_hp"):
		var v: Variant = st.call("current_hp")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			cur = float(v)
	elif _has_prop(st, "current_hp"):
		var vv: Variant = st.get("current_hp")
		if typeof(vv) == TYPE_INT or typeof(vv) == TYPE_FLOAT:
			cur = float(vv)

	return cur > 0.0

func _choose_smart_target(cands: Array) -> Node2D:
	var ratios: Dictionary = {}
	var d2map: Dictionary = {}
	var min_ratio: float = 2.0
	for n in cands:
		if n == null or not is_instance_valid(n):
			continue
		var ratio: float = 1.0
		var st: Node = _find_stats_component(n)
		if st != null:
			var cur: float = 0.0
			var mx: float = 1.0
			if st.has_method("current_hp"):
				var v: Variant = st.call("current_hp")
				if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
					cur = float(v)
			elif _has_prop(st, "current_hp"):
				var vv: Variant = st.get("current_hp")
				if typeof(vv) == TYPE_INT or typeof(vv) == TYPE_FLOAT:
					cur = float(vv)
			if st.has_method("max_hp"):
				var m: Variant = st.call("max_hp")
				if typeof(m) == TYPE_INT or typeof(m) == TYPE_FLOAT:
					mx = maxf(1.0, float(m))
			elif _has_prop(st, "max_hp"):
				var mm: Variant = st.get("max_hp")
				if typeof(mm) == TYPE_INT or typeof(mm) == TYPE_FLOAT:
					mx = maxf(1.0, float(mm))
			if mx <= 0.0:
				mx = 1.0
			ratio = clampf(cur / mx, 0.0, 1.0)
		ratios[n] = ratio
		d2map[n] = (n.global_position - global_position).length_squared()
		if ratio < min_ratio:
			min_ratio = ratio
	var near_hp: Array = []
	for n2 in cands:
		if not ratios.has(n2):
			continue
		var r: float = float(ratios[n2])
		if r <= min_ratio + hp_tie_epsilon + 1e-6:
			near_hp.append(n2)
	if near_hp.is_empty():
		return null
	var min_d2: float = INF
	for n3 in near_hp:
		var d2_n: float = float(d2map[n3])
		if d2_n < min_d2:
			min_d2 = d2_n
	var near_dist: Array = []
	var eps_d2: float = dist_tie_epsilon_px * dist_tie_epsilon_px
	for n4 in near_hp:
		var d2_n2: float = float(d2map[n4])
		if d2_n2 <= min_d2 + eps_d2:
			near_dist.append(n4)
	if near_dist.size() > 1 and randomize_tie_choice:
		var idx: int = _rng.randi_range(0, near_dist.size() - 1)
		return near_dist[idx] as Node2D
	return near_dist[0] as Node2D

# ---------------- Helpers: cone/aim ----------------
func _facing_vector() -> Vector2:
	if _facing == Facing.UP:
		return Vector2.UP
	if _facing == Facing.DOWN:
		return Vector2.DOWN
	if _facing_left:
		return Vector2.LEFT
	return Vector2.RIGHT

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
	var dir: Vector2 = to / maxf(0.001, dist)
	var dot_val: float = clampf(aim.normalized().dot(dir), -1.0, 1.0)
	var ang: float = acos(dot_val)
	return ang <= deg_to_rad(attack_arc_deg * 0.5)

# ---------------- AI ----------------
func _run_ai(_delta: float) -> void:
	var ms: float = 90.0
	if stats != null and stats.has_method("get_final_stat"):
		var val: Variant = stats.call("get_final_stat", "MoveSpeed")
		if typeof(val) == TYPE_INT or typeof(val) == TYPE_FLOAT:
			var f: float = float(val)
			if f > 0.0:
				ms = f

	# Respect external animation locks (projectile/bridge casts)
	if is_action_locked():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	# If casting or attacking via animation handlers, hold still
	if _is_attacking or _is_casting:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	# Safety: drop target immediately if it becomes invalid or no longer attackable.
	if _target != null:
		if not is_instance_valid(_target) or not _candidate_is_attackable(_target):
			_target = null

	if _target != null and is_instance_valid(_target):
		if _target == self:
			_target = null
		else:
			var to_tgt: Vector2 = _target.global_position - global_position
			var dist: float = to_tgt.length()
			var dir: Vector2 = Vector2.ZERO
			var use_ranged_spacing: bool = not _has_melee_in_kit_flag

			if use_ranged_spacing:
				# Back off if too close; approach if too far; idle in the goldilocks band.
				if dist < ranged_hold_min_px:
					if dist > 0.001:
						dir = (-to_tgt / dist)
					else:
						dir = Vector2.ZERO
				elif dist > ranged_hold_max_px:
					if dist > 0.001:
						dir = (to_tgt / dist)
					else:
						dir = Vector2.ZERO
				else:
					dir = Vector2.ZERO
			else:
				# Melee spacing band: avoid full overlap while staying in range.
				var inner: float = melee_hold_min_px
				var outer: float = melee_hold_max_px
				if outer <= inner:
					outer = inner + 4.0

				var can_swing: bool = _in_attack_cone(_target.global_position) and _can_basic_attack()
				if can_swing:
					velocity = Vector2.ZERO
					move_and_slide()
					_start_attack()
					return

				var too_close: bool = (dist < inner)
				var too_far: bool = (dist > outer)

				if too_far:
					if dist > 0.001:
						dir = to_tgt / dist
				elif too_close:
					if dist > 0.001:
						dir = (-to_tgt / dist)
				else:
					dir = Vector2.ZERO

			velocity = dir * ms
			move_and_slide()

			# Facing: only update from movement to avoid fight with EnemyAbilityAI aim
			if velocity.length() > 0.01:
				_set_facing_from_vector(velocity)
	else:
		velocity = Vector2.ZERO
		move_and_slide()

# ---------------- Ability gating for base attack ----------------
func _can_basic_attack() -> bool:
	if _is_casting:
		return false
	if not has_ability("attack"):
		return false
	if _abilitysys != null and _abilitysys.has_method("can_cast"):
		var v: Variant = _abilitysys.call("can_cast", self, "attack")
		if typeof(v) == TYPE_BOOL and not bool(v):
			return false
	if _cooldown_timer > 0.0:
		return false
	return true

# ---------------- Ability bridges ----------------
func get_current_target() -> Node2D:
	return _target

func get_attack_range_px() -> float:
	return attack_range

func get_attack_arc_deg() -> float:
	return attack_arc_deg

func get_attack_hit_frame() -> int:
	return attack_hit_frame

func play_melee_attack_anim(aim_dir: Vector2, _hit_frame: int, on_hit: Callable) -> void:
	if _is_attacking:
		return
	_is_attacking = true
	_attack_pending = true
	_on_hit_cb = on_hit if on_hit.is_valid() else Callable()
	_attack_seq += 1
	_current_attack_id = _attack_seq
	_set_facing_from_vector(aim_dir)
	_attack_anim_name = _compose_anim(anim_attack_prefix)
	_post_cooldown = _attack_total_cd
	if anim != null and anim.sprite_frames != null and anim.sprite_frames.has_animation(_attack_anim_name):
		anim.sprite_frames.set_animation_loop(_attack_anim_name, false)
		anim.play(_attack_anim_name)
		anim.frame = 0
	else:
		if _on_hit_cb.is_valid():
			_on_hit_cb.call()
		else:
			_do_attack_hit()
		_is_attacking = false
		_cooldown_timer = _attack_total_cd

func play_heal_anim(aim_dir: Vector2, hit_frame: int, on_apply: Callable) -> void:
	play_cast_anim(aim_dir, hit_frame, on_apply)

func play_cast_anim(aim_dir: Vector2, hit_frame: int, on_apply: Callable) -> void:
	if _is_casting:
		return
	_is_casting = true
	_on_cast_cb = on_apply if on_apply.is_valid() else Callable()
	_pending_cast_hit_frame = hit_frame
	_set_facing_from_vector(aim_dir)
	_cast_anim_name = _compose_anim(anim_cast_prefix)
	if anim != null and anim.sprite_frames != null and anim.sprite_frames.has_animation(_cast_anim_name):
		anim.sprite_frames.set_animation_loop(_cast_anim_name, false)
		anim.play(_cast_anim_name)
		anim.frame = 0
	else:
		if _on_cast_cb.is_valid():
			_on_cast_cb.call()
		_on_cast_cb = Callable()
		_is_casting = false

# ---------------- Attack (legacy EnemyBase path) ----------------
func _start_attack() -> void:
	if _is_attacking:
		return
	if _cooldown_timer > 0.0:
		return
	if _target == null or _target == self:
		return
	_is_attacking = true
	_attack_pending = true
	_on_hit_cb = Callable()
	_attack_seq += 1
	_current_attack_id = _attack_seq
	_attack_anim_name = _compose_anim(anim_attack_prefix)
	_post_cooldown = _attack_total_cd
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
				var remain: float = _attack_total_cd - clip
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
			_cooldown_timer = _attack_total_cd
	else:
		_do_attack_hit()
		_is_attacking = false
		_cooldown_timer = _attack_total_cd

func _do_attack_hit() -> void:
	if _target == null or not is_instance_valid(_target):
		return
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
	if t_stats == stats:
		if debug_prints:
			print("[EnemyBase] Prevented self-hit (t_stats == self.stats)")
		return
	var packet: Dictionary = {
		"amount": amt,
		"source": enemy_name,
		"is_crit": did_crit,
		"attack_id": _current_attack_id,
		"source_node_path": get_path()
	}
	t_stats.call("apply_damage_packet", packet)

# ---------------- Anim events ----------------
func _on_anim_frame_changed() -> void:
	if anim == null:
		return
	if _is_attacking and anim.animation == _attack_anim_name and anim.frame == attack_hit_frame:
		if _attack_pending:
			_attack_pending = false
			if _on_hit_cb.is_valid():
				_on_hit_cb.call()
			else:
				_do_attack_hit()

func _on_cast_frame_changed() -> void:
	if anim == null:
		return
	if not _is_casting:
		return
	if anim.animation != _cast_anim_name:
		return
	if anim.frame != _pending_cast_hit_frame:
		return
	if _on_cast_cb.is_valid():
		var cb: Callable = _on_cast_cb
		_on_cast_cb = Callable()
		cb.call()

func _on_anim_finished() -> void:
	if anim == null:
		return
	if _is_attacking and anim.animation == _attack_anim_name:
		_is_attacking = false
		_cooldown_timer = _post_cooldown
		_on_hit_cb = Callable()
		var idle_name: String = _compose_anim(anim_idle_prefix)
		anim.play(idle_name)
	elif _is_casting and anim.animation == _cast_anim_name:
		_is_casting = false
		_on_cast_cb = Callable()
		var idle_name2: String = _compose_anim(anim_idle_prefix)
		anim.play(idle_name2)

# ---------------- Damage relays ----------------
func _on_damage_taken(amount: float, dmg_type: String, source: String) -> void:
	emit_signal("damaged", self, amount, dmg_type, source)

func _on_died() -> void:
	emit_signal("died", self)
	_spawn_death_vfx()
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
	if anim == null:
		return
	# Do not override active action/cast animations or external locks
	if is_action_locked():
		return
	if _is_attacking or _is_casting:
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
		var v: Variant = attacker_stats.call("get_final_stat", "Attack")
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
		var v: Variant = attacker_stats.call("get_final_stat", "CritChance")
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			cc = float(v)
	if cc > 1.0:
		cc *= 0.01
	cc = clampf(cc, 0.0, 0.95)
	return _rng.randf() < cc

# ---------------- VFX helpers ----------------
func _resolve_death_frames() -> SpriteFrames:
	if death_vfx_frames != null:
		return death_vfx_frames
	if death_vfx_frames_path != "":
		var res: Resource = load(death_vfx_frames_path)
		if res is SpriteFrames:
			return res as SpriteFrames
	return null

func _spawn_death_vfx() -> void:
	var frames: SpriteFrames = _resolve_death_frames()
	if frames == null:
		return
	var frames_copy: SpriteFrames = frames.duplicate() as SpriteFrames
	var vfx_spr: AnimatedSprite2D = AnimatedSprite2D.new()
	vfx_spr.sprite_frames = frames_copy
	var vfx_anim: String = death_vfx_anim
	if vfx_spr.sprite_frames != null and not vfx_spr.sprite_frames.has_animation(vfx_anim):
		var vfx_names: PackedStringArray = vfx_spr.sprite_frames.get_animation_names()
		if vfx_names.size() > 0:
			vfx_anim = String(vfx_names[0])
	vfx_spr.sprite_frames.set_animation_loop(vfx_anim, false)
	vfx_spr.modulate = Color(1.0, 1.0, 1.0, 0.6)
	vfx_spr.animation = vfx_anim
	vfx_spr.play(vfx_anim)
	vfx_spr.scale = Vector2(death_vfx_scale, death_vfx_scale)
	var anchor_pos: Vector2 = global_position
	if anim != null and is_instance_valid(anim):
		anchor_pos = anim.global_position
	var vfx_parent: Node = get_tree().current_scene
	if vfx_parent == null:
		vfx_parent = get_tree().root
	vfx_parent.add_child(vfx_spr)
	vfx_spr.global_position = anchor_pos + death_vfx_offset

	# IMPORTANT: connect cleanup directly to the VFX node so it survives enemy free()
	if vfx_spr.has_signal("animation_finished"):
		var free_cb: Callable = Callable(vfx_spr, "queue_free")
		vfx_spr.animation_finished.connect(free_cb)

	if death_vfx_lifetime_sec > 0.0:
		var t: SceneTreeTimer = get_tree().create_timer(death_vfx_lifetime_sec)
		var t_cb: Callable = Callable(vfx_spr, "queue_free")
		t.timeout.connect(t_cb)

func _on_death_vfx_anim_finished(vfx_spr: AnimatedSprite2D) -> void:
	if is_instance_valid(vfx_spr):
		vfx_spr.queue_free()

func _on_death_vfx_timer_timeout(vfx_spr: AnimatedSprite2D) -> void:
	if is_instance_valid(vfx_spr):
		vfx_spr.queue_free()

# ---------------- Utils ----------------
func _resolve_known_abilities_node() -> Node:
	var n: Node = get_node_or_null("KnownAbilities")
	if n != null:
		return n
	var found: Node = find_child("KnownAbilities", true, false)
	if found != null:
		return found
	var alt: Node = get_node_or_null("KnownAbilitiesComponent")
	if alt != null:
		return alt
	return null

func _compute_has_melee_in_kit() -> bool:
	var kac: Node = _resolve_known_abilities_node()
	if kac == null:
		# No KnownAbilities component found: assume melee-capable to avoid
		# accidentally flipping everything into ranged kiting.
		return true

	var ids: PackedStringArray = PackedStringArray()

	# Prefer component API if present (KnownAbilitiesComponent.get_all()).
	if kac.has_method("get_all"):
		var all_any: Variant = kac.call("get_all")
		if typeof(all_any) == TYPE_PACKED_STRING_ARRAY:
			ids = all_any

	# Fallback to direct exported property if still empty.
	if ids.is_empty() and "known_abilities" in kac:
		var arr_any: Variant = kac.get("known_abilities")
		if typeof(arr_any) == TYPE_PACKED_STRING_ARRAY:
			ids = arr_any

	if ids.is_empty():
		# No abilities configured; treat as melee-capable by default.
		return true

	# Try to resolve via AbilitySystem and read ability_type.
	var asys: Node = _abilitysys
	if asys == null:
		asys = get_node_or_null("/root/AbilitySys")
		_abilitysys = asys

	if asys != null and asys.has_method("_resolve_ability_def"):
		var i: int = 0
		while i < ids.size():
			var ability_id: String = ids[i]
			if ability_id != "":
				var def_any: Variant = asys.call("_resolve_ability_def", ability_id)
				if def_any is Resource:
					var r: Resource = def_any
					if "ability_type" in r:
						var at_any: Variant = r.get("ability_type")
						if typeof(at_any) == TYPE_STRING:
							var t: String = String(at_any)
							if t != "":
								t = t.strip_edges().to_upper()
								if t == "MELEE":
									# Any MELEE ability in the kit is enough
									# to mark this enemy as melee-capable.
									return true
			i += 1
		# If we get here, no MELEE-type ability defs were found.
		# Fall through to legacy heuristic.

	# Legacy fallback: treat "attack" ability as melee indicator.
	if ids.has("attack"):
		return true

	# No melee-like abilities found; treat as ranged-only kit.
	return false

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var by_name: Node = root.find_child("StatsComponent", true, false)
	if by_name != null:
		return by_name
	if root.has_method("apply_damage_packet"):
		return root
	return null

# ---------------- Collision helpers ----------------
func _mask_from_bits(bits: PackedInt32Array) -> int:
	var mask: int = 0
	var i: int = 0
	while i < bits.size():
		var b: int = bits[i]
		if b >= 1 and b <= 32:
			mask |= 1 << (b - 1)
		i += 1
	return mask

func _configure_as_enemy(body: CollisionObject2D) -> void:
	if body == null:
		return
	body.collision_layer = _mask_from_bits(PackedInt32Array([LBIT_ENEMY]))
	body.collision_mask = _mask_from_bits(PackedInt32Array([LBIT_WORLD]))
	if debug_prints:
		print("[EnemyBase] collision_layer=", body.collision_layer, " collision_mask=", body.collision_mask)
