extends Node
class_name SaveSystem

signal save_slots_changed()

const SAVE_DIR: String = "user://saves"
const SAVE_FILE_PREFIX: String = "slot_"
const SAVE_FILE_SUFFIX: String = ".save"
const MAX_SLOTS: int = 3

# slot_index (int) -> metadata Dictionary
# Example keys: "player_name", "area_path", "entry_tag", "updated_at", "created_at", "play_time_sec"
var _slot_meta: Dictionary = {}

var _current_slot: int = -1

# The full payload from the last successful load_from_slot call.
# BootArea and other systems can use this to decide how to initialize the world.
var _last_loaded_payload: Dictionary = {}

func _ready() -> void:
	_ensure_save_dir()
	_scan_slots()

# ----------------------------------------------------------------------
# Public API — Slot listing / meta
# ----------------------------------------------------------------------

func has_any_save() -> bool:
	return _slot_meta.size() > 0

func slot_exists(slot_index: int) -> bool:
	return _slot_meta.has(slot_index)

func list_slots() -> Array:
	var result: Array = _slot_meta.keys()
	result.sort()
	return result

func get_slot_meta(slot_index: int) -> Dictionary:
	if _slot_meta.has(slot_index):
		var meta: Dictionary = _slot_meta[slot_index]
		return meta
	return {}

func get_current_slot() -> int:
	return _current_slot

func set_current_slot(slot_index: int) -> void:
	_current_slot = slot_index

func get_last_played_slot() -> int:
	# Simple heuristic: pick the slot with the latest "updated_at" value,
	# or the highest index if no timestamps exist yet.
	var best_slot: int = -1
	var best_stamp: String = ""
	for slot_index_obj in _slot_meta.keys():
		var slot_index: int = int(slot_index_obj)
		var meta_any: Variant = _slot_meta[slot_index]
		var meta: Dictionary = {}
		if typeof(meta_any) == TYPE_DICTIONARY:
			meta = meta_any
		var stamp: String = ""
		if meta.has("updated_at"):
			stamp = str(meta["updated_at"])
		if best_slot == -1:
			best_slot = slot_index
			best_stamp = stamp
		else:
			if stamp > best_stamp:
				best_slot = slot_index
				best_stamp = stamp
	return best_slot

# ----------------------------------------------------------------------
# Public API — Last loaded payload
# ----------------------------------------------------------------------

func get_last_loaded_payload() -> Dictionary:
	return _last_loaded_payload

func clear_last_loaded_payload() -> void:
	_last_loaded_payload = {}

# ----------------------------------------------------------------------
# Public API — Save / Load / Delete
# ----------------------------------------------------------------------

func save_to_slot(slot_index: int, payload: Dictionary) -> void:
	# NOTE: For now, this expects a ready-to-save payload from higher-level code.
	# Later, we will build the payload by querying Party, InventorySys, etc.
	if slot_index < 1 or slot_index > MAX_SLOTS:
		push_warning("[SaveSystem] save_to_slot: invalid slot_index: %d" % slot_index)
		return
	
	_ensure_save_dir()
	
	var full_payload: Dictionary = payload.duplicate(true)
	full_payload["version"] = 1
	full_payload["slot_index"] = slot_index
	full_payload["updated_at"] = Time.get_datetime_string_from_system()
	if not full_payload.has("created_at"):
		full_payload["created_at"] = full_payload["updated_at"]
	
	var path: String = _slot_path(slot_index)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveSystem] Could not open file for writing: %s" % path)
		return
	
	var json: String = JSON.stringify(full_payload, "\t")
	file.store_string(json)
	file.flush()
	file.close()
	
	_update_slot_meta_from_payload(slot_index, full_payload)
	_current_slot = slot_index
	_last_loaded_payload = full_payload.duplicate(true)
	emit_signal("save_slots_changed")

func load_from_slot(slot_index: int) -> Dictionary:
	if slot_index < 1 or slot_index > MAX_SLOTS:
		push_warning("[SaveSystem] load_from_slot: invalid slot_index: %d" % slot_index)
		return {}
	
	var path: String = _slot_path(slot_index)
	if not FileAccess.file_exists(path):
		push_warning("[SaveSystem] load_from_slot: no file at: %s" % path)
		return {}
	
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[SaveSystem] Could not open file for reading: %s" % path)
		return {}
	
	var content: String = file.get_as_text()
	file.close()
	
	var json := JSON.new()
	var err: int = json.parse(content)
	if err != OK:
		push_error("[SaveSystem] JSON parse error %d in %s" % [err, path])
		return {}
	
	var data_any: Variant = json.get_data()
	if typeof(data_any) != TYPE_DICTIONARY:
		push_error("[SaveSystem] Invalid save payload type in %s" % path)
		return {}
	
	var payload: Dictionary = data_any
	_update_slot_meta_from_payload(slot_index, payload)
	_current_slot = slot_index
	_last_loaded_payload = payload.duplicate(true)
	return payload

func delete_slot(slot_index: int) -> void:
	if slot_index < 1 or slot_index > MAX_SLOTS:
		push_warning("[SaveSystem] delete_slot: invalid slot_index: %d" % slot_index)
		return
	
	var path: String = _slot_path(slot_index)
	if FileAccess.file_exists(path):
		var err: int = DirAccess.remove_absolute(path)
		if err != OK:
			push_error("[SaveSystem] Failed to delete slot %d file (%s), err=%d" % [slot_index, path, err])
	
	if _slot_meta.has(slot_index):
		_slot_meta.erase(slot_index)
	if _current_slot == slot_index:
		_current_slot = -1
	_last_loaded_payload = {}
	
	emit_signal("save_slots_changed")

# ----------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------

func _ensure_save_dir() -> void:
	if DirAccess.dir_exists_absolute(SAVE_DIR):
		return
	
	var root_dir := DirAccess.open("user://")
	if root_dir == null:
		push_error("[SaveSystem] Could not open user:// directory.")
		return
	
	var err: int = root_dir.make_dir_recursive("saves")
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("[SaveSystem] Could not create save dir, err=%d" % err)

func _scan_slots() -> void:
	_slot_meta.clear()
	
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		return
	
	var da := DirAccess.open(SAVE_DIR)
	if da == null:
		push_error("[SaveSystem] Could not open save dir: %s" % SAVE_DIR)
		return
	
	da.list_dir_begin()
	while true:
		var fname: String = da.get_next()
		if fname == "":
			break
		if da.current_is_dir():
			continue
		if not fname.begins_with(SAVE_FILE_PREFIX):
			continue
		if not fname.ends_with(SAVE_FILE_SUFFIX):
			continue
		
		var slot_index: int = _slot_index_from_filename(fname)
		if slot_index < 1 or slot_index > MAX_SLOTS:
			continue
		
		var path: String = "%s/%s" % [SAVE_DIR, fname]
		var meta: Dictionary = _read_meta_from_file(path)
		_slot_meta[slot_index] = meta
	da.list_dir_end()

func _slot_index_from_filename(fname: String) -> int:
	# Example: "slot_1.save" -> 1
	var without_prefix: String = fname.substr(SAVE_FILE_PREFIX.length(), fname.length() - SAVE_FILE_PREFIX.length())
	var dot_index: int = without_prefix.rfind(".")
	if dot_index >= 0:
		without_prefix = without_prefix.substr(0, dot_index)
	if without_prefix.is_valid_int():
		return int(without_prefix.to_int())
	return -1

func _slot_path(slot_index: int) -> String:
	return "%s/%s%d%s" % [SAVE_DIR, SAVE_FILE_PREFIX, slot_index, SAVE_FILE_SUFFIX]

func _read_meta_from_file(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	
	var content: String = file.get_as_text()
	file.close()
	
	var json := JSON.new()
	var err: int = json.parse(content)
	if err != OK:
		return {}
	
	var data_any: Variant = json.get_data()
	if typeof(data_any) != TYPE_DICTIONARY:
		return {}
	
	var payload: Dictionary = data_any
	var meta: Dictionary = {}
	
	# Pull some lightweight metadata for menus.
	if payload.has("player_name"):
		meta["player_name"] = str(payload["player_name"])
	if payload.has("area_path"):
		meta["area_path"] = str(payload["area_path"])
	if payload.has("entry_tag"):
		meta["entry_tag"] = str(payload["entry_tag"])
	if payload.has("created_at"):
		meta["created_at"] = str(payload["created_at"])
	if payload.has("updated_at"):
		meta["updated_at"] = str(payload["updated_at"])
	if payload.has("play_time_sec"):
		meta["play_time_sec"] = int(payload["play_time_sec"])
	
	return meta

func _update_slot_meta_from_payload(slot_index: int, payload: Dictionary) -> void:
	var meta: Dictionary = _readable_meta_from_payload(payload)
	_slot_meta[slot_index] = meta

func _readable_meta_from_payload(payload: Dictionary) -> Dictionary:
	var meta: Dictionary = {}
	if payload.has("player_name"):
		meta["player_name"] = str(payload["player_name"])
	if payload.has("area_path"):
		meta["area_path"] = str(payload["area_path"])
	if payload.has("entry_tag"):
		meta["entry_tag"] = str(payload["entry_tag"])
	if payload.has("created_at"):
		meta["created_at"] = str(payload["created_at"])
	if payload.has("updated_at"):
		meta["updated_at"] = str(payload["updated_at"])
	if payload.has("play_time_sec"):
		meta["play_time_sec"] = int(payload["play_time_sec"])
	return meta
