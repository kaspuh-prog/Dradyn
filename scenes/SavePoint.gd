extends Node2D
class_name SavePoint

## Interactable save point.
## Works with InteractionSys via:
## - group "interactable"
## - interact(actor)
## - get_interact_radius()
## - set_interact_highlight(on)
## - get_interact_prompt()

signal save_requested(save_point: SavePoint, actor: Node)

@export var auto_register_group: bool = true
@export var interact_radius: float = 32.0

@export_group("UI")
@export var interact_prompt: String = "Save"
@export var prompt_text: String = "Save your game?"
@export var speaker_name: String = "Statue of Guldah"

@export_group("Highlight")
@export var highlight_enabled: bool = false
@export var highlight_modulate: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var highlight_scale: Vector2 = Vector2(1.08, 1.08)
@export var sprite_node_path: NodePath = NodePath("")

var _sprite_2d: Sprite2D = null
var _anim_sprite_2d: AnimatedSprite2D = null
var _orig_modulate: Color = Color(1.0, 1.0, 1.0, 1.0)
var _orig_scale: Vector2 = Vector2.ONE

func _ready() -> void:
	if auto_register_group:
		add_to_group(&"interactable")

	_resolve_sprite_cache()

func interact(actor: Node) -> void:
	save_requested.emit(self, actor)

func get_interact_radius() -> float:
	if interact_radius > 0.0:
		return interact_radius
	return 32.0

func get_interact_prompt() -> String:
	# InteractionPromptHUD requires a non-empty prompt string.
	var p: String = interact_prompt.strip_edges()
	if p == "":
		return "Interact"
	return p

func set_interact_highlight(on: bool) -> void:
	if not highlight_enabled:
		return

	_resolve_sprite_cache()
	if _sprite_2d == null and _anim_sprite_2d == null:
		return

	if on:
		_set_sprite_modulate(highlight_modulate)
		_set_sprite_scale(_orig_scale * highlight_scale)
	else:
		_set_sprite_modulate(_orig_modulate)
		_set_sprite_scale(_orig_scale)

func _resolve_sprite_cache() -> void:
	if _sprite_2d != null or _anim_sprite_2d != null:
		return

	var n: Node = null
	if sprite_node_path != NodePath(""):
		n = get_node_or_null(sprite_node_path)
	else:
		n = find_child("Sprite2D", true, false)
		if n == null:
			n = find_child("AnimatedSprite2D", true, false)

	_sprite_2d = n as Sprite2D
	_anim_sprite_2d = n as AnimatedSprite2D

	if _sprite_2d != null:
		_orig_modulate = _sprite_2d.modulate
		_orig_scale = _sprite_2d.scale
	elif _anim_sprite_2d != null:
		_orig_modulate = _anim_sprite_2d.modulate
		_orig_scale = _anim_sprite_2d.scale

func _set_sprite_modulate(c: Color) -> void:
	if _sprite_2d != null:
		_sprite_2d.modulate = c
		return
	if _anim_sprite_2d != null:
		_anim_sprite_2d.modulate = c

func _set_sprite_scale(s: Vector2) -> void:
	if _sprite_2d != null:
		_sprite_2d.scale = s
		return
	if _anim_sprite_2d != null:
		_anim_sprite_2d.scale = s
