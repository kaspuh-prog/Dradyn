extends Node
class_name SceneManager

signal area_changed(area: Node, entry_tag: String)

@export var world_root_path: NodePath = NodePath("")

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

	# 1) Fade-out if Transition autoload exists
	var trans: TransitionLayer = get_node_or_null("/root/Transition") as TransitionLayer
	if trans != null:
		await trans.fade_to_black()

	# 2) Unload current area immediately, then let physics settle
	if _current_area != null:
		if is_instance_valid(_current_area):
			if _current_area.get_parent() == world_root:
				world_root.remove_child(_current_area)
			_current_area.free()
		_current_area = null

	await get_tree().process_frame

	# 3) Load and mount the new area
	var packed: PackedScene = load(area_scene_path) as PackedScene
	if packed == null:
		push_error("[SceneManager] change_area: failed to load: " + area_scene_path)
		_swap_in_progress = false
		# If fade-out happened, fade back in to keep UX sane
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

	# 4) Give the new scene one frame to finish _ready()
	await get_tree().process_frame

	# 5) Notify listeners (PartyManager will teleport to EntryPoints during blackout)
	emit_signal("area_changed", _current_area, entry_tag)

	# 6) Optional: one more frame to let followers/camera retarget
	await get_tree().process_frame

	# 7) Fade-in to reveal the new area
	if trans != null:
		await trans.fade_from_black()

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
