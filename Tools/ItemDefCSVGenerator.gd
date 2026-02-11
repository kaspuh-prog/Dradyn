@tool
extends EditorScript
class_name ItemDefCsvGenerator

## Godot 4.5
##
## Reads a CSV at CSV_PATH and generates/updates ItemDef .tres resources.
## Output path:
##   res://Data/items/<item_type>/<id>.tres
##
## CSV header:
## id,display_name,description,item_type,equipment_class,base_gold_value,stack_max,equip_slot,restore_hp,restore_mp,restore_end,use_ability_id,weapon_weight,icon_id,stat_modifier_ids

const CSV_PATH: String = "res://Data/items/ItemDefs.csv"
const ITEMS_BASE_DIR: String = "res://Data/items/"
const STAT_MOD_DIR: String = "res://Data/StatModifiers/"
const ICONS_BASE_DIR: String = "res://assets/sprites/items"

func _run() -> void:
	if not Engine.is_editor_hint():
		return

	print("[ItemDefCsvGenerator] Building icon lookup from: ", ICONS_BASE_DIR)
	var icon_lookup: Dictionary = _build_icon_lookup()
	print("[ItemDefCsvGenerator] Icon ids available: ", icon_lookup.keys())

	print("[ItemDefCsvGenerator] Starting generation from CSV: ", CSV_PATH)

	var file: FileAccess = FileAccess.open(CSV_PATH, FileAccess.READ)
	if file == null:
		push_error("[ItemDefCsvGenerator] Could not open CSV file: " + CSV_PATH)
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

		# IMPORTANT: allow_empty = true so empty cells are preserved
		var cells: PackedStringArray = line.split(",", true)

		# First non-empty, non-comment line is the header.
		if header_map.is_empty():
			_build_header_map(cells, header_map)
			continue

		_process_data_row(cells, header_map, icon_lookup, line_index)

	file.close()
	print("[ItemDefCsvGenerator] Done.")

func _build_header_map(cells: PackedStringArray, header_map: Dictionary) -> void:
	header_map.clear()
	for i in range(cells.size()):
		var key: String = cells[i].strip_edges().to_lower()
		if key != "":
			header_map[key] = i
	print("[ItemDefCsvGenerator] Header columns: ", header_map.keys())

func _process_data_row(
	cells: PackedStringArray,
	header_map: Dictionary,
	icon_lookup: Dictionary,
	line_index: int
) -> void:
	var id_text: String = _get_cell(cells, header_map, "id", "").strip_edges()
	if id_text == "":
		push_error("[ItemDefCsvGenerator] Line " + str(line_index) + ": id is required.")
		return

	var item_type_text: String = _get_cell(
		cells,
		header_map,
		"item_type",
		""
	).strip_edges()
	if item_type_text == "":
		push_error("[ItemDefCsvGenerator] Line " + str(line_index) + ": item_type is required.")
		return

	# Compute resource path based on item_type + id.
	var subfolder: String = item_type_text
	var resource_path: String = ITEMS_BASE_DIR + subfolder + "/" + id_text + ".tres"

	# Create ItemDef resource.
	var item_def: ItemDef = ItemDef.new()
	item_def.id = StringName(id_text)
	item_def.item_type = item_type_text

	item_def.display_name = _get_cell(
		cells,
		header_map,
		"display_name",
		""
	).strip_edges()
	item_def.description = _get_cell(cells, header_map, "description", "")

	# equipment_class (optional).
	var equipment_class_text: String = _get_cell(
		cells,
		header_map,
		"equipment_class",
		""
	).strip_edges()
	if equipment_class_text != "":
		item_def.equipment_class = StringName(equipment_class_text)

	# base_gold_value.
	var base_gold_text: String = _get_cell(
		cells,
		header_map,
		"base_gold_value",
		""
	).strip_edges()
	if base_gold_text != "":
		item_def.base_gold_value = int(base_gold_text)

	# stack_max.
	var stack_max_text: String = _get_cell(
		cells,
		header_map,
		"stack_max",
		""
	).strip_edges()
	if stack_max_text != "":
		item_def.stack_max = int(stack_max_text)

	# equip_slot (optional).
	var equip_slot_text: String = _get_cell(
		cells,
		header_map,
		"equip_slot",
		""
	).strip_edges()
	if equip_slot_text != "":
		item_def.equip_slot = equip_slot_text

	# restore_hp/mp/end (optional).
	var restore_hp_text: String = _get_cell(
		cells,
		header_map,
		"restore_hp",
		""
	).strip_edges()
	if restore_hp_text != "":
		item_def.restore_hp = int(restore_hp_text)

	var restore_mp_text: String = _get_cell(
		cells,
		header_map,
		"restore_mp",
		""
	).strip_edges()
	if restore_mp_text != "":
		item_def.restore_mp = int(restore_mp_text)

	var restore_end_text: String = _get_cell(
		cells,
		header_map,
		"restore_end",
		""
	).strip_edges()
	if restore_end_text != "":
		item_def.restore_end = int(restore_end_text)

	# use_ability_id (optional).
	var use_ability_text: String = _get_cell(
		cells,
		header_map,
		"use_ability_id",
		""
	).strip_edges()
	if use_ability_text != "":
		item_def.use_ability_id = use_ability_text

	# weapon_weight (optional).
	var weapon_weight_text: String = _get_cell(
		cells,
		header_map,
		"weapon_weight",
		""
	).strip_edges()
	if weapon_weight_text != "":
		item_def.weapon_weight = weapon_weight_text.to_float()

	# Icon via icon_id -> lookup (optional but validated if present).
	var icon_id: String = _get_cell(
		cells,
		header_map,
		"icon_id",
		""
	).strip_edges()
	if icon_id != "":
		if icon_lookup.has(icon_id):
			var icon_path: String = icon_lookup[icon_id]
			var icon_res: Texture2D = load(icon_path) as Texture2D
			if icon_res == null:
				push_error(
					"[ItemDefCsvGenerator] Line "
					+ str(line_index)
					+ ": could not load icon at "
					+ icon_path
				)
			else:
				item_def.icon = icon_res
		else:
			push_error(
				"[ItemDefCsvGenerator] Line "
				+ str(line_index)
				+ ": icon_id '"
				+ icon_id
				+ "' not found under "
				+ ICONS_BASE_DIR
			)

	# Stat modifiers via StatModifier ids (semi-colon separated).
	var stat_ids_text: String = _get_cell(
		cells,
		header_map,
		"stat_modifier_ids",
		""
	).strip_edges()
	var stat_mods: Array[Resource] = []
	if stat_ids_text != "":
		var parts: PackedStringArray = stat_ids_text.split(";", false)
		for part in parts:
			var stat_id: String = part.strip_edges()
			if stat_id == "":
				continue

			var mod_path: String = STAT_MOD_DIR + stat_id + ".tres"
			if ResourceLoader.exists(mod_path):
				var mod_res: Resource = load(mod_path)
				if mod_res != null:
					stat_mods.append(mod_res)
				else:
					push_error(
						"[ItemDefCsvGenerator] Line "
						+ str(line_index)
						+ ": failed to load StatModifier at "
						+ mod_path
					)
			else:
				push_error(
					"[ItemDefCsvGenerator] Line "
					+ str(line_index)
					+ ": StatModifier not found at "
					+ mod_path
				)
	item_def.stat_modifiers = stat_mods

	# Ensure directory and save resource.
	_ensure_directory_for_path(resource_path)

	var err: int = ResourceSaver.save(item_def, resource_path)
	if err != OK:
		push_error(
			"[ItemDefCsvGenerator] Failed to save "
			+ resource_path
			+ ": "
			+ error_string(err)
		)
	else:
		print("[ItemDefCsvGenerator] Wrote ItemDef: ", resource_path)

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

func _build_icon_lookup() -> Dictionary:
	var result: Dictionary = {}
	var stack: Array[String] = []
	stack.append(ICONS_BASE_DIR)

	while stack.size() > 0:
		var dir_path: String = stack.pop_back()
		var dir: DirAccess = DirAccess.open(dir_path)
		if dir == null:
			continue

		dir.list_dir_begin()
		while true:
			var name: String = dir.get_next()
			if name == "":
				break

			if name.begins_with("."):
				continue

			if dir.current_is_dir():
				var subdir_path: String = dir_path + "/" + name
				stack.append(subdir_path)
			else:
				if name.ends_with(".png"):
					var stem: String = name.substr(0, name.length() - 4)
					var full_path: String = dir_path + "/" + name
					if not result.has(stem):
						result[stem] = full_path
					else:
						# Duplicate stems would be ambiguous, so just log them.
						print(
							"[ItemDefCsvGenerator] Duplicate icon stem '",
							stem,
							"' at ",
							full_path,
							" (already have ",
							result[stem],
							")"
						)

		dir.list_dir_end()

	return result

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
				"[ItemDefCsvGenerator] Could not create directory: "
				+ absolute
				+ " error: "
				+ error_string(mk_err)
			)
