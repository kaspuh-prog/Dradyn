extends Resource
class_name AbilityDef
# Godot 4.5 — fully typed, no ternaries.

# ---------------------------
# Identity & UI
# ---------------------------

## Stable string ID used in data, hotbar slots, saves, and logs.
## Example: "necro_drain_01"
@export var ability_id: String = ""

## Player-facing name shown in UI.
@export var display_name: String = ""

## UI icon for menus/hotbar.
@export var icon: Texture2D

## Author-facing description of what the ability does.
## Often reused for UI tooltips/ability details panels.
@export_multiline var description: String = ""   # author-facing description, used for tooltips

## If set, this ability may require an item (depends on your gating logic).
## Prefer StringName IDs from your item database.
@export var required_item_id: StringName = &""

# ---------------------------
# Unlock / Tree metadata
# ---------------------------

## Skill point / unlock cost for the tree.
## 0 = free, 1 = standard.
@export var unlock_cost: int = 1

## Which skill tree section this lives in (used by SkillTree UI/logic).
@export_enum("Section1", "Section2", "Section3", "Section4")
var section_index: int = 0

## Ability level (authoring metadata).
## Used for gating/balancing if you hook it up.
@export var level: int = 1

# ---------------------------
# Core runtime metadata
# ---------------------------

## Dispatch key used by AbilityExecutor.
## Common values used in this project:
## - "MELEE"
## - "PROJECTILE"
## - "DAMAGE_SPELL"
## - "DOT_SPELL"
## - "HOT_SPELL"
## - "HEAL_SPELL"
## - "CURE_SPELL"
## - "REVIVE_SPELL"
## - "BUFF"
## - "DEBUFF"
## - "SUMMON_SPELL"
## - "PASSIVE"
@export var ability_type: String = ""     # "MELEE","PROJECTILE","DAMAGE_SPELL","DOT_SPELL","HOT_SPELL","HEAL_SPELL","CURE_SPELL","REVIVE_SPELL","BUFF","DEBUFF","SUMMON_SPELL","PASSIVE"

## If true, the cast expects a target (unless your executor resolves a fallback target).
## If false, treat it as SELF/AREA depending on target_rule.
@export var requires_target: bool = true

## Targeting intent string consumed by your targeting system and interpreted by AbilityExecutor.
@export var target_rule: String = ""      # "ALLY_SINGLE","ENEMY_SINGLE","SELF", etc.

# Costs & timings

## MP cost.
## Units: MP points.
## 0 = free.
@export var mp_cost: float = 0.0

## END cost (stamina-derived runtime resource).
## Units: END points.
## 0 = free.
@export var end_cost: float = 0.0

## Custom GCD duration.
## Units: seconds.
## 0 = use system default / none.
@export var gcd_sec: float = 0.0

## Cooldown duration.
## Units: seconds.
## 0 = no cooldown / executor default.
@export var cooldown_sec: float = 0.0

# Generic power hooks

## Generic power knob (meaning depends on ability_type/executor).
## Examples: base damage, base heal, base DOT tick, etc.
@export var power: float = 0.0

## Primary scaling stat key.
## Examples: "STR","DEX","INT","WIS"
## Leave empty to use executor defaults.
@export var scale_stat: String = ""       # "STR","DEX","INT","WIS", etc.

# ---------------------------
# Presentation hooks
# ---------------------------

## AnimationBridge string.
## If cast_anim_is_prefix is true, this is treated as a prefix
## (e.g., "cast_" to build "cast_up","cast_down", etc.).
@export var cast_anim: String = ""        # AnimationBridge prefix

## If true, cast_anim is treated as a prefix.
## If false, cast_anim is treated as an explicit animation name.
@export var cast_anim_is_prefix: bool = true

## Locks movement/inputs for this many seconds during cast.
## Units: seconds.
## 0 = no cast lock.
@export var cast_lock_sec: float = 0.0

## Free-form VFX key/hint consumed by VFXBridge (or your executor).
## Use consistent naming so content is searchable.
@export var vfx_hint: String = ""

## LEGACY: cast-start SFX event key (kept for backward compatibility).
## Step 2 keeps supporting this; prefer sfx_cues once wired.
@export var sfx_event: String = ""        # LEGACY: cast-start SFX (Step 2 will keep supporting this)

## NEW: timed SFX cues authored in frames.
## Only used if your AbilityExecutor plays them (Step 2 wiring note).
@export var sfx_cues: Array[AbilitySfxCue] = []

# ---------------------------
# Delivery parameters
# ---------------------------

## Projectile scene to spawn when ability_type expects a projectile.
## Leave null for non-projectile abilities.
@export var projectile_scene: PackedScene

# --- NEW: Summon authoring (SUMMON_SPELL) ---

## Summoned entity scene (used when ability_type == "SUMMON_SPELL").
@export var summon_scene: PackedScene

## Spawn offset distance from the caster (typically forward).
## Units: pixels.
@export var summon_spawn_offset_px: float = 16.0

## Summon lifetime.
## Units: seconds.
## 0 = unlimited (persists until killed/removed by other logic).
@export var summon_lifetime_sec: float = 0.0

# --- /NEW ---

## Radius for AOE effects.
## Units: pixels.
## 0 = not a radius ability.
@export var radius: float = 0.0

## Cone/arc angle.
## Units: degrees.
## 0 = not a cone ability.
@export var arc_degrees: float = 0.0

## Maximum targeting/cast range.
## Units: pixels.
## 0 = executor default or unlimited (depending on your logic).
@export var max_range: float = 0.0

## Tick interval for DOT/HOT.
## Units: seconds.
## 0 = no ticking (instant-only).
@export var tick_interval_sec: float = 0.0

## Total duration for DOT/HOT/BUFF/DEBUFF.
## Units: seconds.
## 0 = instant or executor default.
@export var duration_sec: float = 0.0

# ---------------------------
# Knockback authoring (optional)
# ---------------------------

## Knockback speed.
## Units: pixels per second.
## 0 = no knockback.
@export var knockback_speed_px_s: float = 0.0

## Knockback duration.
## Units: seconds.
## 0 = no knockback.
@export var knockback_duration_s: float = 0.0

## Knockback direction mode (consumed by AbilityExecutor / hit logic when wired).
## - FROM_CASTER   : push target away from caster
## - FROM_AIM      : push target along caster aim_dir
## - TO_CASTER     : pull target toward caster
## - CUSTOM_CTX    : executor reads a direction from ctx (e.g. ctx["knockback_dir"])
@export_enum("FROM_CASTER", "FROM_AIM", "TO_CASTER", "CUSTOM_CTX")
var knockback_dir_mode: String = "FROM_CASTER"

# ---------------------------
# Optional per-ability melee tuning
# ---------------------------

## Melee reach distance.
## Units: pixels.
@export var melee_range_px: float = 28.0

## Melee swing arc.
## Units: degrees.
@export var melee_arc_deg: float = 70.0

## Forward offset applied to melee hit shape.
## Units: pixels.
@export var melee_forward_offset_px: float = 10.0

## LEGACY: single hit frame index (used if melee_hit_frames is empty).
## Units: animation frame index (keep your project consistent if 0-based vs 1-based).
@export var melee_hit_frame: int = 2

## NEW: multi-hit frame indices.
## If non-empty, Step 2 will use these frames instead of melee_hit_frame.
## Units: animation frame indices.
@export var melee_hit_frames: PackedInt32Array = PackedInt32Array()

## Thickness of melee swing capsule/shape.
## Units: pixels.
@export var melee_swing_thickness_px: float = 6.0

# ---------------------------
# Revive tuning
# ---------------------------

## Flat HP granted on revive (if your executor uses it).
## Units: HP points.
## 0 = unused.
@export var revive_fixed_hp: int = 0

## Percent of target max HP granted on revive.
## IMPORTANT: ratio 0..1 (0.20 = 20%).
## 0 = unused.
@export var revive_percent_max_hp: float = 0.0

## Cap on HP restored by revive.
## Units: HP points.
## 0 = no cap / unused.
@export var revive_max_hp: int = 0

## If true, revive uses the heal formula path (if supported).
## If false, use fixed/percent fields.
@export var revive_use_heal_formula: bool = false

## Invulnerability time after revive.
## Units: seconds.
@export var revive_invuln_seconds: float = 2.0

# ---------------------------
# BUFF / DEBUFF authoring
# ---------------------------

## Stat modifiers applied as a BUFF.
## Execution behavior depends on your status/modifier system.
@export var buff_mods: Array[StatModifier] = []

## Stat modifiers applied as a DEBUFF.
## Execution behavior depends on your status/modifier system.
@export var debuff_mods: Array[StatModifier] = []

# ---------------------------
# PASSIVE gating & proc metadata (new)
# ---------------------------

## Gate mode for passives.
## "NONE" = always active.
## Other modes require equipment or item conditions (as implemented by your passive system).
@export_enum("NONE", "EQUIPPED_CLASS_IN_SLOT", "EQUIPPED_ITEM_ID_IN_SLOT", "HAS_REQUIRED_ITEM_ID")
var passive_gate_mode: String = "NONE"

## Equipment slot key used by gate checks.
## Example: "mainhand","offhand","chest", etc.
@export var passive_gate_slot: StringName = &"mainhand"

## Allowed equipment 'classes' for gate checks.
## Only used when gate mode expects equipment classes.
@export var passive_gate_equipment_classes: PackedStringArray = PackedStringArray()

## Allowed item IDs for gate checks.
## Only used when gate mode expects explicit item IDs.
@export var passive_gate_item_ids: PackedStringArray = PackedStringArray()

## Proc mode for passives.
## "NONE" = no proc.
## Other modes trigger based on cast events, filtered by section/type/id.
@export_enum("NONE", "ON_ABILITY_CAST_SECTION_INDEX", "ON_ABILITY_CAST_ABILITY_TYPE", "ON_ABILITY_CAST_ABILITY_ID")
var passive_proc_mode: String = "NONE"

## Section indices that can trigger proc (when proc mode is ON_ABILITY_CAST_SECTION_INDEX).
@export var passive_proc_section_indices: PackedInt32Array = PackedInt32Array()

## Ability types that can trigger proc (when proc mode is ON_ABILITY_CAST_ABILITY_TYPE).
@export var passive_proc_ability_types: PackedStringArray = PackedStringArray()

## Ability IDs that can trigger proc (when proc mode is ON_ABILITY_CAST_ABILITY_ID).
@export var passive_proc_ability_ids: PackedStringArray = PackedStringArray()

## If > 0, overrides duration_sec when proc applies.
## Units: seconds.
## 0 = do not override.
@export var passive_proc_duration_override_sec: float = 0.0

## If true, reapplying the proc refreshes duration on the existing instance.
@export var passive_proc_refresh_in_place: bool = true

# ---------------------------
# CURE authoring (optional)
# ---------------------------

## Status IDs to remove.
@export var cure_status_ids: PackedStringArray = PackedStringArray()

## Modifier sources to remove (if your modifier system tags sources).
@export var cure_modifier_sources: PackedStringArray = PackedStringArray()

## Stacking keys to remove (if your status system uses stacking keys).
@export var cure_stacking_keys: PackedStringArray = PackedStringArray()

# ---------------------------
# STATUS application (new single-bucket)
# ---------------------------

## Status application specs to apply on hit/cast.
## Behavior depends on StatusApplySpec + your executor.
@export var applies_status: Array[StatusApplySpec] = []

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

func is_passive() -> bool:
	if ability_type.to_upper() == "PASSIVE":
		return true
	return false

func passive_has_gate() -> bool:
	if passive_gate_mode != "NONE":
		return true
	return false

func passive_has_proc() -> bool:
	if passive_proc_mode != "NONE":
		return true
	return false
