extends Node
class_name StoryStateSystem

signal story_step_changed(act_id: int, step_id: int)
signal flags_changed()

@export var default_act_id: int = 1
@export var default_step_id: int = 1

# Internal state
var _current_act_id: int = 1
var _current_step_id: int = 1

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

func _ready() -> void:
	_current_act_id = default_act_id
	_current_step_id = default_step_id


# -------------------------------------------------------------------
# Story table registration / access
# -------------------------------------------------------------------

func set_story_table(table: Dictionary) -> void:
	_story_table = table.duplicate(true)

func get_story_table() -> Dictionary:
	return _story_table


# -------------------------------------------------------------------
# Current act / step
# -------------------------------------------------------------------

func get_current_act_id() -> int:
	return _current_act_id

func get_current_step_id() -> int:
	return _current_step_id

func set_current_act(act_id: int) -> void:
	if act_id == _current_act_id:
		return
	
	_current_act_id = act_id
	# When act changes, you may want to reset step to 1 or leave as-is.
	# For now we leave it as-is and only emit a combined step-changed signal.
	_emit_story_step_changed()

func set_current_step(step_id: int) -> void:
	if step_id == _current_step_id:
		return
	
	_current_step_id = step_id
	_emit_story_step_changed()

func set_current_step_full(act_id: int, step_id: int) -> void:
	var changed: bool = false
	
	if act_id != _current_act_id:
		_current_act_id = act_id
		changed = true
	if step_id != _current_step_id:
		_current_step_id = step_id
		changed = true
	
	if changed:
		_emit_story_step_changed()

func _emit_story_step_changed() -> void:
	story_step_changed.emit(_current_act_id, _current_step_id)


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
	state["flags"] = get_all_flags()
	return state

func apply_save_state(state: Dictionary) -> void:
	if state.has("act_id") and state.has("step_id"):
		var act_any: Variant = state["act_id"]
		var step_any: Variant = state["step_id"]
		if typeof(act_any) == TYPE_INT and typeof(step_any) == TYPE_INT:
			set_current_step_full(int(act_any), int(step_any))
	
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
# Internal utilities
# -------------------------------------------------------------------

func _to_roman(value: int) -> String:
	if value <= 0:
		return ""
	
	# Only need a small range for DRADYN (Acts I–X-ish).
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
