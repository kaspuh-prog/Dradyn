extends Node
class_name DebugInventoryDevTools

@export_file("*.tres") var item_def_path: String = "res://Data/items/weaponresources/WoodenSword.tres"
@export var quantity: int = 1
@export var bag_index_for_unlock: int = 0
@export var unlock_count: int = 48

var _hotkeys_ready: bool = false

func _ready() -> void:
	_ensure_action("debug_give_item", KEY_F9 as Key)
	_ensure_action("debug_probe_inventory", KEY_F10 as Key)
	_ensure_action("debug_unlock_bag1", KEY_F11 as Key)
	_hotkeys_ready = true
	print("[DebugInventoryDevTools] Ready. F9=Give, F10=Probe, F11=Unlock Bag 1")

func _process(_delta: float) -> void:
	if not _hotkeys_ready:
		return
	if Input.is_action_just_pressed("debug_give_item"):
		_give_item()
	if Input.is_action_just_pressed("debug_probe_inventory"):
		_probe_inventory()
	if Input.is_action_just_pressed("debug_unlock_bag1"):
		_unlock_bag()

func _ensure_action(action_name: StringName, key: Key) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	var ev := InputEventKey.new()
	ev.keycode = key
	InputMap.action_add_event(action_name, ev)

func _give_item() -> void:
	if not has_node("/root/InventorySys"):
		push_warning("[DebugInv] InventorySys not found.")
		return
	if item_def_path == "":
		push_warning("[DebugInv] item_def_path is empty.")
		return
	var leftover: int = int(InventorySys.give_item_by_path(item_def_path, quantity))
	print("[DebugInv] give_item_by_path leftover = ", str(leftover))

func _get_prop_if_exists(obj: Object, prop_name: String) -> Variant:
	var plist: Array = obj.get_property_list()
	var i: int = 0
	while i < plist.size():
		var d: Dictionary = plist[i]
		if String(d.get("name", "")) == prop_name:
			return obj.get(prop_name)
		i += 1
	return null

func _probe_inventory() -> void:
	if not has_node("/root/InventorySys"):
		push_warning("[DebugInv] InventorySys not found.")
		return
	if not "inventory_model" in InventorySys:
		push_warning("[DebugInv] InventorySys.inventory_model missing.")
		return

	var mdl: Object = InventorySys.inventory_model
	var total_slots: int = _get_model_slot_count(mdl)
	print("[DebugInv] Model slots (approx) = ", total_slots)

	var first_idx: int = -1
	var limit: int = min(total_slots, 120)
	var i: int = 0
	while i < limit:
		var st_v: Variant = (mdl as Object).call("get_slot_stack", i)
		if st_v != null and st_v is Object:
			var st: Object = st_v
			var itm_v: Variant = _get_prop_if_exists(st, "item")
			var cnt_v: Variant = _get_prop_if_exists(st, "count")

			var name_str: String = ""
			var qty: int = 0

			if itm_v is Object:
				var dn_v: Variant = _get_prop_if_exists(itm_v, "display_name")
				if dn_v != null:
					name_str = String(dn_v)
			if typeof(cnt_v) == TYPE_INT:
				qty = int(cnt_v)

			if qty > 0 or name_str != "":
				print("[DebugInv] slot ", i, " → ", name_str, " x", qty)
				if first_idx == -1:
					first_idx = i
		i += 1
	print("[DebugInv] first non-empty index = ", first_idx)


func _unlock_bag() -> void:
	var sheetc: Node = _find_sheet_controller()
	if sheetc == null:
		push_warning("[DebugInv] SheetController not found.")
		return

	# Safely read 'unlocked_by_tab' via property list (no .has()).
	var plist: Array = sheetc.get_property_list()
	var found: bool = false
	var i: int = 0
	while i < plist.size():
		var d: Dictionary = plist[i]
		if String(d.get("name", "")) == "unlocked_by_tab":
			found = true
			break
		i += 1

	if not found:
		push_warning("[DebugInv] SheetController.unlocked_by_tab missing.")
		return

	var arr_v: Variant = sheetc.get("unlocked_by_tab")
	if typeof(arr_v) != TYPE_PACKED_INT32_ARRAY:
		push_warning("[DebugInv] unlocked_by_tab is not PackedInt32Array.")
		return

	var arr: PackedInt32Array = arr_v
	if bag_index_for_unlock < 0 or bag_index_for_unlock >= arr.size():
		push_warning("[DebugInv] bag index out of range.")
		return

	arr[bag_index_for_unlock] = unlock_count
	sheetc.set("unlocked_by_tab", arr)

	# Refresh current tab.
	var active_index: int = 0
	# get bag_tabs_row_path (NodePath) if it exists
	var tabs_path: NodePath = NodePath()
	var j: int = 0
	while j < plist.size():
		var d2: Dictionary = plist[j]
		if String(d2.get("name", "")) == "bag_tabs_row_path":
			var p_v: Variant = sheetc.get("bag_tabs_row_path")
			if typeof(p_v) == TYPE_NODE_PATH:
				tabs_path = NodePath(p_v)
			break
		j += 1

	if String(tabs_path) != "":
		var tabs: Node = sheetc.get_node_or_null(tabs_path)
		if tabs != null and tabs.has_method("get_active"):
			var v: Variant = tabs.call("get_active")
			if typeof(v) == TYPE_INT:
				active_index = int(v)

	if sheetc.has_method("_on_bag_changed"):
		sheetc.call("_on_bag_changed", active_index)

	print("[DebugInv] Unlocked bag ", bag_index_for_unlock, " to ", unlock_count, " slots.")


func _find_sheet_controller() -> Node:
	if has_node("/root/GameRoot/HUDLayer/TabbedMenu/Content/InventorySheet/SheetController"):
		return get_node("/root/GameRoot/HUDLayer/TabbedMenu/Content/InventorySheet/SheetController")
	if has_node("%SheetController"):
		return get_node("%SheetController")
	return null

func _get_model_slot_count(mdl: Object) -> int:
	# Prefer a method if present.
	if (mdl as Object).has_method("get_slot_count"):
		var v: Variant = (mdl as Object).call("get_slot_count")
		if typeof(v) == TYPE_INT:
			return int(v)

	# Fallback: look for a 'slots' property via the property list.
	var plist: Array = (mdl as Object).get_property_list()
	var i: int = 0
	while i < plist.size():
		var d: Dictionary = plist[i]
		if String(d.get("name", "")) == "slots":
			var v2: Variant = (mdl as Object).get("slots")
			if typeof(v2) == TYPE_INT:
				return int(v2)
		i += 1

	# Conservative default
	return 120
