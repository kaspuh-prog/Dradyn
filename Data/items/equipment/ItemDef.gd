extends Resource
class_name ItemDef

# Identity / presentation
@export var id: StringName
@export var display_name: String = ""
@export var description: String = ""          # NEW: short blurb shown in the description pane
@export var icon: Texture2D
@export_enum("consumable", "equipment", "reagent", "key_item") var item_type: String = "consumable"

# Equipment classification / merchant value
# equipment_class is used with ClassDefinition.allowed_equipment_classes to gate who can equip this item.
# Leave empty ("") for unrestricted items. For armor, examples include "cloth", "leather", "chain", "plate".
# For weapons, use the weapon categories from the GDD (e.g. "sword", "greatsword", "staff", etc.).
@export var equipment_class: StringName = &""
# Base merchant value for this item before LCK / shop modifiers.
@export var base_gold_value: int = 0

# Stack rules
@export var stack_max: int = 99

# For consumables
@export var use_ability_id: String = ""       # optional: pipe into AbilitySystem
@export var restore_hp: int = 0               # simple direct effects (optional)
@export var restore_mp: int = 0
@export var restore_end: int = 0

# For equipment
# NOTE: enum includes "mainhand" per latest decision.
@export_enum("head", "chest", "hands", "legs", "feet", "neck", "ring1", "ring2", "mainhand", "offhand", "back", "keepsake")
var equip_slot: String = ""

# Authorable stat modifiers (equipment bonuses, auras, etc.)
# These can be StatModifier resources OR plain Dictionaries shaped like StatModifier.to_dict().
@export var stat_modifiers: Array[Resource] = []

# Optional: per-item WeaponWeight override (used by DerivedFormulas.calc_attack_speed via StatsComponent).
# Typical scale based on current project comments:
#   0.5 = dagger/light book, 1.0 = sword/wand, 2.0 = greatsword/heavy tome.
# Leave < 0.0 to ignore and use actor/base stats instead.
@export var weapon_weight: float = -1.0

# -----------------------------------------------------------------------------
# NEW: In-hand weapon sprite (NOT the inventory icon)
# -----------------------------------------------------------------------------
# Put either:
#  - a filename without extension, e.g. "WoodenSword"
#  - or a filename with extension, e.g. "WoodenSword.png"
# This will load from: res://assets/sprites/weapons/<name>
@export var weapon_sprite_name: String = ""

const WEAPON_SPRITE_BASE_DIR: String = "res://assets/sprites/weapons/"

func get_weapon_sprite_path() -> String:
	if weapon_sprite_name.strip_edges() == "":
		return ""

	var name_clean: String = weapon_sprite_name.strip_edges()

	if name_clean.contains("."):
		return WEAPON_SPRITE_BASE_DIR + name_clean

	return WEAPON_SPRITE_BASE_DIR + name_clean + ".png"

func load_weapon_sprite_texture() -> Texture2D:
	var p: String = get_weapon_sprite_path()
	if p == "":
		return null

	if not ResourceLoader.exists(p):
		return null

	var res: Resource = ResourceLoader.load(p)
	if res == null:
		return null

	var tex: Texture2D = res as Texture2D
	return tex

# -----------------------------------------------------------------------------
# NEW: Cloak frames key (NOT the inventory icon)
# -----------------------------------------------------------------------------
# This is the SpriteFrames stem used by EquipmentVisuals for CloakSprites:
#   res://assets/sprites/characters/<Gender>/CloakSprites/<cloak_frames_name>.tres
# You can set either:
#  - "TravelerCloak"
#  - "TravelerCloak.tres"
@export var cloak_frames_name: String = ""

func get_cloak_frames_key() -> String:
	var s: String = cloak_frames_name.strip_edges()
	if s == "":
		return ""
	# if author typed "Whatever.tres", strip extension for matching
	if s.to_lower().ends_with(".tres") or s.to_lower().ends_with(".res"):
		return s.get_basename()
	return s

func get_stat_modifiers() -> Array:
	var out: Array = []

	# 1) Include authorable modifiers as-is
	var i: int = 0
	while i < stat_modifiers.size():
		out.append(stat_modifiers[i])
		i += 1

	# 2) If this is equippable and carries an explicit WeaponWeight, add an override modifier.
	#    Only relevant for hand-held slots; harmless if you later add other slots using weight.
	if item_type == "equipment":
		if weapon_weight >= 0.0:
			if equip_slot == "mainhand" or equip_slot == "offhand":
				var m: Dictionary = {
					"stat_name": "WeaponWeight",
					"add_value": 0.0,
					"mul_value": 1.0,
					"apply_override": true,
					"override_value": weapon_weight,
					"source_id": "",                 # EquipmentModel will set a stable source_id per slot
					"duration_sec": 0.0,
					"time_left": 0.0,
					"stacking_key": "",
					"max_stacks": 1,
					"refresh_duration_on_stack": true,
					"source_type": 1,                # StatModifier.ModifierSourceType.EQUIPMENT
					"stacks": 1
				}
				out.append(m)

	return out
