@icon("res://icon.svg")
extends Resource
class_name ClassDefinition

## Data-only class profile used by leveling/derivation systems.

# ---- Identity ----
@export var class_title: String = "Class"
@export_multiline var description: String = ""

# ---- MP derivation policy (StatsComponent reads this via set_mp_source) ----
# Valid: "int", "wis", "hybrid"
@export_enum("int", "wis", "hybrid") var mp_source: String = "int"
# Only used if mp_source == "hybrid"
@export var mp_hybrid_weights: Dictionary = {"INT": 0.5, "WIS": 0.5}

# ---- One-time base multipliers (apply once when class is set) ----
# Tip: keep vitals out of multipliers (HP/MP/Stamina are derived elsewhere).
@export var base_multipliers: Dictionary = {
	"Attack": 1.0,
	"Defense": 1.0,
	"MoveSpeed": 1.0
}

# ---- Per-level growth to primary/GDD stats (NOT vitals) ----
# Keep numbers small; DerivedFormulas will make them feel meaningful.
@export var growth_per_level: Dictionary = {
	"STR": 0.6, "DEX": 0.6, "STA": 0.7,
	"INT": 0.6, "WIS": 0.6,
	"CHA": 0.2, "LCK": 0.2,
	# END is normally derived from STA; leave 0.0 unless you want a nudge
	"END": 0.0,
	"Attack": 0.3, "Defense": 0.25
}

# ---- Tiny steady flats to vitals per level (optional) ----
@export var flat_vital_growth_per_level: Dictionary = {
	"HP": 0.0,
	"MP": 0.0,
	"Stamina": 0.0
}

# ---- Player allocation settings ----
@export var points_per_level: int = 0
@export var allowed_point_targets: Array[String] = [
	"STR","DEX","STA","INT","WIS","CHA","LCK","Attack","Defense"
]

# ============================================================================
# Optional helpers (safe no-ops if the callee lacks the methods)
# ============================================================================

## Apply one-time base multipliers to a StatsComponent-like object.
func apply_base_multipliers(stats_component: Variant) -> void:
	if stats_component == null or typeof(base_multipliers) != TYPE_DICTIONARY:
		return
	for k in base_multipliers.keys():
		var mult: float = float(base_multipliers[k])
		if stats_component.has_method("multiply_base_stat"):
			stats_component.multiply_base_stat(k, mult)
		else:
			# Explicit types to avoid inference errors
			var sc_stats: Variant = stats_component.get("stats")
			if sc_stats == null:
				continue
			var base_dict_v: Variant = sc_stats.get("base_stats")
			if typeof(base_dict_v) == TYPE_DICTIONARY:
				var base_dict: Dictionary = base_dict_v
				if base_dict.has(k):
					base_dict[k] = float(base_dict[k]) * mult
					sc_stats.set("base_stats", base_dict)

## Set MP derivation policy on StatsComponent (picked up by DerivedFormulas.mp_max).
func apply_mp_policy(stats_component: Variant) -> void:
	if stats_component == null:
		return
	if stats_component.has_method("set_mp_source"):
		if mp_source == "hybrid":
			stats_component.set_mp_source(mp_source, mp_hybrid_weights)
		else:
			stats_component.set_mp_source(mp_source)

## Convenience: do both at once when assigning a class to a character.
func initialize_character(stats_component: Variant) -> void:
	apply_base_multipliers(stats_component)
	apply_mp_policy(stats_component)
