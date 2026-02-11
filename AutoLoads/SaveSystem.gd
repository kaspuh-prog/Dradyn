extends Node
class_name SaveSystem

signal save_slots_changed()

const SAVE_DIR: String = "user://saves"
const SAVE_FILE_PREFIX: String = "slot_"
const SAVE_FILE_SUFFIX: String = ".save"
const MAX_SLOTS: int = 6

@export_group("Capture")
@export var auto_capture_runtime_state: bool = true
@export var include_story_state: bool = true
@export var include_party_state: bool = true
@export var include_inventory_state: bool = true
@export var include_hotbar_state: bool = true

# NEW: ItemDef lookup roots (locked to where you said they live)
@export_group("ItemDef Lookup")
@export var itemdef_scan_roots: PackedStringArray = PackedStringArray(["res://Data/items/equipment"])

# slot_index (int) -> metadata Dictionary
# Example keys: "player_name", "area_path", "entry_tag", "updated_at", "created_at", "play_time_sec"
var _slot_meta: Dictionary = {}

var _current_slot: int = -1

# The full payload from the last successful load_from_slot call.
# BootArea and other systems can use this to decide how to initialize the world.
var _last_loaded_payload: Dictionary = {}

# NEW: ItemDef id -> path cache (built lazily)
var _itemdef_id_to_path_cache: Dictionary = {}
var _itemdef_cache_built: bool = false


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

## Builds a full save payload from runtime systems (Party, InventorySys, HotbarSys, StoryStateSys, SceneMgr),
## then calls save_to_slot(slot_index, payload).
func save_game_to_slot(slot_index: int) -> void:
	var payload: Dictionary = build_runtime_payload({})
	save_to_slot(slot_index, payload)


## Build a payload by augmenting a seed payload (optional) with runtime state.
## This is safe to call from menus/controllers that already provide area_path, player_name, etc.
func build_runtime_payload(seed_payload: Dictionary) -> Dictionary:
	var out: Dictionary = seed_payload.duplicate(true)
	if not auto_capture_runtime_state:
		return out

	_ensure_required_world_fields(out)

	if include_story_state:
		_attach_story_state(out)

	if include_party_state:
		_attach_party_state(out)

	if include_inventory_state:
		_attach_inventory_global_state(out)

	if include_hotbar_state:
		_attach_hotbar_state(out)

	# Convenience labels for UI
	_attach_ui_meta(out)

	return out


func save_to_slot(slot_index: int, payload: Dictionary) -> void:
	# This can accept a minimal payload; if auto_capture_runtime_state is true,
	# we will augment it with runtime game state.
	if slot_index < 1 or slot_index > MAX_SLOTS:
		push_warning("[SaveSystem] save_to_slot: invalid slot_index: %d" % slot_index)
		return

	_ensure_save_dir()

	var full_payload: Dictionary = payload.duplicate(true)

	if auto_capture_runtime_state:
		full_payload = build_runtime_payload(full_payload)

	full_payload["version"] = 2
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
# Internal — Runtime capture
# ----------------------------------------------------------------------

func _ensure_required_world_fields(payload: Dictionary) -> void:
	# Area path
	var area_path: String = ""
	if payload.has("area_path"):
		area_path = str(payload["area_path"]).strip_edges()
	if area_path == "":
		area_path = _derive_current_area_path()
	if area_path != "":
		payload["area_path"] = area_path

	# Entry tag (optional)
	if not payload.has("entry_tag"):
		payload["entry_tag"] = "default"
	else:
		var et: String = str(payload["entry_tag"]).strip_edges()
		if et == "":
			payload["entry_tag"] = "default"

	# Player name (optional)
	var player_name: String = ""
	if payload.has("player_name"):
		player_name = str(payload["player_name"]).strip_edges()
	if player_name == "":
		player_name = _derive_player_name()
	if player_name != "":
		payload["player_name"] = player_name


func _derive_current_area_path() -> String:
	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm != null and sm.has_method("get_current_area"):
		var area_any: Variant = sm.call("get_current_area")
		var area: Node = area_any as Node
		if area != null:
			var p: String = area.scene_file_path
			if p != "":
				return p

	# Fallback: look under /root/GameRoot/WorldRoot for the first child with a scene_file_path.
	var world: Node = get_node_or_null("/root/GameRoot/WorldRoot")
	if world != null:
		var children: Array[Node] = world.get_children()
		var i: int = 0
		while i < children.size():
			var c: Node = children[i]
			if c != null:
				var cp: String = c.scene_file_path
				if cp != "":
					return cp
			i += 1

	return ""


func _derive_player_name() -> String:
	var pm: Node = get_node_or_null("/root/Party")
	if pm != null and pm.has_method("get_controlled"):
		var a_any: Variant = pm.call("get_controlled")
		var actor: Node = a_any as Node
		if actor != null:
			# Prefer explicit fields if present, else node name.
			if "character_name" in actor:
				var v: Variant = actor.get("character_name")
				var s: String = str(v).strip_edges()
				if s != "":
					return s
			if "player_name" in actor:
				var v2: Variant = actor.get("player_name")
				var s2: String = str(v2).strip_edges()
				if s2 != "":
					return s2
			return actor.name
	return ""


func _attach_story_state(payload: Dictionary) -> void:
	if payload.has("story_state"):
		return

	var story: Node = get_node_or_null("/root/StoryStateSys")
	if story == null:
		return
	if not story.has_method("get_save_state"):
		return

	var state_any: Variant = story.call("get_save_state")
	if typeof(state_any) == TYPE_DICTIONARY:
		payload["story_state"] = state_any


func _attach_party_state(payload: Dictionary) -> void:
	var pm: Node = get_node_or_null("/root/Party")
	if pm == null:
		return
	if not pm.has_method("get_members"):
		return

	var members_any: Variant = pm.call("get_members")
	if typeof(members_any) != TYPE_ARRAY:
		return
	var members: Array = members_any

	var party_out: Dictionary = {}
	var member_out: Array = []

	var controlled_index: int = 0
	if pm.has_method("get_controlled"):
		var c_any: Variant = pm.call("get_controlled")
		var controlled: Node = c_any as Node
		if controlled != null:
			var i_find: int = 0
			while i_find < members.size():
				if members[i_find] == controlled:
					controlled_index = i_find
					break
				i_find += 1

	var i: int = 0
	while i < members.size():
		var actor: Node = members[i] as Node
		var actor_dict: Dictionary = _serialize_actor(actor)
		member_out.append(actor_dict)
		i += 1

	party_out["members"] = member_out
	party_out["controlled_index"] = controlled_index
	payload["party"] = party_out


func _serialize_actor(actor: Node) -> Dictionary:
	var out: Dictionary = {}
	if actor == null:
		return out

	out["node_name"] = actor.name
	var sp: String = actor.scene_file_path
	if sp == "":
		# Fallback: PartyRoot_Bootstrap stamps this for reliable reconstruction.
		if actor.has_meta("spawn_scene_path"):
			var m_any: Variant = actor.get_meta("spawn_scene_path")
			var m_str: String = str(m_any).strip_edges()
			if m_str != "":
				sp = m_str

	out["scene_path"] = sp

	# Level / points
	var lvl: Node = actor.get_node_or_null("LevelComponent")
	if lvl == null:
		var f_lvl: Node = actor.find_child("LevelComponent", true, false)
		if f_lvl != null:
			lvl = f_lvl

	if lvl != null:
		if "level" in lvl:
			out["level"] = int(lvl.get("level"))
		if "current_xp" in lvl:
			out["current_xp"] = int(lvl.get("current_xp"))

		if lvl.has_method("get_unspent_points"):
			var up_any: Variant = lvl.call("get_unspent_points")
			if typeof(up_any) == TYPE_INT:
				out["unspent_points"] = int(up_any)

		if lvl.has_method("get_unspent_skill_points"):
			var usp_any: Variant = lvl.call("get_unspent_skill_points")
			if typeof(usp_any) == TYPE_INT:
				out["unspent_skill_points"] = int(usp_any)

		if lvl.has_method("get_total_skill_points_awarded"):
			var tot_any: Variant = lvl.call("get_total_skill_points_awarded")
			if typeof(tot_any) == TYPE_INT:
				out["total_skill_points_awarded"] = int(tot_any)

	# Stats base + vitals
	var stats: Node = actor.get_node_or_null("StatsComponent")
	if stats == null:
		var f_stats: Node = actor.find_child("StatsComponent", true, false)
		if f_stats != null:
			stats = f_stats

	if stats != null:
		if "stats" in stats:
			var sr_any: Variant = stats.get("stats")
			var sr: Resource = sr_any as Resource
			if sr != null and sr.has_method("to_dict"):
				var dict_any: Variant = sr.call("to_dict")
				if typeof(dict_any) == TYPE_DICTIONARY:
					out["stats_base"] = dict_any

		var vitals: Dictionary = {}
		if "current_hp" in stats:
			vitals["hp"] = float(stats.get("current_hp"))
		if "current_mp" in stats:
			vitals["mp"] = float(stats.get("current_mp"))
		if "current_end" in stats:
			vitals["end"] = float(stats.get("current_end"))
		if vitals.size() > 0:
			out["vitals"] = vitals

	# Known abilities (skill tree purchases)
	var known: Node = actor.get_node_or_null("KnownAbilitiesComponent")
	if known == null:
		var f_known: Node = actor.find_child("KnownAbilitiesComponent", true, false)
		if f_known != null:
			known = f_known

	if known != null:
		if "known_abilities" in known:
			var ka_any: Variant = known.get("known_abilities")
			if typeof(ka_any) == TYPE_PACKED_STRING_ARRAY:
				var psa: PackedStringArray = ka_any
				var arr: Array[String] = []
				var i_ka: int = 0
				while i_ka < psa.size():
					arr.append(String(psa[i_ka]))
					i_ka += 1
				out["known_abilities"] = arr

	# Inventory + equipment
	if include_inventory_state:
		out["inventory"] = _serialize_inventory_for_actor(actor)
		out["equipment"] = _serialize_equipment_for_actor(actor)

	return out


func _serialize_inventory_for_actor(actor: Node) -> Array:
	var out: Array = []
	if actor == null:
		return out

	var inv: Node = get_node_or_null("/root/InventorySys")
	if inv == null:
		return out
	if not inv.has_method("get_inventory_model_for"):
		return out

	var bag_any: Variant = inv.call("get_inventory_model_for", actor)
	var bag: Node = bag_any as Node
	if bag == null and inv.has_method("ensure_inventory_model_for"):
		var bag2_any: Variant = inv.call("ensure_inventory_model_for", actor)
		bag = bag2_any as Node
	if bag == null:
		return out

	if not bag.has_method("slot_count"):
		return out

	var slots_any: Variant = bag.call("slot_count")
	var slots: int = 0
	if typeof(slots_any) == TYPE_INT:
		slots = int(slots_any)

	var i: int = 0
	while i < slots:
		var slot_dict: Dictionary = {}
		if bag.has_method("get_slot_stack"):
			var st_any: Variant = bag.call("get_slot_stack", i)
			var st: Resource = st_any as Resource
			if st != null and "item" in st and "count" in st:
				var item_any: Variant = st.get("item")
				var item: Resource = item_any as Resource
				var count: int = int(st.get("count"))
				if item != null and count > 0:
					var item_path: String = item.resource_path
					var item_id: String = ""
					if "id" in item:
						item_id = str(item.get("id"))
					if item_path != "":
						slot_dict["item_path"] = item_path
					if item_id != "":
						slot_dict["item_id"] = item_id
					slot_dict["count"] = count

		out.append(slot_dict)
		i += 1

	return out


func _serialize_equipment_for_actor(actor: Node) -> Dictionary:
	var out: Dictionary = {}
	if actor == null:
		return out

	var inv: Node = get_node_or_null("/root/InventorySys")
	if inv == null:
		return out
	if not inv.has_method("ensure_equipment_model_for"):
		return out

	var em_any: Variant = inv.call("ensure_equipment_model_for", actor)
	var em: Node = em_any as Node
	if em == null:
		return out

	if not em.has_method("all_slots"):
		return out
	if not em.has_method("get_equipped"):
		return out

	var slots_any: Variant = em.call("all_slots")
	if typeof(slots_any) != TYPE_ARRAY and typeof(slots_any) != TYPE_PACKED_STRING_ARRAY:
		return out

	var slots: Array = []
	if typeof(slots_any) == TYPE_PACKED_STRING_ARRAY:
		var psa: PackedStringArray = slots_any
		var i_psa: int = 0
		while i_psa < psa.size():
			slots.append(String(psa[i_psa]))
			i_psa += 1
	else:
		slots = slots_any

	var i: int = 0
	while i < slots.size():
		var slot_name: String = str(slots[i]).strip_edges()
		if slot_name == "":
			i += 1
			continue

		var it_any: Variant = em.call("get_equipped", slot_name)
		var it: Resource = it_any as Resource
		if it != null:
			var p: String = it.resource_path
			var iid: String = ""
			if "id" in it:
				iid = str(it.get("id")).strip_edges()

			# If resource_path is empty (runtime-created), resolve by id.
			if p == "" and iid != "":
				p = _resolve_itemdef_path_from_id(iid)

			# IMPORTANT: for equipment, ONLY save paths we can reload.
			if p != "":
				out[slot_name] = p
			else:
				print("[SaveSystem] WARNING: Could not resolve equipped item for slot=", slot_name, " id=", iid, " actor=", actor.name)

		i += 1

	return out


func _attach_inventory_global_state(payload: Dictionary) -> void:
	var inv: Node = get_node_or_null("/root/InventorySys")
	if inv == null:
		return

	var out: Dictionary = {}

	if inv.has_method("get_currency"):
		var cur_any: Variant = inv.call("get_currency")
		if typeof(cur_any) == TYPE_INT:
			out["currency"] = int(cur_any)

	if "unlocked_by_tab" in inv:
		var ubt_any: Variant = inv.get("unlocked_by_tab")
		if typeof(ubt_any) == TYPE_PACKED_INT32_ARRAY:
			var p: PackedInt32Array = ubt_any
			var arr_tab: Array[int] = []
			var i_tab: int = 0
			while i_tab < p.size():
				arr_tab.append(int(p[i_tab]))
				i_tab += 1
			out["unlocked_by_tab"] = arr_tab

	if out.size() > 0:
		payload["inventory_global"] = out


func _attach_hotbar_state(payload: Dictionary) -> void:
	var pm: Node = get_node_or_null("/root/Party")
	var hb: Node = get_node_or_null("/root/HotbarSys")
	if pm == null or hb == null:
		return
	if not pm.has_method("get_members"):
		return
	if not hb.has_method("export_party_profiles"):
		return

	var members_any2: Variant = pm.call("get_members")
	if typeof(members_any2) != TYPE_ARRAY:
		return
	var members2: Array = members_any2

	var profiles_any: Variant = hb.call("export_party_profiles", members2)
	if typeof(profiles_any) == TYPE_ARRAY:
		payload["hotbar_profiles"] = profiles_any


func _attach_ui_meta(payload: Dictionary) -> void:
	# Keep these lightweight for SaveSelectScreen.
	var meta: Dictionary = {}

	# Prefer explicit story label.
	var story: Node = get_node_or_null("/root/StoryStateSys")
	if story != null and story.has_method("get_act_step_display_string"):
		var disp_any: Variant = story.call("get_act_step_display_string")
		if typeof(disp_any) == TYPE_STRING:
			var s: String = String(disp_any).strip_edges()
			if s != "":
				meta["story_display"] = s

	# Leader level + name + class
	var pm: Node = get_node_or_null("/root/Party")
	if pm != null and pm.has_method("get_controlled"):
		var c_any: Variant = pm.call("get_controlled")
		var controlled: Node = c_any as Node
		if controlled != null:
			meta["leader_name"] = _derive_player_name()
			var lvl: Node = controlled.get_node_or_null("LevelComponent")
			if lvl == null:
				var f: Node = controlled.find_child("LevelComponent", true, false)
				if f != null:
					lvl = f
			if lvl != null and "level" in lvl:
				meta["leader_level"] = int(lvl.get("level"))

			# NEW: leader class (title) from LevelComponent.class_def (ClassDef)
			var class_title: String = _derive_class_title_from_level_component(lvl)
			if class_title != "":
				meta["leader_class_title"] = class_title

	if meta.size() > 0:
		payload["ui_meta"] = meta


func _derive_class_title_from_level_component(lvl: Node) -> String:
	if lvl == null:
		return ""

	# ClassDef is assigned to LevelComponent; we read it without assuming a concrete script API.
	if not ("class_def" in lvl):
		return ""

	var cd_any: Variant = lvl.get("class_def")
	var cd: Resource = cd_any as Resource
	if cd == null:
		return ""

	# Prefer common naming conventions.
	if "display_name" in cd:
		var v: Variant = cd.get("display_name")
		var s: String = str(v).strip_edges()
		if s != "":
			return s

	if "class_name" in cd:
		var v2: Variant = cd.get("class_name")
		var s2: String = str(v2).strip_edges()
		if s2 != "":
			return s2

	if "name" in cd:
		var v3: Variant = cd.get("name")
		var s3: String = str(v3).strip_edges()
		if s3 != "":
			return s3

	# Final fallback: resource_name is always present but might be generic.
	var rn: String = cd.resource_name.strip_edges()
	return rn


# ----------------------------------------------------------------------
# NEW: ItemDef id -> res:// path lookup (equipment folder)
# ----------------------------------------------------------------------

func _ensure_itemdef_cache() -> void:
	if _itemdef_cache_built:
		return

	_itemdef_cache_built = true
	_itemdef_id_to_path_cache = {}

	var i: int = 0
	while i < itemdef_scan_roots.size():
		var root_path: String = String(itemdef_scan_roots[i]).strip_edges()
		if root_path != "":
			_build_itemdef_cache_from_dir(root_path)
		i += 1


func _build_itemdef_cache_from_dir(root_path: String) -> void:
	# Do NOT use dir_exists_absolute() for res://; it can lie.
	# Try open; if fails, skip.
	var d: DirAccess = DirAccess.open(root_path)
	if d == null:
		return

	d.list_dir_begin()
	while true:
		var name: String = d.get_next()
		if name == "":
			break
		if name.begins_with("."):
			continue

		var full_path: String = root_path.path_join(name)

		if d.current_is_dir():
			_build_itemdef_cache_from_dir(full_path)
		else:
			if full_path.ends_with(".tres"):
				var res: Resource = ResourceLoader.load(full_path)
				var it: ItemDef = res as ItemDef
				if it != null:
					var id_str: String = ""
					if "id" in it:
						id_str = str(it.get("id")).strip_edges()
					if id_str != "":
						_itemdef_id_to_path_cache[id_str] = full_path

	d.list_dir_end()


func _resolve_itemdef_path_from_id(item_id: String) -> String:
	var id_str: String = item_id.strip_edges()
	if id_str == "":
		return ""

	_ensure_itemdef_cache()

	if _itemdef_id_to_path_cache.has(id_str):
		var p_any: Variant = _itemdef_id_to_path_cache[id_str]
		var p: String = str(p_any).strip_edges()
		if p != "" and ResourceLoader.exists(p):
			return p

	return ""


# ----------------------------------------------------------------------
# Internal helpers — file IO + meta scan
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
	var meta: Dictionary = _readable_meta_from_payload(payload)
	return meta


func _update_slot_meta_from_payload(slot_index: int, payload: Dictionary) -> void:
	var meta: Dictionary = _readable_meta_from_payload(payload)
	_slot_meta[slot_index] = meta


func _readable_meta_from_payload(payload: Dictionary) -> Dictionary:
	var meta: Dictionary = {}

	# Core legacy fields
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

	# New lightweight UI fields (optional)
	if payload.has("ui_meta"):
		var ui_any: Variant = payload["ui_meta"]
		if typeof(ui_any) == TYPE_DICTIONARY:
			var ui: Dictionary = ui_any
			if ui.has("leader_name"):
				meta["leader_name"] = str(ui["leader_name"])
			if ui.has("leader_level"):
				meta["leader_level"] = int(ui["leader_level"])
			if ui.has("story_display"):
				meta["story_display"] = str(ui["story_display"])
			# NEW: leader class
			if ui.has("leader_class_title"):
				meta["leader_class_title"] = str(ui["leader_class_title"])

	return meta
