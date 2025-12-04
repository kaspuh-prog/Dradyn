extends Control
class_name PortraitCluster

## Signals in your project:
## - PartyManager emits: controlled_changed(new_leader: Node)
## - PartyManager has: get_controlled() -> Node

@export var portrait_node: NodePath = ^"Portrait"  # TextureRect inside PortraitCluster
@export var party_manager_path: NodePath           # Optional: set to /root/PartyManager if you prefer
@export var search_party_manager_by_group: bool = true
@export var party_manager_group_name: String = "PartyManager"

@onready var _portrait: TextureRect = get_node(portrait_node) as TextureRect

var _party_manager: Node = null

func _ready() -> void:
	# Basic safety: ensure the portrait TextureRect exists
	if _portrait == null:
		push_warning("PortraitCluster: Portrait TextureRect not found. Please set `portrait_node`.")
		return

	# Try to resolve PartyManager (explicit path first, then group)
	_resolve_party_manager()

	# Initialize from current controlled, if available
	if _party_manager != null and _party_manager.has_method("get_controlled"):
		var leader: Node = _party_manager.call("get_controlled") as Node
		_update_portrait_from_leader(leader)

func _exit_tree() -> void:
	_disconnect_party_manager()

func _resolve_party_manager() -> void:
	_disconnect_party_manager()

	var candidate: Node = null

	# 1) Explicit NodePath if provided
	if party_manager_path != NodePath(""):
		var node_candidate: Node = get_node_or_null(party_manager_path)
		if node_candidate != null:
			candidate = node_candidate

	# 2) Fallback: search by group if allowed
	if candidate == null and search_party_manager_by_group:
		var list: Array[Node] = get_tree().get_nodes_in_group(party_manager_group_name)
		if list.size() > 0:
			candidate = list[0]

	_party_manager = candidate

	# Connect to controlled_changed if present
	if _party_manager != null:
		if _party_manager.has_signal("controlled_changed"):
			_party_manager.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
		else:
			push_warning("PortraitCluster: PartyManager found but does not have `controlled_changed` signal.")

func _disconnect_party_manager() -> void:
	if _party_manager != null:
		if _party_manager.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
			_party_manager.disconnect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
	_party_manager = null

func _on_party_controlled_changed(new_leader: Node) -> void:
	_update_portrait_from_leader(new_leader)

func _update_portrait_from_leader(leader: Node) -> void:
	if leader == null:
		_set_portrait_texture(null)
		return

	# 1) Preferred: character provides a dedicated portrait texture
	if leader.has_method("get_portrait_texture"):
		var tex: Texture2D = leader.call("get_portrait_texture") as Texture2D
		if tex != null:
			_set_portrait_texture(tex)
			return

	# 2) Try AnimatedSprite2D → SpriteFrames → "idle_down" frame 0
	var anim_sprite: AnimatedSprite2D = _find_first_animated_sprite2d(leader)
	if anim_sprite != null:
		var frames: SpriteFrames = anim_sprite.sprite_frames
		if frames != null:
			if frames.has_animation("idle_down"):
				if frames.get_frame_count("idle_down") > 0:
					var frame_tex: Texture2D = frames.get_frame_texture("idle_down", 0)
					if frame_tex != null:
						_set_portrait_texture(frame_tex)
						return

	# 3) Fallback: any Sprite2D texture
	var sprite2d: Sprite2D = _find_first_sprite2d(leader)
	if sprite2d != null:
		var spr_tex: Texture2D = sprite2d.texture
		if spr_tex != null:
			_set_portrait_texture(spr_tex)
			return

	# Nothing found
	_set_portrait_texture(null)

func _set_portrait_texture(tex: Texture2D) -> void:
	# Set TextureRect properties for pixel art clarity
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_portrait.texture = tex

# --------- Helpers ---------

func _find_first_animated_sprite2d(root: Node) -> AnimatedSprite2D:
	# Search breadth-first for an AnimatedSprite2D under the leader
	var q: Array[Node] = []
	q.append(root)
	while q.size() > 0:
		var n: Node = q.pop_front()
		var aspr: AnimatedSprite2D = n as AnimatedSprite2D
		if aspr != null:
			return aspr
		# enqueue children
		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1
	return null

func _find_first_sprite2d(root: Node) -> Sprite2D:
	var q: Array[Node] = []
	q.append(root)
	while q.size() > 0:
		var n: Node = q.pop_front()
		var spr: Sprite2D = n as Sprite2D
		if spr != null and spr.texture != null:
			return spr
		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1
	return null
