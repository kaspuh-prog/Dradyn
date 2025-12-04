extends Area2D
class_name InteractableDoor

@export var target_scene_path: String = ""
@export var entry_tag: String = "default"
@export var require_press: bool = true

# NEW: let the door be easier to grab without changing global radius
@export var interact_radius_override: float = 48.0
func get_interact_radius() -> float:
	return interact_radius_override

# NEW: animation wiring
@export var animated_sprite_path: NodePath
@export var open_animation: StringName = "open"
@export var closed_animation: StringName = "closed"

const GROUP_LEADER: String = "PartyLeader"

var _sprite: AnimatedSprite2D = null


func get_interact_prompt() -> String:
	if target_scene_path == "":
		return ""
	return "Open"


func can_interact(actor: Node) -> bool:
	if target_scene_path == "":
		return false
	if actor == null:
		return false
	return true


func interact(actor: Node) -> void:
	if not can_interact(actor):
		return

	_play_open_visual()

	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm == null:
		return
	if sm.has_method("change_area"):
		sm.call("change_area", target_scene_path, entry_tag)


func _on_body_entered(body: Node) -> void:
	if not require_press:
		if body != null:
			if body.is_in_group(GROUP_LEADER):
				interact(body)


func _ready() -> void:
	if not is_in_group("interactable"):
		add_to_group("interactable")
	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))

	_resolve_sprite()
	_play_closed_visual()


# -------------------------------------------------
# Visual helpers
# -------------------------------------------------

func _resolve_sprite() -> void:
	_sprite = null

	if animated_sprite_path != NodePath(""):
		var node: Node = get_node_or_null(animated_sprite_path)
		if node != null and node is AnimatedSprite2D:
			_sprite = node as AnimatedSprite2D
	else:
		var direct: Node = get_node_or_null("AnimatedSprite2D")
		if direct != null and direct is AnimatedSprite2D:
			_sprite = direct as AnimatedSprite2D


func _play_closed_visual() -> void:
	if _sprite == null:
		return

	var anim_name: String = String(closed_animation)
	if anim_name == "":
		return

	if _sprite.sprite_frames != null:
		if _sprite.sprite_frames.has_animation(anim_name):
			_sprite.play(anim_name)
		else:
			# Fallback: still try to play, in case animations were renamed later.
			_sprite.play(anim_name)
	else:
		_sprite.play(anim_name)


func _play_open_visual() -> void:
	if _sprite == null:
		return

	var anim_name: String = String(open_animation)
	if anim_name == "":
		return

	if _sprite.sprite_frames != null:
		if _sprite.sprite_frames.has_animation(anim_name):
			_sprite.play(anim_name)
		else:
			_sprite.play(anim_name)
	else:
		_sprite.play(anim_name)
