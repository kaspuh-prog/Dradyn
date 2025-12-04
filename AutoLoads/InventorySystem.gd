extends Node
class_name InventorySystem
## Party-scoped inventory (legacy) + per-actor equipment bridges.
## NEW: Per-actor inventory bags (backward-compatible).
## UI-safe tab view with per-tab unlocked counts (Bag1..Bag5, Key Items).
## Defaults: Bag1=12 unlocked, Bags2-5=0, Key=48 unlocked.
## Adds "give / transfer" helpers so gameplay code can award and move items cleanly.
## Party currency remains party-wide.

signal inventory_changed()
signal actor_equipped_changed(actor: Node, slot: String, prev_item: ItemDef, new_item: ItemDef)
signal item_obtained(item: ItemDef, added: int, leftover: int)
signal currency_changed(total: int, delta: int)

@export var initial_slots: int = 48

@export var tab_names: Array[String] = [
	"Bag 1", "Bag 2", "Bag 3", "Bag 4", "Bag 5", "Key Items"
]

@export var unlocked_by_tab: PackedInt32Array = [12, 0, 0, 0, 0, 48]

@export var starting_currency: int = 0

# -----------------------------
# Storage
# -----------------------------
var inventory_model: InventoryModel                               # Legacy party bag (kept)
var _equip_by_actor: Dictionary = {}                              # Node -> EquipmentModel
var _bag_by_actor: Dictionary = {}                                # Node -> InventoryModel (NEW)
var _currency: int = 0

func _ready() -> void:
	# Legacy party bag
	inventory_model = InventoryModel.new()
	inventory_model.slots = initial_slots
	add_child(inventory_model)
	inventory_model.connect("inventory_changed", Callable(self, "_relay_inventory_changed"))
	_normalize_unlocked()
	_init_currency()

# -----------------------------
# Currency (party-wide)
# -----------------------------
func _init_currency() -> void:
	var v: int = starting_currency
	if v < 0:
		v = 0
	_currency = v

func get_currency() -> int:
	return _currency

func set_currency(value: int) -> void:
	var new_total: int = value
	if new_total < 0:
		new_total = 0
	var delta: int = new_total - _currency
	if delta == 0:
		return
	_currency = new_total
	emit_signal("currency_changed", _currency, delta)
	emit_signal("inventory_changed")

func add_currency(amount: int) -> int:
	if amount <= 0:
		return 0
	var after: int = _currency + amount
	if after < 0:
		after = 0
	_currency = after
	emit_signal("currency_changed", _currency, amount)
	emit_signal("inventory_changed")
	return amount

func try_spend_currency(amount: int) -> bool:
	if amount <= 0:
		return true
	if _currency < amount:
		return false
	var after: int = _currency - amount
	if after < 0:
		after = 0
	var delta: int = after - _currency
	_currency = after
	emit_signal("currency_changed", _currency, delta)
	emit_signal("inventory_changed")
	return true

func give_currency(amount: int) -> int:
	return add_currency(amount)

# -----------------------------
# Per-actor inventory (NEW)
# -----------------------------
func ensure_inventory_model_for(actor: Node) -> InventoryModel:
	if _bag_by_actor.has(actor):
		var v: Variant = _bag_by_actor[actor]
		return v as InventoryModel
	var bag: InventoryModel = InventoryModel.new()
	bag.slots = initial_slots
	add_child(bag)
	bag.connect("inventory_changed", Callable(self, "_relay_inventory_changed"))
	_bag_by_actor[actor] = bag
	return bag

func get_inventory_model_for(actor: Node) -> InventoryModel:
	if _bag_by_actor.has(actor):
		var v: Variant = _bag_by_actor[actor]
		return v as InventoryModel
	return null

func get_stack_at_for(actor: Node, slot_index: int) -> Variant:
	if slot_index < 0 or slot_index >= initial_slots:
		return null
	var bag: InventoryModel = get_inventory_model_for(actor)
	if bag == null:
		return null
	return bag.get_slot_stack(slot_index)

func set_stack_at_for(actor: Node, slot_index: int, stack: ItemStack) -> void:
	if slot_index < 0 or slot_index >= initial_slots:
		return
	var bag: InventoryModel = ensure_inventory_model_for(actor)
	bag.set_stack(slot_index, stack)

## Add to a specific actor's bag. Returns leftover that did not fit.
func add_item_for(actor: Node, item: ItemDef, count: int) -> int:
	if actor == null:
		return count
	if item == null:
		return count
	if count <= 0:
		return 0
	var bag: InventoryModel = ensure_inventory_model_for(actor)
	var before: int = count
	var leftover: int = bag.add_item(item, count)
	var added: int = before - leftover
	if added > 0:
		emit_signal("item_obtained", item, added, leftover)
		emit_signal("inventory_changed")
	return leftover

## Remove up to 'count' of item from a specific actor's bag. Returns removed qty.
func remove_item_for(actor: Node, item: ItemDef, count: int) -> int:
	if actor == null:
		return 0
	if item == null:
		return 0
	if count <= 0:
		return 0

	var bag: InventoryModel = get_inventory_model_for(actor)
	if bag == null:
		return 0

	var remaining: int = count
	var removed_total: int = 0
	var slots: int = bag.slot_count()
	var i: int = 0

	while i < slots and remaining > 0:
		var st_v: Variant = bag.get_slot_stack(i)
		if st_v is ItemStack:
			var st: ItemStack = st_v
			if st.item == item and st.count > 0:
				var to_remove: int = remaining
				if to_remove > st.count:
					to_remove = st.count
				var removed_here: int = bag.remove_amount(i, to_remove)
				if removed_here > 0:
					removed_total += removed_here
					remaining -= removed_here
		i += 1

	if removed_total > 0:
		emit_signal("inventory_changed")

	return removed_total

## Move a whole stack from one actor's slot to another actor's bag. Returns leftover (0 on full success).
func transfer_stack_between_actors(from_actor: Node, from_index: int, to_actor: Node) -> int:
	if from_actor == null or to_actor == null:
		return -1
	if from_index < 0 or from_index >= initial_slots:
		return -1
	var from_bag: InventoryModel = get_inventory_model_for(from_actor)
	if from_bag == null:
		return -1
	var st: ItemStack = from_bag.get_slot_stack(from_index)
	if st == null:
		return 0
	var to_bag: InventoryModel = ensure_inventory_model_for(to_actor)

	var item: ItemDef = st.item
	var qty: int = st.count
	if item == null or qty <= 0:
		return 0

	var leftover: int = to_bag.add_item(item, qty)
	var moved: int = qty - leftover
	if moved > 0:
		from_bag.remove_amount(from_index, moved)

	emit_signal("inventory_changed")
	return leftover

# -----------------------------
# Legacy party-bag helpers (kept)
# -----------------------------
func _relay_inventory_changed() -> void:
	emit_signal("inventory_changed")

func _normalize_unlocked() -> void:
	var max_tabs: int = tab_names.size()
	var i: int = 0
	while i < unlocked_by_tab.size():
		if i >= max_tabs:
			break
		var v: int = unlocked_by_tab[i]
		if v < 0:
			v = 0
		if v > initial_slots:
			v = initial_slots
		unlocked_by_tab[i] = v
		i += 1
	while unlocked_by_tab.size() < max_tabs:
		unlocked_by_tab.append(0)

# -----------------------------
# Equipment bridge per-actor (existing)
# -----------------------------
func ensure_equipment_model_for(actor: Node) -> EquipmentModel:
	if _equip_by_actor.has(actor):
		var v: Variant = _equip_by_actor[actor]
		return v as EquipmentModel

	var em: EquipmentModel = EquipmentModel.new()
	add_child(em)

	var stats: StatsComponent = actor.get_node_or_null("StatsComponent") as StatsComponent
	if stats == null:
		var f: Node = actor.find_child("StatsComponent", true, false)
		if f != null and f is StatsComponent:
			stats = f as StatsComponent

	if stats != null:
		em.owner_stats_path = em.get_path_to(stats)

	_equip_by_actor[actor] = em
	em.connect("equipped_changed", Callable(self, "_on_actor_equipped_changed").bind(actor))
	return em

func _on_actor_equipped_changed(slot: String, prev_item: ItemDef, new_item: ItemDef, actor: Node) -> void:
	emit_signal("actor_equipped_changed", actor, slot, prev_item, new_item)

# -----------------------------
# Class-based equip restriction helper
# -----------------------------
func _can_actor_equip_item(actor: Node, item: ItemDef) -> bool:
	if actor == null:
		return false
	if item == null:
		return false

	# Only gate equipment items here.
	if String(item.item_type) != "equipment":
		return true

	# Items without an equipment_class are unrestricted.
	var eq_class: StringName = item.equipment_class
	var eq_str: String = String(eq_class)
	if eq_str == "":
		return true

	# Resolve StatsComponent on the actor.
	var stats: StatsComponent = actor.get_node_or_null("StatsComponent") as StatsComponent
	if stats == null:
		var f: Node = actor.find_child("StatsComponent", true, false)
		if f != null and f is StatsComponent:
			stats = f as StatsComponent

	# If the actor has no stats, or no class_def, fall back to allowing (no restrictions configured).
	if stats == null:
		return true
	if not stats.has_method("get_class_def"):
		return true

	var cd_v: Variant = stats.call("get_class_def")
	if cd_v == null:
		return true

	var cd: ClassDefinition = cd_v as ClassDefinition
	if cd == null:
		return true

	return cd.can_equip_class(eq_class)

# -----------------------------
# Per-actor equip / unequip (NEW)
# -----------------------------
## Equip an item from the actor's own bag at inv_index into its equip_slot.
## Returns true if equipped and one item was removed from the bag.
func try_equip_from_actor_bag(actor: Node, inv_index: int) -> bool:
	if actor == null:
		return false

	var bag: InventoryModel = get_inventory_model_for(actor)
	if bag == null:
		return false

	if inv_index < 0 or inv_index >= initial_slots:
		return false

	var st_v: Variant = bag.get_slot_stack(inv_index)
	if st_v == null:
		return false

	var st: ItemStack = st_v as ItemStack
	if st == null:
		return false

	var item: ItemDef = st.item
	if item == null:
		return false

	# Class-based equipment restriction.
	if not _can_actor_equip_item(actor, item):
		return false

	if String(item.item_type) != "equipment":
		return false

	var slot_name: String = String(item.equip_slot)
	var em: EquipmentModel = ensure_equipment_model_for(actor)
	var equipped_ok: bool = em.equip(slot_name, item)
	if not equipped_ok:
		return false

	# consume one from the actor's bag
	if st.count > 1:
		st.count -= 1
		if bag.has_signal("inventory_changed"):
			bag.emit_signal("inventory_changed")
	else:
		bag.set_stack(inv_index, null)

	emit_signal("inventory_changed")
	return true

## Unequip an item from the given slot into the actor's own bag (first-fit).
## Returns true if the item was placed into the bag.
func try_unequip_to_actor_bag(actor: Node, slot: String) -> bool:
	if actor == null:
		return false

	var em: EquipmentModel = ensure_equipment_model_for(actor)
	var itm: ItemDef = em.get_equipped(slot)
	if itm == null:
		return false

	var bag: InventoryModel = ensure_inventory_model_for(actor)
	var leftover: int = bag.add_item(itm, 1)
	if leftover == 0:
		em.unequip(slot)
		emit_signal("inventory_changed")
		return true
	return false

## Unequip an item from the given slot into a specific index in the actor's bag.
## Supports merging if same item and capacity allows. Returns true if placed/merged.
func try_unequip_to_actor_bag_at(actor: Node, slot: String, to_index: int) -> bool:
	if actor == null:
		return false
	if to_index < 0 or to_index >= initial_slots:
		return false

	var em: EquipmentModel = ensure_equipment_model_for(actor)
	var itm: ItemDef = em.get_equipped(slot)
	if itm == null:
		return false

	var bag: InventoryModel = ensure_inventory_model_for(actor)
	var st_to: ItemStack = bag.get_slot_stack(to_index)

	# Empty cell → place new stack
	if st_to == null:
		var ns: ItemStack = ItemStack.new()
		ns.item = itm
		ns.count = 1
		bag.set_stack(to_index, ns)
		em.unequip(slot)
		emit_signal("inventory_changed")
		return true

	# Merge if same item and space remains
	if st_to.item != null:
		if st_to.item.id == itm.id and st_to.count < st_to.item.stack_max:
			st_to.count += 1
			if bag.has_signal("inventory_changed"):
				bag.emit_signal("inventory_changed")
			em.unequip(slot)
			emit_signal("inventory_changed")
			return true

	return false

# -----------------------------
# Back-compat helpers (UI & legacy calls)
# -----------------------------
func _controlled_actor() -> Node:
	var p: Node = get_node_or_null("/root/Party")
	if p != null and p.has_method("get_controlled"):
		var v: Variant = p.call("get_controlled")
		if v is Node:
			return v as Node
	var pm: Node = get_node_or_null("/root/PartyManager")
	if pm == null:
		pm = get_tree().get_first_node_in_group("PartyManager")
	if pm != null and pm.has_method("get_controlled"):
		var v2: Variant = pm.call("get_controlled")
		if v2 is Node:
			return v2 as Node
	return null

# -----------------------------
# Legacy party-bag equip helpers (kept for back-compat),
# now prefer per-actor bags when available.
# -----------------------------
func try_equip_from_inventory(actor: Node, inv_index: int) -> bool:
	if actor == null:
		return false

	# Prefer per-actor bag
	var bag_for: InventoryModel = get_inventory_model_for(actor)
	if bag_for != null:
		return try_equip_from_actor_bag(actor, inv_index)

	# Fallback to legacy party bag
	var st: Variant = inventory_model.get_slot_stack(inv_index)
	if st == null:
		return false
	var item: ItemDef = st.item
	if item == null:
		return false

	# Class-based equipment restriction.
	if not _can_actor_equip_item(actor, item):
		return false

	if String(item.item_type) != "equipment":
		return false
	var em: EquipmentModel = ensure_equipment_model_for(actor)
	if em.equip(String(item.equip_slot), item):
		inventory_model.remove_amount(inv_index, 1)
		emit_signal("inventory_changed")
		return true
	return false

func try_unequip_to_inventory(actor: Node, slot: String) -> bool:
	if actor == null:
		return false

	# Prefer per-actor bag
	var bag_for: InventoryModel = get_inventory_model_for(actor)
	if bag_for != null:
		return try_unequip_to_actor_bag(actor, slot)

	# Fallback to legacy party bag
	var em: EquipmentModel = ensure_equipment_model_for(actor)
	var itm: ItemDef = em.get_equipped(slot)
	if itm == null:
		return false
	var leftover: int = inventory_model.add_item(itm, 1)
	if leftover == 0:
		em.unequip(slot)
		emit_signal("inventory_changed")
		return true
	return false

func try_unequip_to_inventory_at(actor: Node, slot: String, to_index: int) -> bool:
	if actor == null:
		return false

	# Prefer per-actor bag
	var bag_for: InventoryModel = get_inventory_model_for(actor)
	if bag_for != null:
		return try_unequip_to_actor_bag_at(actor, slot, to_index)

	# Fallback to legacy party bag
	var em: EquipmentModel = ensure_equipment_model_for(actor)
	var itm: ItemDef = em.get_equipped(slot)
	if itm == null:
		return false

	var st_to: ItemStack = inventory_model.get_slot_stack(to_index)
	if st_to == null:
		var ns: ItemStack = ItemStack.new()
		ns.item = itm
		ns.count = 1
		inventory_model.set_stack(to_index, ns)
		em.unequip(slot)
		emit_signal("inventory_changed")
		return true

	if st_to.item != null:
		if st_to.item.id == itm.id and st_to.count < st_to.item.stack_max:
			st_to.count += 1
			inventory_model.emit_signal("inventory_changed")
			em.unequip(slot)
			emit_signal("inventory_changed")
			return true

	return false

# -----------------------------
# UI-safe tab view (read-only; legacy party bag)
# -----------------------------
func get_tab_count() -> int:
	return tab_names.size()

func get_tab_name(tab_index: int) -> String:
	if tab_index < 0 or tab_index >= tab_names.size():
		return ""
	return tab_names[tab_index]

func get_tab_capacity(tab_index: int) -> int:
	return initial_slots

func get_tab_unlocked_capacity(tab_index: int) -> int:
	if tab_index < 0 or tab_index >= unlocked_by_tab.size():
		return 0
	var v: int = unlocked_by_tab[tab_index]
	if v < 0:
		v = 0
	if v > initial_slots:
		v = initial_slots
	return v

func get_items_for_tab(tab_index: int) -> Array:
	var out: Array = []
	var last_key_tab: int = tab_names.size() - 1
	var is_key_tab: bool = tab_index == last_key_tab

	var total: int = initial_slots
	var i: int = 0
	while i < total:
		var st: Variant = inventory_model.get_slot_stack(i)
		if st != null:
			var item: ItemDef = st.item
			if item != null:
				var itype: String = String(item.item_type)
				if is_key_tab:
					if itype == "key item":
						var row: Dictionary = {}
						row["slot"] = i
						row["stack"] = st
						out.append(row)
				else:
					if itype != "key item":
						var row2: Dictionary = {}
						row2["slot"] = i
						row2["stack"] = st
						out.append(row2)
		i += 1
	return out

func get_items_in_bag(tab_index: int) -> Array:
	return get_items_for_tab(tab_index)

# -----------------------------
# Slot-level read helpers (UI legacy)
# -----------------------------
func get_stack_at(slot_index: int) -> Variant:
	if slot_index < 0 or slot_index >= initial_slots:
		return null
	var user: Node = _controlled_actor()
	if user != null:
		var v: Variant = get_stack_at_for(user, slot_index)
		return v
	# Fallback to legacy party bag if no controlled actor
	return inventory_model.get_slot_stack(slot_index)

func get_item_summary_for_slot(slot_index: int) -> Dictionary:
	var result: Dictionary = {
		"has_item": false,
		"name": "",
		"qty": 0,
		"desc": "",
		"icon": null,
		"stats": []
	}

	var st: Variant = get_stack_at(slot_index)
	if st == null:
		return result

	var item: ItemDef = null
	var qty: int = 1

	if typeof(st) == TYPE_DICTIONARY:
		var d: Dictionary = st
		if d.has("item"):
			var iv: Variant = d["item"]
			if iv is ItemDef:
				item = iv
		if d.has("count"):
			qty = int(d["count"])
		elif d.has("quantity"):
			qty = int(d["quantity"])
	elif st is Object:
		if st is ItemStack:
			var ist: ItemStack = st as ItemStack
			if ist != null:
				item = ist.item
				qty = ist.count
		else:
			var obj: Object = st as Object
			if obj.has_method("get_item"):
				var v_item: Variant = obj.call("get_item")
				if v_item is ItemDef:
					item = v_item
			elif obj.has_method("item"):
				var v_item2: Variant = obj.call("item")
				if v_item2 is ItemDef:
					item = v_item2
			if obj.has_method("get_count"):
				var v_count: Variant = obj.call("get_count")
				if typeof(v_count) == TYPE_INT:
					qty = int(v_count)
			elif obj.has_method("count"):
				var v_count2: Variant = obj.call("count")
				if typeof(v_count2) == TYPE_INT:
					qty = int(v_count2)

	if item != null:
		result["has_item"] = true

		if "display_name" in item:
			result["name"] = String(item.display_name)
		elif "name" in item:
			result["name"] = String(item.name)
		if "description" in item:
			result["desc"] = String(item.description)

		if "icon" in item and item.icon != null:
			result["icon"] = item.icon

		if item.has_method("get_stat_modifiers"):
			var mods: Array = item.call("get_stat_modifiers")
			var lines: Array[String] = []
			var i2: int = 0
			while i2 < mods.size():
				var m_v: Variant = mods[i2]
				var line: String = ""
				if m_v is StatModifier:
					var m: StatModifier = m_v
					if m.apply_override:
						line = String(m.stat_name) + " = " + str(m.override_value)
					else:
						var parts: Array[String] = []
						if abs(m.add_value) > 0.0:
							var sign: String = "+"
							if m.add_value < 0.0:
								sign = ""
							parts.append(sign + str(int(m.add_value)) + " " + String(m.stat_name))
						if abs(m.mul_value - 1.0) > 0.0001:
							var mul_str: String = "×" + str(round(m.mul_value * 100.0) / 100.0)
							parts.append(mul_str + " " + String(m.stat_name))
						line = ", ".join(parts)
				elif typeof(m_v) == TYPE_DICTIONARY:
					var d2: Dictionary = m_v
					var sname: String = String(d2.get("stat_name", ""))
					var addv: float = float(d2.get("add_value", 0.0))
					var mulv: float = float(d2.get("mul_value", 1.0))
					var ovrd: bool = bool(d2.get("apply_override", false))
					var ovv: float = float(d2.get("override_value", 0.0))
					if ovrd:
						line = sname + " = " + str(ovv)
					else:
						var parts2: Array[String] = []
						if abs(addv) > 0.0:
							var sign2: String = "+"
							if addv < 0.0:
								sign2 = ""
							parts2.append(sign2 + str(int(addv)) + " " + sname)
						if abs(mulv - 1.0) > 0.0001:
							var mul_str2: String = "×" + str(round(mulv * 100.0) / 100.0)
							parts2.append(mul_str2 + " " + sname)
						line = ", ".join(parts2)
				if String(line) != "":
					lines.append(line)
				i2 += 1
			result["stats"] = lines

	result["qty"] = qty
	return result

# -----------------------------
# Gameplay award (legacy party bag)
# -----------------------------
func give_item(item: ItemDef, count: int) -> int:
	if item == null:
		return count
	if count <= 0:
		return 0
	var before_leftover: int = count
	var leftover: int = inventory_model.add_item(item, count)
	var added: int = before_leftover - leftover
	emit_signal("item_obtained", item, added, leftover)
	if added > 0:
		emit_signal("inventory_changed")
	return leftover

func give_item_by_path(path: String, count: int) -> int:
	if path == "":
		return count
	var res: Resource = ResourceLoader.load(path)
	var def: ItemDef = res as ItemDef
	if def == null:
		return count
	return give_item(def, count)

# -----------------------------
# Unlock helpers (UI)
# -----------------------------
func set_unlocked_slots_for_tab(tab_index: int, value: int) -> void:
	if tab_index < 0 or tab_index >= tab_names.size():
		return
	var v: int = value
	if v < 0:
		v = 0
	if v > initial_slots:
		v = initial_slots
	unlocked_by_tab[tab_index] = v
	emit_signal("inventory_changed")

func unlock_slots(tab_index: int, amount: int) -> int:
	if tab_index < 0 or tab_index >= tab_names.size():
		return 0
	if amount <= 0:
		return 0
	var before: int = get_tab_unlocked_capacity(tab_index)
	var after: int = before + amount
	if after > initial_slots:
		after = initial_slots
	var granted: int = after - before
	if granted <= 0:
		return 0
	unlocked_by_tab[tab_index] = after
	emit_signal("inventory_changed")
	return granted

func unlock_bag1(amount: int) -> int:
	return unlock_slots(0, amount)

func unlock_key_items(amount: int) -> int:
	var key_index: int = tab_names.size() - 1
	return unlock_slots(key_index, amount)
