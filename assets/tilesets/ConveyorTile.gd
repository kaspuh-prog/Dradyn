@tool
extends Node2D
class_name ConveyorTile

enum ConveyorDirection {
	RIGHT,
	LEFT,
	UP,
	DOWN
}

@export var direction: ConveyorDirection = ConveyorDirection.RIGHT:
	set(value):
		direction = value
		_apply_direction()

@export var sprite_path: NodePath = NodePath("AnimatedSprite2D"):
	set(value):
		sprite_path = value
		_apply_direction()

# If your art is authored facing RIGHT, this is correct.
# If you authored facing LEFT instead, set this to LEFT.
@export var authored_facing: ConveyorDirection = ConveyorDirection.RIGHT:
	set(value):
		authored_facing = value
		_apply_direction()

# If you only care about horizontal belts for now, you can leave vertical disabled.
@export var allow_vertical: bool = true:
	set(value):
		allow_vertical = value
		_apply_direction()

var _sprite: AnimatedSprite2D

func _enter_tree() -> void:
	_cache_nodes()
	_apply_direction()

func _ready() -> void:
	_cache_nodes()
	_apply_direction()

func _cache_nodes() -> void:
	var n: Node = get_node_or_null(sprite_path)
	if n == null:
		_sprite = null
		return
	if n is AnimatedSprite2D:
		_sprite = n
	else:
		_sprite = null

func _apply_direction() -> void:
	if _sprite == null:
		_cache_nodes()
	if _sprite == null:
		return

	var desired: ConveyorDirection = direction

	if allow_vertical == false:
		if desired == ConveyorDirection.UP:
			desired = ConveyorDirection.RIGHT
		if desired == ConveyorDirection.DOWN:
			desired = ConveyorDirection.RIGHT

	# Reset transform baseline.
	_sprite.rotation = 0.0
	_sprite.scale = Vector2.ONE

	# Normalize: treat authored facing as RIGHT baseline.
	# If authored facing is LEFT, we pre-flip to convert it to RIGHT baseline.
	if authored_facing == ConveyorDirection.LEFT:
		_sprite.scale = Vector2(-1.0, 1.0)

	# Apply desired direction from RIGHT baseline.
	if desired == ConveyorDirection.RIGHT:
		return
	elif desired == ConveyorDirection.LEFT:
		_sprite.scale = Vector2(_sprite.scale.x * -1.0, _sprite.scale.y)
	elif desired == ConveyorDirection.UP:
		_sprite.rotation = -PI * 0.5
	elif desired == ConveyorDirection.DOWN:
		_sprite.rotation = PI * 0.5

func get_flow_dir() -> Vector2:
	if direction == ConveyorDirection.RIGHT:
		return Vector2.RIGHT
	elif direction == ConveyorDirection.LEFT:
		return Vector2.LEFT
	elif direction == ConveyorDirection.UP:
		return Vector2.UP
	else:
		return Vector2.DOWN
