extends Node2D
class_name AreaTemplate

@export var tileset: TileSet

@onready var _l0_ground: TileMapLayer = $L0_Ground
@onready var _l1_details: TileMapLayer = $L1_Details
@onready var _l2_colliders: TileMapLayer = $L2_Colliders
@onready var _l3_overhangs: TileMapLayer = $L3_Overhangs

const Z_GROUND: int = -10
const Z_DETAILS: int = -3
const Z_COLLIDERS_ABSOLUTE: int = -4
const Z_OVERHANGS: int = 10

func _ready() -> void:
	_apply_tileset_to_layers()
	_apply_z_order_defaults()

func _apply_tileset_to_layers() -> void:
	if tileset == null:
		return
	_l0_ground.tile_set = tileset
	_l1_details.tile_set = tileset
	_l2_colliders.tile_set = tileset
	_l3_overhangs.tile_set = tileset

func _apply_z_order_defaults() -> void:
	# Ground and Details use normal relative z.
	_l0_ground.z_as_relative = true
	_l0_ground.z_index = Z_GROUND

	_l1_details.z_as_relative = true
	_l1_details.z_index = Z_DETAILS

	# Colliders become an absolute back-plane: ignore any per-tile z,
	# and use a very low absolute z so actors (0/1) always render above.
	_l2_colliders.z_as_relative = false
	_l2_colliders.z_index = Z_COLLIDERS_ABSOLUTE

	# Overhangs on top (relative is fine here).
	_l3_overhangs.z_as_relative = true
	_l3_overhangs.z_index = Z_OVERHANGS
