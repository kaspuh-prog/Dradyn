extends Resource
class_name ClassDefinition

# ---------- Identity ----------
@export var class_title: String = "Class"
@export_multiline var description: String = ""

# ---------- MP policy ----------
@export_enum("int", "wis", "hybrid", "none") var mp_source: String = "int"
@export var mp_weight_INT: float = 0.5
@export var mp_weight_WIS: float = 0.5

# ---------- Base multipliers (applied as permanent modifiers) ----------
@export_group("Base Multipliers")
@export var mul_Attack: float = 1.0
@export var mul_Defense: float = 1.0
@export var mul_MoveSpeed: float = 1.0
@export var mul_CritChance: float = 1.0
@export var mul_CritPower: float = 1.0
@export var mul_extras: Array[KeyFloatPair] = []

# ---------- Per-level growth (additive) ----------
@export_group("Growth Per Level")
@export var gr_STR: float = 0.0
@export var gr_DEX: float = 0.0
@export var gr_STA: float = 0.0
@export var gr_INT: float = 0.0
@export var gr_WIS: float = 0.0
@export var gr_CHA: float = 0.0
@export var gr_LCK: float = 0.0
@export var gr_Attack: float = 0.0
@export var gr_Defense: float = 0.0
@export var gr_extras: Array[KeyFloatPair] = []

# ---------- Flat vital growth per level (optional floors) ----------
@export_group("Flat Vital Growth / Level")
@export var grv_HP: float = 0.0
@export var grv_MP: float = 0.0
@export var grv_end: float = 0.0 # note: normalized to "END" when applying
@export var grv_extras: Array[KeyFloatPair] = []

# ---------- Allocation policy ----------
@export_group("")
@export var points_per_level: int = 1
@export var allowed_point_targets: PackedStringArray = PackedStringArray(
	["STR","DEX","STA","INT","WIS","CHA","LCK","Attack","Defense"]
)

# ---------- Equipment permissions ----------
@export_group("Equipment Permissions")
## List of equipment_class strings that this class is allowed to equip.
## If empty, the class is treated as able to equip any equipment_class.
@export var allowed_equipment_classes: PackedStringArray = PackedStringArray()

func can_equip_class(equipment_class: StringName) -> bool:
	var cls: String = String(equipment_class)
	if cls == "":
		# Items without an equipment_class are unrestricted.
		return true
	if allowed_equipment_classes.is_empty():
		# No restrictions configured for this class.
		return true
	var i: int = 0
	while i < allowed_equipment_classes.size():
		if allowed_equipment_classes[i] == cls:
			return true
		i += 1
	return false

# =====================================================================
# NEW: SkillTree (Directory-driven)
# Each class can define a base directory and 4 section subfolders.
# The UI labels are also customizable per class.
# =====================================================================
@export_group("SkillTree: Directory-driven")
@export var skilltree_base_dir: String = "res://Data/Abilities/Defs/Classes/Unknown"

# Section display names (what the UI shows)
@export var section0_name: String = "Type A"
@export var section1_name: String = "Type B"
@export var section2_name: String = "Type C"
@export var section3_name: String = "Type D"

# Section directories:
# - If a value starts with "res://", it is used as an absolute directory.
# - Otherwise it is resolved relative to skilltree_base_dir.
@export var section0_dir: String = "SectionA"
@export var section1_dir: String = "SectionB"
@export var section2_dir: String = "SectionC"
@export var section3_dir: String = "SectionD"

# ---------- Runtime dictionary views (API compatible) ----------
var mp_hybrid_weights: Dictionary:
	get:
		var d: Dictionary = {}
		d["INT"] = float(mp_weight_INT)
		d["WIS"] = float(mp_weight_WIS)
		return d
	set(value):
		if value == null:
			return
		if value.has("INT"):
			var v_int: Variant = value["INT"]
			if typeof(v_int) == TYPE_INT or typeof(v_int) == TYPE_FLOAT:
				mp_weight_INT = float(v_int)
		if value.has("WIS"):
			var v_wis: Variant = value["WIS"]
			if typeof(v_wis) == TYPE_INT or typeof(v_wis) == TYPE_FLOAT:
				mp_weight_WIS = float(v_wis)

var base_multipliers: Dictionary:
	get:
		var d: Dictionary = {}
		if not is_equal_approx(mul_Attack, 1.0):
			d["Attack"] = mul_Attack
		if not is_equal_approx(mul_Defense, 1.0):
			d["Defense"] = mul_Defense
		if not is_equal_approx(mul_MoveSpeed, 1.0):
			d["MoveSpeed"] = mul_MoveSpeed
		if not is_equal_approx(mul_CritChance, 1.0):
			d["CritChance"] = mul_CritChance
		if not is_equal_approx(mul_CritPower, 1.0):
			d["CritPower"] = mul_CritPower
		for p in mul_extras:
			if p != null and p.key != "":
				d[p.key] = float(p.value)
		return d
	set(value):
		if value == null:
			return
		mul_Attack = float(value.get("Attack", mul_Attack))
		mul_Defense = float(value.get("Defense", mul_Defense))
		mul_MoveSpeed = float(value.get("MoveSpeed", mul_MoveSpeed))
		mul_CritChance = float(value.get("CritChance", mul_CritChance))
		mul_CritPower = float(value.get("CritPower", mul_CritPower))
		mul_extras.clear()
		for k in value.keys():
			var ks: String = String(k)
			if ks == "Attack" or ks == "Defense" or ks == "MoveSpeed" or ks == "CritChance" or ks == "CritPower":
				continue
			var pair := KeyFloatPair.new()
			pair.key = ks
			var vv: Variant = value[k]
			if typeof(vv) == TYPE_INT or typeof(vv) == TYPE_FLOAT:
				pair.value = float(vv)
			mul_extras.append(pair)

var growth_per_level: Dictionary:
	get:
		var d: Dictionary = {}
		d["STR"] = gr_STR; d["DEX"] = gr_DEX; d["STA"] = gr_STA
		d["INT"] = gr_INT; d["WIS"] = gr_WIS; d["CHA"] = gr_CHA; d["LCK"] = gr_LCK
		d["Attack"] = gr_Attack; d["Defense"] = gr_Defense
		for p in gr_extras:
			if p != null and p.key != "":
				d[p.key] = float(p.value)
		return d
	set(value):
		if value == null:
			return
		gr_STR = float(value.get("STR", gr_STR))
		gr_DEX = float(value.get("DEX", gr_DEX))
		gr_STA = float(value.get("STA", gr_STA))
		gr_INT = float(value.get("INT", gr_INT))
		gr_WIS = float(value.get("WIS", gr_WIS))
		gr_CHA = float(value.get("CHA", gr_CHA))
		gr_LCK = float(value.get("LCK", gr_LCK))
		gr_Attack = float(value.get("Attack", gr_Attack))
		gr_Defense = float(value.get("Defense", gr_Defense))
		gr_extras.clear()
		for k in value.keys():
			var ks: String = String(k)
			if ks in ["STR","DEX","STA","INT","WIS","CHA","LCK","Attack","Defense"]:
				continue
			var pair := KeyFloatPair.new()
			pair.key = ks
			var vv: Variant = value[k]
			if typeof(vv) == TYPE_INT or typeof(vv) == TYPE_FLOAT:
				pair.value = float(vv)
			gr_extras.append(pair)

var flat_vital_growth_per_level: Dictionary:
	get:
		var d: Dictionary = {}
		d["HP"] = grv_HP; d["MP"] = grv_MP; d["end"] = grv_end
		for p in grv_extras:
			if p != null and p.key != "":
				d[p.key] = float(p.value)
		return d
	set(value):
		if value == null:
			return
		grv_HP = float(value.get("HP", grv_HP))
		grv_MP = float(value.get("MP", grv_MP))
		grv_end = float(value.get("end", grv_end))
		grv_extras.clear()
		for k in value.keys():
			var ks: String = String(k)
			if ks in ["HP","MP","end"]:
				continue
			var pair := KeyFloatPair.new()
			pair.key = ks
			var vv: Variant = value[k]
			if typeof(vv) == TYPE_INT or typeof(vv) == TYPE_FLOAT:
				pair.value = float(vv)
			grv_extras.append(pair)

# ---------- Convenience lookups ----------
func multiplier_for(stat_name: String) -> float:
	var d: Dictionary = base_multipliers
	if d.has(stat_name):
		var v: Variant = d[stat_name]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return float(v)
	return 1.0

func growth_for(stat_name: String) -> float:
	var d: Dictionary = growth_per_level
	if d.has(stat_name):
		var v: Variant = d[stat_name]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return float(v)
	return 0.0

func flat_vital_growth_for(stat_name: String) -> float:
	var d: Dictionary = flat_vital_growth_per_level
	if d.has(stat_name):
		var v: Variant = d[stat_name]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return float(v)
	return 0.0

func get_points_per_level() -> int:
	return points_per_level

func get_allowed_point_targets() -> PackedStringArray:
	return allowed_point_targets

# ---------- Apply to StatsComponent ----------
static func _make_modifier(stat_name: StringName, mul_value: float, source_id: String) -> Dictionary:
	var mod: Dictionary = {
		"stat_name": String(stat_name),
		"add_value": 0.0,
		"mul_value": float(mul_value),
		"source_id": source_id,
		"duration_sec": 0.0
	}
	return mod

func _class_source_id() -> String:
	var t: String = class_title
	if t == "":
		t = "Class"
	return "class_def:" + t

func clear_class_modifiers(stats_component: Variant) -> void:
	if stats_component == null:
		return
	if not stats_component.has_method("remove_modifiers_by_source"):
		return
	stats_component.remove_modifiers_by_source(_class_source_id())

func apply_base_multipliers(stats_component: Variant) -> void:
	if stats_component == null:
		return
	clear_class_modifiers(stats_component)
	var d: Dictionary = base_multipliers
	if d.is_empty():
		return
	var sid: String = _class_source_id()
	for k in d.keys():
		var s: String = String(k)
		var mult: float = 1.0
		var v: Variant = d[k]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			mult = float(v)
		if is_equal_approx(mult, 1.0):
			continue
		var mod: Dictionary = _make_modifier(StringName(s), mult, sid)
		if stats_component.has_method("add_modifier"):
			stats_component.add_modifier(mod)

func apply_mp_policy(stats_component: Variant) -> void:
	if stats_component == null:
		return
	if not stats_component.has_method("set_mp_source"):
		return
	match mp_source:
		"hybrid":
			var w: Dictionary = {"INT": float(mp_weight_INT), "WIS": float(mp_weight_WIS)}
			stats_component.set_mp_source("hybrid", w)
		"int":
			stats_component.set_mp_source("int")
		"wis":
			stats_component.set_mp_source("wis")
		"none":
			# Explicitly disable INT/WIS scaling by using hybrid with zeroed weights
			stats_component.set_mp_source("hybrid", {"INT": 0.0, "WIS": 0.0})
		_:
			var w2: Dictionary = {"INT": float(mp_weight_INT), "WIS": float(mp_weight_WIS)}
			stats_component.set_mp_source("hybrid", w2)

# ---------- New: apply level growth ----------
func apply_level_growth(stats_component: Variant, new_level: int) -> void:
	if stats_component == null:
		return
	var sid: String = "level:Lv.%d" % [int(new_level)]

	# 1) Primaries / derived (from growth_per_level + extras)
	var gp: Dictionary = growth_per_level
	for k in gp.keys():
		var key: String = String(k)
		var delta_v: Variant = gp[k]
		var delta: float = 0.0
		if typeof(delta_v) == TYPE_INT or typeof(delta_v) == TYPE_FLOAT:
			delta = float(delta_v)
		if is_zero_approx(delta):
			continue
		var mod1: Dictionary = {
			"stat_name": key,
			"add_value": delta,
			"mul_value": 1.0,
			"source_id": sid,
			"duration_sec": 0.0
		}
		if stats_component.has_method("add_modifier"):
			stats_component.add_modifier(mod1)

	# 2) Flat vitals (normalize "end" -> "END")
	var fv: Dictionary = flat_vital_growth_per_level
	for vk in fv.keys():
		var vkey_raw: String = String(vk)
		var vkey: String = vkey_raw
		if vkey_raw == "end":
			vkey = "END"
		var dv_v: Variant = fv[vk]
		var dv: float = 0.0
		if typeof(dv_v) == TYPE_INT or typeof(dv_v) == TYPE_FLOAT:
			dv = float(dv_v)
		if is_zero_approx(dv):
			continue
		var mod2: Dictionary = {
			"stat_name": vkey,
			"add_value": dv,
			"mul_value": 1.0,
			"source_id": sid,
			"duration_sec": 0.0
		}
		if stats_component.has_method("add_modifier"):
			stats_component.add_modifier(mod2)

# ---------- Initialization: apply base + MP policy + starting growth ----------
func initialize_character(stats_component: Variant) -> void:
	apply_base_multipliers(stats_component)
	apply_mp_policy(stats_component)

	# Apply cumulative growth for actors that start above level 1.
	var start_level: int = 1
	if stats_component is Node:
		var node_sc: Node = stats_component as Node
		var actor: Node = node_sc.get_parent()
		if actor != null:
			var lc: Node = actor.get_node_or_null("LevelComponent")
			if lc != null:
				# keep Variant safety for user-defined LevelComponent
				var lv_v: Variant = lc.get("level")
				if typeof(lv_v) == TYPE_INT:
					start_level = int(lv_v)
	if start_level > 1:
		for i in range(2, start_level + 1):
			apply_level_growth(stats_component, i)

# ---------- Save/Load ----------
func to_dict() -> Dictionary:
	var d: Dictionary = {
		"class_title": class_title,
		"description": description,
		"mp_source": mp_source,
		"mp_hybrid_weights": mp_hybrid_weights,
		"base_multipliers": base_multipliers,
		"growth_per_level": growth_per_level,
		"flat_vital_growth_per_level": flat_vital_growth_per_level,
		"points_per_level": points_per_level,
		"allowed_point_targets": allowed_point_targets,
		"allowed_equipment_classes": allowed_equipment_classes,
		# NEW: persist skilltree directory config & names
		"skilltree_base_dir": skilltree_base_dir,
		"section_names": get_skilltree_section_names(),
		"section_dirs": get_skilltree_section_dirs_raw()
	}
	return d

func from_dict(d: Dictionary) -> void:
	class_title = str(d.get("class_title", class_title))
	description = str(d.get("description", description))

	var mps_v: Variant = d.get("mp_source", mp_source)
	if typeof(mps_v) == TYPE_STRING:
		mp_source = String(mps_v)

	var w_v: Variant = d.get("mp_hybrid_weights", {})
	if typeof(w_v) == TYPE_DICTIONARY:
		mp_hybrid_weights = w_v

	var bm_v: Variant = d.get("base_multipliers", {})
	if typeof(bm_v) == TYPE_DICTIONARY:
		base_multipliers = bm_v

	var g_v: Variant = d.get("growth_per_level", {})
	if typeof(g_v) == TYPE_DICTIONARY:
		growth_per_level = g_v

	var f_v: Variant = d.get("flat_vital_growth_per_level", {})
	if typeof(f_v) == TYPE_DICTIONARY:
		flat_vital_growth_per_level = f_v

	points_per_level = int(d.get("points_per_level", points_per_level))

	var apt_v: Variant = d.get("allowed_point_targets", allowed_point_targets)
	if typeof(apt_v) == TYPE_PACKED_STRING_ARRAY:
		allowed_point_targets = apt_v
	elif typeof(apt_v) == TYPE_ARRAY:
		var arr: Array = apt_v
		var psa: PackedStringArray = PackedStringArray()
		for x in arr:
			psa.append(str(x))
		allowed_point_targets = psa

	# NEW: restore allowed_equipment_classes if present
	var aec_v: Variant = d.get("allowed_equipment_classes", allowed_equipment_classes)
	if typeof(aec_v) == TYPE_PACKED_STRING_ARRAY:
		allowed_equipment_classes = aec_v
	elif typeof(aec_v) == TYPE_ARRAY:
		var aarr: Array = aec_v
		var a_psa: PackedStringArray = PackedStringArray()
		for x in aarr:
			a_psa.append(str(x))
		allowed_equipment_classes = a_psa

	# NEW: restore skilltree directory config & names if present
	var bdir_v: Variant = d.get("skilltree_base_dir", skilltree_base_dir)
	if typeof(bdir_v) == TYPE_STRING:
		skilltree_base_dir = String(bdir_v)

	var sn_v: Variant = d.get("section_names", PackedStringArray())
	if typeof(sn_v) == TYPE_PACKED_STRING_ARRAY:
		var sn: PackedStringArray = sn_v
		if sn.size() >= 4:
			section0_name = sn[0]
			section1_name = sn[1]
			section2_name = sn[2]
			section3_name = sn[3]
	elif typeof(sn_v) == TYPE_ARRAY:
		var sna: Array = sn_v
		if sna.size() >= 4:
			section0_name = str(sna[0])
			section1_name = str(sna[1])
			section2_name = str(sna[2])
			section3_name = str(sna[3])

	var sd_v: Variant = d.get("section_dirs", PackedStringArray())
	if typeof(sd_v) == TYPE_PACKED_STRING_ARRAY:
		var sd: PackedStringArray = sd_v
		if sd.size() >= 4:
			section0_dir = sd[0]
			section1_dir = sd[1]
			section2_dir = sd[2]
			section3_dir = sd[3]
	elif typeof(sd_v) == TYPE_ARRAY:
		var sda: Array = sd_v
		if sda.size() >= 4:
			section0_dir = str(sda[0])
			section1_dir = str(sda[1])
			section2_dir = str(sda[2])
			section3_dir = str(sda[3])

# =====================================================================
# NEW: Helper API for SkillTreeMediator / UI
# =====================================================================

func get_skilltree_section_names() -> PackedStringArray:
	var arr: PackedStringArray = PackedStringArray()
	arr.append(section0_name)
	arr.append(section1_name)
	arr.append(section2_name)
	arr.append(section3_name)
	return arr

# Raw (as stored) subfolder names or absolute res:// paths (strings as-is).
func get_skilltree_section_dirs_raw() -> PackedStringArray:
	var arr: PackedStringArray = PackedStringArray()
	arr.append(section0_dir)
	arr.append(section1_dir)
	arr.append(section2_dir)
	arr.append(section3_dir)
	return arr

# Fully-resolved res:// directories for each section (size == 4).
func get_skilltree_section_dirs_resolved() -> PackedStringArray:
	var resolved: PackedStringArray = PackedStringArray()
	resolved.append(_resolve_dir(section0_dir))
	resolved.append(_resolve_dir(section1_dir))
	resolved.append(_resolve_dir(section2_dir))
	resolved.append(_resolve_dir(section3_dir))
	return resolved

# Optional: return a 4-element array where each element is a PackedStringArray
# of resource paths to .tres/.res files found in the corresponding section directory.
func list_ability_def_paths_by_section() -> Array:
	var out: Array = []
	var dirs: PackedStringArray = get_skilltree_section_dirs_resolved()
	var i: int = 0
	while i < 4:
		var dir_path: String = dirs[i]
		var files: PackedStringArray = _list_ability_def_files(dir_path)
		out.append(files)
		i += 1
	return out

# ---------- Internals ----------
func _resolve_dir(subpath: String) -> String:
	if subpath.begins_with("res://"):
		return subpath
	var base: String = skilltree_base_dir
	if base == "":
		base = "res://"
	if base.ends_with("/"):
		return base + subpath
	return base + "/" + subpath

func _list_ability_def_files(dir_path: String) -> PackedStringArray:
	var results: PackedStringArray = PackedStringArray()
	if dir_path == "":
		return results
	if not DirAccess.dir_exists_absolute(dir_path):
		return results
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return results
	da.list_dir_begin()
	while true:
		var fname: String = da.get_next()
		if fname == "":
			break
		if da.current_is_dir():
			continue
		var is_tres: bool = fname.ends_with(".tres")
		var is_res: bool = fname.ends_with(".res")
		if not is_tres and not is_res:
			continue
		var res_path: String = dir_path.strip_edges(true, true)
		if res_path.ends_with("/"):
			res_path = res_path + fname
		else:
			res_path = res_path + "/" + fname
		results.append(res_path)
	da.list_dir_end()

	# Optional: stable ordering by filename (string sort)
	results.sort()
	return results
