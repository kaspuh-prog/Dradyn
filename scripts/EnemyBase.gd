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

# Animation names
@export var anim_idle_prefix: String = "idle"
@export var anim_walk_prefix: String = "walk"

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

# Targeting mode (party-wide)
enum TargetMode { SMART, NEAREST }
@export var target_mode: int = TargetMode.SMART

# Ranged spacing (active when no melee in kit)
@export var ranged_hold_min_px: float = 72.0
@export var ranged_hold_max_px: float = 160.0

# Melee spacing (for melee enemies; avoids overlapping the target)
@export var melee_hold_min_px: float = 14.0
@export var melee_hold_max_px: float = 26.0

# Threat system config
@export var initial_threat: float = 10.0

# Threat tuning coefficients (relative ordering: HEAL > direct > HOT > DOT > DEBUFF; PROJECTILE lowest)
@export var threat_damage_coeff: float = 1.0      # direct damage (melee/basic/DAMAGE_SPELL)
@export var threat_dot_coeff: float = 0.5         # DOT_SPELL
@export var threat_heal_coeff: float = 1.5        # HEAL_SPELL
@export var threat_hot_coeff: float = 0.75        # HOT_SPELL
@export var threat_projectile_coeff: float = 0.25 # PROJECTILE attacks (ranged) – lowest damage threat
@export var threat_debuff_flat: float = 5.0       # flat threat for debuffs (used from StatusConditions later)

# Knockback receiver (for AbilityExecutor knockback)
@export var allow_knockback: bool = true
@export var knockback_locks_actions: bool = true

# --- External motion (generic: conveyors, wind, currents, etc.) --------------
# Contributors provide velocities in px/s while active.
# Enemies generally should not "resist" environmental motion; keep this at 0 unless desired.
@export var external_resist: float = 0.0 # 0 = no resist; 1 = fully cancel external when self-moving
@export var external_resist_dot_threshold: float = -0.15

var _external_vel_by_id: Dictionary = {} # Dictionary[StringName, Vector2]

# --- Signals ---
signal damaged(enemy: EnemyBase, amount: float, dmg_type: String, source: String)
signal died(enemy: EnemyBase)

# --- Runtime ---
var _threat: Dictionary = {}        # Node2D -> float
var _in_combat: bool = false

var _target: Node2D = null
var _party_mgr: Node = null
var _abilitysys: Node = null
var _known_abilities_node: Node = null   # child "KnownAbilities" component
var _has_melee_in_kit_flag: bool = true  # computed at ready

enum Facing { DOWN, UP, SIDE }
var _facing: int = Facing.DOWN
var _facing_left: bool = false

# RNG (smart targeting tiebreakers)
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# time-based action lock for ability-driven animations
var _action_anim_until_msec: int = 0

# Knockback runtime
var _knockback_until_msec: int = 0
var _knockback_velocity: Vector2 = Vector2.ZERO


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

	if stats == null:
		push_warning("[EnemyBase] StatsComponent missing under " + name)
	else:
		if stats.has_signal("died") and not stats.is_connected("died", Callable(self, "_on_died")):
			stats.connect("died", Callable(self, "_on_died"))
		if stats.has_signal("damage_taken") and not stats.is_connected("damage_taken", Callable(self, "_on_damage_taken")):
			stats.connect("damage_taken", Callable(self, "_on_damage_taken"))
		# Threat-aware damage signal from this enemy's StatsComponent
		if stats.has_signal("damage_threat") and not stats.is_connected("damage_threat", Callable(self, "_on_damage_threat")):
			stats.connect("damage_threat", Callable(self, "_on_damage_threat"))

	get_tree().call_group("DamageNumberSpawners", "register_emitter", stats, sprite_anchor)

	if anim != null:
		if not anim.is_connected("animation_finished", Callable(self, "_on_anim_finished")):
			anim.connect("animation_finished", Callable(self, "_on_anim_finished"))

	_party_mgr = get_tree().get_first_node_in_group("PartyManager")
	_abilitysys = get_node_or_null("/root/AbilitySys")
	_known_abilities_node = _resolve_known_abilities_node()
	_has_melee_in_kit_flag = _compute_has_melee_in_kit()

	# Listen to party healing for HEAL_SPELL / HOT_SPELL threat
	_connect_party_heal_threat_listeners()


func _physics_process(delta: float) -> void:
	_acquire_target()

	if _is_knockback_active():
		_run_knockback(delta)
	else:
		_run_ai(delta)

	_update_anim()

# --- External motion API ------------------------------------------------------

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

# ---------------- Knockback receiver ----------------
# AbilityExecutor expects: apply_knockback(dir: Vector2, speed: float, duration: float)
func apply_knockback(dir: Vector2, speed: float, duration: float) -> void:
	if not allow_knockback:
		return

	var d: Vector2 = dir
	if d.length_squared() < 0.000001:
		# Fallback: push away from current target if we can, otherwise do nothing.
		var t: Node2D = _target
		if t != null and is_instance_valid(t):
			d = global_position - t.global_position
		else:
			return

	if d.length_squared() < 0.000001:
		return

	var s: float = speed
	if s < 0.0:
		s = 0.0

	var dur: float = duration
	if dur < 0.0:
		dur = 0.0

	var nd: Vector2 = d.normalized()
	_knockback_velocity = nd * s

	var now: int = Time.get_ticks_msec()
	var ms: int = int(dur * 1000.0)
	if ms < 1:
		# If duration is ~0, still apply a single physics tick worth of push.
		ms = 1

	_knockback_until_msec = now + ms

	if knockback_locks_actions:
		lock_action_for(ms)


func _is_knockback_active() -> bool:
	if Time.get_ticks_msec() < _knockback_until_msec:
		return true
	return false


func _run_knockback(_delta: float) -> void:
	# During knockback, we do not let AI overwrite velocity.
	# External motion still applies (wind/conveyors can move a knocked enemy too).
	var ext: Vector2 = _compute_external_velocity(_knockback_velocity)
	velocity = _knockback_velocity + ext
	move_and_slide()

	# If the timer has expired, clear residual velocity so we don't drift.
	if not _is_knockback_active():
		_knockback_velocity = Vector2.ZERO
		velocity = Vector2.ZERO

# ---------------- AbilitySystem integration ----------------

func is_action_locked() -> bool:
	# EnemyBase no longer owns attack/cast animations; AbilityExecutor / AnimationBridge
	# will call lock_action / lock_action_for during ability usage.
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

# ---------------- Targeting ----------------

func _acquire_target() -> void:
	# Threat-aware targeting
	_prune_threat_table()

	# If we already have threat information, prefer the highest-threat valid target.
	if _threat.size() > 0:
		_refresh_primary_target_from_threat()

	# If threat did not yield a valid target, fall back to zero-threat rules (SMART/NEAREST).
	if _target == null or not is_instance_valid(_target) or not _candidate_is_attackable(_target):
		var candidates: Array = _gather_party_candidates()
		if candidates.is_empty():
			_target = null
			_update_in_combat_state()
			return

		var in_range: Array = []
		var r2: float = detection_radius * detection_radius

		for n in candidates:
			if n == null or not is_instance_valid(n):
				continue
			var n2d: Node2D = n as Node2D
			if n2d == null:
				continue
			if not _candidate_is_attackable(n2d):
				continue
			var d2: float = (n2d.global_position - global_position).length_squared()
			if d2 <= r2:
				in_range.append(n2d)

		if in_range.is_empty():
			_target = null
			_update_in_combat_state()
			return

		var chosen: Node2D = null
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

		# Seed initial threat for the chosen target, so subsequent threat-based
		# updates can take over.
		if _target != null and not _threat.has(_target) and initial_threat > 0.0:
			_threat[_target] = initial_threat

	_update_in_combat_state()


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
	# Require a stats/damage interface AND verify the target is alive.
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
		var n2d: Node2D = n as Node2D
		if n2d == null:
			continue
		var ratio: float = 1.0
		var st: Node = _find_stats_component(n2d)
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
		ratios[n2d] = ratio
		d2map[n2d] = (n2d.global_position - global_position).length_squared()
		if ratio < min_ratio:
			min_ratio = ratio

	var near_hp: Array = []
	for n2 in cands:
		var n2d2: Node2D = n2 as Node2D
		if n2d2 == null:
			continue
		if not ratios.has(n2d2):
			continue
		var r: float = float(ratios[n2d2])
		if r <= min_ratio + hp_tie_epsilon + 1e-6:
			near_hp.append(n2d2)

	if near_hp.is_empty():
		return null

	var min_d2: float = INF
	for n3 in near_hp:
		var n3d: Node2D = n3 as Node2D
		if n3d == null:
			continue
		var d2_n: float = float(d2map[n3d])
		if d2_n < min_d2:
			min_d2 = d2_n

	var near_dist: Array = []
	var eps_d2: float = dist_tie_epsilon_px * dist_tie_epsilon_px
	for n4 in near_hp:
		var n4d: Node2D = n4 as Node2D
		if n4d == null:
			continue
		var d2_n2: float = float(d2map[n4d])
		if d2_n2 <= min_d2 + eps_d2:
			near_dist.append(n4d)

	if near_dist.size() > 1 and randomize_tie_choice:
		var idx: int = _rng.randi_range(0, near_dist.size() - 1)
		return near_dist[idx] as Node2D

	return near_dist[0] as Node2D

# ---------------- Threat API & queries ----------------

func add_threat(actor: Node2D, amount: float, source_type: StringName) -> void:
	if actor == null or not is_instance_valid(actor):
		return
	if amount <= 0.0:
		return
	var current: float = 0.0
	if _threat.has(actor):
		var existing: Variant = _threat.get(actor, 0.0)
		if typeof(existing) == TYPE_INT or typeof(existing) == TYPE_FLOAT:
			current = float(existing)
	var value: float = current + amount
	_threat[actor] = value
	_refresh_primary_target_from_threat()


func add_flat_threat(actor: Node2D, amount: float, source_type: StringName) -> void:
	add_threat(actor, amount, source_type)


func clear_threat_for(actor: Node2D) -> void:
	if actor == null:
		return
	if _threat.has(actor):
		_threat.erase(actor)
	if _target == actor:
		_target = null
	_update_in_combat_state()


func get_primary_target() -> Node2D:
	return _target


func has_primary_target() -> bool:
	var t: Node2D = _target
	if t == null or not is_instance_valid(t):
		return false
	if not _candidate_is_attackable(t):
		return false
	return true


func is_in_melee_band(range_px: float) -> bool:
	var t: Node2D = get_primary_target()
	if t == null:
		return false
	var dist: float = (t.global_position - global_position).length()
	return dist <= range_px


func is_in_ranged_band(min_px: float, max_px: float) -> bool:
	var t: Node2D = get_primary_target()
	if t == null:
		return false
	var dist: float = (t.global_position - global_position).length()
	if dist < min_px:
		return false
	if dist > max_px:
		return false
	return true


func is_in_combat() -> bool:
	return _in_combat


func _prune_threat_table() -> void:
	if _threat.is_empty():
		return
	var to_erase: Array = []
	for k in _threat.keys():
		var n: Node2D = k as Node2D
		if n == null or not is_instance_valid(n):
			to_erase.append(k)
			continue
		if not _candidate_is_attackable(n):
			to_erase.append(k)
	for rem in to_erase:
		_threat.erase(rem)


func _refresh_primary_target_from_threat() -> void:
	if _threat.is_empty():
		return
	var best: Node2D = null
	var best_threat: float = -INF
	var r2: float = detection_radius * detection_radius
	for k in _threat.keys():
		var n: Node2D = k as Node2D
		if n == null or not is_instance_valid(n):
			continue
		if not _candidate_is_attackable(n):
			continue
		var d2: float = (n.global_position - global_position).length_squared()
		if d2 > r2:
			continue
		var v: Variant = _threat.get(n, 0.0)
		var tval: float = 0.0
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			tval = float(v)
		if tval > best_threat:
			best_threat = tval
			best = n
	_target = best


func _update_in_combat_state() -> void:
	var t: Node2D = _target
	if t == null or not is_instance_valid(t):
		_in_combat = false
		return
	if not _candidate_is_attackable(t):
		_in_combat = false
		return
	var max_dist: float = detection_radius + 32.0
	var d2: float = (t.global_position - global_position).length_squared()
	_in_combat = d2 <= max_dist * max_dist

# ---------------- AI (movement only; attacks are via AbilitySystem) ----------------

func _run_ai(_delta: float) -> void:
	var ms: float = 90.0
	if stats != null and stats.has_method("get_final_stat"):
		var val: Variant = stats.call("get_final_stat", "MoveSpeed")
		if typeof(val) == TYPE_INT or typeof(val) == TYPE_FLOAT:
			var f: float = float(val)
			if f > 0.0:
				ms = f

	# Respect external animation locks (ability casts / projectiles)
	# BUT still allow external motion (conveyors/wind) to move the enemy.
	if is_action_locked():
		var ext_only: Vector2 = _compute_external_velocity(Vector2.ZERO)
		velocity = ext_only
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

			var desired_self: Vector2 = dir * ms
			var ext: Vector2 = _compute_external_velocity(desired_self)

			velocity = desired_self + ext
			move_and_slide()

			# Facing: only update from movement to avoid fighting with AnimationBridge
			if desired_self.length() > 1.0:
				_set_facing_from_vector(desired_self)
	else:
		var ext_idle: Vector2 = _compute_external_velocity(Vector2.ZERO)
		velocity = ext_idle
		move_and_slide()

# ---------------- Threat handlers ----------------

# Damage-based threat from this enemy's StatsComponent (damage_threat signal)
func _on_damage_threat(amount: float, dmg_type: String, source_node: Node, ability_id: String, ability_type: String) -> void:
	if source_node == null or not is_instance_valid(source_node):
		return

	# Only generate threat from party actors, not other enemies.
	if not source_node.is_in_group("PartyMembers"):
		return

	# Normalize ability_type to decide DOT vs direct / projectile / other.
	var atype: String = String(ability_type).strip_edges().to_upper()
	var threat_amount: float = 0.0

	if atype == "DOT_SPELL":
		threat_amount = amount * threat_dot_coeff
	elif atype == "PROJECTILE":
		# Ranged projectiles intentionally generate the least threat among damage sources.
		threat_amount = amount * threat_projectile_coeff
	else:
		# Everything else (melee/basic/DAMAGE_SPELL/etc.) uses the direct damage coeff.
		threat_amount = amount * threat_damage_coeff

	if threat_amount <= 0.0:
		return

	# Prefer to treat the source_node itself as the actor if it is a Node2D.
	if source_node is Node2D:
		add_threat(source_node as Node2D, threat_amount, "damage")
	else:
		# Fallback: try parent as a Node2D (covers cases where StatsComponent is the source)
		var parent: Node = source_node.get_parent()
		if parent is Node2D:
			add_threat(parent as Node2D, threat_amount, "damage")


# Connect to party StatsComponents' heal_threat signals
func _connect_party_heal_threat_listeners() -> void:
	# We want to listen to heals done by party actors, so that any enemy in combat
	# can add threat to the healer (HEAL_SPELL / HOT_SPELL).
	var party_nodes: Array = []

	if _party_mgr != null and _party_mgr.has_method("get_members"):
		var arr_any: Variant = _party_mgr.call("get_members")
		if typeof(arr_any) == TYPE_ARRAY:
			var arr: Array = arr_any
			for n in arr:
				if n is Node:
					party_nodes.append(n)
	else:
		var list: Array = get_tree().get_nodes_in_group("PartyMembers")
		for n2 in list:
			if n2 is Node:
				party_nodes.append(n2)

	for actor in party_nodes:
		var actor_node: Node = actor
		if actor_node == null or not is_instance_valid(actor_node):
			continue
		var sc: Node = actor_node.find_child("StatsComponent", true, false)
		if sc == null:
			continue
		if sc.has_signal("heal_threat") and not sc.is_connected("heal_threat", Callable(self, "_on_party_heal_threat")):
			sc.connect("heal_threat", Callable(self, "_on_party_heal_threat"))


# Healing-based threat from party StatsComponents (heal_threat signal)
func _on_party_heal_threat(amount: float, healer_node: Node, ability_id: String, ability_type: String) -> void:
	# Only apply healing threat to enemies that are already in combat with the party.
	if not is_in_combat():
		return

	if healer_node == null or not is_instance_valid(healer_node):
		return

	if not healer_node.is_in_group("PartyMembers"):
		return

	var atype: String = String(ability_type).strip_edges().to_upper()
	var threat_amount: float = 0.0

	if atype == "HEAL_SPELL":
		threat_amount = amount * threat_heal_coeff
	elif atype == "HOT_SPELL":
		threat_amount = amount * threat_hot_coeff
	else:
		# Non-healing abilities should not create heal threat here.
		return

	if threat_amount <= 0.0:
		return

	if healer_node is Node2D:
		add_threat(healer_node as Node2D, threat_amount, "heal")
	else:
		var parent: Node = healer_node.get_parent()
		if parent is Node2D:
			add_threat(parent as Node2D, threat_amount, "heal")


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
	# Do not override while an ability-driven lock is active
	if is_action_locked():
		return
	var next_name: String = ""
	if velocity.length() > 1.0:
		next_name = _compose_anim(anim_walk_prefix)
	else:
		next_name = _compose_anim(anim_idle_prefix)
	if anim.animation != next_name or not anim.is_playing():
		anim.play(next_name)


func _on_anim_finished() -> void:
	# For future use if we ever wire AnimationBridge back through AnimatedSprite2D.
	pass

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
