# TestArea.gd
extends Node2D

func _ready() -> void:
	_set_z($L0_Ground, -10)
	_set_z($L1_Details, -5)
	_set_z($L3_Overhangs, 10)
	_set_z($L2_Colliders, 1) # only if you keep it visible

	# Normalize all actor sprites under PartyRoot at runtime
	var party_root := get_tree().root.find_child("PartyRoot", true, false)
	if party_root:
		for a in party_root.get_children():
			_normalize_actor_sprite_z(a)

func _set_z(node: Node, z: int) -> void:
	if node and node is CanvasItem:
		(node as CanvasItem).z_index = z
		(node as CanvasItem).z_as_relative = false

func _normalize_actor_sprite_z(actor: Node) -> void:
	if actor == null: return
	# Find the visual (Sprite2D/AnimatedSprite2D) and set relative Z
	var sprite := actor.find_child("Sprite2D", true, false)
	if sprite == null:
		sprite = actor.find_child("AnimatedSprite2D", true, false)
	if sprite and sprite is CanvasItem:
		(sprite as CanvasItem).z_index = 0
		(sprite as CanvasItem).z_as_relative = true
