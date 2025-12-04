extends Node
class_name InventoryModel
## Party-wide bag of fixed-size slots with 16x16 icons (visual added in Step 2).

signal inventory_changed()
signal item_used(slot_index: int, ok: bool)

@export var slots: int = 64
var _stacks: Array[ItemStack] = []

func _ready() -> void:
	var i: int = 0
	while i < slots:
		_stacks.append(null)
		i += 1

func get_stacks() -> Array:
	return _stacks.duplicate(true)

func slot_count() -> int:
	return _stacks.size()

func get_slot_stack(index: int) -> ItemStack:
	if index < 0:
		return null
	if index >= _stacks.size():
		return null
	return _stacks[index] as ItemStack

func set_stack(index: int, stack: ItemStack) -> void:
	if index < 0:
		return
	if index >= _stacks.size():
		return
	_stacks[index] = stack
	emit_signal("inventory_changed")

func add_item(item: ItemDef, amount: int) -> int:
	# Returns leftover after trying to add; 0 means success.
	if item == null:
		return amount
	if amount <= 0:
		return 0

	var remaining: int = amount

	# First pass: merge into existing stacks
	var i: int = 0
	while i < _stacks.size():
		var st: ItemStack = _stacks[i]
		if st != null and st.item != null and st.item.id == item.id and st.count < item.stack_max:
			var can_put: int = st.remaining_capacity()
			if can_put > 0:
				var put: int = can_put
				if put > remaining:
					put = remaining
				st.count += put
				remaining -= put
				if remaining <= 0:
					emit_signal("inventory_changed")
					return 0
		i += 1

	# Second pass: place into empty slots
	i = 0
	while i < _stacks.size() and remaining > 0:
		if _stacks[i] == null:
			var to_create: int = item.stack_max
			if to_create > remaining:
				to_create = remaining
			var ns := ItemStack.new()
			ns.item = item
			ns.count = to_create
			_stacks[i] = ns
			remaining -= to_create
		i += 1

	emit_signal("inventory_changed")
	return remaining

func remove_amount(index: int, amount: int) -> int:
	# Returns removed amount
	var st: ItemStack = get_slot_stack(index)
	if st == null:
		return 0
	if amount <= 0:
		return 0
	var take: int = amount
	if take > st.count:
		take = st.count
	st.count -= take
	if st.count <= 0:
		_stacks[index] = null
	emit_signal("inventory_changed")
	return take

func move_or_merge(from_index: int, to_index: int) -> void:
	if from_index == to_index:
		return
	var a: ItemStack = get_slot_stack(from_index)
	var b: ItemStack = get_slot_stack(to_index)
	if a == null:
		return

	if b == null:
		_stacks[to_index] = a
		_stacks[from_index] = null
		emit_signal("inventory_changed")
		return

	if a.can_merge(b):
		var cap: int = b.remaining_capacity()
		if cap > 0:
			var moved: int = cap
			if moved > a.count:
				moved = a.count
			b.count += moved
			a.count -= moved
			if a.count <= 0:
				_stacks[from_index] = null
			emit_signal("inventory_changed")
			return

	# If we get here, swap
	_stacks[to_index] = a
	_stacks[from_index] = b
	emit_signal("inventory_changed")

func split_stack(from_index: int, to_index: int, amount: int) -> bool:
	var a: ItemStack = get_slot_stack(from_index)
	if a == null:
		return false
	if amount <= 0:
		return false
	if to_index < 0:
		return false
	if to_index >= _stacks.size():
		return false
	if _stacks[to_index] != null:
		return false
	if amount > a.count:
		return false

	var ns := ItemStack.new()
	ns.item = a.item
	ns.count = amount
	a.count -= amount
	_stacks[to_index] = ns
	if a.count <= 0:
		_stacks[from_index] = null
	emit_signal("inventory_changed")
	return true

func use_item(index: int, user: Node) -> void:
	var st: ItemStack = get_slot_stack(index)
	if st == null:
		emit_signal("item_used", index, false)
		return
	var item: ItemDef = st.item
	if item == null:
		emit_signal("item_used", index, false)
		return

	var ok: bool = _apply_use_effect(item, user)
	if ok:
		remove_amount(index, 1)
		emit_signal("item_used", index, true)
	else:
		emit_signal("item_used", index, false)

func _apply_use_effect(item: ItemDef, user: Node) -> bool:
	if item.item_type == "consumable":
		var s: StatsComponent = user.get_node_or_null("StatsComponent") as StatsComponent
		if s != null:
			if item.restore_hp > 0:
				s.apply_heal(float(item.restore_hp), "item", false)
			if item.restore_mp > 0:
				s.restore_mp(float(item.restore_mp))
			if item.restore_end > 0:
				s.restore_end(float(item.restore_end))

		if String(item.use_ability_id) != "":
			var abil := get_node_or_null("/root/AbilitySys") as AbilitySystem
			if abil != null:
				var ctx := {"source": "item_use"}
				abil.request_cast(user, String(item.use_ability_id), ctx)
		return true

	return false
