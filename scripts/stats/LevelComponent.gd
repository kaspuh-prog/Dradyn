@icon("res://icon.svg")
extends Node
class_name LevelComponent

signal xp_changed(current_xp: int, xp_to_next: int, level: int)
signal level_up(new_level: int, levels_gained: int)

@export var stats_component_path: NodePath
@onready var stats_component: Node = get_node_or_null(stats_component_path)

@export var class_def: ClassDefinition

@export var level: int = 1
@export var current_xp: int = 0
@export var max_level: int = 50

# Quadratic XP curve: XP(L -> L+1) = a*L^2 + b*L + c
@export var curve_a: float = 20.0
@export var curve_b: float = 80.0
@export var curve_c: float = 100.0

# Optional player allocation pool (uses StatsComponent.can_allocate)
var unspent_points: int = 0

func _ready() -> void:
	assert(stats_component != null, "LevelComponent: stats_component_path must point to a StatsComponent node.")
	# Initialize class effects (base multipliers + MP policy)
	if class_def:
		class_def.initialize_character(stats_component)
	# Sync vitals to current max after class init
	_refill_all_vitals_to_max()
	emit_signal("xp_changed", current_xp, get_xp_to_next(), level)

# -----------------------------
# Public API
# -----------------------------
func get_xp_to_next(at_level: int = -1) -> int:
	var L: int = at_level if at_level > 0 else level
	return int(floor(curve_a * L * L + curve_b * L + curve_c))

func add_xp(amount: int) -> void:
	if amount <= 0 or level >= max_level:
		return
	current_xp += amount
	var levels_gained: int = 0
	while current_xp >= get_xp_to_next() and level < max_level:
		current_xp -= get_xp_to_next()
		level += 1
		levels_gained += 1
		_on_level_up()
	emit_signal("xp_changed", current_xp, get_xp_to_next(), level)
	if levels_gained > 0:
		emit_signal("level_up", level, levels_gained)

func allocate_point(stat_name: String, count: int = 1) -> bool:
	if class_def == null or class_def.points_per_level <= 0:
		return false
	if !stats_component.has_method("can_allocate") or !stats_component.can_allocate(stat_name):
		return false
	if !(stat_name in class_def.allowed_point_targets):
		return false
	if unspent_points < count:
		return false
	unspent_points -= count
	_add_to_base_stat(stat_name, float(count))
	# Max vitals may shift via derivations; clamp/touch HUD if needed
	_reconcile_all_vitals()
	return true

func set_class_def(new_def: ClassDefinition, initialize: bool = true) -> void:
	class_def = new_def
	if initialize and class_def:
		class_def.initialize_character(stats_component)
		_reconcile_all_vitals()

# -----------------------------
# Internals
# -----------------------------
func _on_level_up() -> void:
	# A) Per-level growth to primaries (NOT vitals)
	if class_def:
		# Primaries/GDD growth
		for k in class_def.growth_per_level.keys():
			_add_to_base_stat(k, float(class_def.growth_per_level[k]))
		# Optional tiny flat vital growth (your base HP/MP/Stamina fields)
		for v in class_def.flat_vital_growth_per_level.keys():
			_add_to_base_stat(v, float(class_def.flat_vital_growth_per_level[v]))
		# Points for manual allocation
		unspent_points += class_def.points_per_level
	# B) Clamp/refresh HUD after growth
	_reconcile_all_vitals()
	# C) Full refill on level up
	_refill_all_vitals_to_max()

func _add_to_base_stat(stat_name: String, delta: float) -> void:
	# Works against your StatsResource base_stats dict, preserving your derivation model.
	if stats_component == null:
		return
	var res: Variant = stats_component.get("stats")
	if res == null:
		return
	var base_dict_v: Variant = res.get("base_stats")
	if typeof(base_dict_v) != TYPE_DICTIONARY:
		return
	var base_dict: Dictionary = base_dict_v
	var cur: float = float(base_dict.get(stat_name, 0.0))
	base_dict[stat_name] = cur + delta
	res.set("base_stats", base_dict)  # write back

func _reconcile_all_vitals() -> void:
	# Touch signals and clamp currents to new maxes
	if stats_component == null:
		return
	# Ask for current maxes through your component (derived through getters)
	var hp_max_val: float = stats_component.max_hp()
	var mp_max_val: float = stats_component.max_mp()
	var st_max_val: float = stats_component.max_stamina()
	# Nudge current values into range without changing relative % more than needed
	if stats_component.has_method("change_hp"):
		var delta_hp: float = clamp(stats_component.current_hp, 0.0, hp_max_val) - stats_component.current_hp
		if absf(delta_hp) > 1e-6: stats_component.change_hp(delta_hp)
	if stats_component.has_method("change_mp"):
		var delta_mp: float = clamp(stats_component.current_mp, 0.0, mp_max_val) - stats_component.current_mp
		if absf(delta_mp) > 1e-6: stats_component.change_mp(delta_mp)
	if stats_component.has_method("change_stamina"):
		var delta_st: float = clamp(stats_component.current_stamina, 0.0, st_max_val) - stats_component.current_stamina
		if absf(delta_st) > 1e-6: stats_component.change_stamina(delta_st)

func _refill_all_vitals_to_max() -> void:
	if stats_component == null:
		return
	# Simple top-up to max using your public methods
	if stats_component.has_method("change_hp"):
		stats_component.change_hp(stats_component.max_hp() - stats_component.current_hp)
	if stats_component.has_method("change_mp"):
		stats_component.change_mp(stats_component.max_mp() - stats_component.current_mp)
	if stats_component.has_method("change_stamina"):
		stats_component.change_stamina(stats_component.max_stamina() - stats_component.current_stamina)

# -----------------------------
# Save / Load (optional)
# -----------------------------
func to_dict() -> Dictionary:
	var d: Dictionary = {}
	d["level"] = level
	d["xp"] = current_xp
	d["unspent_points"] = unspent_points
	d["class_def_path"] = "" if class_def == null else class_def.resource_path
	return d

func from_dict(d: Dictionary) -> void:
	level = int(d.get("level", 1))
	current_xp = int(d.get("xp", 0))
	unspent_points = int(d.get("unspent_points", 0))
	var p_v: Variant = d.get("class_def_path", "")
	var p: String = String(p_v) if typeof(p_v) == TYPE_STRING else ""
	if p != "":
		var res: Resource = load(p)
		if res is ClassDefinition:
			class_def = res
			# Ensure policy/multipliers are re-applied after load
			class_def.apply_mp_policy(stats_component)
	_reconcile_all_vitals()
