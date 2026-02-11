extends Node
class_name BootArea

@export_file("*.tscn") var start_area: String = "res://scenes/WorldAreas/OrphanageCommonRoom.tscn"
@export var start_entry_tag: String = "default"
@export var auto_start: bool = true

var _pending_payload: Dictionary = {}
var _has_pending_payload: bool = false

var _applied_hotbar: bool = false
var _applied_known_abilities: bool = false
var _applied_level_state: bool = false
var _applied_inventory_equipment: bool = false
var _applied_stats_vitals: bool = false

# NEW: global inventory state (currency, etc.)
var _applied_inventory_global: bool = false

# NEW: once we successfully apply known abilities + level pools, force-refresh mediators once.
var _forced_skill_tree_refresh: bool = false


func _ready() -> void:
	if not auto_start:
		return

	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm == null:
		push_error("[BootArea] SceneMgr autoload not found. Add it in Project Settings → Autoload.")
		return

	# Apply AFTER area mount / party spawn.
	if sm.has_signal("area_changed"):
		if not sm.is_connected("area_changed", Callable(self, "_on_area_changed")):
			sm.connect("area_changed", Callable(self, "_on_area_changed"))

	var pm: Node = get_node_or_null("/root/Party")
	if pm != null and pm.has_signal("party_changed"):
		if not pm.is_connected("party_changed", Callable(self, "_on_party_changed")):
			pm.connect("party_changed", Callable(self, "_on_party_changed"))

	var target_area: String = start_area
	var target_entry_tag: String = start_entry_tag

	var save_sys: Node = get_node_or_null("/root/SaveSys")
	if save_sys != null and save_sys.has_method("get_last_loaded_payload"):
		var payload_any: Variant = save_sys.call("get_last_loaded_payload")
		if typeof(payload_any) == TYPE_DICTIONARY:
			var payload: Dictionary = payload_any
			_pending_payload = payload.duplicate(true)
			_has_pending_payload = _pending_payload.size() > 0

			print("[BootArea] Loaded payload keys: ", _pending_payload.keys())

			if _pending_payload.has("area_path"):
				var ap: String = str(_pending_payload["area_path"]).strip_edges()
				if ap != "":
					target_area = ap
			if _pending_payload.has("entry_tag"):
				var et: String = str(_pending_payload["entry_tag"]).strip_edges()
				if et != "":
					target_entry_tag = et

			# Apply story state early (before content gates run).
			if _pending_payload.has("story_state"):
				var story_state_any: Variant = _pending_payload["story_state"]
				if typeof(story_state_any) == TYPE_DICTIONARY:
					var story_state: Dictionary = story_state_any
					var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
					if story != null:
						story.apply_save_state(story_state)

	if sm.has_method("change_area"):
		sm.call("change_area", target_area, target_entry_tag)

	# Multiple early attempts (some components finalize over several frames).
	await get_tree().process_frame
	_try_apply_loaded_state("frame1")
	await get_tree().process_frame
	_try_apply_loaded_state("frame2")
	await get_tree().process_frame
	_try_apply_loaded_state("frame3")
	await get_tree().process_frame
	_try_apply_loaded_state("frame4")

	# NEW: PartyRoot may rebuild/spawn AFTER frame4 now. Keep retrying briefly.
	await _retry_apply_loaded_state_frames(60)


func _on_area_changed(_area: Node, _entry_tag: String) -> void:
	call_deferred("_deferred_try_apply_after_area")


func _deferred_try_apply_after_area() -> void:
	_try_apply_loaded_state("area_changed_deferred")


func _on_party_changed(_members: Array) -> void:
	_try_apply_loaded_state("party_changed")


func _retry_apply_loaded_state_frames(max_frames: int) -> void:
	if max_frames <= 0:
		return

	var i: int = 0
	while i < max_frames:
		await get_tree().process_frame
		_try_apply_loaded_state("frame_retry_%d" % i)

		if _applied_known_abilities and _applied_level_state and _applied_stats_vitals and _applied_inventory_equipment and _applied_hotbar and _applied_inventory_global:
			return

		i += 1


func _try_apply_loaded_state(reason: String) -> void:
	if not _has_pending_payload:
		return

	# 0) Restore global inventory state (party currency, etc.)
	if not _applied_inventory_global:
		_applied_inventory_global = _try_apply_inventory_global_state(reason)

	# 1) Restore unlocked/purchased abilities (eligibility)
	if not _applied_known_abilities:
		_applied_known_abilities = _try_apply_known_abilities(reason)

	# 2) Restore LevelComponent pools (skill points, etc.) so SkillTree matches
	if not _applied_level_state:
		_applied_level_state = _try_apply_level_state(reason)

	# If we got the two SkillTree prerequisites applied, force a mediator refresh once.
	# (This makes the sheet repopulate/reevaluate after save restore.)
	if _applied_known_abilities and _applied_level_state and not _forced_skill_tree_refresh:
		_forced_skill_tree_refresh = true
		_force_refresh_skill_tree(reason)

	# 3) Restore StatsResource base_stats + vitals per actor
	if not _applied_stats_vitals:
		_applied_stats_vitals = _try_apply_stats_and_vitals(reason)

	# 4) Restore inventory + equipment per actor
	if not _applied_inventory_equipment:
		_applied_inventory_equipment = _try_apply_inventory_and_equipment(reason)

	# 5) Restore hotbar layout (icons/slots)
	if not _applied_hotbar:
		_applied_hotbar = _try_apply_hotbar_profiles(reason)


# ------------------------------------------------------------
# NEW: Inventory global (currency)
# ------------------------------------------------------------
func _try_apply_inventory_global_state(reason: String) -> bool:
	if not _pending_payload.has("inventory_global"):
		return true

	var inv_global_any: Variant = _pending_payload["inventory_global"]
	if typeof(inv_global_any) != TYPE_DICTIONARY:
		return true

	var inv_global: Dictionary = inv_global_any

	var inv_sys: InventorySystem = _resolve_inventory_autoload()
	if inv_sys == null:
		return false

	if inv_global.has("currency"):
		var cur_any: Variant = inv_global["currency"]
		var cur: int = 0
		if typeof(cur_any) == TYPE_INT:
			cur = int(cur_any)
		elif typeof(cur_any) == TYPE_FLOAT:
			cur = int(cur_any)
		elif typeof(cur_any) == TYPE_STRING:
			var s: String = String(cur_any).strip_edges()
			if s != "":
				cur = int(s)

		if cur < 0:
			cur = 0

		if inv_sys.has_method("set_currency"):
			inv_sys.set_currency(cur)
			print("[BootArea] Applied inventory_global.currency=", str(cur), " via ", reason)
		else:
			# Should not happen in current project, but keep safe.
			print("[BootArea] InventorySystem missing set_currency; cannot apply currency via ", reason)

	return true


func _resolve_inventory_autoload() -> InventorySystem:
	var n: Node = get_node_or_null("/root/InventorySys")
	if n == null:
		n = get_node_or_null("/root/InventorySystem")
	return n as InventorySystem


func _force_refresh_skill_tree(reason: String) -> void:
	# We want to refresh any SkillTreeMediator currently alive so it repopulates rows
	# after KnownAbilities/Level state are restored.
	var mediators: Array[SkillTreeMediator] = _find_skill_tree_mediators()
	if mediators.is_empty():
		# UI may not be instantiated yet; party_changed/controlled_changed will refresh later anyway.
		print("[BootArea] SkillTreeMediator not found yet; refresh skipped via ", reason)
		return

	var i: int = 0
	while i < mediators.size():
		var m: SkillTreeMediator = mediators[i]
		if m != null:
			if m.has_method("register_and_refresh"):
				m.call("register_and_refresh")
		i += 1

	print("[BootArea] Forced SkillTreeMediator refresh (", str(mediators.size()), ") via ", reason)


func _find_skill_tree_mediators() -> Array[SkillTreeMediator]:
	var out: Array[SkillTreeMediator] = []
	var root: Node = get_tree().root
	if root == null:
		return out

	# BFS walk of the active scene tree
	var queue: Array[Node] = []
	queue.append(root)

	while queue.size() > 0:
		var n: Node = queue.pop_front()
		if n is SkillTreeMediator:
			out.append(n as SkillTreeMediator)

		for c in n.get_children():
			queue.append(c)

	return out


# ------------------------------------------------------------
# Hotbar
# ------------------------------------------------------------
func _try_apply_hotbar_profiles(reason: String) -> bool:
	if not _pending_payload.has("hotbar_profiles"):
		return true

	var pm: Node = get_node_or_null("/root/Party")
	if pm == null or not pm.has_method("get_members"):
		return false

	var members_any: Variant = pm.call("get_members")
	if typeof(members_any) != TYPE_ARRAY:
		return false
	var members: Array = members_any
	if members.is_empty():
		return false

	var hb: Node = get_node_or_null("/root/HotbarSys")
	if hb == null or not hb.has_method("import_party_profiles"):
		return false

	var profiles_any: Variant = _pending_payload["hotbar_profiles"]
	if typeof(profiles_any) != TYPE_ARRAY:
		return true
	var profiles: Array = profiles_any

	hb.call("import_party_profiles", members, profiles)
	print("[BootArea] Applied hotbar_profiles (", str(members.size()), " live members) via ", reason)

	if members.size() >= profiles.size():
		return true
	return false


# ------------------------------------------------------------
# Known abilities
# ------------------------------------------------------------
func _try_apply_known_abilities(reason: String) -> bool:
	if not _pending_payload.has("party"):
		return true

	var party_any: Variant = _pending_payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return true
	var party_dict: Dictionary = party_any

	if not party_dict.has("members"):
		return true

	var saved_members_any: Variant = party_dict["members"]
	if typeof(saved_members_any) != TYPE_ARRAY:
		return true
	var saved_members: Array = saved_members_any

	var pm: Node = get_node_or_null("/root/Party")
	if pm == null or not pm.has_method("get_members"):
		return false

	var live_members_any: Variant = pm.call("get_members")
	if typeof(live_members_any) != TYPE_ARRAY:
		return false
	var live_members: Array = live_members_any
	if live_members.is_empty():
		return false

	var applied_count: int = 0
	var i: int = 0
	while i < live_members.size() and i < saved_members.size():
		var actor: Node = live_members[i] as Node
		var saved_any: Variant = saved_members[i]
		if actor != null and typeof(saved_any) == TYPE_DICTIONARY:
			var saved: Dictionary = saved_any
			applied_count += _apply_known_abilities_to_actor(actor, saved)
		i += 1

	print("[BootArea] Applied known_abilities to ", str(applied_count), " actor(s) via ", reason)

	if live_members.size() >= saved_members.size():
		return true
	return false


func _apply_known_abilities_to_actor(actor: Node, saved_actor: Dictionary) -> int:
	if actor == null:
		return 0
	if not saved_actor.has("known_abilities"):
		return 0

	var ka_any: Variant = saved_actor["known_abilities"]
	if typeof(ka_any) != TYPE_ARRAY:
		return 0
	var ka_arr: Array = ka_any

	var kac: KnownAbilitiesComponent = actor.get_node_or_null("KnownAbilitiesComponent") as KnownAbilitiesComponent
	if kac == null:
		var found: Node = actor.find_child("KnownAbilitiesComponent", true, false)
		kac = found as KnownAbilitiesComponent
	if kac == null:
		var found2: Node = actor.find_child("KnownAbilities", true, false)
		kac = found2 as KnownAbilitiesComponent
	if kac == null:
		return 0

	kac.clear_all()

	var j: int = 0
	while j < ka_arr.size():
		var id_any: Variant = ka_arr[j]
		var id_str: String = ""
		if typeof(id_any) == TYPE_STRING:
			id_str = String(id_any)
		id_str = id_str.strip_edges()
		if id_str != "":
			kac.add_ability(id_str)
		j += 1

	return 1


# ------------------------------------------------------------
# Level state
# ------------------------------------------------------------
func _try_apply_level_state(reason: String) -> bool:
	if not _pending_payload.has("party"):
		return true

	var party_any: Variant = _pending_payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return true
	var party_dict: Dictionary = party_any

	if not party_dict.has("members"):
		return true

	var saved_members_any: Variant = party_dict["members"]
	if typeof(saved_members_any) != TYPE_ARRAY:
		return true
	var saved_members: Array = saved_members_any

	var pm: Node = get_node_or_null("/root/Party")
	if pm == null or not pm.has_method("get_members"):
		return false

	var live_members_any: Variant = pm.call("get_members")
	if typeof(live_members_any) != TYPE_ARRAY:
		return false
	var live_members: Array = live_members_any
	if live_members.is_empty():
		return false

	var applied_count: int = 0
	var i: int = 0
	while i < live_members.size() and i < saved_members.size():
		var actor: Node = live_members[i] as Node
		var saved_any: Variant = saved_members[i]
		if actor != null and typeof(saved_any) == TYPE_DICTIONARY:
			var saved: Dictionary = saved_any
			applied_count += _apply_level_to_actor(actor, saved)
		i += 1

	print("[BootArea] Applied LevelComponent state to ", str(applied_count), " actor(s) via ", reason)

	if live_members.size() >= saved_members.size():
		return true
	return false


func _apply_level_to_actor(actor: Node, saved_actor: Dictionary) -> int:
	if actor == null:
		return 0

	var lvl: LevelComponent = actor.find_child("LevelComponent", true, false) as LevelComponent
	if lvl == null:
		var direct: Node = actor.get_node_or_null("LevelComponent")
		lvl = direct as LevelComponent
	if lvl == null:
		return 0

	if saved_actor.has("level"):
		if "level" in lvl:
			lvl.set("level", int(saved_actor["level"]))

	if saved_actor.has("current_xp"):
		if "current_xp" in lvl:
			lvl.set("current_xp", int(saved_actor["current_xp"]))

	if saved_actor.has("unspent_points"):
		if "unspent_points" in lvl:
			lvl.set("unspent_points", int(saved_actor["unspent_points"]))
			if lvl.has_signal("points_changed"):
				lvl.emit_signal("points_changed", int(lvl.get("unspent_points")))

	if saved_actor.has("unspent_skill_points"):
		if "unspent_skill_points" in lvl:
			lvl.set("unspent_skill_points", int(saved_actor["unspent_skill_points"]))

	if saved_actor.has("total_skill_points_awarded"):
		if "total_skill_points_awarded" in lvl:
			lvl.set("total_skill_points_awarded", int(saved_actor["total_skill_points_awarded"]))

	if lvl.has_signal("skill_points_changed"):
		var usp: int = 0
		var tot: int = 0
		if "unspent_skill_points" in lvl:
			usp = int(lvl.get("unspent_skill_points"))
		if "total_skill_points_awarded" in lvl:
			tot = int(lvl.get("total_skill_points_awarded"))
		lvl.emit_signal("skill_points_changed", usp, tot)

	return 1


# ------------------------------------------------------------
# NEW: Stats base + vitals restore
# ------------------------------------------------------------
func _try_apply_stats_and_vitals(reason: String) -> bool:
	if not _pending_payload.has("party"):
		return true

	var party_any: Variant = _pending_payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return true
	var party_dict: Dictionary = party_any

	if not party_dict.has("members"):
		return true

	var saved_members_any: Variant = party_dict["members"]
	if typeof(saved_members_any) != TYPE_ARRAY:
		return true
	var saved_members: Array = saved_members_any

	var pm: Node = get_node_or_null("/root/Party")
	if pm == null or not pm.has_method("get_members"):
		return false

	var live_members_any: Variant = pm.call("get_members")
	if typeof(live_members_any) != TYPE_ARRAY:
		return false
	var live_members: Array = live_members_any
	if live_members.is_empty():
		return false

	var applied_count: int = 0

	var i: int = 0
	while i < live_members.size() and i < saved_members.size():
		var actor: Node = live_members[i] as Node
		var saved_any: Variant = saved_members[i]
		if actor != null and typeof(saved_any) == TYPE_DICTIONARY:
			var saved: Dictionary = saved_any
			if _apply_stats_and_vitals_to_actor(actor, saved):
				applied_count += 1
		i += 1

	print("[BootArea] Applied stats_base + vitals to ", str(applied_count), " actor(s) via ", reason)

	if live_members.size() >= saved_members.size():
		return true
	return false


func _apply_stats_and_vitals_to_actor(actor: Node, saved_actor: Dictionary) -> bool:
	var stats: StatsComponent = actor.get_node_or_null("StatsComponent") as StatsComponent
	if stats == null:
		var found: Node = actor.find_child("StatsComponent", true, false)
		stats = found as StatsComponent
	if stats == null:
		return false

	# 1) Restore base_stats via StatsResource.from_dict
	if saved_actor.has("stats_base"):
		var sb_any: Variant = saved_actor["stats_base"]
		if typeof(sb_any) == TYPE_DICTIONARY:
			var sb: Dictionary = sb_any
			if stats.stats != null and stats.stats.has_method("from_dict"):
				stats.stats.call("from_dict", sb)

	# Ensure derived/vitals behavior is consistent after base changes
	if stats.has_method("_recalc_processing"):
		stats.call("_recalc_processing")

	# 2) Restore vitals (current_hp/mp/end)
	if saved_actor.has("vitals"):
		var vit_any: Variant = saved_actor["vitals"]
		if typeof(vit_any) == TYPE_DICTIONARY:
			var vit: Dictionary = vit_any

			if vit.has("hp") and "current_hp" in stats:
				var hp_val: float = float(vit["hp"])
				var hp_max: float = stats.max_hp()
				stats.current_hp = clampf(hp_val, 0.0, hp_max)
				if stats.has_signal("hp_changed"):
					stats.emit_signal("hp_changed", stats.current_hp, hp_max)

			if vit.has("mp") and "current_mp" in stats:
				var mp_val: float = float(vit["mp"])
				var mp_max: float = stats.max_mp()
				stats.current_mp = clampf(mp_val, 0.0, mp_max)
				if stats.has_signal("mp_changed"):
					stats.emit_signal("mp_changed", stats.current_mp, mp_max)

			if vit.has("end") and "current_end" in stats:
				var end_val: float = float(vit["end"])
				var end_max: float = stats.max_end()
				stats.current_end = clampf(end_val, 0.0, end_max)
				if stats.has_signal("end_changed"):
					stats.emit_signal("end_changed", stats.current_end, end_max)

	return true


# ------------------------------------------------------------
# Inventory + Equipment restore (per party member)
# ------------------------------------------------------------
func _try_apply_inventory_and_equipment(reason: String) -> bool:
	if not _pending_payload.has("party"):
		return true

	var party_any: Variant = _pending_payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return true
	var party_dict: Dictionary = party_any

	if not party_dict.has("members"):
		return true

	var saved_members_any: Variant = party_dict["members"]
	if typeof(saved_members_any) != TYPE_ARRAY:
		return true
	var saved_members: Array = saved_members_any

	var pm: Node = get_node_or_null("/root/Party")
	if pm == null or not pm.has_method("get_members"):
		return false

	var live_members_any: Variant = pm.call("get_members")
	if typeof(live_members_any) != TYPE_ARRAY:
		return false
	var live_members: Array = live_members_any
	if live_members.is_empty():
		return false

	var inv_sys: InventorySystem = get_node_or_null("/root/InventorySys") as InventorySystem
	if inv_sys == null:
		return false

	var applied_inv: int = 0
	var applied_eq: int = 0

	var i: int = 0
	while i < live_members.size() and i < saved_members.size():
		var actor: Node = live_members[i] as Node
		var saved_any: Variant = saved_members[i]
		if actor != null and typeof(saved_any) == TYPE_DICTIONARY:
			var saved: Dictionary = saved_any
			applied_inv += _apply_inventory_to_actor(inv_sys, actor, saved)
			applied_eq += _apply_equipment_to_actor(inv_sys, actor, saved)
		i += 1

	print("[BootArea] Applied inventory to ", str(applied_inv), " actor(s), equipment to ", str(applied_eq), " actor(s) via ", reason)

	if live_members.size() >= saved_members.size():
		return true
	return false


func _apply_inventory_to_actor(inv_sys: InventorySystem, actor: Node, saved_actor: Dictionary) -> int:
	if inv_sys == null or actor == null:
		return 0
	if not saved_actor.has("inventory"):
		return 0

	var inv_any: Variant = saved_actor["inventory"]
	if typeof(inv_any) != TYPE_ARRAY:
		return 0
	var inv_arr: Array = inv_any

	var bag: InventoryModel = inv_sys.ensure_inventory_model_for(actor)
	if bag == null:
		return 0

	var slots: int = bag.slot_count()
	var idx: int = 0
	while idx < slots:
		var stack: ItemStack = null

		if idx < inv_arr.size():
			var entry_any: Variant = inv_arr[idx]
			if typeof(entry_any) == TYPE_DICTIONARY:
				var entry: Dictionary = entry_any
				if entry.has("count"):
					var count: int = int(entry["count"])
					if count > 0:
						var item: ItemDef = _load_itemdef_from_entry(entry)
						if item != null:
							var capped: int = count
							if "stack_max" in item:
								var sm: int = int(item.get("stack_max"))
								if sm > 0 and capped > sm:
									capped = sm
							var s: ItemStack = ItemStack.new()
							s.item = item
							s.count = capped
							stack = s

		bag.set_stack(idx, stack)
		idx += 1

	return 1


func _apply_equipment_to_actor(inv_sys: InventorySystem, actor: Node, saved_actor: Dictionary) -> int:
	if inv_sys == null or actor == null:
		return 0
	if not saved_actor.has("equipment"):
		return 0

	var eq_any: Variant = saved_actor["equipment"]
	if typeof(eq_any) != TYPE_DICTIONARY:
		return 0
	var eq_dict: Dictionary = eq_any

	var em: EquipmentModel = inv_sys.ensure_equipment_model_for(actor)
	if em == null:
		return 0

	var all_any: Variant = em.all_slots()
	if typeof(all_any) == TYPE_ARRAY:
		var all_slots: Array = all_any
		var i: int = 0
		while i < all_slots.size():
			var slot_name: String = str(all_slots[i]).strip_edges()
			if slot_name != "":
				em.unequip(slot_name)
			i += 1

	for k in eq_dict.keys():
		var slot: String = str(k).strip_edges()
		if slot == "":
			continue
		var ref: String = str(eq_dict[k]).strip_edges()
		if ref == "":
			continue

		var item: ItemDef = _load_itemdef_from_ref(ref)
		if item != null:
			var ok: bool = em.equip(slot, item)
			if not ok:
				print("[BootArea] equip failed slot=", slot, " item=", ref, " actor=", actor.name)

	return 1


func _load_itemdef_from_entry(entry: Dictionary) -> ItemDef:
	if entry.has("item_path"):
		var p: String = str(entry["item_path"]).strip_edges()
		var it1: ItemDef = _load_itemdef_from_ref(p)
		if it1 != null:
			return it1
	return null


func _load_itemdef_from_ref(ref: String) -> ItemDef:
	var p: String = ref.strip_edges()
	if p == "":
		return null
	if ResourceLoader.exists(p):
		var res: Resource = ResourceLoader.load(p)
		var it: ItemDef = res as ItemDef
		if it != null:
			return it
	return null
