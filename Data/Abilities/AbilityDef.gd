extends Resource
class_name AbilityDef
# Godot 4.5 — fully typed, no ternaries.

# ---------------------------
# Identity & UI
# ---------------------------
@export var ability_id: String = ""
@export var display_name: String = ""
@export var icon: Texture2D
@export_multiline var description: String = ""   # New: author-facing description, used for tooltips

# ---------------------------
# Unlock / Tree metadata
# ---------------------------
@export var unlock_cost: int = 1
@export_enum("Section1", "Section2", "Section3", "Section4")
var section_index: int = 0
@export var level: int = 1

# ---------------------------
# Core runtime metadata
# ---------------------------
@export var ability_type: String = ""     # "MELEE","PROJECTILE","DAMAGE_SPELL","DOT_SPELL","HOT_SPELL","HEAL_SPELL","CURE_SPELL","REVIVE_SPELL","BUFF","DEBUFF","SUMMON_SPELL","PASSIVE"
@export var requires_target: bool = true
@export var target_rule: String = ""      # "ALLY_SINGLE","ENEMY_SINGLE","SELF", etc.

# Costs & timings
@export var mp_cost: float = 0.0
@export var end_cost: float = 0.0
@export var gcd_sec: float = 0.0
@export var cooldown_sec: float = 0.0

# Generic power hooks
@export var power: float = 0.0
@export var scale_stat: String = ""       # "STR","DEX","INT","WIS", etc.

# ---------------------------
# Presentation hooks
# ---------------------------
@export var cast_anim: String = ""        # AnimationBridge prefix
@export var cast_anim_is_prefix: bool = true
@export var cast_lock_sec: float = 0.0

@export var vfx_hint: String = ""
@export var sfx_event: String = ""

# ---------------------------
# Delivery parameters
# ---------------------------
@export var projectile_scene: PackedScene
@export var radius: float = 0.0
@export var arc_degrees: float = 0.0
@export var max_range: float = 0.0
@export var tick_interval_sec: float = 0.0
@export var duration_sec: float = 0.0

# ---------------------------
# Optional per-ability melee tuning
# ---------------------------
@export var melee_range_px: float = 28.0
@export var melee_arc_deg: float = 70.0
@export var melee_forward_offset_px: float = 10.0
@export var melee_hit_frame: int = 2
@export var melee_swing_thickness_px: float = 6.0

# ---------------------------
# Revive tuning
# ---------------------------
@export var revive_fixed_hp: int = 0
@export var revive_percent_max_hp: float = 0.0
@export var revive_max_hp: int = 0
@export var revive_use_heal_formula: bool = false
@export var revive_invuln_seconds: float = 2.0

# ---------------------------
# BUFF / DEBUFF authoring
# ---------------------------
@export var buff_mods: Array[StatModifier] = []
@export var debuff_mods: Array[StatModifier] = []

# ---------------------------
# CURE authoring (optional)
# ---------------------------
@export var cure_status_ids: PackedStringArray = PackedStringArray()
@export var cure_modifier_sources: PackedStringArray = PackedStringArray()
@export var cure_stacking_keys: PackedStringArray = PackedStringArray()

# ---------------------------
# STATUS application (new single-bucket)
# ---------------------------
@export var applies_status: Array[StatusApplySpec] = []

# ---------------------------
# Legacy bridge (removed)
# ---------------------------
# SUGGESTED REMOVAL (approved): handler_resource / handler_path were deprecated and are gone.

# ---------------------------
# Convenience helpers
# ---------------------------
func has_custom_gcd() -> bool:
	if gcd_sec > 0.0:
		return true
	return false

func has_custom_cooldown() -> bool:
	if cooldown_sec > 0.0:
		return true
	return false

func has_projectile() -> bool:
	if projectile_scene != null:
		return true
	return false

func uses_cone() -> bool:
	if arc_degrees > 0.0:
		return true
	return false

func uses_radius() -> bool:
	if radius > 0.0:
		return true
	return false

func requires_explicit_target() -> bool:
	if requires_target:
		return true
	return false

func anim_prefix() -> String:
	if cast_anim_is_prefix:
		return cast_anim
	return cast_anim

func anim_lock_seconds() -> float:
	return cast_lock_sec
