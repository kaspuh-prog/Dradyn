@tool
extends EditorScript
class_name LootTableCsvImporter

const LOOT_TABLES_CSV_PATH: String = "res://Data/loot/LootTables.csv"
const LOOT_ENTRIES_CSV_PATH: String = "res://Data/loot/LootEntries.csv"

# Where generated LootTable resources will be written.
const OUTPUT_TABLE_DIR: String = "res://world/loot/generated_tables"

# Optional: also generate a separate LootEntry.tres per CSV row.
const GENERATE_ENTRY_FILES: bool = true
const OUTPUT_ENTRY_DIR: String = "res://world/loot/generated_entries"

# Root folder where ItemDef resources live.
const ITEM_ROOT_DIR: String = "res://Data/items"


func _run() -> void:
	print("")
	print("=== LootTableCsvImporter: START ===")

	if not FileAccess.file_exists(LOOT_TABLES_CSV_PATH):
		push_error("LootTableCsvImporter: Missing LootTables CSV at: " + LOOT_TABLES_CSV_PATH)
		return

	if not FileAccess.file_exists(LOOT_ENTRIES_CSV_PATH):
		push_error("LootTableCsvImporter: Missing LootEntries CSV at: " + LOOT_ENTRIES_CSV_PATH)
		return

	var table_rows: Array[Dictionary] = _read_csv(LOOT_TABLES_CSV_PATH)
	var entry_rows: Array[Dictionary] = _read_csv(LOOT_ENTRIES_CSV_PATH)

	if table_rows.is_empty():
		push_error("LootTablesCsvImporter: LootTables CSV returned 0 data rows.")
		return

	var tables_by_id: Dictionary = _build_tables_by_id(table_rows)
	if tables_by_id.is_empty():
		push_error("LootTableCsvImporter: No valid table_id rows found in LootTables CSV.")
		return

	var entries_by_table_id: Dictionary = _group_entries_by_table_id(entry_rows)
	var item_def_map: Dictionary = _build_item_def_cache()

	var dir_error: int = DirAccess.make_dir_recursive_absolute(OUTPUT_TABLE_DIR)
	if dir_error != OK:
		push_error("LootTableCsvImporter: Failed to create output dir '" + OUTPUT_TABLE_DIR + "' error=" + str(dir_error))
		return

	if GENERATE_ENTRY_FILES:
		var entries_dir_error: int = DirAccess.make_dir_recursive_absolute(OUTPUT_ENTRY_DIR)
		if entries_dir_error != OK:
			push_error("LootTableCsvImporter: Failed to create entry output dir '" + OUTPUT_ENTRY_DIR + "' error=" + str(entries_dir_error))
			return

	var table_count: int = 0
	for table_id_any: Variant in tables_by_id.keys():
		var table_id: String = str(table_id_any)
		var table_row: Dictionary = tables_by_id[table_id]

		var loot_table: LootTable = _create_loot_table_from_row(table_row)

		# Grab raw array (untyped), then build a typed Array[Dictionary]
		var raw_entries: Array = entries_by_table_id.get(table_id, [])
		var entries_for_table: Array[Dictionary] = []
		for row_any: Variant in raw_entries:
			var row_dict: Dictionary = row_any as Dictionary
			entries_for_table.append(row_dict)

		var created_entries: Array[LootEntry] = _create_entries_for_table(table_id, entries_for_table, item_def_map)
		loot_table.entries = created_entries

		var resource_path: String = OUTPUT_TABLE_DIR + "/" + table_id + "LootTable.tres"
		var save_error: int = ResourceSaver.save(loot_table, resource_path)
		if save_error != OK:
			push_error("LootTableCsvImporter: Failed to save LootTable '" + table_id + "' at '" + resource_path + "': " + error_string(save_error))
		else:
			print("LootTableCsvImporter: Saved LootTable '" + table_id + "' with " + str(created_entries.size()) + " entries -> " + resource_path)
			table_count += 1

	print("=== LootTableCsvImporter: DONE. Generated " + str(table_count) + " tables. ===")
	print("")


# -------------------------------------------------------------------
# CSV READING
# -------------------------------------------------------------------

func _read_csv(path: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("LootTableCsvImporter: Failed to open CSV: " + path)
		return rows

	var header: PackedStringArray = PackedStringArray()
	var line_index: int = 0

	while file.get_position() < file.get_length():
		var raw_line: String = file.get_line()

		# Handle optional UTF-8 BOM on the first line.
		if line_index == 0 and raw_line.length() > 0 and raw_line.unicode_at(0) == 0xfeff:
			raw_line = raw_line.substr(1)

		var trimmed_line: String = raw_line.strip_edges()
		if trimmed_line == "":
			line_index += 1
			continue

		var cells: PackedStringArray = _split_csv_line(raw_line)
		var i: int = 0
		while i < cells.size():
			cells[i] = cells[i].strip_edges()
			if cells[i].begins_with("\"") and cells[i].ends_with("\"") and cells[i].length() >= 2:
				cells[i] = cells[i].substr(1, cells[i].length() - 2)
			i += 1

		if line_index == 0:
			header = cells.duplicate()
			i = 0
			while i < header.size():
				header[i] = header[i].strip_edges()
				i += 1
		else:
			var row: Dictionary = {}
			i = 0
			while i < header.size() and i < cells.size():
				row[header[i]] = cells[i]
				i += 1
			rows.append(row)

		line_index += 1

	file.close()
	return rows


func _split_csv_line(line: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	var current: String = ""
	var inside_quotes: bool = false
	var i: int = 0

	while i < line.length():
		var ch: String = line.substr(i, 1)
		if ch == "\"":
			inside_quotes = not inside_quotes
		elif ch == "," and not inside_quotes:
			result.append(current)
			current = ""
		else:
			current += ch
		i += 1

	result.append(current)
	return result


# -------------------------------------------------------------------
# TABLE ROW HANDLING
# -------------------------------------------------------------------

func _build_tables_by_id(rows: Array[Dictionary]) -> Dictionary:
	var out: Dictionary = {}
	for row_any: Variant in rows:
		var row: Dictionary = row_any as Dictionary
		var id_str: String = str(row.get("table_id", "")).strip_edges()
		if id_str == "":
			continue
		if out.has(id_str):
			push_warning("LootTableCsvImporter: Duplicate table_id '" + id_str + "' in LootTables CSV. Later row will override earlier row.")
		out[id_str] = row
	return out


func _group_entries_by_table_id(rows: Array[Dictionary]) -> Dictionary:
	var out: Dictionary = {}
	for row_any: Variant in rows:
		var row: Dictionary = row_any as Dictionary
		var id_str: String = str(row.get("table_id", "")).strip_edges()
		if id_str == "":
			continue

		var list_for_table: Array = []
		if out.has(id_str):
			list_for_table = out[id_str] as Array
		list_for_table.append(row)
		out[id_str] = list_for_table
	return out


func _create_loot_table_from_row(row: Dictionary) -> LootTable:
	var loot_table: LootTable = LootTable.new()

	var rolls_str: String = str(row.get("rolls", "1"))
	var allow_duplicates_str: String = str(row.get("allow_duplicates", "true"))
	var currency_percent_str: String = str(row.get("currency_percent_chance", "0"))
	var currency_min_str: String = str(row.get("currency_min", "0"))
	var currency_max_str: String = str(row.get("currency_max", "0"))

	loot_table.rolls = _to_int(rolls_str, 1)
	loot_table.allow_duplicates = _to_bool(allow_duplicates_str, true)
	loot_table.currency_percent_chance = _to_float(currency_percent_str, 0.0)
	loot_table.currency_min = _to_int(currency_min_str, 0)
	loot_table.currency_max = _to_int(currency_max_str, 0)

	if loot_table.currency_max < loot_table.currency_min:
		loot_table.currency_max = loot_table.currency_min

	return loot_table


# -------------------------------------------------------------------
# ENTRY ROW HANDLING
# -------------------------------------------------------------------

func _create_entries_for_table(table_id: String, rows: Array[Dictionary], item_def_map: Dictionary) -> Array[LootEntry]:
	var result: Array[LootEntry] = []

	for row_any: Variant in rows:
		var row: Dictionary = row_any as Dictionary

		var enabled_str: String = str(row.get("enabled", "true")).to_lower()
		var enabled: bool = _to_bool(enabled_str, true)
		if not enabled:
			continue

		var entry: LootEntry = _create_loot_entry_from_row(row, item_def_map, table_id)
		result.append(entry)

		if GENERATE_ENTRY_FILES:
			_save_loot_entry_resource(entry)

	return result


func _create_loot_entry_from_row(row: Dictionary, item_def_map: Dictionary, table_id: String) -> LootEntry:
	var entry: LootEntry = LootEntry.new()

	entry.id = str(row.get("entry_id", "")).strip_edges()
	entry.weight = _to_float(str(row.get("weight", "1.0")), 1.0)
	entry.percent_chance = _to_float(str(row.get("percent_chance", "100")), 100.0)
	entry.min_qty = _to_int(str(row.get("min_qty", "1")), 1)
	entry.max_qty = _to_int(str(row.get("max_qty", "1")), entry.min_qty)

	if entry.max_qty < entry.min_qty:
		entry.max_qty = entry.min_qty

	var item_id_str: String = str(row.get("item_id", "")).strip_edges()
	if item_id_str != "":
		if item_def_map.has(item_id_str):
			entry.item_def = item_def_map[item_id_str] as ItemDef
		else:
			push_warning("LootTableCsvImporter: For table_id='" + table_id + "', entry_id='" + entry.id + "' refers to unknown ItemDef id '" + item_id_str + "'.")

	return entry


func _save_loot_entry_resource(entry: LootEntry) -> void:
	# Name each file exactly entry_id.tres (sanitized for filesystem safety).
	var safe_entry: String = _sanitize_for_filename(entry.id)
	if safe_entry == "":
		safe_entry = "Entry"

	var file_name: String = safe_entry + ".tres"
	var resource_path: String = OUTPUT_ENTRY_DIR + "/" + file_name

	var save_error: int = ResourceSaver.save(entry, resource_path)
	if save_error != OK:
		push_warning(
			"LootTableCsvImporter: Failed to save LootEntry '" +
			entry.id +
			"' at '" + resource_path + "': " + error_string(save_error)
		)


# -------------------------------------------------------------------
# ITEM DEF CACHE
# -------------------------------------------------------------------

func _build_item_def_cache() -> Dictionary:
	var out: Dictionary = {}
	_scan_item_dir(ITEM_ROOT_DIR, out)
	print("LootTableCsvImporter: ItemDef cache built with " + str(out.size()) + " entries.")
	return out


func _scan_item_dir(dir_path: String, out: Dictionary) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		push_warning("LootTableCsvImporter: Cannot open item dir: " + dir_path)
		return

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break

		if dir.current_is_dir():
			if name == "." or name == "..":
				continue
			var child_dir_path: String = dir_path + "/" + name
			_scan_item_dir(child_dir_path, out)
		else:
			if name.ends_with(".tres") or name.ends_with(".res"):
				var res_path: String = dir_path + "/" + name
				var res: Resource = ResourceLoader.load(res_path)
				if res is ItemDef:
					var item_def: ItemDef = res as ItemDef
					var id_str: String = str(item_def.id)
					if id_str == "":
						id_str = name.get_basename()
						item_def.id = StringName(id_str)
						var save_error: int = ResourceSaver.save(item_def, res_path)
						if save_error != OK:
							push_warning("LootTableCsvImporter: Failed to backfill id for ItemDef at '" + res_path + "': " + error_string(save_error))
					if not out.has(id_str):
						out[id_str] = item_def
					else:
						push_warning("LootTableCsvImporter: Duplicate ItemDef id '" + id_str + "' at path '" + res_path + "'.")
	dir.list_dir_end()


# -------------------------------------------------------------------
# HELPERS
# -------------------------------------------------------------------

func _sanitize_for_filename(value: String) -> String:
	var trimmed: String = value.strip_edges()
	if trimmed == "":
		return ""

	var result: String = ""
	var i: int = 0
	while i < trimmed.length():
		var ch: String = trimmed.substr(i, 1)
		var code: int = ch.unicode_at(0)

		var is_digit: bool = code >= 48 and code <= 57
		var is_upper: bool = code >= 65 and code <= 90
		var is_lower: bool = code >= 97 and code <= 122

		if is_digit or is_upper or is_lower:
			result += ch
		else:
			result += "_"

		i += 1

	return result


func _to_int(value: String, default_value: int) -> int:
	var trimmed: String = value.strip_edges()
	if trimmed == "":
		return default_value
	var parsed: int = default_value
	parsed = int(trimmed.to_int())
	return parsed


func _to_float(value: String, default_value: float) -> float:
	var trimmed: String = value.strip_edges()
	if trimmed == "":
		return default_value
	var parsed: float = default_value
	parsed = float(trimmed.to_float())
	return parsed


func _to_bool(value: String, default_value: bool) -> bool:
	var trimmed: String = value.strip_edges().to_lower()
	if trimmed == "true" or trimmed == "1" or trimmed == "yes" or trimmed == "y":
		return true
	if trimmed == "false" or trimmed == "0" or trimmed == "no" or trimmed == "n":
		return false
	return default_value
