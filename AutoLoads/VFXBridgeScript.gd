extends Node
class_name VFXBridgeScript
# Godot 4.5 — fully typed, no ternaries.

@export_group("Lookup")
@export var base_vfx_dir: String = "res://assets/VFX"
@export var recursive_search: bool = false

@export_group("Appearance Defaults")
@export var heal_lifetime: float = 1.20
@export var heal_offset: Vector2 = Vector2(-2, -24)
@export var heal_opacity: float = 0.80
@export var heal_z_index: int = 5

@export var revive_lifetime: float = 1.20
@export var revive_offset: Vector2 = Vector2(0, -20)
@export var revive_opacity: float = 0.90
@export var revive_z_index: int = 6

@export_group("Debug")
@export var debug_logging: bool = false

const GROUP_TRANSIENT_VFX: String = "TransientVFX"
const META_DESPAWN_AT_MS: String = "vfx_despawn_at_ms"


func _ready() -> void:
	# Make sure our cleanup _process runs every frame, even when the game is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func emit_for_node(hint: StringName, target: Node, ctx: Dictionary = {}) -> void:
	if hint == StringName(""):
		return
	if target == null:
		_log("emit_for_node: target is null")
		return

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
		return

	var anchor: Node2D = _best_anchor_for(target)
	if anchor == null:
		_log("No anchor found for target=" + target.name)
		return

	if hint == StringName("revive_target"):
		_spawn_frames_sprite(anchor, frames, revive_lifetime, revive_offset, revive_z_index, revive_opacity)
	else:
		_spawn_frames_sprite(anchor, frames, heal_lifetime, heal_offset, heal_z_index, heal_opacity)


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

	var spr: AnimatedSprite2D = _spawn_frames_sprite(parent, frames, 1.0, Vector2.ZERO, 0, 1.0)
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


func _spawn_frames_sprite(parent: Node2D, frames: SpriteFrames, lifetime: float, offset: Vector2, z_index: int, opacity: float) -> AnimatedSprite2D:
	if parent == null or frames == null:
		return null

	var spr: AnimatedSprite2D = AnimatedSprite2D.new()
	var dup_frames: SpriteFrames = frames.duplicate(true) as SpriteFrames
	spr.sprite_frames = dup_frames
	spr.centered = true
	spr.visible = true
	spr.z_index = z_index

	# Tag as transient VFX so we can hard-clean if timers fail.
	spr.add_to_group(GROUP_TRANSIENT_VFX)
	var now_ms: int = Time.get_ticks_msec()
	var base_ms: int = int(max(0.0, lifetime) * 1000.0)
	var extra_ms: int = 1000
	var despawn_at_ms: int = now_ms + base_ms + extra_ms
	spr.set_meta(META_DESPAWN_AT_MS, despawn_at_ms)

	parent.add_child(spr)

	var n2d: Node2D = spr as Node2D
	if n2d != null:
		n2d.position += offset

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

	spr.animation = anim_name
	spr.play()

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


func _fallback_world_canvas() -> Node2D:
	var root: Node = get_tree().current_scene
	if root == null:
		return null
	var r2d: Node2D = root as Node2D
	return r2d


# Small helpers
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
