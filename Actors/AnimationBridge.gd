extends Node
class_name AnimationBridge
# Godot 4.5 — fully typed, no ternaries.

@export var sprite_path: NodePath = NodePath("../AnimatedSprite2D")
@export var supports_side_anims: bool = true

# --- Footsteps (centralized; walk* only; NO interval gating) ---
@export_group("Footsteps")
@export var enable_footsteps: bool = true
@export var footstep_anim_prefix: String = "walk"
@export var footstep_frames: Array[int] = [1, 5]
@export var footstep_min_speed: float = 10.0
@export var footstep_volume_db: float = -10.0
@export var footstep_use_distance_gate: bool = true
@export var footstep_min_distance_px: float = 8.0

# Default action prefixes (can be overridden per-call or at runtime)
@export var default_attack_prefix: String = "attack1"
@export var default_cast_prefix: String = "cast1"
@export var default_buff_prefix: String = "buff1"
@export var default_projectile_prefix: String = "projectile1"

# Base locomotion names (single side)
@export var anim_idle_side: String = "idle_side"
@export var anim_walk_side: String = "walk_side"

# Split left/right variants (optional; auto-detected if present)
@export var anim_idle_left: String = "idle_left"
@export var anim_idle_right: String = "idle_right"
@export var anim_walk_left: String = "walk_left"
@export var anim_walk_right: String = "walk_right"

# Vertical
@export var anim_idle_up: String = "idle_up"
@export var anim_idle_down: String = "idle_down"
@export var anim_walk_up: String = "walk_up"
@export var anim_walk_down: String = "walk_down"

# VFX
@export var revive_frames_path: String = "res://assets/VFX/BlessingofLife.tres"

# Revive sizing controls
@export var revive_vfx_scale: float = 1.0
@export var revive_vfx_ref_height_px: float = 48.0
@export var revive_vfx_max_width_px: float = 0.0
@export var revive_vfx_normalize_by_height: bool = true

# Auto-flip for single-side sets
@export var auto_flip_for_side_single: bool = true

# Dead-walk helpers
@export var allow_dead_walk_visuals: bool = true
@export var dead_walk_dir_threshold: float = 0.2
@export var dead_walk_min_speed: float = 1.0
@export var dead_walk_min_dist_px: float = 0.5

# ----------------------------------------------------------------------------- #
# State
# ----------------------------------------------------------------------------- #
var _sprite: AnimatedSprite2D = null
var _pending_hit_frame: int = -1
var _pending_hit_callable: Callable = Callable()
var _last_dir: Vector2 = Vector2.RIGHT

var _actor_body: CharacterBody2D = null
var _actor_node: Node2D = null

var _has_last_gpos: bool = false
var _last_gpos: Vector2 = Vector2.ZERO

var _has_side_single: bool = false
var _has_side_split: bool = false
var _has_vertical: bool = false

var _action_lock_until_msec: int = 0

# Footstep runtime state
var _footstep_last_pos: Vector2 = Vector2.ZERO
var _footstep_was_moving: bool = false

# Action prefix registry (runtime-tweakable; keys: "attack","cast","buff","projectile")
var _prefix: Dictionary = {
	"attack": "",
	"cast": "",
	"buff": "",
	"projectile": ""
}

# ----------------------------------------------------------------------------- #
# Lifecycle
# ----------------------------------------------------------------------------- #
func _ready() -> void:
	var n: Node = get_node_or_null(sprite_path)
	if n != null:
		_sprite = n as AnimatedSprite2D

	_actor_node = _find_actor_node2d()
	_actor_body = _find_actor_body()

	if _sprite != null:
		_sprite.frame_changed.connect(Callable(self, "_on_sprite_frame_changed"))
		_sprite.animation_finished.connect(Callable(self, "_on_sprite_anim_finished"))
		_autodetect_sets()

	# Seed runtime registry with exports
	_set_prefix_if_empty("attack", default_attack_prefix)
	_set_prefix_if_empty("cast", default_cast_prefix)
	_set_prefix_if_empty("buff", default_buff_prefix)
	_set_prefix_if_empty("projectile", default_projectile_prefix)

func _find_actor_node2d() -> Node2D:
	var p: Node = self
	while p != null and is_instance_valid(p):
		if p is Node2D:
			return p as Node2D
		p = p.get_parent()
	return null

func _find_actor_body() -> CharacterBody2D:
	var p: Node = self
	while p != null and is_instance_valid(p):
		if p is CharacterBody2D:
			return p as CharacterBody2D
		p = p.get_parent()
	return null

# ----------------------------------------------------------------------------- #
# Prefix registry (public helpers)
# ----------------------------------------------------------------------------- #
func set_action_prefix(kind: String, prefix: String) -> void:
	if kind == "":
		return
	_prefix[kind] = prefix

func get_action_prefix(kind: String) -> String:
	if kind == "":
		return ""
	if _prefix.has(kind):
		var v: Variant = _prefix[kind]
		if typeof(v) == TYPE_STRING:
			var s: String = v
			if s != "":
				return s
	# fall back to exports
	if kind == "attack":
		return default_attack_prefix
	if kind == "cast":
		return default_cast_prefix
	if kind == "buff":
		return default_buff_prefix
	if kind == "projectile":
		return default_projectile_prefix
	return ""

func _set_prefix_if_empty(kind: String, prefix: String) -> void:
	if not _prefix.has(kind):
		_prefix[kind] = ""
	if typeof(_prefix[kind]) == TYPE_STRING:
		if String(_prefix[kind]) == "":
			_prefix[kind] = prefix

# ----------------------------------------------------------------------------- #
# Movement driving (unchanged; supports *_dead)
# ----------------------------------------------------------------------------- #
func set_movement(dir: Vector2, moving: bool) -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return
	if _pending_hit_frame >= 0:
		return

	var dead_now: bool = _is_dead()

	var use_dir: Vector2 = dir
	if moving and use_dir.length() > 0.001:
		_last_dir = use_dir.normalized()
	else:
		use_dir = _last_dir

	# NEW: detect actual movement from the body, not just the flag.
	var movement_epsilon: float = 0.05
	var actual_speed: float = 0.0
	if _actor_body != null:
		actual_speed = _actor_body.velocity.length()

	var moving_eff: bool = moving

	# If the body is really moving, force locomotion animations to be considered "moving",
	# even if an action (attack / cast) recently locked the animator.
	if actual_speed > movement_epsilon:
		moving_eff = true

	# Existing dead-walk visuals: only kick in if not already moving and actor is dead.
	if not moving_eff and allow_dead_walk_visuals and dead_now:
		var speed_mag: float = 0.0
		if _actor_body != null:
			speed_mag = _actor_body.velocity.length()

		var moved_dist: float = 0.0
		if _actor_node != null:
			if _has_last_gpos:
				moved_dist = (_actor_node.global_position - _last_gpos).length()
			_last_gpos = _actor_node.global_position
			_has_last_gpos = true

		if speed_mag > dead_walk_min_speed:
			moving_eff = true
		elif moved_dist > dead_walk_min_dist_px:
			moving_eff = true
		elif use_dir.length() >= dead_walk_dir_threshold:
			moving_eff = true

	# Action lock normally prevents movement anims (so attacks/casts play fully),
	# but if the body is actually moving, we allow walking to override the lock
	# to prevent "gliding while attacking".
	if Time.get_ticks_msec() < _action_lock_until_msec:
		var is_actually_moving: bool = actual_speed > movement_epsilon
		if not is_actually_moving and not (dead_now and moving_eff):
			return

	var target: String = ""
	if moving_eff:
		target = _pick_walk(use_dir)
	else:
		target = _pick_idle(use_dir)

	if dead_now:
		target = _dead_variant_for_palettes(target, use_dir, moving_eff)

	if target == "" or not _has_anim(target):
		return

	_apply_horizontal_flip(use_dir, target)

	if _sprite.animation == target and _sprite.is_playing():
		return
	_sprite.play(target)

# ----------------------------------------------------------------------------- #
# NEW: Explicit facing seed for lock-only actions (no animation kick)
# ----------------------------------------------------------------------------- #
func set_facing(dir: Vector2) -> void:
	if dir.length() > 0.001:
		_last_dir = dir.normalized()

func _pick_idle(dir: Vector2) -> String:
	var ax: float = absf(dir.x)
	var ay: float = absf(dir.y)

	if _has_vertical and ay > ax:
		if dir.y < 0.0:
			return anim_idle_up
		else:
			return anim_idle_down

	if supports_side_anims and _has_side_split:
		if dir.x < 0.0:
			return anim_idle_left
		else:
			return anim_idle_right

	if supports_side_anims and _has_side_single:
		return anim_idle_side

	return _first_existing([anim_idle_up, anim_idle_down, anim_idle_left, anim_idle_right, anim_idle_side])

func _pick_walk(dir: Vector2) -> String:
	var ax: float = absf(dir.x)
	var ay: float = absf(dir.y)

	if _has_vertical and ay > ax:
		if dir.y < 0.0:
			return anim_walk_up
		else:
			return anim_walk_down

	if supports_side_anims and _has_side_split:
		if dir.x < 0.0:
			return anim_walk_left
		else:
			return anim_walk_right

	if supports_side_anims and _has_side_single:
		return anim_walk_side

	return _first_existing([anim_walk_up, anim_walk_down, anim_walk_left, anim_walk_right, anim_walk_side])

# ----------------------------- dead variant logic -----------------------------
func _dead_variant_for_palettes(alive_choice: String, dir: Vector2, moving: bool) -> String:
	if alive_choice == "":
		return alive_choice

	var direct: String = alive_choice + "_dead"
	if _has_anim(direct):
		if moving and direct.begins_with("idle_"):
			var walk_same: String = direct.replace("idle_", "walk_")
			if _has_anim(walk_same):
				return walk_same
		return direct

	var use_split: bool = _has_any(["walk_left_dead","idle_left_dead"]) or _has_any(["walk_right_dead","idle_right_dead"])
	var use_side: bool = _has_any(["walk_side_dead","idle_side_dead"])

	var horizontal: bool = (absf(dir.x) >= absf(dir.y))
	var left_facing: bool = (dir.x < 0.0)
	var up_facing: bool = (dir.y < 0.0)

	if moving:
		if horizontal:
			if use_split:
				if left_facing and _has_anim("walk_left_dead"):
					return "walk_left_dead"
				if not left_facing and _has_anim("walk_right_dead"):
					return "walk_right_dead"
			if use_side and _has_anim("walk_side_dead"):
				return "walk_side_dead"
		if up_facing and _has_anim("walk_up_dead"):
			return "walk_up_dead"
		if _has_anim("walk_down_dead"):
			return "walk_down_dead"
		var any_walk: String = _first_existing([
			"walk_left_dead","walk_right_dead","walk_side_dead","walk_up_dead","walk_down_dead"
		])
		if any_walk != "":
			return any_walk

	if horizontal:
		if use_split:
			if left_facing and _has_anim("idle_left_dead"):
				return "idle_left_dead"
			if not left_facing and _has_anim("idle_right_dead"):
				return "idle_right_dead"
		if use_side and _has_anim("idle_side_dead"):
			return "idle_side_dead"
	if up_facing and _has_anim("idle_up_dead"):
		return "idle_up_dead"
	if _has_anim("idle_down_dead"):
		return "idle_down_dead"

	var any_dead: String = _first_existing([
		"idle_left_dead","idle_right_dead","idle_side_dead","idle_up_dead","idle_down_dead",
		"walk_left_dead","walk_right_dead","walk_side_dead","walk_up_dead","walk_down_dead"
	])
	if any_dead != "":
		return any_dead

	return alive_choice

func _has_any(names: Array) -> bool:
	var i: int = 0
	while i < names.size():
		var v: Variant = names[i]
		if typeof(v) == TYPE_STRING and _has_anim(String(v)):
			return true
		i += 1
	return false

# ----------------------------- sprite / flip utils ----------------------------
func _apply_horizontal_flip(dir: Vector2, chosen_anim: String) -> void:
	if _sprite == null:
		return
	var should_flip: bool = false

	if supports_side_anims and _has_side_split:
		should_flip = false
	else:
		if supports_side_anims and _has_side_single and auto_flip_for_side_single:
			# PATCH: flip for ANY "*_side" action anim too (attack/cast/buff/projectile).
			var is_side_anim: bool = false
			if chosen_anim == anim_walk_side or chosen_anim == anim_idle_side:
				is_side_anim = true
			elif chosen_anim == "walk_side_dead" or chosen_anim == "idle_side_dead":
				is_side_anim = true
			elif chosen_anim.ends_with("_side"):
				is_side_anim = true
			elif chosen_anim.ends_with("_side_dead"):
				is_side_anim = true
			elif chosen_anim.find("_side_") != -1:
				is_side_anim = true
			elif chosen_anim.find("_side_dead") != -1:
				is_side_anim = true

			if is_side_anim:
				should_flip = true

	if should_flip:
		var want_left: bool = (dir.x < 0.0)
		_set_flip_h(want_left)
	else:
		_set_flip_h(false)

func _set_flip_h(left: bool) -> void:
	if _sprite == null:
		return
	if _has_property(_sprite, "flip_h"):
		_sprite.set("flip_h", left)
	else:
		var sc: Vector2 = _sprite.scale
		if left and sc.x > 0.0:
			sc.x = -sc.x
		elif not left and sc.x < 0.0:
			sc.x = -sc.x
		_sprite.scale = sc

func _has_property(obj: Object, prop: String) -> bool:
	var plist: Array = obj.get_property_list()
	var i: int = 0
	while i < plist.size():
		var p: Dictionary = plist[i]
		if p.has("name"):
			var nm: String = String(p["name"])
			if nm == prop:
				return true
		i += 1
	return false

func _autodetect_sets() -> void:
	_has_side_single = _has_anim(anim_idle_side) and _has_anim(anim_walk_side)
	_has_side_split = _has_anim(anim_idle_left) and _has_anim(anim_idle_right) and _has_anim(anim_walk_left) and _has_anim(anim_walk_right)
	_has_vertical = _has_anim(anim_idle_up) and _has_anim(anim_idle_down) and _has_anim(anim_walk_up) and _has_anim(anim_walk_down)
	if not supports_side_anims:
		if _has_side_single or _has_side_split:
			supports_side_anims = true

func _has_anim(name_str: String) -> bool:
	if _sprite == null or _sprite.sprite_frames == null:
		return false
	return _sprite.sprite_frames.has_animation(name_str)

func _first_existing(candidates: Array) -> String:
	if _sprite == null or _sprite.sprite_frames == null:
		return ""
	var i: int = 0
	while i < candidates.size():
		var c: Variant = candidates[i]
		if typeof(c) == TYPE_STRING:
			var s: String = String(c)
			if _sprite.sprite_frames.has_animation(s):
				return s
		i += 1
	return ""

# ------------------------------ dead-state check ------------------------------
func _is_dead() -> bool:
	var root: Node = self
	while root != null and is_instance_valid(root):
		var sc: Node = root.get_node_or_null("StatusConditions")
		if sc != null and sc.has_method("is_dead"):
			var sv: Variant = sc.call("is_dead")
			if typeof(sv) == TYPE_BOOL and bool(sv):
				return true
		var stats: Node = root.get_node_or_null("StatsComponent")
		if stats == null:
			stats = root.get_node_or_null("Stats")
		if stats != null:
			if stats.has_method("is_dead"):
				var d: Variant = stats.call("is_dead")
				if typeof(d) == TYPE_BOOL and bool(d):
					return true
			if stats.has_method("get_hp"):
				var gh: Variant = stats.call("get_hp")
				if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
					return true
			if stats.has_method("current_hp"):
				var ch: Variant = stats.call("current_hp")
				if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
					return true
		if root is Node and root.has_method("is_dead"):
			var dv: Variant = root.call("is_dead")
			if typeof(dv) == TYPE_BOOL and bool(dv):
				return true
		if "dead" in root:
			var df: Variant = root.get("dead")
			if typeof(df) == TYPE_BOOL and bool(df):
				return true
		root = root.get_parent()
	return false

# ----------------------------------------------------------------------------- #
# Generic action resolvers (NEW)
# ----------------------------------------------------------------------------- #
func play_attack_with_prefix(prefix: String, aim_dir: Vector2, hit_frame: int, on_hit: Callable) -> void:
	_play_action_internal("attack", prefix, aim_dir, hit_frame, on_hit, 0.9)

func play_cast_with_prefix(prefix: String, cast_time_sec: float) -> void:
	_play_lock_only("cast", prefix, cast_time_sec)

func play_buff_with_prefix(prefix: String, dur_sec: float = 0.0) -> void:
	# Buffs typically have no lock, but we allow a tiny visual lock if needed.
	_play_lock_only("buff", prefix, minf(dur_sec, 0.2))

func play_projectile_with_prefix(prefix: String, windup_sec: float = 0.0) -> void:
	_play_lock_only("projectile", prefix, windup_sec)

func _play_action_internal(kind: String, prefix: String, aim_dir: Vector2, hit_frame: int, on_hit: Callable, lock_sec: float) -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return

	var use_prefix: String = prefix
	if use_prefix == "":
		use_prefix = get_action_prefix(kind)

	var anim_name: String = _resolve_anim_for_prefix(use_prefix, aim_dir)
	if anim_name == "":
		return

	# PATCH: seed facing + apply flip for side-only sets on actions too.
	var dir_for_flip: Vector2 = _last_dir
	if aim_dir.length() > 0.001:
		dir_for_flip = aim_dir.normalized()
		_last_dir = dir_for_flip
	_apply_horizontal_flip(dir_for_flip, anim_name)

	_pending_hit_frame = hit_frame
	_pending_hit_callable = on_hit
	_action_lock_until_msec = Time.get_ticks_msec() + int(lock_sec * 1000.0)

	var lock_target: Node = _actor_body
	if lock_target == null:
		lock_target = _actor_node
	if lock_target != null and lock_target.has_method("lock_action"):
		lock_target.call("lock_action", lock_sec)

	_sprite.play(anim_name)

func _play_lock_only(kind: String, prefix: String, lock_sec: float) -> void:
	if _sprite == null:
		return

	var use_prefix: String = prefix
	if use_prefix == "":
		use_prefix = get_action_prefix(kind)

	var aim: Vector2 = _last_dir
	if aim == Vector2.ZERO:
		aim = Vector2.DOWN
	var anim_name: String = _resolve_anim_for_prefix(use_prefix, aim)
	if anim_name == "":
		return

	_action_lock_until_msec = Time.get_ticks_msec() + int(maxf(0.0, lock_sec) * 1000.0)

	var lock_target: Node = _actor_body
	if lock_target == null:
		lock_target = _actor_node
	if lock_target != null and lock_target.has_method("lock_action"):
		lock_target.call("lock_action", lock_sec)

	# PATCH: apply flip for lock-only actions too.
	_apply_horizontal_flip(aim, anim_name)

	_sprite.play(anim_name)

# Resolve "<prefix>_(down/up/left/right/side)" based on available sets and aim
func _resolve_anim_for_prefix(prefix: String, aim: Vector2) -> String:
	if _sprite == null or _sprite.sprite_frames == null:
		return ""

	# Normalize aim; if tiny, default to DOWN.
	var dir: Vector2 = aim
	if dir.length() <= 0.001:
		dir = Vector2.DOWN
	else:
		dir = dir.normalized()

	var ax: float = absf(dir.x)
	var ay: float = absf(dir.y)

	var left_name: String = prefix + "_left"
	var right_name: String = prefix + "_right"
	var up_name: String = prefix + "_up"
	var down_name: String = prefix + "_down"
	var side_name: String = prefix + "_side"

	# Prefer explicit L/R when horizontal is dominant
	if ax >= ay:
		if dir.x < 0.0:
			if _has_anim(left_name):
				return left_name
		else:
			if _has_anim(right_name):
				return right_name
		# fallback: single-side if present
		if supports_side_anims and _has_anim(side_name):
			return side_name
		# fallback: use vertical that exists
		if dir.y < 0.0 and _has_anim(up_name):
			return up_name
		if _has_anim(down_name):
			return down_name
		# last resort: any of the four
		return _first_existing([left_name, right_name, up_name, down_name, side_name])

	# Prefer explicit U/D when vertical is dominant
	if dir.y < 0.0:
		if _has_anim(up_name):
			return up_name
	else:
		if _has_anim(down_name):
			return down_name

	# fallback: try explicit L/R
	if dir.x < 0.0:
		if _has_anim(left_name):
			return left_name
	else:
		if _has_anim(right_name):
			return right_name

	# fallback: single-side if present
	if supports_side_anims and _has_anim(side_name):
		return side_name

	# last resort
	return _first_existing([up_name, down_name, left_name, right_name, side_name])

# ----------------------------------------------------------------------------- #
# Back-compat shims (existing API kept)
# ----------------------------------------------------------------------------- #
func play_melee_attack(aim_dir: Vector2, hit_frame: int, on_hit: Callable) -> void:
	# Uses current "attack" prefix from registry (default_attack_prefix unless overridden)
	play_attack_with_prefix(get_action_prefix("attack"), aim_dir, hit_frame, on_hit)

func play_cast(cast_time_sec: float) -> void:
	play_cast_with_prefix(get_action_prefix("cast"), cast_time_sec)

func play_death() -> void:
	if _sprite == null:
		return
	if _sprite.sprite_frames != null and _sprite.sprite_frames.has_animation("death"):
		_sprite.play("death")

func play_hit_react() -> void:
	if _sprite == null:
		return
	if _sprite.sprite_frames != null and _sprite.sprite_frames.has_animation("hit"):
		_sprite.play("hit")

# ----------------------------------------------------------------------------- #
# Hit-frame + footsteps + lock lifecycle
# ----------------------------------------------------------------------------- #
func _on_sprite_frame_changed() -> void:
	if _sprite == null:
		return

	# Hit-frame callback
	if _pending_hit_frame >= 0:
		if _sprite.frame == _pending_hit_frame:
			if _pending_hit_callable.is_valid():
				_pending_hit_callable.call()
			_pending_hit_frame = -1
			_pending_hit_callable = Callable()

	# Footsteps (walk* only)
	_maybe_play_footstep()

func _maybe_play_footstep() -> void:
	if not enable_footsteps:
		return
	if _sprite == null:
		return
	if _actor_body == null:
		return
	if _is_dead():
		return

	var anim_prefix: String = footstep_anim_prefix
	if anim_prefix == "":
		anim_prefix = "walk"

	var anim_name: String = _sprite.animation
	if not anim_name.begins_with(anim_prefix):
		_footstep_was_moving = false
		return

	var speed_len: float = _actor_body.velocity.length()
	if speed_len < footstep_min_speed:
		_footstep_was_moving = false
		return

	# Reset distance baseline when movement starts
	if not _footstep_was_moving:
		_footstep_was_moving = true
		_footstep_last_pos = _actor_body.global_position

	var frame_index: int = _sprite.frame

	# Frame gate (optional)
	if footstep_frames.is_empty():
		_try_play_footstep()
		return

	if frame_index in footstep_frames:
		_try_play_footstep()

func _try_play_footstep() -> void:
	if _actor_body == null:
		return

	if footstep_use_distance_gate:
		var dist_px: float = _actor_body.global_position.distance_to(_footstep_last_pos)
		if dist_px < footstep_min_distance_px:
			return

	var pos: Vector2 = _actor_body.global_position
	var event_any: StringName = AudioSys.get_footstep_event_at(pos)
	AudioSys.play_sfx_event(event_any, pos, footstep_volume_db)

	_footstep_last_pos = pos

func _on_sprite_anim_finished() -> void:
	_pending_hit_frame = -1
	_pending_hit_callable = Callable()
	_action_lock_until_msec = 0
	var lock_target: Node = _actor_body
	if lock_target == null:
		lock_target = _actor_node
	if lock_target != null and lock_target.has_method("unlock_action"):
		lock_target.call("unlock_action")

# ----------------------------------------------------------------------------- #
# VFX (Heal / Revive) — unchanged from your version
# ----------------------------------------------------------------------------- #
func play_heal_vfx(amount: int = 0) -> void:
	if _sprite == null:
		return
	var frames: SpriteFrames = _resolve_heal_frames()
	if frames == null:
		return
	_spawn_centered_vfx(frames, "heal", 0.6, Vector2(0, -8), 0.8)

func play_revive_vfx() -> void:
	if _sprite == null:
		return
	var frames: SpriteFrames = null

	if revive_frames_path != "" and ResourceLoader.exists(revive_frames_path):
		var res: Resource = ResourceLoader.load(revive_frames_path)
		frames = res as SpriteFrames

	if frames == null:
		var reg: Node = _find_vfx_registry()
		if reg != null and reg.has_method("get_revive_frames"):
			var fr_any: Variant = reg.call("get_revive_frames")
			if fr_any is SpriteFrames:
				frames = fr_any

	if frames == null:
		frames = _resolve_heal_frames()
	if frames == null:
		return

	_spawn_centered_vfx(
		frames,
		"revive",
		0.6,
		Vector2(0, -8),
		0.8,
		revive_vfx_scale,
		revive_vfx_max_width_px,
		revive_vfx_normalize_by_height,
		revive_vfx_ref_height_px
	)

func _resolve_heal_frames() -> SpriteFrames:
	var frames: SpriteFrames = null
	var p1: String = "res://Dradyn/assets/VFX/HealingWhisper.tres"
	var p2: String = "res://Dradyn/Data/Abilities/HealingWhisper.tres"
	if ResourceLoader.exists(p1):
		var r1: Resource = ResourceLoader.load(p1)
		frames = r1 as SpriteFrames
	if frames == null and ResourceLoader.exists(p2):
		var r2: Resource = ResourceLoader.load(p2)
		frames = r2 as SpriteFrames
	if frames == null:
		var reg: Node = _find_vfx_registry()
		if reg != null and reg.has_method("get_heal_frames"):
			var fr: Variant = reg.call("get_heal_frames")
			if fr is SpriteFrames:
				frames = fr
	return frames

func _find_vfx_registry() -> Node:
	var root: Node = get_tree().root
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n == null:
			continue
		if n.get_script() != null:
			var cn: String = String(n.get_script().get_global_name())
			if cn == "VFXregistry":
				return n
		var i: int = 0
		while i < n.get_child_count():
			stack.push_back(n.get_child(i))
			i += 1
	return null

func _spawn_centered_vfx(
	frames: SpriteFrames,
	prefer_anim: String,
	rise_sec: float,
	offset: Vector2,
	opacity: float,
	scale_mult: float = 1.0,
	max_width_px: float = 0.0,
	normalize_to_vfx_height: bool = false,
	ref_vfx_height_px: float = 48.0
) -> void:
	if _sprite == null or frames == null:
		return

	var anim: AnimatedSprite2D = AnimatedSprite2D.new()
	anim.sprite_frames = frames

	var play_name: String = prefer_anim
	if not frames.has_animation(play_name):
		var names: PackedStringArray = frames.get_animation_names()
		if names.size() > 0:
			play_name = names[0]
	anim.animation = play_name

	var anchor: Node2D = _sprite
	if anchor == null:
		if _actor_node != null:
			anchor = _actor_node
		elif _actor_body != null:
			anchor = _actor_body
	if anchor == null:
		return

	anchor.add_child(anim)
	anim.z_index = anchor.z_index + 1
	anim.position = Vector2.ZERO + offset

	var col: Color = anim.self_modulate
	if opacity < 0.0:
		opacity = 0.0
	if opacity > 1.0:
		opacity = 1.0
	col.a = opacity
	anim.self_modulate = col

	var scale_f: float = 1.0
	if _sprite.sprite_frames != null:
		var cur_anim: String = _sprite.animation
		if cur_anim == "":
			var names2: PackedStringArray = _sprite.sprite_frames.get_animation_names()
			if names2.size() > 0:
				cur_anim = names2[0]
		var tex_actor: Texture2D = _sprite.sprite_frames.get_frame_texture(cur_anim, 0)
		if tex_actor != null:
			var h_actor: float = float(tex_actor.get_height())
			if h_actor > 0.0:
				var calc: float = h_actor / 48.0
				if calc < 0.75:
					scale_f = 0.75
				elif calc > 2.5:
					scale_f = 2.5
				else:
					scale_f = calc

	var tex_vfx: Texture2D = frames.get_frame_texture(play_name, 0)
	if normalize_to_vfx_height and tex_vfx != null and ref_vfx_height_px > 0.0:
		var h_vfx: float = float(tex_vfx.get_height())
		if h_vfx > 0.0:
			var norm: float = ref_vfx_height_px / h_vfx
			scale_f = scale_f * norm

	if scale_mult <= 0.0:
		scale_mult = 0.01
	scale_f = scale_f * scale_mult

	if max_width_px > 0.0 and tex_vfx != null:
		var vfx_w: float = float(tex_vfx.get_width())
		if vfx_w > 0.0:
			var scaled_w: float = vfx_w * scale_f
			if scaled_w > max_width_px:
				var clamp_factor: float = max_width_px / scaled_w
				scale_f = scale_f * clamp_factor

	anim.scale = Vector2.ONE * scale_f

	var tw: Tween = create_tween()
	tw.tween_property(anim, "position", anim.position + Vector2(0, -16), rise_sec)
	tw.parallel().tween_property(anim, "modulate:a", 0.0, rise_sec)
	anim.play()
	tw.finished.connect(func() -> void:
		if is_instance_valid(anim):
			anim.queue_free()
	)
