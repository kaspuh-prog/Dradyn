extends Node
class_name VFXBridgeScript
# Godot 4.5 — fully typed, no ternaries.

@export_group("Lookup")
@export var base_vfx_dir: String = "res://assets/VFX"
@export var recursive_search: bool = false

@export_group("Appearance Defaults")
@export var heal_lifetime: float = 1.20
# Legacy (kept for compatibility; no longer used)
@export var heal_offset: Vector2 = Vector2(-2, -24)
@export var heal_opacity: float = 0.80
@export var heal_z_index: int = 5

@export var revive_lifetime: float = 1.20
# Legacy (kept for compatibility; no longer used)
@export var revive_offset: Vector2 = Vector2(0, -20)
@export var revive_opacity: float = 0.90
@export var revive_z_index: int = 6

@export_group("Global VFX Offset")
@export var vfx_offset_from_center: Vector2 = Vector2(0, -4)
# You can override per-cast via ctx["vfx_offset"] = Vector2(...)

@export_group("Auto Scale")
@export var auto_scale_enabled: bool = true
@export var auto_scale_only_down: bool = true
@export var auto_scale_target_height_px: float = 64.0
@export var auto_scale_max_width_px: float = 64.0
@export var auto_scale_min_scale: float = 0.12
@export var auto_scale_max_scale: float = 3.0

# ctx overrides supported:
#  - vfx_disable_auto_scale: bool
#  - vfx_target_height_px: float
#  - vfx_max_width_px: float
#  - vfx_scale: float   (multiplies final computed scale)
#  - vfx_offset: Vector2 (overrides vfx_offset_from_center)

@export_group("Debug")
@export var debug_logging: bool = false

const GROUP_TRANSIENT_VFX: String = "TransientVFX"
const META_DESPAWN_AT_MS: String = "vfx_despawn_at_ms"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


# -------------------------------------------------------------------
# Public API (legacy): emit and forget
# -------------------------------------------------------------------
func emit_for_node(hint: StringName, target: Node, ctx: Dictionary = {}) -> void:
	emit_for_node_sprite(hint, target, ctx)


# -------------------------------------------------------------------
# Public API (NEW): emit and return the spawned sprite (for frame hooks)
# -------------------------------------------------------------------
func emit_for_node_sprite(hint: StringName, target: Node, ctx: Dictionary = {}) -> AnimatedSprite2D:
	if hint == StringName(""):
		return null
	if target == null:
		_log("emit_for_node_sprite: target is null")
		return null

	var frames: SpriteFrames = _resolve_frames_by_ctx(ctx)

	if frames == null:
		var hint_str: String = String(hint)
		if hint_str != "":
			_log("Trying hint-as-name: " + hint_str)
			frames = _try_find_frames_in_folder(hint_str)
			if frames != null:
				_log("Resolved VFX frames via hint: " + hint_str)

	if frames == null:
		_log("No frames resolved for hint=" + String(hint))
		return null

	var anchor: Node2D = _best_anchor_for(target)
	if anchor == null:
		_log("No anchor found for target=" + target.name)
		return null

	# NOTE: Offsets are now globally controlled by vfx_offset_from_center (or ctx["vfx_offset"]).
	if hint == StringName("revive_target"):
		return _spawn_frames_sprite(anchor, frames, revive_lifetime, Vector2.ZERO, revive_z_index, revive_opacity, ctx, hint)

	return _spawn_frames_sprite(anchor, frames, heal_lifetime, Vector2.ZERO, heal_z_index, heal_opacity, ctx, hint)


func emit_at_position(hint: StringName, world_position: Vector2, ctx: Dictionary = {}, parent_hint: Node = null) -> void:
	if hint == StringName(""):
		return

	var frames: SpriteFrames = _resolve_frames_by_ctx(ctx)
	if frames == null:
		var hint_str: String = String(hint)
		if hint_str != "":
			frames = _try_find_frames_in_folder(hint_str)

	if frames == null:
		return

	var parent: Node2D = parent_hint as Node2D
	if parent == null:
		parent = _fallback_world_canvas()
	if parent == null:
		return

	var spr: AnimatedSprite2D = _spawn_frames_sprite(parent, frames, 1.0, Vector2.ZERO, 0, 1.0, ctx, hint)
	if spr != null:
		spr.global_position = world_position


# -------------------------------------------------------------------
# Safety broom: ensure transient VFX never linger forever
# -------------------------------------------------------------------
func _process(delta: float) -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var now_ms: int = Time.get_ticks_msec()
	var nodes: Array[Node] = tree.get_nodes_in_group(GROUP_TRANSIENT_VFX)

	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		i += 1

		if not is_instance_valid(n):
			continue

		var spr: AnimatedSprite2D = n as AnimatedSprite2D
		if spr == null:
			continue

		if not spr.has_meta(META_DESPAWN_AT_MS):
			continue

		var despawn_any: Variant = spr.get_meta(META_DESPAWN_AT_MS)
		var despawn_ms: int = int(despawn_any)

		if now_ms >= despawn_ms:
			spr.queue_free()


# --- Internals --------------------------------------------------------------- #
func _best_anchor_for(target: Node) -> Node2D:
	var n2d: Node2D = null
	if target.has_node("VFXAnchor"):
		var a: Node = target.get_node("VFXAnchor")
		n2d = a as Node2D
		if n2d != null:
			return n2d
	n2d = target as Node2D
	if n2d != null:
		return n2d
	var p: Node = target.get_parent()
	while p != null:
		var pn2d: Node2D = p as Node2D
		if pn2d != null:
			return pn2d
		p = p.get_parent()
	return null


func _resolve_frames_by_ctx(ctx: Dictionary) -> SpriteFrames:
	var candidates: PackedStringArray = PackedStringArray()
	if ctx.has("vfx_name"):
		var v1: Variant = ctx["vfx_name"]
		if typeof(v1) == TYPE_STRING:
			candidates.append(String(v1))
	if ctx.has("ability_id"):
		var v2: Variant = ctx["ability_id"]
		if typeof(v2) == TYPE_STRING:
			var s: String = String(v2)
			candidates.append(s)
			candidates.append(_to_camel_no_space(s))
	if ctx.has("ability_name"):
		var v3: Variant = ctx["ability_name"]
		if typeof(v3) == TYPE_STRING:
			var s2: String = String(v3)
			candidates.append(s2)
			candidates.append(_strip_non_alnum(s2))
	if ctx.has("display_name"):
		var v4: Variant = ctx["display_name"]
		if typeof(v4) == TYPE_STRING:
			var s3: String = String(v4)
			candidates.append(s3)
			candidates.append(_strip_non_alnum(s3))

	var checked: Dictionary = {}
	var i: int = 0
	while i < candidates.size():
		var c: String = candidates[i]
		if c != "":
			if not checked.has(c):
				checked[c] = true
				var frames: SpriteFrames = _try_find_frames_in_folder(c)
				if frames != null:
					_log("Resolved VFX frames for " + c)
					return frames
		i += 1
	return null


func _try_find_frames_in_folder(base_name: String) -> SpriteFrames:
	var attempts: PackedStringArray = PackedStringArray()
	attempts.append("%s.tres" % base_name)
	attempts.append("%s.tres" % base_name.to_lower())
	attempts.append("%s.tres" % _strip_non_alnum(base_name))

	var i: int = 0
	while i < attempts.size():
		var file_name: String = attempts[i]
		var full_path: String = _join_path(base_vfx_dir, file_name)
		_log("Try load: " + full_path)
		var frames: SpriteFrames = _try_load_frames(full_path)
		if frames != null:
			return frames
		i += 1

	if recursive_search:
		return _recursive_search_level1(base_name)
	return null


func _recursive_search_level1(base_name: String) -> SpriteFrames:
	if not DirAccess.dir_exists_absolute(base_vfx_dir):
		return null
	var dir: DirAccess = DirAccess.open(base_vfx_dir)
	if dir == null:
		return null
	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break
		if name == "." or name == "..":
			continue
		var sub: String = base_vfx_dir.path_join(name)
		if DirAccess.dir_exists_absolute(sub):
			var p1: String = sub.path_join("%s.tres" % base_name)
			var p2: String = sub.path_join("%s.tres" % base_name.to_lower())
			var p3: String = sub.path_join("%s.tres" % _strip_non_alnum(base_name))
			_log("Rec try: " + p1)
			var f1: SpriteFrames = _try_load_frames(p1)
			if f1 != null:
				return f1
			_log("Rec try: " + p2)
			var f2: SpriteFrames = _try_load_frames(p2)
			if f2 != null:
				return f2
			_log("Rec try: " + p3)
			var f3: SpriteFrames = _try_load_frames(p3)
			if f3 != null:
				return f3
	return null


func _try_load_frames(path: String) -> SpriteFrames:
	if path == "":
		return null
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = ResourceLoader.load(path)
	var frames: SpriteFrames = res as SpriteFrames
	if frames == null:
		_log("Not a SpriteFrames: " + path)
	return frames


func _spawn_frames_sprite(
	parent: Node2D,
	frames: SpriteFrames,
	lifetime: float,
	offset: Vector2,
	z_index: int,
	opacity: float,
	ctx: Dictionary = {},
	hint: StringName = &""
) -> AnimatedSprite2D:
	if parent == null or frames == null:
		return null

	var spr: AnimatedSprite2D = AnimatedSprite2D.new()
	var dup_frames: SpriteFrames = frames.duplicate(true) as SpriteFrames
	spr.sprite_frames = dup_frames
	spr.centered = true
	spr.visible = true
	spr.z_index = z_index

	var scale_factor: float = _compute_vfx_scale(dup_frames, ctx)
	if scale_factor != 1.0:
		spr.scale = Vector2(scale_factor, scale_factor)

	spr.add_to_group(GROUP_TRANSIENT_VFX)
	var now_ms: int = Time.get_ticks_msec()
	var base_ms: int = int(max(0.0, lifetime) * 1000.0)
	var extra_ms: int = 1000
	var despawn_at_ms: int = now_ms + base_ms + extra_ms
	spr.set_meta(META_DESPAWN_AT_MS, despawn_at_ms)

	parent.add_child(spr)

	var final_offset: Vector2 = Vector2.ZERO
	final_offset += offset
	final_offset += _resolve_vfx_offset(ctx)

	var n2d: Node2D = spr as Node2D
	if n2d != null:
		n2d.position += final_offset

	var ci: CanvasItem = spr as CanvasItem
	if ci != null:
		var m: Color = ci.modulate
		m.a = opacity
		ci.modulate = m

	var anim_name: String = "default"
	if dup_frames != null:
		if not dup_frames.has_animation(anim_name):
			var names: PackedStringArray = dup_frames.get_animation_names()
			if names.size() > 0:
				anim_name = names[0]

	if dup_frames != null:
		dup_frames.set_animation_loop(anim_name, false)

	spr.animation = anim_name
	spr.play()

	spr.animation_finished.connect(func() -> void:
		if is_instance_valid(spr):
			spr.queue_free()
	)

	var timer: Timer = Timer.new()
	timer.one_shot = true
	timer.wait_time = max(0.0, lifetime)
	timer.autostart = true
	spr.add_child(timer)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(spr):
			spr.queue_free()
	)

	return spr


func _resolve_vfx_offset(ctx: Dictionary) -> Vector2:
	if ctx.has("vfx_offset"):
		var v: Variant = ctx["vfx_offset"]
		if typeof(v) == TYPE_VECTOR2:
			return v as Vector2
	return vfx_offset_from_center


func _compute_vfx_scale(frames: SpriteFrames, ctx: Dictionary) -> float:
	var final_scale: float = 1.0

	var disable_auto: bool = false
	if ctx.has("vfx_disable_auto_scale"):
		var v_disable: Variant = ctx["vfx_disable_auto_scale"]
		if typeof(v_disable) == TYPE_BOOL:
			disable_auto = bool(v_disable)

	var target_h: float = auto_scale_target_height_px
	if ctx.has("vfx_target_height_px"):
		var v_th: Variant = ctx["vfx_target_height_px"]
		if typeof(v_th) == TYPE_FLOAT or typeof(v_th) == TYPE_INT:
			target_h = float(v_th)

	var max_w: float = auto_scale_max_width_px
	if ctx.has("vfx_max_width_px"):
		var v_mw: Variant = ctx["vfx_max_width_px"]
		if typeof(v_mw) == TYPE_FLOAT or typeof(v_mw) == TYPE_INT:
			max_w = float(v_mw)

	if auto_scale_enabled and not disable_auto:
		var anim_name: String = "default"
		if not frames.has_animation(anim_name):
			var names: PackedStringArray = frames.get_animation_names()
			if names.size() > 0:
				anim_name = names[0]

		var tex: Texture2D = null
		if frames.has_animation(anim_name):
			if frames.get_frame_count(anim_name) > 0:
				tex = frames.get_frame_texture(anim_name, 0)

		if tex != null:
			var w: float = float(tex.get_width())
			var h: float = float(tex.get_height())

			var scale_h: float = 1.0
			if h > 0.0 and target_h > 0.0:
				scale_h = target_h / h

			var scale_w: float = 1.0
			if max_w > 0.0 and w > 0.0:
				scale_w = max_w / w

			var computed: float = scale_h
			if scale_w < computed:
				computed = scale_w

			if auto_scale_only_down:
				if computed > 1.0:
					computed = 1.0

			if computed < auto_scale_min_scale:
				computed = auto_scale_min_scale
			if computed > auto_scale_max_scale:
				computed = auto_scale_max_scale

			final_scale = computed

	if ctx.has("vfx_scale"):
		var v_scale: Variant = ctx["vfx_scale"]
		if typeof(v_scale) == TYPE_FLOAT or typeof(v_scale) == TYPE_INT:
			var mul: float = float(v_scale)
			final_scale *= mul

	return final_scale


func _fallback_world_canvas() -> Node2D:
	var root: Node = get_tree().current_scene
	if root == null:
		return null
	var r2d: Node2D = root as Node2D
	return r2d


func _to_camel_no_space(s: String) -> String:
	var parts: PackedStringArray = s.split("_", false)
	var out: String = ""
	var i: int = 0
	while i < parts.size():
		var p: String = parts[i]
		if p.length() > 0:
			out += p.substr(0, 1).to_upper() + p.substr(1).to_lower()
		i += 1
	return out


func _strip_non_alnum(s: String) -> String:
	var out: String = ""
	var i: int = 0
	while i < s.length():
		var ch: String = s.substr(i, 1)
		var code: int = ch.unicode_at(0)
		var is_num: bool = code >= 48 and code <= 57
		var is_up: bool = code >= 65 and code <= 90
		var is_low: bool = code >= 97 and code <= 122
		if is_num or is_up or is_low:
			out += ch
		i += 1
	return out


func _join_path(a: String, b: String) -> String:
	if a.ends_with("/"):
		return a + b
	return a + "/" + b


func _log(msg: String) -> void:
	if debug_logging:
		print("[VFXBridge] " + msg)
