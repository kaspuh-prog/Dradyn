extends Resource
class_name StatsResource
## Godot 4.5
## Central store of base stats for an entity. StatsComponent reads from `base_stats`.

@export var base_stats: Dictionary = {
	# ---- Vitals & Core Combat ----
	"HP": 100.0,
	"MP": 30.0,
	"Stamina": 100.0,
	"MoveSpeed": 90.0,
	"Attack": 10.0,
	"Defense": 5.0,

	# ---- Primary Attributes (GDD) ----
	"STR": 10.0,  # melee dmg & 2H atk speed
	"DEX": 10.0,  # ranged dmg, non-2H atk speed, parry/evasion
	"STA": 10.0,  # HP growth, tied to END
	"INT": 10.0,  # spell dmg & specials
	"WIS": 10.0,  # divine/healing potency
	"CHA": 10.0,  # recruitment, shops, factions, dialogue
	"LCK": 10.0,  # crits, loot, random rewards
	"END": 10.0,  # endurance: stamina/HP growth tie

	# ---- Derived placeholders (computed elsewhere; kept for UI baselines if desired) ----
	"BlockChance": 0.0,
	"ParryChance": 0.0,
	"Evasion": 0.0,
	"CritChance": 0.05,
	"CritHealChance": 0.0,
	"CritDamage": 1.5,

	# ---- Damage Resistances ----
	"SlashRes": 0.0,
	"PierceRes": 0.0,
	"BluntRes": 0.0,
	"FireRes": 0.0,
	"IceRes": 0.0,
	"WindRes": 0.0,
	"EarthRes": 0.0,
	"MagicRes": 0.0,
	"LightRes": 0.0,
	"DarknessRes": 0.0,
	"PoisonRes": 0.0,
}

func _init() -> void:
	# Optional one-time migration if older data used LightningRes
	if base_stats.has("LightningRes") and not base_stats.has("WindRes"):
		base_stats["WindRes"] = float(base_stats["LightningRes"])
		base_stats.erase("LightningRes")

# ---- Helpers ----

func has_stat(name: String) -> bool:
	return base_stats.has(name)

func get_base(name: String, default_val: float = 0.0) -> float:
	return float(base_stats.get(name, default_val))

func set_base(name: String, value: float) -> void:
	base_stats[name] = float(value)

func get_all_stat_names() -> PackedStringArray:
	var keys := PackedStringArray()
	for k in base_stats.keys():
		keys.append(str(k))
	return keys

# ---- (De)Serialization (useful for debugging, editors, or save systems) ----

func to_dict() -> Dictionary:
	return {"base_stats": base_stats}

func from_dict(data: Dictionary) -> void:
	if data.has("base_stats") and typeof(data["base_stats"]) == TYPE_DICTIONARY:
		base_stats = data["base_stats"]
		_init() # run migration just in case
