extends Resource
class_name StatsResource
## Godot 4.5
## Central store of base stats for an entity. No runtime mutation.
## Supports read-time overlay from an optional ClassDefinition (overrides + multipliers).
## END here is a floor; actual END is derived in DerivedFormulas.

@export var base_stats: Dictionary = {
	# ---- Vitals & Core Combat ----
	"HP": 100.0,
	"MP": 30.0,
	"END": 10.0,                # floor; real END derives from STA
	"MoveSpeed": 90.0,
	"Attack": 10.0,
	"Defense": 5.0,

	# ---- Primary Attributes ----
	"STR": 10.0,
	"DEX": 10.0,
	"STA": 10.0,
	"INT": 10.0,
	"WIS": 10.0,
	"CHA": 10.0,
	"LCK": 10.0,

	# ---- Resistances (–0.9..0.9) ----
	"SlashRes": 0.0, "PierceRes": 0.0, "BluntRes": 0.0,
	"FireRes": 0.0,  "IceRes": 0.0,   "WindRes": 0.0, "EarthRes": 0.0,
	"MagicRes": 0.0, "LightRes": 0.0, "DarknessRes": 0.0, "PoisonRes": 0.0,

	# ---- Chances (fractions 0..1) ----
	"CritChance": 0.0,
	"CritHealChance": 0.0,
	"BlockChance": 0.0,
	"ParryChance": 0.0,
	"Evasion": 0.0
}

# ------------------------------------------------------------
# Lifecycle / Migration
# ------------------------------------------------------------
func _init() -> void:
	_migrate_legacy_keys()
	_migrate_percent_to_fraction()
	_ensure_required_defaults()

# Rename old capacity keys to END floor
func _migrate_legacy_keys() -> void:
	if base_stats == null:
		base_stats = {}
	var legacy_to_end: Array = [
		"Stamina", "StaminaMax", "ENDU", "Endu", "Endurance", "EnduranceMax"
	]
	for old_key in legacy_to_end:
		if base_stats.has(old_key):
			var v = base_stats[old_key]
			base_stats.erase(old_key)
			if not base_stats.has("END"):
				if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
					base_stats["END"] = float(v)

# Convert authored percents (e.g., 5.0) to fractions (0.05)
func _migrate_percent_to_fraction() -> void:
	if base_stats == null:
		return
	var chance_keys: Array = ["CritChance", "CritHealChance", "BlockChance", "ParryChance", "Evasion"]
	for k in chance_keys:
		if base_stats.has(k):
			var v = base_stats[k]
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				var f: float = float(v)
				if f > 1.0:
					f = f / 100.0
				if f < 0.0:
					f = 0.0
				if f > 0.95:
					f = 0.95
				base_stats[k] = f

func _ensure_required_defaults() -> void:
	var required: Dictionary = {
		"HP": 100.0, "MP": 30.0, "END": 10.0,
		"MoveSpeed": 90.0, "Attack": 10.0, "Defense": 5.0,
		"STR": 10.0, "DEX": 10.0, "STA": 10.0, "INT": 10.0, "WIS": 10.0, "CHA": 10.0, "LCK": 10.0,
		"SlashRes": 0.0, "PierceRes": 0.0, "BluntRes": 0.0,
		"FireRes": 0.0, "IceRes": 0.0, "WindRes": 0.0, "EarthRes": 0.0,
		"MagicRes": 0.0, "LightRes": 0.0, "DarknessRes": 0.0, "PoisonRes": 0.0,
		"CritChance": 0.0, "CritHealChance": 0.0, "BlockChance": 0.0, "ParryChance": 0.0, "Evasion": 0.0
	}
	for k in required.keys():
		if not base_stats.has(k) or base_stats[k] == null:
			base_stats[k] = required[k]
		else:
			var v = base_stats[k]
			if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
				base_stats[k] = float(v)

# ------------------------------------------------------------
# Basic access (no class overlay)
# ------------------------------------------------------------
func has_stat(stat_name: String) -> bool:
	return base_stats != null and base_stats.has(stat_name)

func get_base(stat_name: String, default_val: float = 0.0) -> float:
	if base_stats == null:
		return default_val
	if base_stats.has(stat_name):
		var v = base_stats[stat_name]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return float(v)
	return default_val

func set_base(stat_name: String, value: float) -> void:
	if base_stats == null:
		base_stats = {}
	base_stats[stat_name] = float(value)

# ------------------------------------------------------------
# Class-aware access (overlay at read-time; no mutation)
# ------------------------------------------------------------
func get_base_for_class(stat_name: String, default_val: float, class_def: Resource) -> float:
	var val: float = get_base(stat_name, default_val)
	if class_def == null:
		return val

	# 1) Override wins
	if "get_base_override" in class_def and class_def.get_base_override is Callable:
		var ov = class_def.get_base_override(stat_name)
		if typeof(ov) == TYPE_INT or typeof(ov) == TYPE_FLOAT:
			val = float(ov)
	else:
		if "base_overrides" in class_def:
			var ovs = class_def.base_overrides
			if typeof(ovs) == TYPE_DICTIONARY and ovs.has(stat_name):
				var ov2 = ovs[stat_name]
				if typeof(ov2) == TYPE_INT or typeof(ov2) == TYPE_FLOAT:
					val = float(ov2)

	# 2) Multiplier scales result
	var mul: float = 1.0
	if "get_base_multiplier" in class_def and class_def.get_base_multiplier is Callable:
		mul = float(class_def.get_base_multiplier(stat_name))
	else:
		if "base_multipliers" in class_def:
			var m = class_def.base_multipliers
			if typeof(m) == TYPE_DICTIONARY and m.has(stat_name):
				var mv = m[stat_name]
				if typeof(mv) == TYPE_INT or typeof(mv) == TYPE_FLOAT:
					mul = float(mv)
	val = val * mul
	return val

# ------------------------------------------------------------
# (De)Serialization
# ------------------------------------------------------------
func get_all_stat_names() -> PackedStringArray:
	var keys: PackedStringArray = PackedStringArray()
	if base_stats == null:
		return keys
	for k in base_stats.keys():
		keys.append(str(k))
	return keys

func to_dict() -> Dictionary:
	return {"base_stats": base_stats}

func from_dict(data: Dictionary) -> void:
	if data.has("base_stats") and typeof(data["base_stats"]) == TYPE_DICTIONARY:
		base_stats = data["base_stats"]
		_init()
