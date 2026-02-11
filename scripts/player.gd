extends CharacterBody2D

# --- References ---
@onready var stats: Node = $StatsComponent
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

# --- Debug ---
@export var debug_log: bool = false

# --- Config / Exports ---
@export var is_leader: bool = false : set = _set_is_leader, get = _get_is_leader
@export var sprint_mul: float = 1.5
@export var end_cost_per_second: float = 0.5
@export var sprint_step_cost: float = 0.08
@export var accel_lerp: float = 0.18
@export var resume_sprint_end: float = 1.0

# Hotbar provider path (optional override). Default is the autoload: /root/HotbarSys.
@export var hotbar_provider_path: NodePath

# Movement
@export var base_move_speed: float = 86.0

# Targeting
@export var target_pick_radius: float = 96.0
var _current_target: Node = null

# Anim profile: side-only left/right (walk_side/idle_side) with flip for left
@export var use_side_anims: bool = false

# --- Interaction ---
@export var interact_action_name: String = "interact"
@export var interact_cooldown_ms: int = 160
var _can_interact_at_msec: int = 0

# --- External motion (generic: conveyors, wind, currents, etc.) --------------
# Contributors provide velocities in px/s for this frame (or continuously while in an area).
# Movers can fight against it if desired.
@export var external_resist_when_inputting: float = 0.5 # 0 = no resist, 1 = fully cancel external when moving
@export var external_resist_dot_threshold: float = -0.15 # resist applies mostly when input opposes external (dot < threshold)

var _external_vel_by_id: Dictionary = {} # Dictionary[StringName, Vector2]

# State
var _controlled: bool = false
var _is_sprinting: bool = false
var _last_move_dir: Vector2 = Vector2.ZERO

# Action animation lock
var _action_anim_until_msec: int = 0
var _pending_hit_frame: int = -1
var _pending_hit_callable: Callable = Callable()

# Legacy fallback
@export var legacy_attack_cooldown_sec: float = 0.5
var _legacy_can_attack_at_msec: int = 0
var _legacy_attack_anim: String = "attack1_down"

# Constants
const MOVE_DIR_THRESHOLD: float = 0.05
const HOTBAR_DEFAULT_SLOTS: int = 8

# --- Lifecycle ----------------------------------------------------------------

func _ready() -> void:
	set_physics_process(true)
	set_process_unhandled_input(true)

	if is_instance_valid(sprite):
		sprite.frame_changed.connect(Callable(self, "_on_sprite_frame_changed"))
		sprite.animation_finished.connect(Callable(self, "_on_sprite_animation_finished"))

	var party: Node = get_node_or_null("/root/Party")
	if party != null and party.has_signal("controlled_changed"):
		party.controlled_changed.connect(_on_controlled_changed)

	# Sync controlled on load
	_sync_controlled_from_party()

	# Proactively ensure HotbarSys is bound to Hotbar if both exist
	call_deferred("_ensure_hotbar_bound")

	call_deferred("_join_party")

	if is_instance_valid(stats) and stats.has_signal("healed"):
		stats.healed.connect(_on_self_healed)

func _unhandled_input(event: InputEvent) -> void:
	if not _controlled:
		return

	# Interact-first on E or action
	if _is_interact_press(event):
		if debug_log:
			_printd("[PLAYER] interact-press detected")
		if _try_interact_now():
			if debug_log:
				_printd("[PLAYER] interact consumed input")
			return
		else:
			if debug_log:
				_printd("[PLAYER] no interact target; falling through to hotbar")

	var idx: int = _hotbar_index_from_event(event)
	if idx != -1:
		if debug_log:
			_printd("[PLAYER] hotbar index resolved=", str(idx))
		_try_hotbar(idx)
		return

func _physics_process(delta: float) -> void:
	var dir: Vector2 = Vector2.ZERO
	var dead_now: bool = _is_dead()

	if _controlled:
		if dead_now:
			_is_sprinting = false
			velocity = velocity.lerp(Vector2.ZERO, clamp(accel_lerp, 0.0, 1.0))
			move_and_slide()
		else:
			dir = _read_move_dir()
			_is_sprinting = _should_sprint(dir)

			var speed: float = base_move_speed
			if _is_sprinting:
				speed = base_move_speed * sprint_mul
				_spend_endurance_tick(delta)

			var desired_self: Vector2 = dir * speed
			var ext: Vector2 = _compute_external_velocity(desired_self)

			# Lerp only the self-driven portion for nice controls; then add external directly.
			var self_vel: Vector2 = velocity.lerp(desired_self, clamp(accel_lerp, 0.0, 1.0))
			velocity = self_vel + ext
			move_and_slide()
	else:
		if velocity.length() > MOVE_DIR_THRESHOLD:
			dir = velocity.normalized()
		else:
			dir = Vector2.ZERO

	if not dead_now:
		_set_move_anim(dir)

	if dir.length() > 0.0:
		_last_move_dir = dir

	_pick_target_if_none()

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

	# Optional resistance when the player is actively inputting.
	# Only applies primarily when input is opposing the external velocity (negative dot).
	if external_resist_when_inputting <= 0.0:
		return ext

	if desired_self.length() <= 0.01:
		return ext

	var a: Vector2 = desired_self.normalized()
	var b: Vector2 = ext.normalized()
	var d: float = a.dot(b)

	if d < external_resist_dot_threshold:
		var t: float = clamp(external_resist_when_inputting, 0.0, 1.0)
		return ext * (1.0 - t)

	return ext

# --- Interaction helpers -----------------------------------------------------

func _is_interact_press(event: InputEvent) -> bool:
	if interact_action_name != "" and InputMap.has_action(interact_action_name):
		if event.is_action_pressed(interact_action_name):
			return true
	var k: InputEventKey = event as InputEventKey
	if k != null and k.pressed and not k.echo:
		if k.keycode == KEY_E:
			return true
	return false

func _try_interact_now() -> bool:
	var now: int = Time.get_ticks_msec()
	if now < _can_interact_at_msec:
		return false

	var sys: Node = _resolve_interaction_sys()
	if sys == null:
		return false
	if not sys.has_method("find_best_target"):
		return false
	if not sys.has_method("try_interact_from"):
		return false

	var facing: Vector2 = Vector2.ZERO
	var target: Node = null
	var v: Variant = sys.call("find_best_target", self, facing)
	if v is Node:
		target = v as Node
	if target == null:
		return false

	var ok_any: Variant = sys.call("try_interact_from", self, facing)
	var ok: bool = false
	if typeof(ok_any) == TYPE_BOOL:
		ok = bool(ok_any)
	if ok:
		_can_interact_at_msec = now + max(0, interact_cooldown_ms)
		var vp: Viewport = get_viewport()
		if vp != null:
			vp.set_input_as_handled()
		return true
	return false

func _resolve_interaction_sys() -> Node:
	var root: Viewport = get_tree().root
	if root == null:
		return null
	var n: Node = root.get_node_or_null("InteractionSys")
	if n != null:
		return n
	return root.get_node_or_null("InteractionSystem")

# --- Hotbar provider + binding ------------------------------------------------

func _hotbar_provider() -> Node:
	# 1) explicit path if assigned
	if hotbar_provider_path != NodePath():
		var n: Node = get_node_or_null(hotbar_provider_path)
		if n != null:
			return n

	# 2) project autoload node (confirmed in project.godot)
	var root: Viewport = get_tree().root
	if root == null:
		return null
	var sys: Node = root.get_node_or_null("HotbarSys")
	if sys != null:
		return sys

	# 3) legacy fallback
	return root.get_node_or_null("HotbarSystem")

func _find_hotbar_node() -> Node:
	# Find the Hotbar scene instance (class_name Hotbar) or a node with the 3 signals.
	var root: Node = get_tree().root
	if root == null:
		return null
	var queue: Array[Node] = [root]
	while queue.size() > 0:
		var n: Node = queue.pop_front()
		if n == null:
			continue
		# Best: class_name
		if n.get_class() == "Hotbar":
			return n
		# Fallback: signal signature
		var has_assign: bool = n.has_signal("slot_assigned")
		var has_clear: bool = n.has_signal("slot_cleared")
		var has_trig: bool = n.has_signal("slot_triggered")
		if has_assign and has_clear and has_trig:
			return n
		for c in n.get_children():
			queue.push_back(c)
	return null

func _ensure_hotbar_bound() -> void:
	var provider: Node = _hotbar_provider()
	if provider == null:
		return
	if not provider.has_method("bind_to_hotbar"):
		return
	var hb: Node = _find_hotbar_node()
	if hb == null:
		return
	# Bind and let the autoload rebuild its internal model from Hotbar signals
	provider.call("bind_to_hotbar", hb)
	if debug_log:
		_printd("[PLAYER] ensured HotbarSys bound to ", hb.get_path())

func _get_hotbar_ability_at(index: int) -> String:
	var provider: Node = _hotbar_provider()
	if provider == null:
		return ""
	if not provider.has_method("get_ability_id_at"):
		return ""
	# First read
	var v0: Variant = provider.call("get_ability_id_at", index)
	if typeof(v0) == TYPE_STRING:
		var s0: String = String(v0)
		if s0 != "":
			return s0
	# If empty, force-bind and retry once
	_ensure_hotbar_bound()
	var v1: Variant = provider.call("get_ability_id_at", index)
	if typeof(v1) == TYPE_STRING:
		return String(v1)
	return ""

func _get_hotbar_slot_count() -> int:
	var provider: Node = _hotbar_provider()
	if provider != null and provider.has_method("get_slot_count"):
		var v: Variant = provider.call("get_slot_count")
		if typeof(v) == TYPE_INT:
			return int(v)
	return HOTBAR_DEFAULT_SLOTS

# --- Ability routing ----------------------------------------------------------

func _pick_heal_target_or_self() -> Node:
	if has_method("_pick_ally_target"):
		var t: Variant = call("_pick_ally_target")
		if t != null and t is Node:
			return t as Node
	return self

func _try_hotbar(index: int) -> void:
	if index < 0:
		return
	if index >= _get_hotbar_slot_count():
		return

	var ability_id: String = _get_hotbar_ability_at(index)
	if ability_id == "":
		if debug_log:
			_printd("[PLAYER] hotbar idx=", str(index), " empty after bind check")
		return

	if ability_id == "attack" and is_action_locked():
		if debug_log:
			_printd("[PLAYER] attack locked by action gate")
		return

	var ability_sys: Node = _ability_system()
	if ability_sys == null:
		if debug_log:
			_printd("[PLAYER] AbilitySys not found.")
		return

	var ctx: Dictionary = {}
	ctx["source"] = "player"

	# Prefer a concrete target for abilities that care about it.
	if _current_target != null and is_instance_valid(_current_target) and _current_target is Node2D:
		ctx["target"] = _current_target
		ctx["prefer"] = "target"

	# --- New: establish aim for melee / general abilities ---
	var aim: Vector2 = Vector2.ZERO

	if ability_id == "attack":
		# Melee: aim toward our current or nearest enemy so the swing cone points correctly.
		var tgt2d: Node2D = null
		if ctx.has("target"):
			var tv: Variant = ctx["target"]
			if tv is Node2D:
				tgt2d = tv as Node2D
		if tgt2d == null:
			var nearest: Node = _find_nearest_enemy()
			if nearest is Node2D:
				tgt2d = nearest as Node2D
		if tgt2d != null:
			aim = tgt2d.global_position - global_position

	# Fallback aim for any ability (including attack if no enemy is near)
	if aim == Vector2.ZERO:
		aim = _last_move_dir
	if aim == Vector2.ZERO and velocity.length() > MOVE_DIR_THRESHOLD:
		aim = velocity.normalized()
	if aim == Vector2.ZERO:
		aim = Vector2.DOWN

	ctx["aim_dir"] = aim

	if ability_id == "heal":
		var heal_tgt: Node = _pick_heal_target_or_self()
		ctx["manual_target"] = heal_tgt
		ctx["prefer"] = "target"
		ctx["target"] = heal_tgt

	if ability_id == "attack":
		ctx["use_gcd"] = false

	if debug_log:
		var msg: String = "[PLAYER] calling AbilitySys.request_cast id=" + ability_id + " idx=" + str(index) + " ctx=" + str(ctx)
		_printd(msg)

	var ok_any: Variant = ability_sys.call("request_cast", self, ability_id, ctx)
	var ok: bool = false
	if typeof(ok_any) == TYPE_BOOL:
		ok = bool(ok_any)

	if debug_log:
		if ok:
			_printd("[PLAYER] AbilitySys.request_cast accepted id=", ability_id)
		else:
			_printd("[PLAYER] AbilitySys.request_cast rejected id=", ability_id)

# --- AnimationBridge compatibility -------------------------------------------

func play_melee_attack(aim_dir: Vector2, hit_frame: int, on_hit: Callable) -> void:
	var bridge: Node = _animation_bridge()
	if bridge != null and bridge.has_method("play_melee_attack"):
		bridge.call("play_melee_attack", aim_dir, hit_frame, on_hit)
		return
	play_melee_attack_anim(aim_dir, hit_frame, on_hit)

func lock_action_for(ms: int) -> void:
	var now: int = Time.get_ticks_msec()
	var until: int = now + max(0, ms)
	if until > _action_anim_until_msec:
		_action_anim_until_msec = until

func lock_action(seconds: float) -> void:
	var ms: int = int(max(0.0, seconds) * 1000.0)
	lock_action_for(ms)

func unlock_action() -> void:
	_action_anim_until_msec = 0

func is_action_locked() -> bool:
	return Time.get_ticks_msec() < _action_anim_until_msec

# --- Legacy melee anim fallback ----------------------------------------------

func play_melee_attack_anim(aim_dir: Vector2, hit_frame: int, on_hit: Callable) -> void:
	if sprite == null:
		return
	lock_action_for(400)
	_pending_hit_frame = max(0, hit_frame)
	_pending_hit_callable = on_hit

	var use_side: bool = false
	if use_side_anims and sprite.sprite_frames != null:
		if sprite.sprite_frames.has_animation("attack1_side"):
			use_side = true

	var name: String = "attack1_down"
	if use_side:
		if absf(aim_dir.x) >= absf(aim_dir.y):
			name = "attack1_side"
			sprite.flip_h = aim_dir.x < 0.0
		else:
			if aim_dir.y >= 0.0:
				name = "attack1_down"
			else:
				name = "attack1_up"
			sprite.flip_h = false
	else:
		if absf(aim_dir.x) > absf(aim_dir.y):
			if aim_dir.x > 0.0:
				name = "attack1_right"
			else:
				name = "attack1_left"
		else:
			if aim_dir.y >= 0.0:
				name = "attack1_down"
			else:
				name = "attack1_up"

	if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(name):
		sprite.sprite_frames.set_animation_loop(name, false)
	sprite.frame = 0
	sprite.play(name)

# --- Input / Hotbar mapping ---------------------------------------------------

func _hotbar_index_from_event(event: InputEvent) -> int:
	if _action_pressed(event, "hb_e"):
		return 0
	if _action_pressed(event, "hb_r"):
		return 1
	if _action_pressed(event, "hb_f"):
		return 2
	if _action_pressed(event, "hb_c"):
		return 3
	if _action_pressed(event, "hb_se"):
		return 4
	if _action_pressed(event, "hb_sr"):
		return 5
	if _action_pressed(event, "hb_sf"):
		return 6
	if _action_pressed(event, "hb_sc"):
		return 7

	var k: InputEventKey = event as InputEventKey
	if k != null and k.pressed and not k.echo:
		var shift: bool = k.shift_pressed
		if k.keycode == KEY_E:
			if shift:
				return 4
			else:
				return 0
		if k.keycode == KEY_R:
			if shift:
				return 5
			else:
				return 1
		if k.keycode == KEY_F:
			if shift:
				return 6
			else:
				return 2
		if k.keycode == KEY_C:
			if shift:
				return 7
			else:
				return 3

	return -1

func _action_pressed(event: InputEvent, action_name: String) -> bool:
	if not InputMap.has_action(action_name):
		return false
	return event.is_action_pressed(action_name)

func _find_slot_with_ability(ability_id: String) -> int:
	var count: int = _get_hotbar_slot_count()
	var i: int = 0
	while i < count:
		if _get_hotbar_ability_at(i) == ability_id:
			return i
		i += 1
	return -1

# --- Movement helpers ---------------------------------------------------------

func _read_move_dir() -> Vector2:
	var x: float = 0.0
	var y: float = 0.0
	if Input.is_action_pressed("ui_left"):
		x -= 1.0
	if Input.is_action_pressed("ui_right"):
		x += 1.0
	if Input.is_action_pressed("ui_up"):
		y -= 1.0
	if Input.is_action_pressed("ui_down"):
		y += 1.0
	var v: Vector2 = Vector2(x, y)
	if v.length() > 1.0:
		v = v.normalized()
	return v

func _should_sprint(dir: Vector2) -> bool:
	if dir.length() <= 0.01:
		return false
	if stats == null:
		return Input.is_action_pressed("sprint")

	var cur: float = 0.0
	if "current_end" in stats:
		var v_any: Variant = stats.get("current_end")
		if typeof(v_any) == TYPE_FLOAT or typeof(v_any) == TYPE_INT:
			cur = float(v_any)
	else:
		if stats.has_method("current_end"):
			var v2_any: Variant = stats.call("current_end")
			if typeof(v2_any) == TYPE_FLOAT or typeof(v2_any) == TYPE_INT:
				cur = float(v2_any)

	if cur < resume_sprint_end:
		return false

	return Input.is_action_pressed("sprint")

func _spend_endurance_tick(delta: float) -> void:
	if stats == null:
		return
	if not stats.has_method("spend_end"):
		return
	var spend: float = end_cost_per_second * delta + sprint_step_cost
	stats.call("spend_end", spend)

# --- Targeting ---------------------------------------------------------------

func _pick_target_if_none() -> void:
	if _current_target != null and is_instance_valid(_current_target):
		return
	_current_target = _find_nearest_enemy()

func _find_nearest_enemy() -> Node:
	var world: World2D = get_world_2d()
	if world == null:
		return null
	var space: PhysicsDirectSpaceState2D = world.direct_space_state
	if space == null:
		return null
	var query: PhysicsPointQueryParameters2D = PhysicsPointQueryParameters2D.new()
	query.position = global_position
	query.collide_with_areas = true
	query.collide_with_bodies = true
	query.collision_mask = 0xFFFFFFFF
	var hits: Array = space.intersect_point(query, 32)
	var best: Node = null
	var best_d2: float = target_pick_radius * target_pick_radius
	for h in hits:
		var c: Object = h.get("collider")
		if c == null:
			continue
		if c == self:
			continue
		var n: Node = c as Node
		if not n.is_in_group("Enemy") and not n.is_in_group("Enemies"):
			continue
		var n2: Node2D = c as Node2D
		if n2 == null:
			continue
		var d2: float = n2.global_position.distance_squared_to(global_position)
		if d2 <= best_d2:
			best_d2 = d2
			best = n2
	return best

# --- Animations --------------------------------------------------------------

func _set_move_anim(dir: Vector2) -> void:
	if sprite == null:
		return
	if is_action_locked():
		return
	if _is_dead():
		return

	if dir.length() < MOVE_DIR_THRESHOLD:
		var idle_name: String = _idle_anim_name()
		if idle_name != "" and sprite.animation != idle_name:
			if sprite.sprite_frames != null and sprite.sprite_frames.has_animation(idle_name):
				sprite.play(idle_name)
		if use_side_anims:
			_apply_side_flip_for_idle()
		return

	var anim_name: String = _walk_anim_name(dir)
	if anim_name != "" and sprite.animation != anim_name:
		sprite.play(anim_name)

	if use_side_anims:
		_apply_side_flip_for_move(dir)

func _idle_anim_name() -> String:
	if use_side_anims:
		if absf(_last_move_dir.x) >= absf(_last_move_dir.y) and absf(_last_move_dir.x) > 0.01:
			return "idle_side"
		else:
			if _last_move_dir.y >= 0.0:
				return "idle_down"
			else:
				return "idle_up"
	if absf(_last_move_dir.x) > absf(_last_move_dir.y):
		if _last_move_dir.x > 0.0:
			return "idle_right"
		else:
			return "idle_left"
	else:
		if _last_move_dir.y >= 0.0:
			return "idle_down"
		else:
			return "idle_up"

func _walk_anim_name(dir: Vector2) -> String:
	if use_side_anims:
		if absf(dir.x) >= absf(dir.y):
			return "walk_side"
		else:
			if dir.y >= 0.0:
				return "walk_down"
			else:
				return "walk_up"
	if absf(dir.x) > absf(dir.y):
		if dir.x > 0.0:
			return "walk_right"
		else:
			return "walk_left"
	else:
		if dir.y >= 0.0:
			return "walk_down"
		else:
			return "walk_up"

func _apply_side_flip_for_move(dir: Vector2) -> void:
	if not is_instance_valid(sprite):
		return
	if absf(dir.x) >= absf(dir.y):
		if dir.x < 0.0:
			sprite.flip_h = true
		else:
			sprite.flip_h = false

func _apply_side_flip_for_idle() -> void:
	if not is_instance_valid(sprite):
		return
	if absf(_last_move_dir.x) > 0.01:
		if _last_move_dir.x < 0.0:
			sprite.flip_h = true
		else:
			sprite.flip_h = false

func _on_sprite_frame_changed() -> void:
	if _pending_hit_frame >= 0 and sprite != null and sprite.frame == _pending_hit_frame:
		if _pending_hit_callable.is_valid():
			_pending_hit_callable.call()
		_pending_hit_frame = -1
		_pending_hit_callable = Callable()

func _on_sprite_animation_finished() -> void:
	_action_anim_until_msec = 0

# --- Heal VFX bridge ---------------------------------------------------------

func _on_self_healed(amount: float, source: String, is_crit: bool) -> void:
	_spawn_heal_vfx_on(self, int(amount))

func _spawn_heal_vfx_on(target_root: Node, amount: int) -> void:
	if target_root == null:
		return
	# hook for heal VFX
	pass

# --- Party / Leader ----------------------------------------------------------

func _on_controlled_changed(actor: Node) -> void:
	_controlled = (actor == self)
	if debug_log:
		_printd("[PLAYER] controlled_changed -> controlled=", str(_controlled))

func _join_party() -> void:
	var pm: Node = get_node_or_null("/root/Party")
	if pm == null:
		return
	if pm.has_method("register_member"):
		pm.call("register_member", self, false)
	elif pm.has_method("add_member"):
		pm.call("add_member", self, false)

func _sync_controlled_from_party() -> void:
	var pm: Node = get_node_or_null("/root/Party")
	if pm == null:
		return
	if pm.has_method("get_controlled"):
		var cur_any: Variant = pm.call("get_controlled")
		if cur_any is Node:
			_controlled = (cur_any as Node) == self

var _leader: bool = false
func _set_is_leader(v: bool) -> void:
	_leader = v
func _get_is_leader() -> bool:
	return _leader

# --- Helpers -----------------------------------------------------------------

func _animation_bridge() -> Node:
	var n: Node = get_node_or_null("AnimationBridge")
	if n != null:
		return n
	for c in get_children():
		if c != null and c.has_method("play_melee_attack"):
			return c
	return null

func _ability_system() -> Node:
	var root: Viewport = get_tree().root
	if root == null:
		return null
	var n: Node = root.get_node_or_null("AbilitySys")
	if n == null:
		n = root.get_node_or_null("AbilitySystem")
	return n

# ---- Dead check (no recursion) ----
func _is_dead() -> bool:
	var sc: Node = get_node_or_null("StatusConditions")
	if sc != null and sc.has_method("is_dead"):
		var v: Variant = sc.call("is_dead")
		if typeof(v) == TYPE_BOOL and bool(v):
			return true

	if stats != null:
		if stats.has_method("get_hp"):
			var gh: Variant = stats.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true
		if stats.has_method("current_hp"):
			var ch: Variant = stats.call("current_hp")
			if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
				return true

	if "dead" in self:
		var df: Variant = get("dead")
		if typeof(df) == TYPE_BOOL and bool(df):
			return true

	return false

func is_dead() -> bool:
	return _is_dead()

# --- Debug helper -------------------------------------------------------------

func _printd(a: String, b: String = "", c: String = "", d: String = "", e: String = "", f: String = "") -> void:
	if not debug_log:
		return
	print(a, b, c, d, e, f)
