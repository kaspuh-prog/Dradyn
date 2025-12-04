extends Resource
class_name LootEntry

# Display / analytics
@export var id: String = ""

# Selection gates
@export var weight: float = 1.0                                  # Weighted roll among eligible entries
@export_range(0.0, 100.0, 0.1) var percent_chance: float = 100.0 # 0–100 gate before weight

# ITEM drop via ItemDef
@export var item_def: ItemDef
@export var min_qty: int = 1
@export var max_qty: int = 1

func get_random_qty(rng: RandomNumberGenerator) -> int:
	var from_value: int = min_qty
	var to_value: int = max_qty
	if to_value < from_value:
		to_value = from_value
	return rng.randi_range(from_value, to_value)

func is_valid_item_entry() -> bool:
	if item_def == null:
		return false
	if max_qty <= 0:
		return false
	return true
