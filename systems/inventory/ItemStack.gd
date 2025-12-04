extends Resource
class_name ItemStack

@export var item: ItemDef
@export var count: int = 1

func can_merge(other: ItemStack) -> bool:
	if item == null:
		return false
	if other == null:
		return false
	if other.item == null:
		return false
	if item.id != other.item.id:
		return false
	return true

func remaining_capacity() -> int:
	if item == null:
		return 0
	var cap: int = item.stack_max
	if cap < 1:
		cap = 1
	var rem: int = cap - count
	if rem < 0:
		rem = 0
	return rem
