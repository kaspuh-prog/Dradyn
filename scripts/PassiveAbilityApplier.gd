extends Node
class_name PassiveAbilityApplier
# Godot 4.5 — fully typed, no ternaries.
# Applies PASSIVE abilities as StatModifiers on StatsComponent when they are known.
#
# NEW (generic): reads passive gate/proc metadata from AbilityDef so we don't hardcode names.
# - Gates: equipment class / item id in a slot (and "required_item_id" in a slot).
# - Procs: apply buff_mods temporarily on AbilitySys.ability_cast events based on the *cast* AbilityDef.

signal passives_refreshed(actor: Node)

@export var stats_path: NodePath = NodePath("")
@export var known_abilities_path: NodePath = NodePath("")
@export var auto_wire_from_parent: bool = true

# Prefix for StatModifier.source_id so we can remove them cleanly.
@export var passive_source_prefix: String = "passive:"
@export var proc_source_suffix: String = ":proc"

var _stats: StatsComponent = null
var _known: KnownAbilitiesComponent = null
var _ability_sys: Node = null
var _inventory_sys: Node = null

# Track which passive ability IDs we have applied as *always-on* aura modifiers so we can remove on refresh.
var _applied_passive_ids: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_resolve_ability_system()
	_resolve_inventory_system()
	_resolve_components()
	_connect_signals()
	_refresh_passives()


# -------------------------------------------------------------------
# Resolution helpers
# -------------------------------------------------------------------
func _resolve_ability_system() -> void:
	_ability_sys = get_tree().root.get_node_or_null("AbilitySys")


func _resolve_inventory_system() -> void:
	_inventory_sys = get_tree().root.get_node_or_null("InventorySys")


func _resolve_components() -> void:
	if stats_path != NodePath(""):
		var s: Node = get_node_or_null(stats_path)
		if s is StatsComponent:
			_stats = s as StatsComponent

	if known_abilities_path != NodePath(""):
		var k: Node = get_node_or_null(known_abilities_path)
		if k is KnownAbilitiesComponent:
			_known = k as KnownAbilitiesComponent

	if auto_wire_from_parent:
		var root: Node = get_parent()
		if root == null:
			root = owner

		if _stats == null and root != null:
			_stats = _find_stats_component(root)

		if _known == null and root != null:
			_known = _find_known_abilities_component(root)


func _find_stats_component(root: Node) -> StatsComponent:
	if root == null:
		return null
	var sc_direct: Node = root.find_child("StatsComponent", true, false)
	if sc_direct is StatsComponent:
		return sc_direct as StatsComponent

	var queue: Array[Node] = []
	queue.append(root)
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur is StatsComponent:
			return cur as StatsComponent
		for c: Node in cur.get_children():
			queue.append(c)
	return null


func _find_known_abilities_component(root: Node) -> KnownAbilitiesComponent:
	if root == null:
		return null
	var kac_direct: Node = root.find_child("KnownAbilitiesComponent", true, false)
	if kac_direct is KnownAbilitiesComponent:
		return kac_direct as KnownAbilitiesComponent

	var queue: Array[Node] = []
	queue.append(root)
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur is KnownAbilitiesComponent:
			return cur as KnownAbilitiesComponent
		for c: Node in cur.get_children():
			queue.append(c)
	return null


func _connect_signals() -> void:
	if _known != null:
		if not _known.is_connected("abilities_changed", Callable(self, "_on_known_abilities_changed")):
			_known.connect("abilities_changed", Callable(self, "_on_known_abilities_changed"))

	# Ability casts (proc triggers)
	if _ability_sys != null and _ability_sys.has_signal("ability_cast"):
		if not _ability_sys.is_connected("ability_cast", Callable(self, "_on_ability_cast")):
			_ability_sys.connect("ability_cast", Callable(self, "_on_ability_cast"))

	# Equipment changes (gate refresh)
	if _inventory_sys != null and _inventory_sys.has_signal("actor_equipped_changed"):
		if not _inventory_sys.is_connected("actor_equipped_changed", Callable(self, "_on_actor_equipped_changed")):
			_inventory_sys.connect("actor_equipped_changed", Callable(self, "_on_actor_equipped_changed"))


# -------------------------------------------------------------------
# Signals from KnownAbilitiesComponent
# -------------------------------------------------------------------
func _on_known_abilities_changed(_current: PackedStringArray) -> void:
	_refresh_passives()


# -------------------------------------------------------------------
# Signals from AbilitySystem / InventorySystem
# -------------------------------------------------------------------
func _on_ability_cast(user: Node, ability_id: String, ok: bool) -> void:
	if not ok:
		return
	if _stats == null or _known == null:
		return

	var actor: Node = _stats.get_parent()
	if actor == null:
		return
	if user != actor:
		return

	# Resolve the cast ability def once; we match passives against this.
	var cast_def: AbilityDef = _get_ability_def_typed(ability_id)
	if cast_def == null:
		return

	# Any known PASSIVE that declares a proc may trigger on this cast.
	var known_ids: PackedStringArray = _known.known_abilities
	var i: int = 0
	while i < known_ids.size():
		var passive_id: String = known_ids[i]
		var passive_def: AbilityDef = _get_ability_def_typed(passive_id)
		if passive_def != null:
			if _is_passive(passive_def):
				if _has_passive_proc(passive_def):
					# Procs still respect gates (if the passive is gated and gate fails, no proc).
					if _passive_gate_allows(passive_def):
						if _proc_matches_cast(passive_def, cast_def):
							_apply_proc_from_def(passive_id, passive_def)
		i += 1


func _on_actor_equipped_changed(actor: Node, _slot: String, _prev_item: ItemDef, _new_item: ItemDef) -> void:
	if _stats == null:
		return
	var my_actor: Node = _stats.get_parent()
	if my_actor == null:
		return
	if actor != my_actor:
		return

	# Any equipment change can affect gates; keep it simple and refresh.
	_refresh_passives()


# -------------------------------------------------------------------
# Core refresh
# -------------------------------------------------------------------
func _refresh_passives() -> void:
	if _stats == null:
		return
	if _known == null:
		return
	if _ability_sys == null:
		_resolve_ability_system()
	if _inventory_sys == null:
		_resolve_inventory_system()

	# 1) Remove any previously applied always-on passive modifiers
	_remove_all_passive_modifiers()

	# 2) Apply always-on passives for all currently known abilities
	var known_ids: PackedStringArray = _known.known_abilities
	var i: int = 0
	while i < known_ids.size():
		var ability_id: String = known_ids[i]
		_apply_passive_aura_for_ability(ability_id)
		i += 1

	passives_refreshed.emit(_stats.get_parent())


func _remove_all_passive_modifiers() -> void:
	if _stats == null:
		return

	var i: int = 0
	while i < _applied_passive_ids.size():
		var ability_id: String = _applied_passive_ids[i]
		var source_id: String = _make_source_id(ability_id)
		if _stats.has_method("remove_modifiers_by_source"):
			_stats.call("remove_modifiers_by_source", source_id)
		i += 1

	_applied_passive_ids.clear()


func _apply_passive_aura_for_ability(ability_id: String) -> void:
	if ability_id == "":
		return
	if _stats == null:
		return

	var def_res: AbilityDef = _get_ability_def_typed(ability_id)
	if def_res == null:
		return
	if not _is_passive(def_res):
		return

	# If this passive is configured as a proc passive, we do NOT apply its buff_mods as an always-on aura.
	# (Momentum-style: buff_mods are applied on proc with duration.)
	if _has_passive_proc(def_res):
		return

	# Respect gate.
	if not _passive_gate_allows(def_res):
		return

	_apply_aura_mods_from_def(ability_id, def_res)


# -------------------------------------------------------------------
# AbilityDef reading (gate + proc)
# -------------------------------------------------------------------
func _is_passive(def_res: AbilityDef) -> bool:
	if def_res == null:
		return false
	if def_res.ability_type.to_upper() == "PASSIVE":
		return true
	return false


func _has_passive_proc(def_res: AbilityDef) -> bool:
	if def_res == null:
		return false
	if def_res.passive_proc_mode != "NONE":
		return true
	return false


func _passive_gate_allows(def_res: AbilityDef) -> bool:
	if def_res == null:
		return false

	if def_res.passive_gate_mode == "NONE":
		return true

	# Gates require equipment access.
	var em: EquipmentModel = _get_equipment_model_for_self()
	if em == null:
		return false

	var slot: StringName = def_res.passive_gate_slot
	if String(slot) == "":
		slot = &"mainhand"

	var item: ItemDef = em.get_equipped(String(slot))
	if item == null:
		return false

	if def_res.passive_gate_mode == "EQUIPPED_CLASS_IN_SLOT":
		var cls: String = String(item.equipment_class).to_lower()
		for want: String in def_res.passive_gate_equipment_classes:
			if cls == want.to_lower():
				return true
		return false

	if def_res.passive_gate_mode == "EQUIPPED_ITEM_ID_IN_SLOT":
		var item_id_str: String = ""
		if item.has_method("get"):
			var v: Variant = item.get("item_id")
			if typeof(v) == TYPE_STRING_NAME:
				item_id_str = String(v)
			elif typeof(v) == TYPE_STRING:
				item_id_str = String(v)
		if item_id_str == "":
			return false

		for want_id: String in def_res.passive_gate_item_ids:
			if item_id_str == want_id:
				return true
		return false

	if def_res.passive_gate_mode == "HAS_REQUIRED_ITEM_ID":
		# Interpreted as: required_item_id must be equipped in passive_gate_slot.
		var req: StringName = def_res.required_item_id
		if req == &"":
			return false

		var item_id_str2: String = ""
		if item.has_method("get"):
			var v2: Variant = item.get("item_id")
			if typeof(v2) == TYPE_STRING_NAME:
				item_id_str2 = String(v2)
			elif typeof(v2) == TYPE_STRING:
				item_id_str2 = String(v2)

		if item_id_str2 == "":
			return false
		if item_id_str2 == String(req):
			return true
		return false

	# Unknown gate mode -> fail closed.
	return false


func _proc_matches_cast(passive_def: AbilityDef, cast_def: AbilityDef) -> bool:
	if passive_def == null or cast_def == null:
		return false

	if passive_def.passive_proc_mode == "ON_ABILITY_CAST_SECTION_INDEX":
		if passive_def.passive_proc_section_indices.size() <= 0:
			return false
		var cast_section: int = cast_def.section_index
		if passive_def.passive_proc_section_indices.has(cast_section):
			return true
		return false

	if passive_def.passive_proc_mode == "ON_ABILITY_CAST_ABILITY_TYPE":
		if passive_def.passive_proc_ability_types.is_empty():
			return false
		var cast_type: String = cast_def.ability_type.to_upper()
		for want_type: String in passive_def.passive_proc_ability_types:
			if cast_type == want_type.to_upper():
				return true
		return false

	if passive_def.passive_proc_mode == "ON_ABILITY_CAST_ABILITY_ID":
		if passive_def.passive_proc_ability_ids.is_empty():
			return false
		var cast_id: String = cast_def.ability_id
		for want_id: String in passive_def.passive_proc_ability_ids:
			if cast_id == want_id:
				return true
		# Also allow matching the resolver id string (ability_id parameter) if author used that.
		# This remains strict (no normalization) to avoid accidental matches.
		return false

	return false


# -------------------------------------------------------------------
# Applying modifiers
# -------------------------------------------------------------------
func _apply_aura_mods_from_def(ability_id: String, def_res: AbilityDef) -> void:
	if _stats == null or def_res == null:
		return

	if def_res.buff_mods.is_empty():
		return

	var src_id: String = _make_source_id(ability_id)
	var applied_any: bool = false

	for m: StatModifier in def_res.buff_mods:
		if m == null:
			continue

		var tmpl: StatModifier = m.duplicate(true) as StatModifier
		if tmpl == null:
			tmpl = m

		# Always-on aura.
		tmpl.duration_sec = 0.0

		if String(tmpl.source_id) == "":
			tmpl.source_id = src_id
		else:
			# Preserve explicit authoring, but still ensure removability by grouping under our source_id.
			tmpl.source_id = src_id

		tmpl.source_type = StatModifier.ModifierSourceType.AURA

		if _stats.has_method("add_modifier"):
			_stats.call("add_modifier", tmpl)
			applied_any = true

	if applied_any:
		if not _applied_passive_ids.has(ability_id):
			_applied_passive_ids.append(ability_id)


func _apply_proc_from_def(passive_id: String, def_res: AbilityDef) -> void:
	if _stats == null or def_res == null:
		return
	if def_res.buff_mods.is_empty():
		return

	var src_id: String = _make_source_id(passive_id) + proc_source_suffix

	# Refresh-in-place (no stacking) behavior.
	if def_res.passive_proc_refresh_in_place:
		if _stats.has_method("remove_modifiers_by_source"):
			_stats.call("remove_modifiers_by_source", src_id)

	for m: StatModifier in def_res.buff_mods:
		if m == null:
			continue

		var tmpl: StatModifier = m.duplicate(true) as StatModifier
		if tmpl == null:
			tmpl = m

		# Proc: duration can be overridden by the AbilityDef proc config.
		if def_res.passive_proc_duration_override_sec > 0.0:
			tmpl.duration_sec = def_res.passive_proc_duration_override_sec

		tmpl.source_id = src_id
		tmpl.source_type = StatModifier.ModifierSourceType.AURA

		if _stats.has_method("add_modifier"):
			_stats.call("add_modifier", tmpl)


# -------------------------------------------------------------------
# Inventory access
# -------------------------------------------------------------------
func _get_equipment_model_for_self() -> EquipmentModel:
	if _stats == null:
		return null
	if _inventory_sys == null:
		return null
	if not _inventory_sys.has_method("ensure_equipment_model_for"):
		return null

	var actor: Node = _stats.get_parent()
	if actor == null:
		return null

	var em_any: Variant = _inventory_sys.call("ensure_equipment_model_for", actor)
	if em_any is EquipmentModel:
		return em_any as EquipmentModel
	return null


# -------------------------------------------------------------------
# AbilityDef resolution
# -------------------------------------------------------------------
func _get_ability_def_typed(ability_id: String) -> AbilityDef:
	if _ability_sys == null:
		return null

	if _ability_sys.has_method("_resolve_ability_def"):
		var any_def: Variant = _ability_sys.call("_resolve_ability_def", ability_id)
		if any_def is AbilityDef:
			return any_def as AbilityDef
		if any_def is Resource and any_def is AbilityDef:
			return any_def as AbilityDef

	return null


# -------------------------------------------------------------------
# Source ids
# -------------------------------------------------------------------
func _make_source_id(ability_id: String) -> String:
	if passive_source_prefix == "":
		return "passive:" + ability_id
	return passive_source_prefix + ability_id
