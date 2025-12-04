# File: res://world/loot/GiveItemOnInteract.gd
extends Node
class_name GiveItemOnInteract

@export var item: ItemDef
@export var quantity: int = 1
@export var destroy_after: bool = true

func give() -> int:
	if item == null:
		return quantity
	var inv: Node = get_node_or_null("/root/InventorySystem")
	if inv == null:
		inv = get_node_or_null("/root/InventorySys")
	if inv == null:
		return quantity
	if not inv.has_method("give_item"):
		return quantity
	var leftover: int = int(inv.call("give_item", item, quantity))
	if destroy_after and leftover == 0 and is_inside_tree():
		queue_free()
	return leftover
