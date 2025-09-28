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

@export var base_xp_to_next: int = 100
@export var xp_growth_per_level: float = 1.20

@export var unspent_points: int = 0

# -----------------------------
# Lifecycle
# -----------------------------
func _ready() -> void:
	# Ensure stats_component is resolved if scene order changed
	if stats_component == null and String(stats_component_path) != "":
		stats_component = get_node_or_null(stats_component_path)
	# Apply class once on spawn so MP policy / class overlays take effect immediately
	_apply_class_to_stats(true)

# -----------------------------
# Public API
# -----------------------------
func get_xp_to_next() -> int:
	var lv: int = max(level - 1, 0)
	var req: float = float(base_xp_to_next) * pow(xp_growth_per_level, float(lv))
	return int(round(req))

func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	if level >= max_level:
		return
	current_xp += amount
	var gained: int = 0
	while current_xp >= get_xp_to_next() and level < max_level:
		current_xp -= get_xp_to_next()
		level += 1
		gained += 1
		_on_level_up()
	emit_signal("xp_changed", current_xp, get_xp_to_next(), level)
	if gained > 0:
		emit_signal("level_up", level, gained)

func allocate_point(stat_name: String, count: int = 1) -> bool:
	if class_def == null:
		return false
	if class_def.points_per_level <= 0:
		return false
	if stats_component == null:
		return false
	if not stats_component.has_method("can_allocate"):
		return false
	if not stats_component.can_allocate(stat_name):
		return false
	if not (stat_name in class_def.allowed_point_targets):
		return false
	if unspent_points < count:
		return false
	unspent_points -= count
	_add_to_base_stat(stat_name, float(count))
	_reconcile_all_vitals()
	return true

# Assign a new class at runtime (cheats, respecs, etc.)
func set_class_def(new_def: ClassDefinition, initialize: bool = true) -> void:
	class_def = new_def
	if initialize:
		_apply_class_to_stats(true)
	else:
		_apply_class_to_stats(false)

# -----------------------------
# Internals
# -----------------------------
func _apply_class_to_stats(refill_after: bool) -> void:
	if stats_component != null and stats_component.has_method("set_class_def"):
		stats_component.call("set_class_def", class_def)
		# Bring current vitals in-bounds of new caps
		_reconcile_all_vitals()
		# Optional: full refill on class apply (keeps parity with your previous initialize flow)
		if refill_after:
			_refill_all_vitals_to_max()

func _on_level_up() -> void:
	if class_def != null:
		# Primary/GDD growth
		var g_keys: Array = class_def.growth_per_level.keys()
		for k in g_keys:
			var inc_v: Variant = class_def.growth_per_level[k]
			var inc: float = 0.0
			if typeof(inc_v) == TYPE_INT or typeof(inc_v) == TYPE_FLOAT:
				inc = float(inc_v)
			_add_to_base_stat(String(k), inc)

		# Optional flat vital floor growth (HP/MP/END floors)
		var v_keys: Array = class_def.flat_vital_growth_per_level.keys()
		for v in v_keys:
			var inc2_v: Variant = class_def.flat_vital_growth_per_level[v]
			var inc2: float = 0.0
			if typeof(inc2_v) == TYPE_INT or typeof(inc2_v) == TYPE_FLOAT:
				inc2 = float(inc2_v)
			_add_to_base_stat(String(v), inc2)

		# Points for manual allocation
		unspent_points += class_def.points_per_level

	# Clamp/refresh derived
	_reconcile_all_vitals()
	# Full refill on level up
	_refill_all_vitals_to_max()

func _add_to_base_stat(stat_name: String, delta: float) -> void:
	if stats_component == null:
		return
	var res: Resource = stats_component.stats
	if res == null:
		return
	if not res.has_method("get"):
		return
	if not res.has_method("set"):
		return

	var base_dict_v: Variant = res.get("base_stats")
	var base_dict: Dictionary = {}
	if typeof(base_dict_v) == TYPE_DICTIONARY:
		base_dict = base_dict_v

	var cur_v: Variant = base_dict.get(stat_name, 0.0)
	var cur: float = 0.0
	if typeof(cur_v) == TYPE_INT or typeof(cur_v) == TYPE_FLOAT:
		cur = float(cur_v)
	base_dict[stat_name] = cur + delta
	res.set("base_stats", base_dict)

func _reconcile_all_vitals() -> void:
	if stats_component == null:
		return
	var hp_max_val: float = 0.0
	var mp_max_val: float = 0.0
	var end_max_val: float = 0.0
	if stats_component.has_method("max_hp"):
		hp_max_val = stats_component.max_hp()
	if stats_component.has_method("max_mp"):
		mp_max_val = stats_component.max_mp()
	if stats_component.has_method("max_end"):
		end_max_val = stats_component.max_end()

	# HP
	if stats_component.has_method("current_hp") and stats_component.has_method("change_hp"):
		var cur_hp: float = float(stats_component.current_hp)
		var clamped_hp: float = clamp(cur_hp, 0.0, hp_max_val)
		var delta_hp: float = clamped_hp - cur_hp
		if absf(delta_hp) > 1e-6:
			stats_component.change_hp(delta_hp)

	# MP
	if stats_component.has_method("current_mp") and stats_component.has_method("change_mp"):
		var cur_mp: float = float(stats_component.current_mp)
		var clamped_mp: float = clamp(cur_mp, 0.0, mp_max_val)
		var delta_mp: float = clamped_mp - cur_mp
		if absf(delta_mp) > 1e-6:
			stats_component.change_mp(delta_mp)

	# END
	if stats_component.has_method("current_end") and stats_component.has_method("change_end"):
		var cur_end: float = float(stats_component.current_end)
		var clamped_end: float = clamp(cur_end, 0.0, end_max_val)
		var delta_end: float = clamped_end - cur_end
		if absf(delta_end) > 1e-6:
			stats_component.change_end(delta_end)

func _refill_all_vitals_to_max() -> void:
	if stats_component == null:
		return
	if stats_component.has_method("current_hp") and stats_component.has_method("change_hp") and stats_component.has_method("max_hp"):
		stats_component.change_hp(stats_component.max_hp() - float(stats_component.current_hp))
	if stats_component.has_method("current_mp") and stats_component.has_method("change_mp") and stats_component.has_method("max_mp"):
		stats_component.change_mp(stats_component.max_mp() - float(stats_component.current_mp))
	if stats_component.has_method("current_end") and stats_component.has_method("change_end") and stats_component.has_method("max_end"):
		stats_component.change_end(stats_component.max_end() - float(stats_component.current_end))

# -----------------------------
# Save/Load helpers
# -----------------------------
func to_dict() -> Dictionary:
	var d: Dictionary = {
		"level": level,
		"xp": current_xp,
		"unspent_points": unspent_points,
		"class_def_path": ""
	}
	var path: String = ""
	if class_def != null:
		path = String(class_def.resource_path)
	d["class_def_path"] = path
	return d

func from_dict(d: Dictionary) -> void:
	level = int(d.get("level", 1))
	current_xp = int(d.get("xp", 0))
	unspent_points = int(d.get("unspent_points", 0))

	var p_v: Variant = d.get("class_def_path", "")
	var p: String = ""
	if typeof(p_v) == TYPE_STRING:
		p = String(p_v)

	if p != "":
		var res: Resource = load(p)
		if res is ClassDefinition:
			class_def = res

	# After loading, re-apply class to stats so overlays/MP policy are active
	_apply_class_to_stats(false)
