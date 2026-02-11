@tool
extends EditorScript
class_name AbilityDefCsvGenerator

const CSV_PATH: String = "res://Data/Abilities/AbilityDefs.csv"
const BASECLASS_DIR: String = "res://Data/BaseClasses/"
const STAT_MOD_DIR: String = "res://Data/StatModifiers/"
const ICONS_DIR: String = "res://assets/sprites/abilityicons/"

const ENEMIES_DIR: String = "res://Data/Abilities/Defs/Enemies/"
const ITEM_ABILITIES_DIR: String = "res://Data/Abilities/Defs/ItemAbilities/"

const STATUS_SPEC_DIR: String = "res://Data/Abilities/StatusApplySpecs/"

# Optional: keep this list small + canonical.
# If you add new types later, add them here to avoid noisy warnings.
# Optional: keep this list small + canonical.
# If you add new types later, add them here to avoid noisy warnings.
const KNOWN_ABILITY_TYPES: Array[String] = [
	"MELEE",
	"PROJECTILE",
	"DAMAGE_SPELL",
	"DOT_SPELL",
	"DEBUFF",
	"HEAL_SPELL",
	"HOT_SPELL",
	"REVIVE_SPELL",
	"CURE_SPELL",
	"BUFF",
	"SUMMON_SPELL",
	"PASSIVE"
]


# If true, prints when the tool had to clean hidden characters (CR/BOM/NBSP).
@export var debug_csv_sanitizer: bool = true


func _run() -> void:
	if not Engine.is_editor_hint():
		return

	print("[AbilityDefCsvGenerator] Starting generation from CSV: ", CSV_PATH)

	var file: FileAccess = FileAccess.open(CSV_PATH, FileAccess.READ)
	if file == null:
		push_error("[AbilityDefCsvGenerator] Could not open CSV file: " + CSV_PATH)
		return

	var header_line: String = file.get_line()
	if header_line == "":
		push_error("[AbilityDefCsvGenerator] CSV has no header line.")
		return

	var header_cells: PackedStringArray = _parse_csv_line(header_line)
	var header_map: Dictionary = {}
	var i: int = 0
	while i < header_cells.size():
		var raw_key: String = header_cells[i]
		var key: String = _sanitize_csv_text(raw_key)
		if debug_csv_sanitizer and key != raw_key.strip_edges():
			print("[AbilityDefCsvGenerator] Header key sanitized: '", raw_key, "' -> '", key, "'")
		if key != "":
			header_map[key] = i
		i += 1

	print("[AbilityDefCsvGenerator] Header columns: ", header_map.keys())

	var line_index: int = 1
	while not file.eof_reached():
		var line: String = file.get_line()
		line_index += 1

		if _sanitize_csv_text(line) == "":
			continue
		if line.begins_with("#"):
			continue

		var cells: PackedStringArray = _parse_csv_line(line)
		_process_data_row(cells, header_map, line_index)

	print("[AbilityDefCsvGenerator] Done.")


func _process_data_row(cells: PackedStringArray, header_map: Dictionary, line_index: int) -> void:
	var class_folder: String = _get_cell(cells, header_map, "class", "")
	class_folder = _sanitize_csv_text(class_folder)

	var section_index_raw: String = _get_cell(cells, header_map, "section_index", "")
	section_index_raw = _sanitize_csv_text(section_index_raw)

	var section_index: int = 0
	if section_index_raw != "":
		section_index = _parse_int(section_index_raw, 0)

	var ability_id: String = _get_cell(cells, header_map, "ability_id", "")
	ability_id = _sanitize_csv_text(ability_id)

	if ability_id == "":
		print("[AbilityDefCsvGenerator] Skipping line ", line_index, ": empty ability_id.")
		return

	var output_dir: String = _resolve_output_dir(class_folder, section_index, line_index)
	if output_dir == "":
		return

	var resource_path: String = _join_path(output_dir, ability_id + ".tres")

	var def: AbilityDef = null
	if ResourceLoader.exists(resource_path):
		var existing: Resource = load(resource_path)
		if existing != null and existing is AbilityDef:
			def = existing as AbilityDef
		else:
			push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": existing resource is not AbilityDef: " + resource_path)
			return
	else:
		def = AbilityDef.new()
		def.ability_id = ability_id

	# Always ensure ability_id matches the filename.
	def.ability_id = ability_id

	# Section index (only overwrite if CSV non-blank)
	if section_index_raw != "":
		def.section_index = section_index

	# --- Identity & UI (only overwrite if CSV non-blank) ---
	_set_string_if_nonblank(def, "display_name", _get_cell(cells, header_map, "display_name", ""))
	_set_string_if_nonblank(def, "description", _get_cell(cells, header_map, "description", ""))

	# Icon: keep existing icon if present; only auto-load if missing.
	if def.icon == null:
		var icon_path: String = _join_path(ICONS_DIR, ability_id + ".png")
		if ResourceLoader.exists(icon_path):
			var tex: Resource = load(icon_path)
			if tex != null and tex is Texture2D:
				def.icon = tex as Texture2D
		else:
			print("[AbilityDefCsvGenerator] Line ", line_index, ": icon not found: ", icon_path)

	# required_item_id (StringName) only if CSV non-blank
	var required_item_id_str: String = _sanitize_csv_text(_get_cell(cells, header_map, "required_item_id", ""))
	if required_item_id_str != "":
		def.required_item_id = StringName(required_item_id_str)

	# --- Unlock / Tree metadata ---
	_set_int_if_nonblank(def, "unlock_cost", _get_cell(cells, header_map, "unlock_cost", ""))
	_set_int_if_nonblank(def, "level", _get_cell(cells, header_map, "level", ""))

	# --- Core runtime metadata ---
	_set_ability_type_if_nonblank(def, "ability_type", _get_cell(cells, header_map, "ability_type", ""), ability_id, line_index)
	_set_bool_if_nonblank(def, "requires_target", _get_cell(cells, header_map, "requires_target", ""))
	_set_string_if_nonblank(def, "target_rule", _get_cell(cells, header_map, "target_rule", ""))

	# --- PASSIVE gating & proc metadata (only overwrite if CSV non-blank) ---
	_set_string_if_nonblank(def, "passive_gate_mode", _get_cell(cells, header_map, "passive_gate_mode", ""))

	var passive_gate_slot_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "passive_gate_slot", ""))
	if passive_gate_slot_raw != "":
		def.passive_gate_slot = StringName(passive_gate_slot_raw)

	var passive_gate_classes_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "passive_gate_equipment_classes", ""))
	if passive_gate_classes_raw != "":
		def.passive_gate_equipment_classes = _parse_string_list(passive_gate_classes_raw)

	var passive_gate_item_ids_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "passive_gate_item_ids", ""))
	if passive_gate_item_ids_raw != "":
		def.passive_gate_item_ids = _parse_string_list(passive_gate_item_ids_raw)

	_set_string_if_nonblank(def, "passive_proc_mode", _get_cell(cells, header_map, "passive_proc_mode", ""))

	var passive_proc_sections_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "passive_proc_section_indices", ""))
	if passive_proc_sections_raw != "":
		def.passive_proc_section_indices = _parse_int_list(passive_proc_sections_raw)

	var passive_proc_types_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "passive_proc_ability_types", ""))
	if passive_proc_types_raw != "":
		# This list is ability types — normalize each token like ability_type.
		def.passive_proc_ability_types = _parse_ability_type_list(passive_proc_types_raw, ability_id, line_index)

	var passive_proc_ids_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "passive_proc_ability_ids", ""))
	if passive_proc_ids_raw != "":
		def.passive_proc_ability_ids = _parse_string_list(passive_proc_ids_raw)

	_set_float_if_nonblank(def, "passive_proc_duration_override_sec", _get_cell(cells, header_map, "passive_proc_duration_override_sec", ""))
	_set_bool_if_nonblank(def, "passive_proc_refresh_in_place", _get_cell(cells, header_map, "passive_proc_refresh_in_place", ""))

	# --- Costs & timings ---
	_set_float_if_nonblank(def, "mp_cost", _get_cell(cells, header_map, "mp_cost", ""))
	_set_float_if_nonblank(def, "end_cost", _get_cell(cells, header_map, "end_cost", ""))
	_set_float_if_nonblank(def, "gcd_sec", _get_cell(cells, header_map, "gcd_sec", ""))
	_set_float_if_nonblank(def, "cooldown_sec", _get_cell(cells, header_map, "cooldown_sec", ""))

	# --- Generic power hooks ---
	_set_float_if_nonblank(def, "power", _get_cell(cells, header_map, "power", ""))
	_set_string_if_nonblank(def, "scale_stat", _get_cell(cells, header_map, "scale_stat", ""))

	# --- Presentation hooks ---
	_set_string_if_nonblank(def, "cast_anim", _get_cell(cells, header_map, "cast_anim", ""))
	_set_bool_if_nonblank(def, "cast_anim_is_prefix", _get_cell(cells, header_map, "cast_anim_is_prefix", ""))
	_set_float_if_nonblank(def, "cast_lock_sec", _get_cell(cells, header_map, "cast_lock_sec", ""))

	_set_string_if_nonblank(def, "sfx_event", _get_cell(cells, header_map, "sfx_event", ""))
	_set_string_if_nonblank(def, "vfx_hint", _get_cell(cells, header_map, "vfx_hint", ""))

	# --- Delivery parameters ---
	var projectile_scene_path: String = _sanitize_csv_text(_get_cell(cells, header_map, "projectile_scene", ""))
	if projectile_scene_path != "":
		if ResourceLoader.exists(projectile_scene_path):
			var ps: Resource = load(projectile_scene_path)
			if ps != null and ps is PackedScene:
				def.projectile_scene = ps as PackedScene
			else:
				push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": projectile_scene is not a PackedScene: " + projectile_scene_path)
		else:
			push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": projectile_scene not found: " + projectile_scene_path)

	_set_float_if_nonblank(def, "radius", _get_cell(cells, header_map, "radius", ""))
	_set_float_if_nonblank(def, "arc_degrees", _get_cell(cells, header_map, "arc_degrees", ""))
	_set_float_if_nonblank(def, "max_range", _get_cell(cells, header_map, "max_range", ""))
	_set_float_if_nonblank(def, "tick_interval_sec", _get_cell(cells, header_map, "tick_interval_sec", ""))
	_set_float_if_nonblank(def, "duration_sec", _get_cell(cells, header_map, "duration_sec", ""))

	# --- Melee tuning ---
	_set_float_if_nonblank(def, "melee_range_px", _get_cell(cells, header_map, "melee_range_px", ""))
	_set_float_if_nonblank(def, "melee_arc_deg", _get_cell(cells, header_map, "melee_arc_deg", ""))
	_set_float_if_nonblank(def, "melee_forward_offset_px", _get_cell(cells, header_map, "melee_forward_offset_px", ""))
	_set_int_if_nonblank(def, "melee_hit_frame", _get_cell(cells, header_map, "melee_hit_frame", ""))
	_set_float_if_nonblank(def, "melee_swing_thickness_px", _get_cell(cells, header_map, "melee_swing_thickness_px", ""))

	# --- Revive tuning ---
	_set_int_if_nonblank(def, "revive_fixed_hp", _get_cell(cells, header_map, "revive_fixed_hp", ""))
	_set_float_if_nonblank(def, "revive_percent_max_hp", _get_cell(cells, header_map, "revive_percent_max_hp", ""))
	_set_int_if_nonblank(def, "revive_max_hp", _get_cell(cells, header_map, "revive_max_hp", ""))
	_set_bool_if_nonblank(def, "revive_use_heal_formula", _get_cell(cells, header_map, "revive_use_heal_formula", ""))
	_set_float_if_nonblank(def, "revive_invuln_seconds", _get_cell(cells, header_map, "revive_invuln_seconds", ""))

	# --- Buff / Debuff authoring (only overwrite if CSV non-blank) ---
	var buff_mods_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "buff_mods", ""))
	if buff_mods_raw != "":
		def.buff_mods = _parse_stat_mod_list(buff_mods_raw, line_index, "buff_mods")

	var debuff_mods_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "debuff_mods", ""))
	if debuff_mods_raw != "":
		def.debuff_mods = _parse_stat_mod_list(debuff_mods_raw, line_index, "debuff_mods")

	# --- Cure authoring (only overwrite if CSV non-blank) ---
	var cure_status_ids_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "cure_status_ids", ""))
	if cure_status_ids_raw != "":
		def.cure_status_ids = _parse_string_list(cure_status_ids_raw)

	var cure_modifier_sources_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "cure_modifier_sources", ""))
	if cure_modifier_sources_raw != "":
		def.cure_modifier_sources = _parse_string_list(cure_modifier_sources_raw)

	var cure_stacking_keys_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "cure_stacking_keys", ""))
	if cure_stacking_keys_raw != "":
		def.cure_stacking_keys = _parse_string_list(cure_stacking_keys_raw)

	# --- applies_status (StatusApplySpec list) ---
	var applies_status_raw: String = _sanitize_csv_text(_get_cell(cells, header_map, "applies_status", ""))
	if applies_status_raw != "":
		def.applies_status = _parse_status_apply_list(applies_status_raw, line_index)

	_ensure_directory_for_path(resource_path)

	var err: int = ResourceSaver.save(def, resource_path)
	if err != OK:
		push_error("[AbilityDefCsvGenerator] Failed to save " + resource_path + ": " + error_string(err))
	else:
		print("[AbilityDefCsvGenerator] Wrote AbilityDef: ", resource_path)


func _resolve_output_dir(class_folder: String, section_index: int, line_index: int) -> String:
	if class_folder == "":
		push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": class is required.")
		return ""

	if class_folder == "Enemies":
		return _ensure_trailing_slash(ENEMIES_DIR)

	if class_folder == "ItemAbilities":
		return _ensure_trailing_slash(ITEM_ABILITIES_DIR)

	var class_def_path: String = _join_path(BASECLASS_DIR, class_folder + ".tres")
	if not ResourceLoader.exists(class_def_path):
		push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": class definition not found: " + class_def_path)
		return ""

	var cd_res: Resource = load(class_def_path)
	if cd_res == null or not (cd_res is ClassDefinition):
		push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": class definition is not ClassDefinition: " + class_def_path)
		return ""

	var cd: ClassDefinition = cd_res as ClassDefinition

	var section_dir_raw: String = ""
	if section_index == 0:
		section_dir_raw = cd.section0_dir
	elif section_index == 1:
		section_dir_raw = cd.section1_dir
	elif section_index == 2:
		section_dir_raw = cd.section2_dir
	elif section_index == 3:
		section_dir_raw = cd.section3_dir
	else:
		push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": section_index must be 0-3, got: " + str(section_index))
		return ""

	section_dir_raw = _sanitize_csv_text(section_dir_raw)
	if section_dir_raw == "":
		push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": section dir is empty for section_index " + str(section_index) + " in " + class_def_path)
		return ""

	if section_dir_raw.begins_with("res://"):
		return _ensure_trailing_slash(section_dir_raw)

	var base_dir: String = _sanitize_csv_text(cd.skilltree_base_dir)
	if base_dir == "":
		push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": skilltree_base_dir is empty in " + class_def_path)
		return ""
	base_dir = _ensure_trailing_slash(base_dir)

	var resolved: String = _join_path(base_dir, section_dir_raw)
	return _ensure_trailing_slash(resolved)


func _parse_stat_mod_list(raw: String, line_index: int, column_name: String) -> Array[StatModifier]:
	var out: Array[StatModifier] = []
	if raw == "":
		return out

	var parts: PackedStringArray = raw.split("|", false)
	for p: String in parts:
		var token: String = _sanitize_csv_text(p)
		if token == "":
			continue

		var path: String = ""
		if token.begins_with("res://"):
			path = token
		else:
			path = _join_path(STAT_MOD_DIR, token + ".tres")

		if not ResourceLoader.exists(path):
			push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": " + column_name + " StatModifier not found: " + path)
			continue

		var r: Resource = load(path)
		if r == null or not (r is StatModifier):
			push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": " + column_name + " not a StatModifier: " + path)
			continue

		out.append(r as StatModifier)

	return out


func _parse_status_apply_list(raw: String, line_index: int) -> Array[StatusApplySpec]:
	var out: Array[StatusApplySpec] = []
	if raw == "":
		return out

	var parts: PackedStringArray = raw.split("|", false)
	for p: String in parts:
		var token: String = _sanitize_csv_text(p)
		if token == "":
			continue

		var path: String = ""
		if token.begins_with("res://"):
			path = token
		else:
			path = _join_path(STATUS_SPEC_DIR, token + ".tres")

		if not ResourceLoader.exists(path):
			push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": applies_status StatusApplySpec not found: " + path)
			continue

		var r: Resource = load(path)
		if r == null or not (r is StatusApplySpec):
			push_error("[AbilityDefCsvGenerator] Line " + str(line_index) + ": applies_status not a StatusApplySpec: " + path)
			continue

		out.append(r as StatusApplySpec)

	return out


func _parse_string_list(raw: String) -> PackedStringArray:
	if raw == "":
		return PackedStringArray()

	var parts: PackedStringArray = raw.split("|", false)
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		var token: String = _sanitize_csv_text(p)
		if token == "":
			continue
		out.append(token)
	return out


func _parse_ability_type_list(raw: String, ability_id: String, line_index: int) -> PackedStringArray:
	if raw == "":
		return PackedStringArray()

	var parts: PackedStringArray = raw.split("|", false)
	var out: PackedStringArray = PackedStringArray()
	for p: String in parts:
		var token: String = _normalize_ability_type(p)
		if token == "":
			continue
		out.append(token)

		if KNOWN_ABILITY_TYPES.size() > 0 and not KNOWN_ABILITY_TYPES.has(token):
			push_warning("[AbilityDefCsvGenerator] Line " + str(line_index) + " (" + ability_id + "): unknown passive_proc_ability_type '" + token + "'")

	return out


func _parse_int_list(raw: String) -> PackedInt32Array:
	var out: PackedInt32Array = PackedInt32Array()
	if raw == "":
		return out

	var parts: PackedStringArray = raw.split("|", false)
	for p: String in parts:
		var token: String = _sanitize_csv_text(p)
		if token == "":
			continue
		if not token.is_valid_int():
			continue
		out.append(int(token))
	return out


func _parse_csv_line(line: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var current: String = ""
	var in_quotes: bool = false
	var i: int = 0
	while i < line.length():
		var ch: String = line.substr(i, 1)
		if ch == "\"":
			if in_quotes:
				if i + 1 < line.length() and line.substr(i + 1, 1) == "\"":
					current += "\""
					i += 1
				else:
					in_quotes = false
			else:
				in_quotes = true
		elif ch == "," and not in_quotes:
			out.append(current)
			current = ""
		else:
			current += ch
		i += 1
	out.append(current)
	return out


func _get_cell(cells: PackedStringArray, header_map: Dictionary, key: String, default_value: String) -> String:
	if not header_map.has(key):
		return default_value
	var idx: int = int(header_map[key])
	if idx < 0 or idx >= cells.size():
		return default_value
	return cells[idx]


func _parse_int(s: String, default_value: int) -> int:
	var t: String = _sanitize_csv_text(s)
	if t == "":
		return default_value
	if not t.is_valid_int():
		return default_value
	return int(t)


func _parse_float(s: String, default_value: float) -> float:
	var t: String = _sanitize_csv_text(s)
	if t == "":
		return default_value
	if not t.is_valid_float():
		return default_value
	return float(t)


func _parse_bool(s: String, default_value: bool) -> bool:
	var t: String = _sanitize_csv_text(s).to_lower()
	if t == "":
		return default_value
	if t == "true":
		return true
	if t == "false":
		return false
	if t == "1":
		return true
	if t == "0":
		return false
	return default_value


func _set_string_if_nonblank(obj: Object, prop: String, raw: String) -> void:
	var v: String = _sanitize_csv_text(raw)
	if v == "":
		return
	obj.set(prop, v)


func _set_int_if_nonblank(obj: Object, prop: String, raw: String) -> void:
	var v: String = _sanitize_csv_text(raw)
	if v == "":
		return
	if not v.is_valid_int():
		return
	obj.set(prop, int(v))


func _set_float_if_nonblank(obj: Object, prop: String, raw: String) -> void:
	var v: String = _sanitize_csv_text(raw)
	if v == "":
		return
	if not v.is_valid_float():
		return
	obj.set(prop, float(v))


func _set_bool_if_nonblank(obj: Object, prop: String, raw: String) -> void:
	var v: String = _sanitize_csv_text(raw).to_lower()
	if v == "":
		return
	if v == "true" or v == "1":
		obj.set(prop, true)
		return
	if v == "false" or v == "0":
		obj.set(prop, false)
		return


func _set_ability_type_if_nonblank(def: AbilityDef, prop: String, raw: String, ability_id: String, line_index: int) -> void:
	var before: String = raw
	var normalized: String = _normalize_ability_type(raw)
	if normalized == "":
		return

	if debug_csv_sanitizer:
		var stripped: String = raw.strip_edges()
		if normalized != stripped.to_upper():
			print("[AbilityDefCsvGenerator] ability_type normalized (", ability_id, " line ", line_index, "): '", before, "' -> '", normalized, "'")

	if KNOWN_ABILITY_TYPES.size() > 0 and not KNOWN_ABILITY_TYPES.has(normalized):
		push_warning("[AbilityDefCsvGenerator] Line " + str(line_index) + " (" + ability_id + "): unknown ability_type '" + normalized + "'")

	def.set(prop, normalized)


func _normalize_ability_type(raw: String) -> String:
	var s: String = _sanitize_csv_text(raw)
	if s == "":
		return ""
	s = s.to_upper()

	# Common CSV authoring mistakes:
	# - spaces instead of underscores
	# - hyphens instead of underscores
	s = s.replace(" ", "_")
	s = s.replace("-", "_")

	# Collapse accidental multiple underscores (cheap + safe)
	while s.find("__") != -1:
		s = s.replace("__", "_")

	return s


func _sanitize_csv_text(raw: String) -> String:
	var s: String = raw

	# Remove BOM if present (common in UTF-8 CSV exports)
	s = s.replace("\ufeff", "")

	# Remove CR/LF that can get preserved from Windows files, especially last column
	s = s.replace("\r", "")
	s = s.replace("\n", "")

	# Replace tabs with spaces
	s = s.replace("\t", " ")

	# Replace non-breaking space with normal space
	var nbsp: String = String.chr(160)
	s = s.replace(nbsp, " ")

	return s.strip_edges()


func _ensure_directory_for_path(res_path: String) -> void:
	var dir_path: String = res_path.get_base_dir()
	if dir_path == "":
		return

	var absolute: String = ProjectSettings.globalize_path(dir_path)
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		var mk_err: int = DirAccess.make_dir_recursive_absolute(absolute)
		if mk_err != OK:
			push_error(
				"[AbilityDefCsvGenerator] Could not create directory: "
				+ absolute
				+ " error: "
				+ error_string(mk_err)
			)


func _join_path(a: String, b: String) -> String:
	var left: String = a
	var right: String = b
	if left.ends_with("/"):
		if right.begins_with("/"):
			return left + right.substr(1)
		return left + right
	else:
		if right.begins_with("/"):
			return left + right
		return left + "/" + right


func _ensure_trailing_slash(p: String) -> String:
	if p.ends_with("/"):
		return p
	return p + "/"
