extends Node
class_name StoryStateSystem

signal story_step_changed(act_id: int, step_id: int)
signal flags_changed()

@export var default_act_id: int = 1
@export var default_step_id: int = 1
@export var default_part_id: int = 1
@export_file("*.csv") var story_csv_path: String = "res://Data/Story/StoryState.csv"

# Internal state
var _current_act_id: int = 1
var _current_step_id: int = 1
var _current_part_id: int = 1

# Story flags (e.g. "met_rosali", "orphanage_intro_complete")
# Stored as: flag_name -> bool
var _flags: Dictionary = {}

# Story table:
# {
#     act_id: {
#         step_id: { "key": String, "label": String }
#     }
# }
# You can either fill this directly, or call set_story_table() from another script.
var _story_table: Dictionary = {}

# Part table:
# {
#     act_id: {
#         step_id: {
#             part_id: {
#                 "key": String,
#                 "label": String,
#                 "next_act_id": int,
#                 "next_step_id": int,
#                 "next_part_id": int,
#                 "flags_set_on_enter": PackedStringArray,
#                 "flags_clear_on_enter": PackedStringArray,
#                 "flags_set_on_complete": PackedStringArray,
#                 "flags_clear_on_complete": PackedStringArray,
#             }
#         }
#     }
# }
var _part_table: Dictionary = {}


func _ready() -> void:
	_current_act_id = default_act_id
	_current_step_id = default_step_id
	_current_part_id = default_part_id
	
	_load_story_from_csv_if_available()


# -------------------------------------------------------------------
# Story table registration / access
# -------------------------------------------------------------------

func set_story_table(table: Dictionary) -> void:
	_story_table = table.duplicate(true)

func get_story_table() -> Dictionary:
	return _story_table

func get_part_table() -> Dictionary:
	return _part_table

func get_part_def(act_id: int, step_id: int, part_id: int) -> Dictionary:
	if not _part_table.has(act_id):
		return {}
	
	var step_map_any: Variant = _part_table[act_id]
	if typeof(step_map_any) != TYPE_DICTIONARY:
		return {}
	
	var step_map: Dictionary = step_map_any
	if not step_map.has(step_id):
		return {}
	
	var part_map_any: Variant = step_map[step_id]
	if typeof(part_map_any) != TYPE_DICTIONARY:
		return {}
	
	var part_map: Dictionary = part_map_any
	if not part_map.has(part_id):
		return {}
	
	var part_def_any: Variant = part_map[part_id]
	if typeof(part_def_any) != TYPE_DICTIONARY:
		return {}
	
	return part_def_any


# -------------------------------------------------------------------
# Current act / step / part
# -------------------------------------------------------------------

func get_current_act_id() -> int:
	return _current_act_id

func get_current_step_id() -> int:
	return _current_step_id

func get_current_part_id() -> int:
	return _current_part_id

func set_current_act(act_id: int) -> void:
	if act_id == _current_act_id:
		return
	
	_current_act_id = act_id
	# When act changes, we currently leave step/part as-is.
	_emit_story_step_changed()

func set_current_step(step_id: int) -> void:
	if step_id == _current_step_id:
		return
	
	_current_step_id = step_id
	# We intentionally leave part as-is for now.
	_emit_story_step_changed()

func set_current_part(part_id: int) -> void:
	if part_id == _current_part_id:
		return
	
	_current_part_id = part_id
	_emit_story_step_changed()

func set_current_step_full(act_id: int, step_id: int) -> void:
	# Backward-compatible helper that ignores part.
	_set_current_story_position_internal(act_id, step_id, _current_part_id)

func set_current_story_position(act_id: int, step_id: int, part_id: int) -> void:
	# New helper that updates act, step, and part together.
	_set_current_story_position_internal(act_id, step_id, part_id)

func _set_current_story_position_internal(act_id: int, step_id: int, part_id: int) -> void:
	var changed: bool = false
	
	if act_id != _current_act_id:
		_current_act_id = act_id
		changed = true
	
	if step_id != _current_step_id:
		_current_step_id = step_id
		changed = true
	
	if part_id != _current_part_id:
		_current_part_id = part_id
		changed = true
	
	if changed:
		_emit_story_step_changed()

func _emit_story_step_changed() -> void:
	story_step_changed.emit(_current_act_id, _current_step_id)


# -------------------------------------------------------------------
# Part enter / complete helpers
# -------------------------------------------------------------------

func enter_story_position(act_id: int, step_id: int, part_id: int) -> void:
	# Move story cursor first, then apply "enter" flags for the target part.
	set_current_story_position(act_id, step_id, part_id)
	
	var part_def: Dictionary = get_part_def(act_id, step_id, part_id)
	if part_def.is_empty():
		return
	
	_apply_enter_flags_from_def(part_def)

func complete_current_part() -> void:
	var act_id: int = _current_act_id
	var step_id: int = _current_step_id
	var part_id: int = _current_part_id
	
	var part_def: Dictionary = get_part_def(act_id, step_id, part_id)
	if part_def.is_empty():
		return
	
	# Apply completion flags for the current part.
	_apply_complete_flags_from_def(part_def)
	
	# Determine next act / step / part, with 0 or missing meaning "no change".
	var next_act_id: int = act_id
	if part_def.has("next_act_id"):
		var next_act_any: Variant = part_def["next_act_id"]
		if typeof(next_act_any) == TYPE_INT:
			var candidate_act: int = int(next_act_any)
			if candidate_act > 0:
				next_act_id = candidate_act
	
	var next_step_id: int = step_id
	if part_def.has("next_step_id"):
		var next_step_any: Variant = part_def["next_step_id"]
		if typeof(next_step_any) == TYPE_INT:
			var candidate_step: int = int(next_step_any)
			if candidate_step > 0:
				next_step_id = candidate_step
	
	var next_part_id: int = part_id
	if part_def.has("next_part_id"):
		var next_part_any: Variant = part_def["next_part_id"]
		if typeof(next_part_any) == TYPE_INT:
			var candidate_part: int = int(next_part_any)
			if candidate_part > 0:
				next_part_id = candidate_part
	
	# Enter the next position, which will apply its "enter" flags.
	enter_story_position(next_act_id, next_step_id, next_part_id)

func _apply_enter_flags_from_def(part_def: Dictionary) -> void:
	if part_def.has("flags_clear_on_enter"):
		var clear_any: Variant = part_def["flags_clear_on_enter"]
		if typeof(clear_any) == TYPE_PACKED_STRING_ARRAY:
			var clear_list: PackedStringArray = clear_any
			_apply_flag_clear_list(clear_list)
	
	if part_def.has("flags_set_on_enter"):
		var set_any: Variant = part_def["flags_set_on_enter"]
		if typeof(set_any) == TYPE_PACKED_STRING_ARRAY:
			var set_list: PackedStringArray = set_any
			_apply_flag_set_list(set_list)

func _apply_complete_flags_from_def(part_def: Dictionary) -> void:
	if part_def.has("flags_clear_on_complete"):
		var clear_any: Variant = part_def["flags_clear_on_complete"]
		if typeof(clear_any) == TYPE_PACKED_STRING_ARRAY:
			var clear_list: PackedStringArray = clear_any
			_apply_flag_clear_list(clear_list)
	
	if part_def.has("flags_set_on_complete"):
		var set_any: Variant = part_def["flags_set_on_complete"]
		if typeof(set_any) == TYPE_PACKED_STRING_ARRAY:
			var set_list: PackedStringArray = set_any
			_apply_flag_set_list(set_list)

func _apply_flag_set_list(flag_names: PackedStringArray) -> void:
	for name_str in flag_names:
		var trimmed: String = String(name_str).strip_edges()
		if trimmed == "":
			continue
		
		var flag_name: StringName = StringName(trimmed)
		set_flag(flag_name, true)

func _apply_flag_clear_list(flag_names: PackedStringArray) -> void:
	for name_str in flag_names:
		var trimmed: String = String(name_str).strip_edges()
		if trimmed == "":
			continue
		
		var flag_name: StringName = StringName(trimmed)
		clear_flag(flag_name)


# -------------------------------------------------------------------
# Story flags (set/clear/check)
# -------------------------------------------------------------------

func set_flag(flag_name: StringName, value: bool = true) -> void:
	var key: StringName = flag_name
	
	var prev: bool = false
	if _flags.has(key):
		var prev_any: Variant = _flags[key]
		if typeof(prev_any) == TYPE_BOOL:
			prev = bool(prev_any)
	
	if prev == value:
		return
	
	_flags[key] = value
	flags_changed.emit()

func clear_flag(flag_name: StringName) -> void:
	var key: StringName = flag_name
	if not _flags.has(key):
		return
	
	_flags.erase(key)
	flags_changed.emit()

func has_flag(flag_name: StringName) -> bool:
	var key: StringName = flag_name
	if not _flags.has(key):
		return false
	
	var value_any: Variant = _flags[key]
	if typeof(value_any) != TYPE_BOOL:
		return false
	
	return bool(value_any)

func get_all_flags() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for key_any in _flags.keys():
		var key: StringName = key_any as StringName
		if key == StringName():
			continue
		
		var value_any: Variant = _flags[key]
		if typeof(value_any) == TYPE_BOOL and bool(value_any):
			result.append(String(key))
	result.sort()
	return result

const STORY_TABLE: Dictionary = {
	1: {
		1: { "key": "WAKE_UP_TO_RATS", "label": "Rats in the Cellar" },
		2: { "key": "VISIT_ROSALI", "label": "A Dinner for Friends" },
		3: { "key": "SHUS_TEST", "label": "Shishuku's Affinity Test" },
		4: { "key": "GOLDEN_HEN_INN", "label": "We've All Got Problems" },
		5: { "key": "SECRET_MEETING", "label": "Meetup on the Rooftops" },
		6: { "key": "SLUMS_AMBUSH", "label": "We the Hunted" },
		7: { "key": "SNEAKING_ENTERTAINMENT", "label": "Creeping through the Entertainment District" },
		8: { "key": "SNEAKING_MARKET", "label": "Ducking through Merchant's Row" },
		9: { "key": "AIRSHIP_DOCKS", "label": "Flight through the Docks" },
		10: { "key": "LEAVING_HOME", "label": "Say Goodbye to Langtree" },
	},
	2: {
		1: { "key": "ACT2_INTRO", "label": "Shadows Over Telmbrook" },
	}
}


# -------------------------------------------------------------------
# Labels and display strings for UI (Act I - The Corrupt & Incorruptable)
# -------------------------------------------------------------------

func get_act_label(act_id: int = -1) -> String:
	var id: int = act_id
	if id <= 0:
		id = _current_act_id
	return "Act " + _to_roman(id)

func get_step_label(act_id: int = -1, step_id: int = -1) -> String:
	var act: int = act_id
	var step: int = step_id
	
	if act <= 0:
		act = _current_act_id
	if step <= 0:
		step = _current_step_id
	
	if not _story_table.has(act):
		return ""
	
	var step_map_any: Variant = _story_table[act]
	if typeof(step_map_any) != TYPE_DICTIONARY:
		return ""
	
	var step_map: Dictionary = step_map_any
	if not step_map.has(step):
		return ""
	
	var def_any: Variant = step_map[step]
	if typeof(def_any) != TYPE_DICTIONARY:
		return ""
	
	var def_dict: Dictionary = def_any
	if def_dict.has("label"):
		return String(def_dict["label"])
	
	return ""

func get_step_key(act_id: int = -1, step_id: int = -1) -> String:
	var act: int = act_id
	var step: int = step_id
	
	if act <= 0:
		act = _current_act_id
	if step <= 0:
		step = _current_step_id
	
	if not _story_table.has(act):
		return ""
	
	var step_map_any: Variant = _story_table[act]
	if typeof(step_map_any) != TYPE_DICTIONARY:
		return ""
	
	var step_map: Dictionary = step_map_any
	if not step_map.has(step):
		return ""
	
	var def_any: Variant = step_map[step]
	if typeof(def_any) != TYPE_DICTIONARY:
		return ""
	
	var def_dict: Dictionary = def_any
	if def_dict.has("key"):
		return String(def_dict["key"])
	
	return ""

func get_act_step_display_string() -> String:
	var label: String = get_step_label()
	if label == "":
		return get_act_label()
	return get_act_label() + " - " + label


# -------------------------------------------------------------------
# Save / load support (for SaveSystem payload)
# -------------------------------------------------------------------

func get_save_state() -> Dictionary:
	var state: Dictionary = {}
	state["act_id"] = _current_act_id
	state["step_id"] = _current_step_id
	state["part_id"] = _current_part_id
	state["flags"] = get_all_flags()
	return state

func apply_save_state(state: Dictionary) -> void:
	if state.has("act_id") and state.has("step_id"):
		var act_any: Variant = state["act_id"]
		var step_any: Variant = state["step_id"]
		
		if typeof(act_any) == TYPE_INT and typeof(step_any) == TYPE_INT:
			var act: int = int(act_any)
			var step: int = int(step_any)
			
			var part: int = 1
			if state.has("part_id"):
				var part_any: Variant = state["part_id"]
				if typeof(part_any) == TYPE_INT:
					part = int(part_any)
			
			set_current_story_position(act, step, part)
	
	_flags.clear()
	
	if state.has("flags"):
		var flags_any: Variant = state["flags"]
		if typeof(flags_any) == TYPE_ARRAY:
			var flags_arr: Array = flags_any
			for f in flags_arr:
				var name: StringName = StringName(String(f))
				_flags[name] = true
	
	flags_changed.emit()


# -------------------------------------------------------------------
# CSV loading
# -------------------------------------------------------------------

func _load_story_from_csv_if_available() -> void:
	if story_csv_path == "":
		return
	
	var file := FileAccess.open(story_csv_path, FileAccess.READ)
	if file == null:
		var err: int = FileAccess.get_open_error()
		push_warning("StoryStateSystem: Could not open story CSV at '%s': %s" % [story_csv_path, error_string(err)])
		return
	
	if file.eof_reached():
		return
	
	var header: PackedStringArray = file.get_csv_line(",")
	if header.size() == 0:
		push_warning("StoryStateSystem: Story CSV '%s' has an empty header row." % [story_csv_path])
		return
	
	var col_indexes: Dictionary = _build_story_csv_column_index_map(header)
	if col_indexes.is_empty():
		push_warning("StoryStateSystem: Story CSV '%s' is missing required columns." % [story_csv_path])
		return
	
	var new_story_table: Dictionary = {}
	var new_part_table: Dictionary = {}
	
	while not file.eof_reached():
		var row: PackedStringArray = file.get_csv_line(",")
		if row.size() == 0:
			continue
		
		var non_empty_found: bool = false
		for cell in row:
			if String(cell).strip_edges() != "":
				non_empty_found = true
				break
		if not non_empty_found:
			continue
		
		_process_story_csv_row(row, col_indexes, new_story_table, new_part_table)
	
	if not new_story_table.is_empty():
		_story_table = new_story_table
		_part_table = new_part_table
	else:
		_story_table = STORY_TABLE.duplicate(true)

func _build_story_csv_column_index_map(header: PackedStringArray) -> Dictionary:
	var result: Dictionary = {}
	
	for i in range(header.size()):
		var name_raw: String = String(header[i])
		var name: String = name_raw.strip_edges().to_lower()
		if name == "act_id":
			result["act_id"] = i
		elif name == "step_id":
			result["step_id"] = i
		elif name == "part_id":
			result["part_id"] = i
		elif name == "story_key":
			result["story_key"] = i
		elif name == "story_label":
			result["story_label"] = i
		elif name == "next_act_id":
			result["next_act_id"] = i
		elif name == "next_step_id":
			result["next_step_id"] = i
		elif name == "next_part_id":
			result["next_part_id"] = i
		elif name == "flags_set_on_enter":
			result["flags_set_on_enter"] = i
		elif name == "flags_clear_on_enter":
			result["flags_clear_on_enter"] = i
		elif name == "flags_set_on_complete":
			result["flags_set_on_complete"] = i
		elif name == "flags_clear_on_complete":
			result["flags_clear_on_complete"] = i
	
	var has_required: bool = true
	if not result.has("act_id"):
		has_required = false
	if not result.has("step_id"):
		has_required = false
	if not result.has("part_id"):
		has_required = false
	if not result.has("story_key"):
		has_required = false
	if not result.has("story_label"):
		has_required = false
	
	if not has_required:
		return {}
	
	return result

func _process_story_csv_row(row: PackedStringArray, col_indexes: Dictionary, story_table: Dictionary, part_table: Dictionary) -> void:
	var act_id: int = _csv_get_int(row, col_indexes, "act_id")
	var step_id: int = _csv_get_int(row, col_indexes, "step_id")
	var part_id: int = _csv_get_int(row, col_indexes, "part_id")
	
	if act_id <= 0 or step_id <= 0 or part_id <= 0:
		return
	
	var story_key: String = _csv_get_string(row, col_indexes, "story_key")
	var story_label: String = _csv_get_string(row, col_indexes, "story_label")
	
	var next_act_id: int = _csv_get_int(row, col_indexes, "next_act_id")
	var next_step_id: int = _csv_get_int(row, col_indexes, "next_step_id")
	var next_part_id: int = _csv_get_int(row, col_indexes, "next_part_id")
	
	var flags_set_on_enter: PackedStringArray = _csv_get_flag_list(row, col_indexes, "flags_set_on_enter")
	var flags_clear_on_enter: PackedStringArray = _csv_get_flag_list(row, col_indexes, "flags_clear_on_enter")
	var flags_set_on_complete: PackedStringArray = _csv_get_flag_list(row, col_indexes, "flags_set_on_complete")
	var flags_clear_on_complete: PackedStringArray = _csv_get_flag_list(row, col_indexes, "flags_clear_on_complete")
	
	if not story_table.has(act_id):
		story_table[act_id] = {}
	
	var step_map_any: Variant = story_table[act_id]
	var step_map: Dictionary = step_map_any
	
	if not step_map.has(step_id):
		step_map[step_id] = {
			"key": story_key,
			"label": story_label,
		}
	
	story_table[act_id] = step_map
	
	if not part_table.has(act_id):
		part_table[act_id] = {}
	
	var part_step_map_any: Variant = part_table[act_id]
	var part_step_map: Dictionary = part_step_map_any
	
	if not part_step_map.has(step_id):
		part_step_map[step_id] = {}
	
	var part_map_any: Variant = part_step_map[step_id]
	var part_map: Dictionary = part_map_any
	
	var part_def: Dictionary = {
		"key": story_key,
		"label": story_label,
		"next_act_id": next_act_id,
		"next_step_id": next_step_id,
		"next_part_id": next_part_id,
		"flags_set_on_enter": flags_set_on_enter,
		"flags_clear_on_enter": flags_clear_on_enter,
		"flags_set_on_complete": flags_set_on_complete,
		"flags_clear_on_complete": flags_clear_on_complete,
	}
	
	part_map[part_id] = part_def
	part_step_map[step_id] = part_map
	part_table[act_id] = part_step_map

func _csv_get_int(row: PackedStringArray, col_indexes: Dictionary, column: String) -> int:
	if not col_indexes.has(column):
		return 0
	
	var col_index_any: Variant = col_indexes[column]
	var col_index: int = int(col_index_any)
	if col_index < 0 or col_index >= row.size():
		return 0
	
	var cell_raw: String = String(row[col_index])
	var cell: String = cell_raw.strip_edges()
	if cell == "":
		return 0
	
	var value: int = 0
	value = cell.to_int()
	return value

func _csv_get_string(row: PackedStringArray, col_indexes: Dictionary, column: String) -> String:
	if not col_indexes.has(column):
		return ""
	
	var col_index_any: Variant = col_indexes[column]
	var col_index: int = int(col_index_any)
	if col_index < 0 or col_index >= row.size():
		return ""
	
	var cell_raw: String = String(row[col_index])
	return cell_raw.strip_edges()

func _csv_get_flag_list(row: PackedStringArray, col_indexes: Dictionary, column: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	
	if not col_indexes.has(column):
		return result
	
	var col_index_any: Variant = col_indexes[column]
	var col_index: int = int(col_index_any)
	if col_index < 0 or col_index >= row.size():
		return result
	
	var cell_raw: String = String(row[col_index])
	var cell: String = cell_raw.strip_edges()
	if cell == "":
		return result
	
	var parts: PackedStringArray = cell.split(";")
	for part in parts:
		var name: String = String(part).strip_edges()
		if name != "":
			result.append(name)
	
	return result


# -------------------------------------------------------------------
# Internal utilities
# -------------------------------------------------------------------

func _to_roman(value: int) -> String:
	if value <= 0:
		return ""
	
	var roman_parts: Array = [
		[1000, "M"],
		[900, "CM"],
		[500, "D"],
		[400, "CD"],
		[100, "C"],
		[90, "XC"],
		[50, "L"],
		[40, "XL"],
		[10, "X"],
		[9, "IX"],
		[5, "V"],
		[4, "IV"],
		[1, "I"],
	]
	
	var n: int = value
	var result: String = ""
	for entry in roman_parts:
		var amount_any: Variant = entry[0]
		var symbol_any: Variant = entry[1]
		var amount: int = int(amount_any)
		var symbol: String = String(symbol_any)
		
		while n >= amount:
			result += symbol
			n -= amount
		
		if n <= 0:
			break
	
	return result
