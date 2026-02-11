extends Node
class_name DebugGiveItemOnStart

# --- Item A (existing) ---
@export_file("*.tres") var item_def_path: String = "res://Data/items/weaponresources/WoodenSword.tres"
@export var quantity: int = 1

# --- Item B (new; e.g., your potion) ---
@export_file("*.tres") var item_def_path_extra: String = ""
@export var quantity_extra: int = 1

var _inv: Node = null

func _ready() -> void:
	# 1) Resolve Inventory autoload
	_inv = get_node_or_null("/root/InventorySystem")
	if _inv == null:
		_inv = get_node_or_null("/root/InventorySys")
	if _inv == null:
		push_warning("[DebugGiveItemOnStart] InventorySystem not found.")
		return

	# 2) Try to give primary item (if set)
	_try_give_item(item_def_path, quantity, "primary")

	# 3) Try to give extra item (if set)
	_try_give_item(item_def_path_extra, quantity_extra, "extra")

func _try_give_item(path: String, qty: int, label: String) -> void:
	if path == "":
		# empty path is fine; skip quietly
		return

	# Optional safety: warn if file missing
	if not FileAccess.file_exists(path):
		push_warning("[DebugGiveItemOnStart] %s item path does not exist: %s" % [label, path])
		return

	# Prefer InventorySystem.give_item_by_path if available
	if _inv.has_method("give_item_by_path"):
		var leftover_by_path: Variant = _inv.call("give_item_by_path", path, qty)
		print("[DebugGiveItemOnStart] (%s) give_item_by_path leftover=" % label, str(leftover_by_path))
		return

	# Fallback: load ItemDef and call give_item
	if not _inv.has_method("give_item"):
		push_warning("[DebugGiveItemOnStart] InventorySystem missing give methods.")
		return

	var res: Resource = load(path)
	var item: ItemDef = res as ItemDef
	if item == null:
		push_warning("[DebugGiveItemOnStart] %s could not load ItemDef at path: %s" % [label, path])
		return

	var leftover: Variant = _inv.call("give_item", item, qty)
	print("[DebugGiveItemOnStart] (%s) give_item leftover=" % label, str(leftover))
