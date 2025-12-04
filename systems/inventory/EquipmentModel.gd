extends Node
class_name EquipmentModel
## Holds equipped items for ONE actor and applies/removes StatsComponent modifiers.

signal equipped_changed(slot: String, prev_item: ItemDef, new_item: ItemDef)

@export var owner_stats_path: NodePath
@export var log_debug: bool = false

var _owner_stats: StatsComponent = null
var _equipped: Dictionary = {}   # slot (String) -> ItemDef

# -------------------------
# Lifecycle
# -------------------------
func _ready() -> void:
	_try_bind_owner_stats()
	call_deferred("_post_parent_bind")

func _post_parent_bind() -> void:
	if _owner_stats == null:
		_try_bind_owner_stats()

	if _owner_stats == null:
		push_warning("[EquipmentModel] owner_stats not resolved; no stat modifiers will apply.")
	else:
		if log_debug:
			print("[EquipmentModel] bound to StatsComponent at: ", owner_stats_path)

# -------------------------
# Binding helpers
# -------------------------
func set_owner_stats(stats: StatsComponent) -> void:
	_owner_stats = stats
	if _owner_stats != null:
		owner_stats_path = get_path_to(_owner_stats)

func _try_bind_owner_stats() -> void:
	if owner_stats_path != NodePath():
		var s_by_path: Node = get_node_or_null(owner_stats_path)
		if s_by_path != null and s_by_path is StatsComponent:
			_owner_stats = s_by_path as StatsComponent
			return

	_resolve_owner_stats_from_parent()

func _resolve_owner_stats_from_parent() -> void:
	var parent_node: Node = get_parent()
	if parent_node == null:
		return

	var direct: Node = parent_node.get_node_or_null("StatsComponent")
	if direct != null and direct is StatsComponent:
		_owner_stats = direct as StatsComponent
		owner_stats_path = get_path_to(_owner_stats)
		return

	var found: Node = parent_node.find_child("StatsComponent", true, false)
	if found != null and found is StatsComponent:
		_owner_stats = found as StatsComponent
		owner_stats_path = get_path_to(_owner_stats)

# -------------------------
# Public API
# -------------------------
func get_equipped(slot: String) -> ItemDef:
	if _equipped.has(slot):
		var v: Variant = _equipped[slot]
		return v as ItemDef
	return null

func all_slots() -> PackedStringArray:
	var keys: Array = _equipped.keys()
	var out: PackedStringArray = PackedStringArray()
	var i: int = 0
	while i < keys.size():
		out.append(String(keys[i]))
		i += 1
	return out

func equip(slot: String, item: ItemDef) -> bool:
	if item == null:
		return false

	if String(item.item_type) != "equipment":
		return false
	if String(item.equip_slot) != String(slot):
		return false

	var prev: ItemDef = null
	if _equipped.has(slot):
		prev = _equipped[slot] as ItemDef
		_remove_item_bonuses(slot, prev)

	_equipped[slot] = item
	_apply_item_bonuses(slot, item)

	emit_signal("equipped_changed", slot, prev, item)

	if log_debug:
		print("[EquipmentModel] equip slot=", slot, " item=", item)

	return true

func unequip(slot: String) -> ItemDef:
	if not _equipped.has(slot):
		return null
	var prev: ItemDef = _equipped[slot] as ItemDef
	_equipped.erase(slot)
	_remove_item_bonuses(slot, prev)

	emit_signal("equipped_changed", slot, prev, null)

	if log_debug:
		print("[EquipmentModel] unequip slot=", slot, " prev=", prev)

	return prev

# -------------------------
# Internals: apply/remove
# -------------------------
func _apply_item_bonuses(slot: String, item: ItemDef) -> void:
	if _owner_stats == null:
		if log_debug:
			print("[EquipmentModel] skip apply; no owner_stats.")
		return
	if item == null:
		return
	if not _owner_stats.has_method("add_modifier"):
		push_warning("[EquipmentModel] StatsComponent missing add_modifier(); cannot apply equipment bonuses.")
		return

	var src: String = _source_id_for(slot)

	var mods_array: Array = []
	if item.has_method("get_stat_modifiers"):
		var v: Variant = item.call("get_stat_modifiers")
		if typeof(v) == TYPE_ARRAY:
			mods_array = v
	elif "stat_modifiers" in item:
		var v2: Variant = item.stat_modifiers
		if typeof(v2) == TYPE_ARRAY:
			mods_array = v2

	if log_debug:
		print("[EquipmentModel] applying ", mods_array.size(), " modifiers from ", item, " src=", src)

	var i: int = 0
	while i < mods_array.size():
		var m: Variant = mods_array[i]

		if m is StatModifier:
			var sm: StatModifier = m
			var dup: StatModifier = null
			if sm.has_method("clone_for_runtime"):
				var v_sm: Variant = sm.call("clone_for_runtime")
				if v_sm is StatModifier:
					dup = v_sm as StatModifier
			if dup == null:
				dup = sm.duplicate(true) as StatModifier

			if "duration_sec" in dup:
				dup.duration_sec = 0.0
			if dup.has_method("start"):
				dup.call("start")
			if "source_id" in dup:
				dup.source_id = src
			if "source_type" in dup:
				dup.source_type = StatModifier.ModifierSourceType.EQUIPMENT

			_owner_stats.add_modifier(dup)

		elif typeof(m) == TYPE_DICTIONARY:
			var d: Dictionary = m
			var out: Dictionary = {}
			out["stat_name"] = str(d.get("stat_name", ""))
			out["add_value"] = float(d.get("add_value", 0.0))
			out["mul_value"] = float(d.get("mul_value", 1.0))
			out["duration_sec"] = 0.0
			out["source_id"] = src
			_owner_stats.add_modifier(out)

		i += 1

func _remove_item_bonuses(slot: String, item: ItemDef) -> void:
	if _owner_stats == null:
		if log_debug:
			print("[EquipmentModel] skip remove; no owner_stats.")
		return
	if not _owner_stats.has_method("remove_modifiers_by_source"):
		push_warning("[EquipmentModel] StatsComponent missing remove_modifiers_by_source(); cannot remove equipment bonuses.")
		return

	var src: String = _source_id_for(slot)

	if log_debug:
		print("[EquipmentModel] removing modifiers for src=", src, " item=", item)

	_owner_stats.remove_modifiers_by_source(src)

func _source_id_for(slot: String) -> String:
	return "equip:" + String(slot)
