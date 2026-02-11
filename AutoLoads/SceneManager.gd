extends Node
class_name SceneManager

signal area_changed(area: Node, entry_tag: String)

@export var world_root_path: NodePath = NodePath("")

@export_group("Diagnostics / Safety")
@export var sanitize_animated_sprites: bool = true
@export var sanitize_entire_tree_during_swap: bool = true
@export var debug_sanitize_logs: bool = false

@onready var world_root: Node = null
var _current_area: Node = null
var _swap_in_progress: bool = false


func _ready() -> void:
	_ensure_world_root()


# Public API — always defer to escape physics flush and input callbacks
func change_area(area_scene_path: String, entry_tag: String = "default") -> void:
	call_deferred("_change_area_internal", area_scene_path, entry_tag)


func _change_area_internal(area_scene_path: String, entry_tag: String) -> void:
	if _swap_in_progress:
		return
	_swap_in_progress = true

	_ensure_world_root()
	if world_root == null:
		push_error("[SceneManager] change_area: WorldRoot not found.")
		_swap_in_progress = false
		return

	# Pre-sanitize before we start doing awaits (catches offenders outside the area too).
	if sanitize_animated_sprites and sanitize_entire_tree_during_swap:
		_sanitize_animated_sprites_in(get_tree().root, "pre_swap_tree")

	# 1) Fade-out if Transition autoload exists
	var trans: TransitionLayer = get_node_or_null("/root/Transition") as TransitionLayer
	if trans != null:
		await trans.fade_to_black()

	# Sanitize again after fade-out in case Transition updated sprites.
	if sanitize_animated_sprites and sanitize_entire_tree_during_swap:
		_sanitize_animated_sprites_in(get_tree().root, "post_fade_to_black_tree")

	# 2) Unload current area immediately, then let physics settle
	if _current_area != null:
		if is_instance_valid(_current_area):
			if sanitize_animated_sprites:
				_sanitize_animated_sprites_in(_current_area, "pre_free_area")

			if _current_area.get_parent() == world_root:
				world_root.remove_child(_current_area)

			_current_area.queue_free()

		_current_area = null

	# IMPORTANT: sanitize BEFORE the frame tick that was previously blowing up
	if sanitize_animated_sprites and sanitize_entire_tree_during_swap:
		_sanitize_animated_sprites_in(get_tree().root, "pre_unload_frame_tree")

	await get_tree().process_frame

	# 3) Load and mount the new area
	var packed: PackedScene = load(area_scene_path) as PackedScene
	if packed == null:
		push_error("[SceneManager] change_area: failed to load: " + area_scene_path)
		_swap_in_progress = false
		if trans != null:
			await trans.fade_from_black()
		return

	var new_area: Node = packed.instantiate()
	if new_area == null:
		push_error("[SceneManager] change_area: failed to instantiate: " + area_scene_path)
		_swap_in_progress = false
		if trans != null:
			await trans.fade_from_black()
		return

	world_root.add_child(new_area)
	_current_area = new_area
	_current_area.name = _derive_area_name_from_path(area_scene_path)

	# CRITICAL: sanitize IMMEDIATELY after mounting, before first frame tick.
	if sanitize_animated_sprites:
		_sanitize_animated_sprites_in(_current_area, "post_mount_area")
		if sanitize_entire_tree_during_swap:
			_sanitize_animated_sprites_in(get_tree().root, "post_mount_tree")

	# 4) Give the new scene one frame to finish _ready()
	await get_tree().process_frame

	# Sanitize again after _ready() ran.
	if sanitize_animated_sprites:
		_sanitize_animated_sprites_in(_current_area, "post_ready_area")
		if sanitize_entire_tree_during_swap:
			_sanitize_animated_sprites_in(get_tree().root, "post_ready_tree")

	# 5) Notify listeners (PartyManager will teleport to EntryPoints during blackout)
	emit_signal("area_changed", _current_area, entry_tag)

	# 6) Optional: one more frame to let followers/camera retarget
	# Sanitize before this tick as well.
	if sanitize_animated_sprites and sanitize_entire_tree_during_swap:
		_sanitize_animated_sprites_in(get_tree().root, "pre_post_emit_frame_tree")

	await get_tree().process_frame

	# 7) Fade-in to reveal the new area
	if trans != null:
		await trans.fade_from_black()

	# One last sanitize after fade-in (Transition may animate sprites)
	if sanitize_animated_sprites and sanitize_entire_tree_during_swap:
		_sanitize_animated_sprites_in(get_tree().root, "post_fade_from_black_tree")

	_swap_in_progress = false


func get_current_area() -> Node:
	return _current_area


func _ensure_world_root() -> void:
	if world_root != null:
		return
	if world_root_path != NodePath(""):
		var wr: Node = get_node_or_null(world_root_path)
		if wr != null:
			world_root = wr
			return
	world_root = get_tree().root.find_child("WorldRoot", true, false)


func _derive_area_name_from_path(p: String) -> String:
	var slash: int = p.rfind("/")
	var dot: int = p.rfind(".")
	if slash == -1:
		slash = 0
	else:
		slash += 1
	if dot == -1:
		dot = p.length()
	return p.substr(slash, dot - slash)


# -------------------------------------------------
# AnimatedSprite2D sanitizer
# - If AnimatedSprite2D has no frames or no animations, disable it (stop + set_process false)
# - If it has frames but current animation is empty/missing, pick a valid one and stop
# -------------------------------------------------
func _sanitize_animated_sprites_in(root: Node, context: String) -> void:
	if root == null:
		return

	var sprites: Array[Node] = root.find_children("*", "AnimatedSprite2D", true, false)
	for n in sprites:
		var spr: AnimatedSprite2D = n as AnimatedSprite2D
		if spr == null:
			continue
		_sanitize_one_sprite(spr, context)


func _sanitize_one_sprite(spr: AnimatedSprite2D, context: String) -> void:
	if spr.sprite_frames == null:
		_disable_empty_sprite(spr, context, "sprite_frames=null")
		return

	var names: PackedStringArray = spr.sprite_frames.get_animation_names()
	if names.size() == 0:
		_disable_empty_sprite(spr, context, "no_animations")
		return

	var current_anim: String = String(spr.animation)
	if current_anim == "" or not spr.sprite_frames.has_animation(current_anim):
		var chosen: String = names[0]
		spr.animation = chosen
		spr.stop()

		if debug_sanitize_logs:
			print("[SceneManager] sanitize AnimatedSprite2D ", _safe_node_path(spr), " ctx=", context, " bad_anim='", current_anim, "' -> '", chosen, "'")


func _disable_empty_sprite(spr: AnimatedSprite2D, context: String, reason: String) -> void:
	if spr.is_playing():
		spr.stop()

	spr.set_process(false)
	spr.set_physics_process(false)

	if debug_sanitize_logs:
		print("[SceneManager] disable empty AnimatedSprite2D ", _safe_node_path(spr), " ctx=", context, " reason=", reason)


func _safe_node_path(n: Node) -> String:
	if n == null:
		return "<null>"
	if n.is_inside_tree():
		return String(n.get_path())
	return "<not_in_tree>"
