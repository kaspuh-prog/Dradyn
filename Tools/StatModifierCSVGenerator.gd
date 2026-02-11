@tool
extends EditorScript
class_name StatModifierCsvGenerator

## Godot 4.5
##
## Reads a CSV at CSV_PATH and generates StatModifier .tres resources in OUTPUT_DIR.
## Usage:
## 1) Open this script in the Godot editor.
## 2) Make sure CSV_PATH points at your StatModifiers.csv.
## 3) Press the "Run" button in the script editor to regenerate all resources.

const CSV_PATH: String = "res://Data/StatModifiers/StatModifiers.csv"
const OUTPUT_DIR: String = "res://Data/StatModifiers/"

func _run() -> void:
	if not Engine.is_editor_hint():
		return

	print("[StatModifierCsvGenerator] Starting generation from CSV: ", CSV_PATH)

	var file: FileAccess = FileAccess.open(CSV_PATH, FileAccess.READ)
	if file == null:
		push_error("[StatModifierCsvGenerator] Could not open CSV file: " + CSV_PATH)
		return

	var header_map: Dictionary = {}
	var line_index: int = 0

	while file.get_position() < file.get_length():
		var raw_line: String = file.get_line()
		line_index += 1

		var line: String = raw_line.strip_edges()
		if line == "":
			continue
		if line.begins_with("#"):
			continue

		var cells: PackedStringArray = line.split(",", false)

		# First non-empty, non-comment line is the header.
		if header_map.is_empty():
			_build_header_map(cells, header_map)
			continue

		_process_data_row(cells, header_map, line_index)

	file.close()
	print("[StatModifierCsvGenerator] Done.")

func _build_header_map(cells: PackedStringArray, header_map: Dictionary) -> void:
	header_map.clear()
	for i in range(cells.size()):
		var key: String = cells[i].strip_edges().to_lower()
		if key != "":
			header_map[key] = i
	print("[StatModifierCsvGenerator] Header columns: ", header_map.keys())

func _process_data_row(
	cells: PackedStringArray,
	header_map: Dictionary,
	line_index: int
) -> void:
	var resource_id: String = _get_cell(cells, header_map, "resource_id", "").strip_edges()

	if resource_id == "":
		print("[StatModifierCsvGenerator] Skipping line ", line_index, ": empty resource_id.")
		return

	var resource_path: String = OUTPUT_DIR + resource_id + ".tres"

	var stat_name_str: String = _get_cell(cells, header_map, "stat_name", "").strip_edges()
	if stat_name_str == "":
		push_error("[StatModifierCsvGenerator] Line " + str(line_index) + ": stat_name is required.")
		return

	var modifier: StatModifier = StatModifier.new()
	modifier.stat_name = StringName(stat_name_str)

	# Numeric fields.
	modifier.add_value = _parse_float(_get_cell(cells, header_map, "add_value", ""), 0.0)
	modifier.mul_value = _parse_float(_get_cell(cells, header_map, "mul_value", ""), 1.0)
	modifier.duration_sec = _parse_float(_get_cell(cells, header_map, "duration_sec", ""), 0.0)
	modifier.override_value = _parse_float(_get_cell(cells, header_map, "override_value", ""), 0.0)

	# Strings / IDs.
	modifier.source_id = _get_cell(cells, header_map, "source_id", "").strip_edges()
	modifier.stacking_key = StringName(_get_cell(cells, header_map, "stacking_key", "").strip_edges())

	# Stacking fields.
	var max_stacks_text: String = _get_cell(cells, header_map, "max_stacks", "").strip_edges()
	if max_stacks_text == "":
		modifier.max_stacks = 1
	else:
		modifier.max_stacks = int(max_stacks_text)

	# Booleans.
	modifier.apply_override = _parse_bool(_get_cell(cells, header_map, "apply_override", ""), false)
	modifier.refresh_duration_on_stack = _parse_bool(
		_get_cell(cells, header_map, "refresh_duration_on_stack", ""),
		true
	)

	# Source type enum.
	var source_type_text: String = _get_cell(cells, header_map, "source_type", "")
	var source_type_value: int = _parse_source_type(source_type_text)
	modifier.source_type = source_type_value

	# Ensure output directory exists.
	_ensure_directory_for_path(resource_path)

	# Save resource.
	var err: int = ResourceSaver.save(modifier, resource_path)
	if err != OK:
		push_error(
			"[StatModifierCsvGenerator] Failed to save " + resource_path + ": " + error_string(err)
		)
	else:
		print("[StatModifierCsvGenerator] Wrote StatModifier: ", resource_path)

func _get_cell(
	cells: PackedStringArray,
	header_map: Dictionary,
	key: String,
	default_value: String
) -> String:
	var lower: String = key.to_lower()
	if not header_map.has(lower):
		return default_value

	var index: int = int(header_map[lower])
	if index < 0 or index >= cells.size():
		return default_value

	return cells[index]

func _parse_float(text: String, default_value: float) -> float:
	var trimmed: String = text.strip_edges()
	if trimmed == "":
		return default_value
	return trimmed.to_float()

func _parse_bool(text: String, default_value: bool) -> bool:
	var trimmed: String = text.strip_edges().to_lower()
	if trimmed == "":
		return default_value

	if trimmed == "1" or trimmed == "true" or trimmed == "yes" or trimmed == "y":
		return true
	if trimmed == "0" or trimmed == "false" or trimmed == "no" or trimmed == "n":
		return false

	return default_value

func _parse_source_type(text: String) -> int:
	var trimmed: String = text.strip_edges()
	if trimmed == "":
		return int(StatModifier.ModifierSourceType.OTHER)

	# Numeric index path.
	var as_int: int = 0
	var is_numeric: bool = true
	for c in trimmed:
		if c < "0" or c > "9":
			is_numeric = false
			break
	if is_numeric:
		as_int = int(trimmed)
		if as_int < int(StatModifier.ModifierSourceType.OTHER):
			return int(StatModifier.ModifierSourceType.OTHER)
		if as_int > int(StatModifier.ModifierSourceType.AURA):
			return int(StatModifier.ModifierSourceType.OTHER)
		return as_int

	# Name path (OTHER, EQUIPMENT, CONSUMABLE, SPELL, AURA).
	var upper: String = trimmed.to_upper()
	match upper:
		"OTHER":
			return int(StatModifier.ModifierSourceType.OTHER)
		"EQUIPMENT":
			return int(StatModifier.ModifierSourceType.EQUIPMENT)
		"CONSUMABLE":
			return int(StatModifier.ModifierSourceType.CONSUMABLE)
		"SPELL":
			return int(StatModifier.ModifierSourceType.SPELL)
		"AURA":
			return int(StatModifier.ModifierSourceType.AURA)
		_:
			return int(StatModifier.ModifierSourceType.OTHER)

func _ensure_directory_for_path(resource_path: String) -> void:
	var dir_path: String = resource_path

	var last_slash: int = dir_path.rfind("/")
	if last_slash >= 0:
		dir_path = dir_path.substr(0, last_slash)
	else:
		return

	var absolute: String = ProjectSettings.globalize_path(dir_path)
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		var mk_err: int = DirAccess.make_dir_recursive_absolute(absolute)
		if mk_err != OK:
			push_error(
				"[StatModifierCsvGenerator] Could not create directory: "
				+ absolute
				+ " error: "
				+ error_string(mk_err)
			)
