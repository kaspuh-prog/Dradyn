extends Node
class_name PassiveAbilityApplier
# Godot 4.5 — fully typed, no ternaries.
# Applies PASSIVE abilities as StatModifiers on StatsComponent when they are known.

signal passives_refreshed(actor: Node)

@export var stats_path: NodePath = NodePath("")
@export var known_abilities_path: NodePath = NodePath("")
@export var auto_wire_from_parent: bool = true

# Prefix for StatModifier.source_id so we can remove them cleanly.
@export var passive_source_prefix: String = "passive:"

var _stats: StatsComponent = null
var _known: KnownAbilitiesComponent = null
var _ability_sys: Node = null

# Track which passive ability IDs we have applied so we can remove them on refresh.
var _applied_passive_ids: PackedStringArray = PackedStringArray()

func _ready() -> void:
	_resolve_ability_system()
	_resolve_components()
	_connect_signals()
	_refresh_passives()


# -------------------------------------------------------------------
# Resolution helpers
# -------------------------------------------------------------------
func _resolve_ability_system() -> void:
	_ability_sys = get_tree().root.get_node_or_null("AbilitySys")


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

	# Fallback: BFS search for a StatsComponent
	var queue: Array = [root]
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur is StatsComponent:
			return cur as StatsComponent
		for c in cur.get_children():
			queue.append(c)
	return null


func _find_known_abilities_component(root: Node) -> KnownAbilitiesComponent:
	if root == null:
		return null
	var kac_direct: Node = root.find_child("KnownAbilitiesComponent", true, false)
	if kac_direct is KnownAbilitiesComponent:
		return kac_direct as KnownAbilitiesComponent

	# Fallback: BFS search for KnownAbilitiesComponent
	var queue: Array = [root]
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur is KnownAbilitiesComponent:
			return cur as KnownAbilitiesComponent
		for c in cur.get_children():
			queue.append(c)
	return null


func _connect_signals() -> void:
	if _known != null:
		if not _known.is_connected("abilities_changed", Callable(self, "_on_known_abilities_changed")):
			_known.connect("abilities_changed", Callable(self, "_on_known_abilities_changed"))


# -------------------------------------------------------------------
# Signals from KnownAbilitiesComponent
# -------------------------------------------------------------------
func _on_known_abilities_changed(_current: PackedStringArray) -> void:
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
	if _ability_sys == null:
		return

	# 1) Remove any previously applied passive modifiers
	_remove_all_passive_modifiers()

	# 2) Apply passives for all currently known abilities
	var known_ids: PackedStringArray = _known.known_abilities
	var i: int = 0
	while i < known_ids.size():
		var ability_id: String = known_ids[i]
		_apply_passive_for_ability(ability_id)
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


func _apply_passive_for_ability(ability_id: String) -> void:
	if ability_id == "":
		return
	if _stats == null or _ability_sys == null:
		return

	var def_res: Resource = _get_ability_def(ability_id)
	if def_res == null:
		return

	var type_name: String = ""
	if def_res.has_method("get"):
		var v_type: Variant = def_res.get("ability_type")
		if typeof(v_type) == TYPE_STRING:
			type_name = String(v_type)

	if type_name.to_upper() != "PASSIVE":
		return

	# Read buff_mods from the AbilityDef
	var mods_any: Variant = null
	if def_res.has_method("get"):
		mods_any = def_res.get("buff_mods")

	if typeof(mods_any) != TYPE_ARRAY:
		return

	var mods: Array = mods_any
	if mods.is_empty():
		return

	var src_id: String = _make_source_id(ability_id)
	var j: int = 0
	var applied_any: bool = false

	while j < mods.size():
		var m: Variant = mods[j]
		if m is StatModifier:
			# Duplicate the template so we never mutate the shared resource.
			var tmpl: StatModifier = (m as StatModifier).duplicate(true) as StatModifier
			if tmpl == null:
				tmpl = m as StatModifier

			# Force permanent duration for passives.
			tmpl.duration_sec = 0.0

			# Mark source so we can remove later.
			if String(tmpl.source_id) == "":
				tmpl.source_id = src_id

			# Optionally mark source type as AURA for clarity.
			tmpl.source_type = StatModifier.ModifierSourceType.AURA

			if _stats.has_method("add_modifier"):
				_stats.call("add_modifier", tmpl)
				applied_any = true
		j += 1

	if applied_any:
		if not _applied_passive_ids.has(ability_id):
			_applied_passive_ids.append(ability_id)


func _make_source_id(ability_id: String) -> String:
	if passive_source_prefix == "":
		return "passive:" + ability_id
	return passive_source_prefix + ability_id


func _get_ability_def(ability_id: String) -> Resource:
	if _ability_sys == null:
		return null

	# We reuse AbilitySystem's internal resolver; the underscore is a convention,
	# but the method is still callable.
	if _ability_sys.has_method("_resolve_ability_def"):
		var any_def: Variant = _ability_sys.call("_resolve_ability_def", ability_id)
		if any_def is Resource:
			return any_def as Resource

	# Fallback: if AbilitySystem ever exposes a public helper like get_def_for(),
	# we can add a call to it here without touching this script's external API.
	return null
