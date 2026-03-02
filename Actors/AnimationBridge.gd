extends Node
class_name AnimationBridge
# Godot 4.5 — fully typed, no ternaries.

@export var sprite_path: NodePath = NodePath("../AnimatedSprite2D")
@export var supports_side_anims: bool = true

# --- Rig Contract v1 (optional; auto-discovered if not set) ---
@export_group("Party Rig (Optional)")
@export var visual_root_path: NodePath = NodePath("")
@export var body_sprite_path: NodePath = NodePath("")
@export var armor_sprite_path: NodePath = NodePath("")
@export var hair_sprite_path: NodePath = NodePath("")
@export var cloak_sprite_path: NodePath = NodePath("")

# optional behind layers (recommended node names in VisualRoot)
@export var hair_behind_sprite_path: NodePath = NodePath("")
@export var cloak_behind_sprite_path: NodePath = NodePath("")

# HeadSprite (preferred). HoodSprite kept as legacy support.
@export var head_sprite_path: NodePath = NodePath("") # optional
@export var hood_sprite_path: NodePath = NodePath("") # optional (legacy)

@export var weapon_root_path: NodePath = NodePath("")
@export var mainhand_path: NodePath = NodePath("")
@export var offhand_path: NodePath = NodePath("")
@export var trail_anchor_path: NodePath = NodePath("")
@export var motion_player_path: NodePath = NodePath("") # optional AnimationPlayer

# AnimationLibrary name used by MotionPlayer (Godot 4 Animation Libraries)
@export var motion_anim_library: String = "CombatAnimations"

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

# Prevent tiny residual velocities from interrupting lock-only actions (casts/buffs/projectiles).
# If actual_speed is below this, we treat the actor as "not actually moving" for action-lock override purposes.
@export var action_lock_walk_override_speed_epsilon: float = 10.0

# ----------------------------------------------------------------------------- #
# Signals
# ----------------------------------------------------------------------------- #
signal facing_changed(dir: Vector2)
signal action_started(kind: String, anim_name: String)
signal action_finished(kind: String, anim_name: String)
signal attack_phase_changed(phase: String)

# ----------------------------------------------------------------------------- #
# State
# ----------------------------------------------------------------------------- #
var _sprite: AnimatedSprite2D = null # master / body
var _layers: Array[AnimatedSprite2D] = [] # includes master (index 0 when present)
var _layer_names: Array[String] = [] # parallel for debugging (not exported)
var _weapon_root: Node2D = null
var _mainhand: Sprite2D = null
var _offhand: Sprite2D = null
var _trail_anchor: Marker2D = null
var _motion_player: AnimationPlayer = null
var _visual_root: Node2D = null

# Behind layers (optional)
var _hair_behind: AnimatedSprite2D = null
var _cloak_behind: AnimatedSprite2D = null

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

# Case-insensitive animation lookup: lower_name -> actual_name
var _anim_name_lut: Dictionary = {}

# Action prefix registry (runtime-tweakable; keys: "attack","cast","buff","projectile")
var _prefix: Dictionary = {
	"attack": "",
	"cast": "",
	"buff": "",
	"projectile": ""
}

# NEW: desired left-mirroring for side-single body anims
var _want_weapon_mirror_left: bool = false

# NEW: post-mix weapon mirror (built from current MotionPlayer animation tracks)
var _weapon_mirror_active: bool = false
var _weapon_mirror_anim: String = ""
var _weapon_mirror_nodes: Array[Node] = []
var _weapon_mirror_props: Array[StringName] = []

# ----------------------------------------------------------------------------- #
# Lifecycle
# ----------------------------------------------------------------------------- #
func _ready() -> void:
	# Ensure our mirror post-step runs late in the frame.
	process_priority = 100

	_actor_node = _find_actor_node2d()
	_actor_body = _find_actor_body()

	_resolve_rig_targets()

	if _sprite != null:
		_sprite.frame_changed.connect(Callable(self, "_on_sprite_frame_changed"))
		_sprite.animation_finished.connect(Callable(self, "_on_sprite_anim_finished"))
		_rebuild_anim_name_lut()
		_autodetect_sets()

	_set_prefix_if_empty("attack", default_attack_prefix)
	_set_prefix_if_empty("cast", default_cast_prefix)
	_set_prefix_if_empty("buff", default_buff_prefix)
	_set_prefix_if_empty("projectile", default_projectile_prefix)

	# Only process when mirroring is active.
	set_process(false)

func _process(_delta: float) -> void:
	# Mirror after MotionPlayer has mixed track values.
	if _weapon_mirror_active:
		_apply_weapon_mirror_post_mix()

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
# Rig resolution
# ----------------------------------------------------------------------------- #
func _resolve_rig_targets() -> void:
	_layers.clear()
	_layer_names.clear()
	_sprite = null
	_visual_root = null
	_weapon_root = null
	_mainhand = null
	_offhand = null
	_trail_anchor = null
	_motion_player = null
	_anim_name_lut.clear()
	_hair_behind = null
	_cloak_behind = null

	_want_weapon_mirror_left = false
	_stop_weapon_mirror(false)

	var explicit_sprite: AnimatedSprite2D = null
	if sprite_path != NodePath(""):
		var n_exp: Node = get_node_or_null(sprite_path)
		if n_exp != null:
			explicit_sprite = n_exp as AnimatedSprite2D

	_visual_root = _resolve_visual_root()

	var body: AnimatedSprite2D = _resolve_layer_sprite("BodySprite", body_sprite_path)
	var armor: AnimatedSprite2D = _resolve_layer_sprite("ArmorSprite", armor_sprite_path)

	var hair: AnimatedSprite2D = _resolve_layer_sprite("HairSprite", hair_sprite_path)
	var cloak: AnimatedSprite2D = _resolve_layer_sprite("CloakSprite", cloak_sprite_path)

	_hair_behind = _resolve_layer_sprite("HairBehindSprite", hair_behind_sprite_path)
	_cloak_behind = _resolve_layer_sprite("CloakBehindSprite", cloak_behind_sprite_path)

	var head: AnimatedSprite2D = _resolve_layer_sprite("HeadSprite", head_sprite_path)
	var hood_legacy: AnimatedSprite2D = null
	if head == null:
		hood_legacy = _resolve_layer_sprite("HoodSprite", hood_sprite_path)

	if body != null:
		_sprite = body
	elif explicit_sprite != null:
		_sprite = explicit_sprite
	else:
		_sprite = _find_first_actor_sprite()

	if _sprite != null:
		_layers.append(_sprite)
		_layer_names.append("Master")

		_add_layer_if_valid(_cloak_behind, "CloakBehindSprite")
		_add_layer_if_valid(_hair_behind, "HairBehindSprite")

		_add_layer_if_valid(armor, "ArmorSprite")
		_add_layer_if_valid(cloak, "CloakSprite")
		_add_layer_if_valid(hair, "HairSprite")
		_add_layer_if_valid(head, "HeadSprite")
		_add_layer_if_valid(hood_legacy, "HoodSprite (Legacy)")

		_rebuild_anim_name_lut()

	_weapon_root = _resolve_weapon_root()
	_mainhand = _resolve_sprite2d_child("Mainhand", mainhand_path)
	_offhand = _resolve_sprite2d_child("Offhand", offhand_path)
	_trail_anchor = _resolve_trail_anchor()
	_motion_player = _resolve_motion_player()

func _resolve_visual_root() -> Node2D:
	if visual_root_path != NodePath(""):
		var n: Node = get_node_or_null(visual_root_path)
		if n != null and n is Node2D:
			return n as Node2D

	var actor: Node = _actor_node
	if actor == null:
		actor = _actor_body
	if actor != null:
		var vr: Node = actor.find_child("VisualRoot", true, false)
		if vr != null and vr is Node2D:
			return vr as Node2D

	return null

func _resolve_layer_sprite(expected_name: String, explicit_path: NodePath) -> AnimatedSprite2D:
	if explicit_path != NodePath(""):
		var n: Node = get_node_or_null(explicit_path)
		if n != null:
			var s: AnimatedSprite2D = n as AnimatedSprite2D
			if s != null:
				return s

	if _visual_root != null:
		var child: Node = _visual_root.get_node_or_null(NodePath(expected_name))
		if child != null:
			var s2: AnimatedSprite2D = child as AnimatedSprite2D
			if s2 != null:
				return s2

		var found: Node = _visual_root.find_child(expected_name, true, false)
		if found != null:
			var s3: AnimatedSprite2D = found as AnimatedSprite2D
			if s3 != null:
				return s3

	return null

func _find_first_actor_sprite() -> AnimatedSprite2D:
	var actor: Node = _actor_node
	if actor == null:
		actor = _actor_body
	if actor == null:
		return null

	var stack: Array[Node] = [actor]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n == null:
			continue

		var s: AnimatedSprite2D = n as AnimatedSprite2D
		if s != null:
			if s.sprite_frames != null:
				return s

		var i: int = 0
		while i < n.get_child_count():
			stack.push_back(n.get_child(i))
			i += 1

	return null

func _add_layer_if_valid(layer: AnimatedSprite2D, name: String) -> void:
	if layer == null:
		return
	if _sprite != null and layer == _sprite:
		return
	_layers.append(layer)
	_layer_names.append(name)

func _resolve_weapon_root() -> Node2D:
	if weapon_root_path != NodePath(""):
		var n: Node = get_node_or_null(weapon_root_path)
		if n != null and n is Node2D:
			return n as Node2D

	if _visual_root != null:
		var wr: Node = _visual_root.get_node_or_null(NodePath("WeaponRoot"))
		if wr != null and wr is Node2D:
			return wr as Node2D
		var wr2: Node = _visual_root.find_child("WeaponRoot", true, false)
		if wr2 != null and wr2 is Node2D:
			return wr2 as Node2D

	var actor: Node = _actor_node
	if actor == null:
		actor = _actor_body
	if actor != null:
		var wr3: Node = actor.find_child("WeaponRoot", true, false)
		if wr3 != null and wr3 is Node2D:
			return wr3 as Node2D

	return null

func _resolve_sprite2d_child(expected_name: String, explicit_path: NodePath) -> Sprite2D:
	if explicit_path != NodePath(""):
		var n: Node = get_node_or_null(explicit_path)
		if n != null:
			var s: Sprite2D = n as Sprite2D
			if s != null:
				return s

	if _weapon_root != null:
		var c: Node = _weapon_root.get_node_or_null(NodePath(expected_name))
		if c != null:
			var s2: Sprite2D = c as Sprite2D
			if s2 != null:
				return s2
		var f: Node = _weapon_root.find_child(expected_name, true, false)
		if f != null:
			var s3: Sprite2D = f as Sprite2D
			if s3 != null:
				return s3

	return null

func _resolve_trail_anchor() -> Marker2D:
	if trail_anchor_path != NodePath(""):
		var n: Node = get_node_or_null(trail_anchor_path)
		if n != null:
			var m: Marker2D = n as Marker2D
			if m != null:
				return m

	if _visual_root != null:
		var t: Node = _visual_root.find_child("TrailAnchor", true, false)
		if t != null:
			var m2: Marker2D = t as Marker2D
			if m2 != null:
				return m2

	return null

func _resolve_motion_player() -> AnimationPlayer:
	if motion_player_path != NodePath(""):
		var n: Node = get_node_or_null(motion_player_path)
		if n != null:
			var ap: AnimationPlayer = n as AnimationPlayer
			if ap != null:
				return ap

	if _visual_root != null:
		var mp: Node = _visual_root.find_child("MotionPlayer", true, false)
		if mp != null:
			var ap2: AnimationPlayer = mp as AnimationPlayer
			if ap2 != null:
				return ap2

	var actor: Node = _actor_node
	if actor == null:
		actor = _actor_body
	if actor != null:
		var mp2: Node = actor.find_child("MotionPlayer", true, false)
		if mp2 != null:
			var ap3: AnimationPlayer = mp2 as AnimationPlayer
			if ap3 != null:
				return ap3

	return null

# ----------------------------------------------------------------------------- #
# Animation name resolution (case-insensitive)
# ----------------------------------------------------------------------------- #
func _rebuild_anim_name_lut() -> void:
	_anim_name_lut.clear()
	if _sprite == null:
		return
	if _sprite.sprite_frames == null:
		return

	var names: PackedStringArray = _sprite.sprite_frames.get_animation_names()
	var i: int = 0
	while i < names.size():
		var actual: String = String(names[i])
		var key: String = actual.to_lower()
		_anim_name_lut[key] = actual
		i += 1

func _resolve_anim_name(requested: String) -> String:
	if requested == "":
		return ""
	if _sprite == null:
		return ""
	if _sprite.sprite_frames == null:
		return ""

	if _sprite.sprite_frames.has_animation(requested):
		return requested

	if _anim_name_lut.is_empty():
		_rebuild_anim_name_lut()

	var key: String = requested.to_lower()
	if _anim_name_lut.has(key):
		var v: Variant = _anim_name_lut[key]
		if typeof(v) == TYPE_STRING:
			return String(v)

	_rebuild_anim_name_lut()
	if _anim_name_lut.has(key):
		var v2: Variant = _anim_name_lut[key]
		if typeof(v2) == TYPE_STRING:
			return String(v2)

	return ""

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
# Movement driving
# ----------------------------------------------------------------------------- #
func set_movement(dir: Vector2, moving: bool) -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return
	if _pending_hit_frame >= 0:
		return

	if _anim_name_lut.is_empty():
		_rebuild_anim_name_lut()

	var dead_now: bool = _is_dead()

	var use_dir: Vector2 = dir
	if moving and use_dir.length() > 0.001:
		_last_dir = use_dir.normalized()
	else:
		use_dir = _last_dir

	var actual_speed: float = 0.0
	if _actor_body != null:
		actual_speed = _actor_body.velocity.length()

	var moving_eff: bool = moving

	if not moving_eff and allow_dead_walk_visuals and dead_now:
		var speed_mag: float = actual_speed

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

	if Time.get_ticks_msec() < _action_lock_until_msec:
		var speed_eps: float = action_lock_walk_override_speed_epsilon
		if speed_eps < 0.0:
			speed_eps = 0.0
		var is_actually_moving: bool = actual_speed > speed_eps
		if not is_actually_moving and not (dead_now and moving_eff):
			return

	var target: String = ""
	if moving_eff:
		target = _pick_walk(use_dir)
	else:
		target = _pick_idle(use_dir)

	if dead_now:
		target = _dead_variant_for_palettes(target, use_dir, moving_eff)

	if target == "":
		return

	var resolved: String = _resolve_anim_name(target)
	if resolved == "":
		return
	target = resolved

	_apply_horizontal_flip(use_dir, target)
	_apply_weapon_z_for_dir(use_dir)

	if _sprite.animation == target and _sprite.is_playing():
		_sync_layers_to_master()
		return

	_play_all_layers(target)

# ----------------------------------------------------------------------------- #
# Explicit facing seed (no animation kick)
# ----------------------------------------------------------------------------- #
func set_facing(dir: Vector2) -> void:
	if dir.length() > 0.001:
		_last_dir = dir.normalized()
		facing_changed.emit(_last_dir)

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

	var use_split: bool = _has_any(["walk_left_dead", "idle_left_dead"]) or _has_any(["walk_right_dead", "idle_right_dead"])
	var use_side: bool = _has_any(["walk_side_dead", "idle_side_dead"])

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
			"walk_left_dead", "walk_right_dead", "walk_side_dead", "walk_up_dead", "walk_down_dead"
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
		"idle_left_dead", "idle_right_dead", "idle_side_dead", "idle_up_dead", "idle_down_dead",
		"walk_left_dead", "walk_right_dead", "walk_side_dead", "walk_up_dead", "walk_down_dead"
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

func _apply_horizontal_flip(dir: Vector2, chosen_anim: String) -> void:
	if _sprite == null:
		return

	var should_flip: bool = false
	var is_side_anim: bool = false

	if supports_side_anims and _has_side_split:
		should_flip = false
	else:
		if supports_side_anims and _has_side_single and auto_flip_for_side_single:
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

		# Body layers still flip for side-single.
		_set_flip_h_all_layers(want_left)

		# NEW: weapon mirroring is handled post-mix from MotionPlayer tracks (for left).
		_want_weapon_mirror_left = want_left
	else:
		_set_flip_h_all_layers(false)
		_want_weapon_mirror_left = false

func _set_flip_h_all_layers(left: bool) -> void:
	var i: int = 0
	while i < _layers.size():
		var s: AnimatedSprite2D = _layers[i]
		if s != null:
			_set_flip_h_one(s, left)
		i += 1

func _set_flip_h_one(s: AnimatedSprite2D, left: bool) -> void:
	if s == null:
		return
	if _has_property(s, "flip_h"):
		s.set("flip_h", left)
	else:
		var sc: Vector2 = s.scale
		if left and sc.x > 0.0:
			sc.x = -sc.x
		elif not left and sc.x < 0.0:
			sc.x = -sc.x
		s.scale = sc

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
	if name_str == "":
		return false
	var resolved: String = _resolve_anim_name(name_str)
	return resolved != ""

func _first_existing(candidates: Array) -> String:
	if _sprite == null or _sprite.sprite_frames == null:
		return ""
	var i: int = 0
	while i < candidates.size():
		var c: Variant = candidates[i]
		if typeof(c) == TYPE_STRING:
			var s: String = String(c)
			var resolved: String = _resolve_anim_name(s)
			if resolved != "":
				return resolved
		i += 1
	return ""

# ----------------------------------------------------------------------------- #
# MotionPlayer weapon animation mapping
# ----------------------------------------------------------------------------- #
func _play_motion_weapon_for_body_anim(body_anim_name: String) -> void:
	if _motion_player == null:
		_stop_weapon_mirror(false)
		return
	if body_anim_name == "":
		_stop_weapon_mirror(false)
		return

	var base_weapon_anim: String = body_anim_name + "_weapon"
	var played_name: String = ""

	# 1) Try unqualified (default library)
	if _motion_player.has_animation(base_weapon_anim):
		if not (_motion_player.current_animation == base_weapon_anim and _motion_player.is_playing()):
			_motion_player.play(base_weapon_anim)
		played_name = base_weapon_anim
	else:
		# 2) Try qualified by library
		var lib: String = motion_anim_library
		if lib != "":
			var qualified: String = lib + "/" + base_weapon_anim
			if _motion_player.has_animation(qualified):
				if not (_motion_player.current_animation == qualified and _motion_player.is_playing()):
					_motion_player.play(qualified)
				played_name = qualified

	if played_name == "":
		_stop_weapon_mirror(false)
		return

	# Apply first-frame values so our post-mix mirror has something to mirror immediately.
	if _motion_player.has_method("advance"):
		_motion_player.advance(0.0)

	_configure_weapon_mirror_for_motion_anim(played_name)

func _play_all_layers(anim_name: String) -> void:
	if anim_name == "":
		return
	if _layers.is_empty():
		return
	if _sprite == null:
		return

	var resolved: String = _resolve_anim_name(anim_name)
	if resolved == "":
		return

	_sprite.play(resolved)

	var i: int = 0
	while i < _layers.size():
		var s: AnimatedSprite2D = _layers[i]
		if s == null:
			i += 1
			continue
		if s == _sprite:
			i += 1
			continue

		var can_play: bool = false
		if s.sprite_frames != null:
			if s.sprite_frames.has_animation(resolved):
				can_play = true
			else:
				var lut: Dictionary = {}
				var names: PackedStringArray = s.sprite_frames.get_animation_names()
				var j: int = 0
				while j < names.size():
					var actual: String = String(names[j])
					lut[actual.to_lower()] = actual
					j += 1
				var key: String = resolved.to_lower()
				if lut.has(key):
					var vv: Variant = lut[key]
					if typeof(vv) == TYPE_STRING:
						var actual2: String = String(vv)
						if actual2 != "":
							s.play(actual2)
							can_play = false

		if can_play:
			s.play(resolved)

		i += 1

	_play_motion_weapon_for_body_anim(resolved)
	_sync_layers_to_master()

func _sync_layers_to_master() -> void:
	if _sprite == null:
		return
	var master_frame: int = _sprite.frame
	var master_progress: float = _sprite.frame_progress
	var i: int = 0
	while i < _layers.size():
		var s: AnimatedSprite2D = _layers[i]
		if s != null and s != _sprite:
			s.frame = master_frame
			s.frame_progress = master_progress
		i += 1

# ----------------------------------------------------------------------------- #
# Weapon post-mix mirroring (fixes "plays both directions" bug)
# ----------------------------------------------------------------------------- #
func _configure_weapon_mirror_for_motion_anim(played_anim: String) -> void:
	# Only mirror when:
	# - we are facing left for a side-single body anim, AND
	# - the weapon motion animation is a *_side_weapon animation.
	var want_left: bool = _want_weapon_mirror_left
	var lower_anim: String = played_anim.to_lower()
	var is_side_weapon: bool = (lower_anim.find("_side_weapon") != -1)

	if not want_left or not is_side_weapon:
		_stop_weapon_mirror(false)
		return

	if _weapon_mirror_active and _weapon_mirror_anim == played_anim:
		# Already configured.
		return

	_weapon_mirror_anim = played_anim
	_weapon_mirror_nodes.clear()
	_weapon_mirror_props.clear()

	var anim: Animation = null
	if _motion_player != null:
		if _motion_player.has_animation(played_anim):
			anim = _motion_player.get_animation(played_anim)

	if anim == null:
		_stop_weapon_mirror(false)
		return

	var root: Node = _motion_player
	if _motion_player != null:
		var rn: NodePath = _motion_player.root_node
		if rn != NodePath(""):
			var rr: Node = _motion_player.get_node_or_null(rn)
			if rr != null:
				root = rr

	var seen: Dictionary = {}

	var tcount: int = anim.get_track_count()
	var ti: int = 0
	while ti < tcount:
		var tp: NodePath = anim.track_get_path(ti)
		var pstr: String = String(tp)
		var colon: int = pstr.rfind(":")
		if colon != -1:
			var node_path_str: String = pstr.substr(0, colon)
			var prop_str: String = pstr.substr(colon + 1, pstr.length() - colon - 1)

			# Only touch weapon rig tracks.
			if node_path_str.find("WeaponRoot") != -1:
				var prop_sn: StringName = StringName(prop_str)
				var accept: bool = false
				if prop_sn == &"position":
					accept = true
				elif prop_sn == &"rotation":
					accept = true
				elif prop_sn == &"rotation_degrees":
					accept = true
				elif prop_sn == &"scale":
					accept = true
				elif prop_sn == &"flip_h":
					accept = true

				if accept:
					var target: Node = null
					if root != null:
						target = root.get_node_or_null(NodePath(node_path_str))
					if target == null and _visual_root != null:
						target = _visual_root.get_node_or_null(NodePath(node_path_str))
					if target == null and _motion_player != null:
						target = _motion_player.get_node_or_null(NodePath(node_path_str))

					if target != null:
						var key: String = String(target.get_path()) + ":" + String(prop_sn)
						if not seen.has(key):
							seen[key] = true
							_weapon_mirror_nodes.append(target)
							_weapon_mirror_props.append(prop_sn)
		ti += 1

	_weapon_mirror_active = true
	set_process(true)

	# Apply immediately for the current frame.
	_apply_weapon_mirror_post_mix()

func _stop_weapon_mirror(unmirror_if_safe: bool) -> void:
	if not _weapon_mirror_active:
		_weapon_mirror_anim = ""
		_weapon_mirror_nodes.clear()
		_weapon_mirror_props.clear()
		set_process(false)
		return

	# Only unmirror when MotionPlayer is not actively driving values anymore.
	var safe_to_unmirror: bool = unmirror_if_safe
	if _motion_player != null:
		if _motion_player.is_playing():
			safe_to_unmirror = false

	if safe_to_unmirror:
		# Mirroring twice restores original (reflection is an involution).
		_apply_weapon_mirror_post_mix()

	_weapon_mirror_active = false
	_weapon_mirror_anim = ""
	_weapon_mirror_nodes.clear()
	_weapon_mirror_props.clear()
	set_process(false)

func _apply_weapon_mirror_post_mix() -> void:
	if not _weapon_mirror_active:
		return

	var i: int = 0
	while i < _weapon_mirror_nodes.size():
		var n: Node = _weapon_mirror_nodes[i]
		if n == null or not is_instance_valid(n):
			i += 1
			continue

		var prop: StringName = _weapon_mirror_props[i]

		if prop == &"position":
			var n2d: Node2D = n as Node2D
			if n2d != null:
				var p: Vector2 = n2d.position
				p.x = -p.x
				n2d.position = p

		elif prop == &"rotation":
			var r2d: Node2D = n as Node2D
			if r2d != null:
				r2d.rotation = PI - r2d.rotation

		elif prop == &"rotation_degrees":
			var rd2d: Node2D = n as Node2D
			if rd2d != null:
				rd2d.rotation_degrees = 180.0 - rd2d.rotation_degrees

		elif prop == &"scale":
			var s2d: Node2D = n as Node2D
			if s2d != null:
				var sc: Vector2 = s2d.scale
				sc.x = -sc.x
				s2d.scale = sc

		elif prop == &"flip_h":
			if n is Sprite2D:
				var sp: Sprite2D = n as Sprite2D
				sp.flip_h = not sp.flip_h
			elif n is AnimatedSprite2D:
				var asp: AnimatedSprite2D = n as AnimatedSprite2D
				asp.flip_h = not asp.flip_h

		i += 1

# ----------------------------------------------------------------------------- #
# Z ordering for weapon
# ----------------------------------------------------------------------------- #
func _apply_weapon_z_for_dir(dir: Vector2) -> void:
	if _weapon_root == null:
		return

	var use_dir: Vector2 = dir
	if use_dir.length() <= 0.001:
		use_dir = _last_dir
	if use_dir.length() <= 0.001:
		use_dir = Vector2.DOWN
	use_dir = use_dir.normalized()

	var ax: float = absf(use_dir.x)
	var ay: float = absf(use_dir.y)

	var front: bool = true
	if ay > ax:
		if use_dir.y < 0.0:
			front = false
		else:
			front = true
	else:
		front = true

	var base_z: int = 0
	if _visual_root != null:
		base_z = _visual_root.z_index
	elif _actor_node != null:
		base_z = _actor_node.z_index
	elif _actor_body != null:
		base_z = _actor_body.z_index

	if front:
		_weapon_root.z_index = base_z + 1
	else:
		_weapon_root.z_index = base_z - 1

# ----------------------------------------------------------------------------- #
# Public action entrypoints
# ----------------------------------------------------------------------------- #
func play_attack_with_prefix(prefix: String, aim_dir: Vector2, hit_frame: int, on_hit: Callable) -> void:
	_play_action_internal("attack", prefix, aim_dir, hit_frame, on_hit, 0.9)

func play_cast_with_prefix(prefix: String, cast_time_sec: float) -> void:
	_play_lock_only("cast", prefix, cast_time_sec)

func play_buff_with_prefix(prefix: String, dur_sec: float = 0.0) -> void:
	_play_lock_only("buff", prefix, minf(dur_sec, 0.2))

func play_projectile_with_prefix(prefix: String, windup_sec: float = 0.0) -> void:
	_play_lock_only("projectile", prefix, windup_sec)

func _play_action_internal(kind: String, prefix: String, aim_dir: Vector2, hit_frame: int, on_hit: Callable, lock_sec: float) -> void:
	if _sprite == null or _sprite.sprite_frames == null:
		return

	if _anim_name_lut.is_empty():
		_rebuild_anim_name_lut()

	var use_prefix: String = prefix
	if use_prefix == "":
		use_prefix = get_action_prefix(kind)

	var anim_name: String = _resolve_anim_for_prefix(use_prefix, aim_dir)
	if anim_name == "":
		return

	var resolved: String = _resolve_anim_name(anim_name)
	if resolved == "":
		return
	anim_name = resolved

	var dir_for_flip: Vector2 = _last_dir
	if aim_dir.length() > 0.001:
		dir_for_flip = aim_dir.normalized()
		_last_dir = dir_for_flip
	facing_changed.emit(_last_dir)

	_apply_horizontal_flip(dir_for_flip, anim_name)
	_apply_weapon_z_for_dir(dir_for_flip)

	_pending_hit_frame = hit_frame
	_pending_hit_callable = on_hit
	_action_lock_until_msec = Time.get_ticks_msec() + int(lock_sec * 1000.0)

	var lock_target: Node = _actor_body
	if lock_target == null:
		lock_target = _actor_node
	if lock_target != null and lock_target.has_method("lock_action"):
		lock_target.call("lock_action", lock_sec)

	action_started.emit(kind, anim_name)
	_play_all_layers(anim_name)

func _anim_length_seconds(anim_name: String) -> float:
	if _sprite == null:
		return 0.0
	if _sprite.sprite_frames == null:
		return 0.0
	if anim_name == "":
		return 0.0

	var resolved: String = _resolve_anim_name(anim_name)
	if resolved == "":
		return 0.0

	var speed: float = _sprite.sprite_frames.get_animation_speed(resolved)
	if speed <= 0.0:
		speed = 1.0

	var count: int = _sprite.sprite_frames.get_frame_count(resolved)
	if count <= 0:
		return 0.0

	var total_units: float = 0.0
	var i: int = 0
	while i < count:
		var dur: float = _sprite.sprite_frames.get_frame_duration(resolved, i)
		if dur <= 0.0:
			dur = 1.0
		total_units += dur
		i += 1

	return total_units / speed

func _play_lock_only(kind: String, prefix: String, lock_sec: float) -> void:
	if _sprite == null:
		return

	if _anim_name_lut.is_empty():
		_rebuild_anim_name_lut()

	var use_prefix: String = prefix
	if use_prefix == "":
		use_prefix = get_action_prefix(kind)

	var aim: Vector2 = _last_dir
	if aim == Vector2.ZERO:
		aim = Vector2.DOWN
	var anim_name: String = _resolve_anim_for_prefix(use_prefix, aim)
	if anim_name == "":
		return

	var resolved: String = _resolve_anim_name(anim_name)
	if resolved == "":
		return
	anim_name = resolved

	var anim_len_sec: float = _anim_length_seconds(anim_name)
	var effective_lock_sec: float = lock_sec
	if anim_len_sec > effective_lock_sec:
		effective_lock_sec = anim_len_sec

	_action_lock_until_msec = Time.get_ticks_msec() + int(maxf(0.0, effective_lock_sec) * 1000.0)

	var lock_target: Node = _actor_body
	if lock_target == null:
		lock_target = _actor_node
	if lock_target != null and lock_target.has_method("lock_action"):
		lock_target.call("lock_action", effective_lock_sec)

	_apply_horizontal_flip(aim, anim_name)
	_apply_weapon_z_for_dir(aim)

	action_started.emit(kind, anim_name)
	_play_all_layers(anim_name)

func _resolve_anim_for_prefix(prefix: String, aim: Vector2) -> String:
	if _sprite == null or _sprite.sprite_frames == null:
		return ""

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

	if ax >= ay:
		if dir.x < 0.0:
			if _has_anim(left_name):
				return left_name
		else:
			if _has_anim(right_name):
				return right_name
		if supports_side_anims and _has_anim(side_name):
			return side_name
		if dir.y < 0.0 and _has_anim(up_name):
			return up_name
		if _has_anim(down_name):
			return down_name
		return _first_existing([left_name, right_name, up_name, down_name, side_name])

	if dir.y < 0.0:
		if _has_anim(up_name):
			return up_name
	else:
		if _has_anim(down_name):
			return down_name

	if dir.x < 0.0:
		if _has_anim(left_name):
			return left_name
	else:
		if _has_anim(right_name):
			return right_name

	if supports_side_anims and _has_anim(side_name):
		return side_name

	return _first_existing([up_name, down_name, left_name, right_name, side_name])

func play_melee_attack(aim_dir: Vector2, hit_frame: int, on_hit: Callable) -> void:
	play_attack_with_prefix(get_action_prefix("attack"), aim_dir, hit_frame, on_hit)

func play_cast(cast_time_sec: float) -> void:
	play_cast_with_prefix(get_action_prefix("cast"), cast_time_sec)

func play_death() -> void:
	if _sprite == null:
		return
	var resolved: String = _resolve_anim_name("death")
	if resolved != "":
		_play_all_layers(resolved)

func play_hit_react() -> void:
	if _sprite == null:
		return
	var resolved: String = _resolve_anim_name("hit")
	if resolved != "":
		_play_all_layers(resolved)

func _on_sprite_frame_changed() -> void:
	if _sprite == null:
		return

	_sync_layers_to_master()

	if _pending_hit_frame >= 0:
		if _sprite.frame == _pending_hit_frame:
			if _pending_hit_callable.is_valid():
				_pending_hit_callable.call()
			_pending_hit_frame = -1
			_pending_hit_callable = Callable()

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

	if not _footstep_was_moving:
		_footstep_was_moving = true
		_footstep_last_pos = _actor_body.global_position

	var frame_index: int = _sprite.frame
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
	var finished_anim: String = ""
	if _sprite != null:
		finished_anim = _sprite.animation

	_pending_hit_frame = -1
	_pending_hit_callable = Callable()
	_action_lock_until_msec = 0

	# Safe to unmirror here (we're leaving the action).
	_stop_weapon_mirror(true)

	var lock_target: Node = _actor_body
	if lock_target == null:
		lock_target = _actor_node
	if lock_target != null and lock_target.has_method("unlock_action"):
		lock_target.call("unlock_action")

	action_finished.emit("", finished_anim)

func set_attack_phase(phase: String) -> void:
	if phase == "":
		return
	attack_phase_changed.emit(phase)

# ----------------------------------------------------------------------------- #
# VFX (unchanged)
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
