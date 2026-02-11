extends Node
class_name SkillTreeMediator
# Godot 4.5 — fully typed, no ternaries.

signal debug(msg: String)
signal ability_unlocked(actor: Node, ability_id: String)

@export var sheet_path: NodePath
@export var level_component_relative: NodePath = NodePath()
@export var ability_defs: Array[AbilityDef] = []
@export var auto_register_on_ready: bool = false
@export var populate_from_class: bool = true

var _sheet: Control
var _actor: Node = null
var _level: LevelComponent = null
var _registered_once: bool = false

# Track what we've "registered" with AbilitySys (by ability_id). With handler scripts removed,
# this is a simple guard to avoid repeated work if you later add lightweight registration.
var _registered_ids: Dictionary = {}  # id:String -> true

func _ready() -> void:
	_sheet = get_node_or_null(sheet_path) as Control
	if _sheet == null:
		push_error("SkillTreeMediator: sheet_path not assigned or missing.")
		return

	# Sheet signal for purchases
	if _sheet.has_signal("ability_purchase_requested"):
		_sheet.connect("ability_purchase_requested", Callable(self, "_on_sheet_purchase_requested"))

	# Party autoload
	var party: Node = _get_party()
	if party != null:
		if not party.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
			party.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
		if not party.is_connected("party_changed", Callable(self, "_on_party_changed")):
			party.connect("party_changed", Callable(self, "_on_party_changed"))

	_bind_to_current_controlled()

	if auto_register_on_ready:
		_register_handlers_with_ability_system()

	# IMPORTANT: grant zero-cost abilities BEFORE first populate
	_auto_unlock_zero_cost_for_current_actor()

	_refresh_sheet_all()
	_push_points_to_sheet()

# -------------------------------------------------------------------
# Public convenience
# -------------------------------------------------------------------
func register_and_refresh() -> void:
	_register_handlers_with_ability_system()
	_auto_unlock_zero_cost_for_current_actor()
	_refresh_sheet_all()
	_push_points_to_sheet()

# -------------------------------------------------------------------
# Autoloads
# -------------------------------------------------------------------
func _get_party() -> Node:
	return get_tree().root.get_node_or_null("Party")

func _get_ability_system() -> Node:
	return get_tree().root.get_node_or_null("AbilitySys")

# -------------------------------------------------------------------
# Party switching
# -------------------------------------------------------------------
func _on_party_changed(_members: Array = []) -> void:
	_bind_to_current_controlled()
	_auto_unlock_zero_cost_for_current_actor()
	_refresh_sheet_all()
	_push_points_to_sheet()

func _on_party_controlled_changed(current: Node) -> void:
	_actor = current
	_rebind_level_component()
	_auto_unlock_zero_cost_for_current_actor()
	_refresh_sheet_all()
	_push_points_to_sheet()

func _bind_to_current_controlled() -> void:
	_actor = null
	var party: Node = _get_party()
	if party != null and party.has_method("get_controlled"):
		var n: Variant = party.call("get_controlled")
		if n is Node:
			_actor = n as Node
	_rebind_level_component()

func _rebind_level_component() -> void:
	_level = null
	if _actor == null:
		return

	if level_component_relative != NodePath():
		var try_node: Node = _actor.get_node_or_null(level_component_relative)
		if try_node is LevelComponent:
			_level = try_node as LevelComponent

	if _level == null:
		_level = _find_level_component(_actor)

	if _level != null and _level.has_signal("skill_points_changed"):
		if not _level.is_connected("skill_points_changed", Callable(self, "_on_skill_points_changed")):
			_level.connect("skill_points_changed", Callable(self, "_on_skill_points_changed"))

func _find_level_component(root: Node) -> LevelComponent:
	if root == null:
		return null
	for c in root.get_children():
		if c is LevelComponent:
			return c as LevelComponent
	var stack: Array[Node] = []
	for c in root.get_children():
		stack.append(c)
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n is LevelComponent:
			return n as LevelComponent
		for c in n.get_children():
			stack.append(c)
	return null

func _on_skill_points_changed(unspent: int, _total_awarded: int) -> void:
	_push_points_to_sheet()
	_update_affordability_on_rows()

# -------------------------------------------------------------------
# AbilitySys registration (inspector list)
# With handler scripts removed, this simply marks IDs to avoid repeated work.
# Keep this in place so we can re-enable real registration later without refactors.
# -------------------------------------------------------------------
func _register_handlers_with_ability_system() -> void:
	if _registered_once:
		return
	var ability_sys: Node = _get_ability_system()
	# ability_sys may be unused now; we keep the lookup for future wiring.
	var i: int = 0
	while i < ability_defs.size():
		var def: AbilityDef = ability_defs[i]
		_register_one_handler(ability_sys, def)
		i += 1
	_registered_once = true

# Register for a provided set of defs (class-driven)
func _register_handlers_for_defs(defs: Array[AbilityDef]) -> void:
	var ability_sys: Node = _get_ability_system()
	var i: int = 0
	while i < defs.size():
		var def: AbilityDef = defs[i]
		_register_one_handler(ability_sys, def)
		i += 1

func _register_one_handler(_ability_sys: Node, def: AbilityDef) -> void:
	if def == null:
		return
	if def.ability_id == "":
		return
	# Guard: avoid double-registration
	if _registered_ids.has(def.ability_id):
		return

	# Handler scripts are removed; no external registration calls here.
	# If later you add a lightweight AbilitySys API (e.g., register_def(def)),
	# we can call it here. For now, just mark as "registered".
	_registered_ids[def.ability_id] = true

# -------------------------------------------------------------------
# Sheet → points + population
# -------------------------------------------------------------------
func _push_points_to_sheet() -> void:
	if _sheet == null:
		return
	if not _sheet.has_method("set_points"):
		return
	var unspent: int = 0
	if _level != null and _level.has_method("get_unspent_skill_points"):
		unspent = _level.get_unspent_skill_points()
	_sheet.call("set_points", 0, unspent)
	_update_affordability_on_rows()

func _refresh_sheet_all() -> void:
	if _sheet == null:
		return

	# Preferred: populate from the actor's ClassDefinition using directory-driven sections
	if populate_from_class:
		var cls: ClassDefinition = _get_current_class_def()
		if cls != null:
			_refresh_sheet_from_class(cls)
			return

	# Fallback: original inspector-defined list
	var sections: Array = [[], [], [], []]

	var i: int = 0
	while i < ability_defs.size():
		var def: AbilityDef = ability_defs[i]
		if def != null:
			var idx: int = _safe_section_index(def)

			var id_str: String = def.ability_id
			var show_name: String = def.display_name
			var show_icon: Texture2D = def.icon
			var show_desc: String = def.description

			var unlocked: bool = _actor_has_ability(id_str)
			var entry := {
				"ability_id": id_str,
				"name": show_name,
				"cost": _get_unlock_cost(def),
				"icon": show_icon,
				"unlocked": unlocked,
				"level": _get_level(def),
				"description": show_desc
			}
			sections[idx].append(entry)
		i += 1

	var s: int = 0
	while s < 4:
		if _sheet.has_method("populate_panel"):
			_sheet.call("populate_panel", s, sections[s])
		s += 1

	_update_affordability_on_rows()

# --------- CLASS-DRIVEN POPULATION (directory scan via ClassDefinition) ---------

func _refresh_sheet_from_class(cls: ClassDefinition) -> void:
	# Update section names on the sheet if supported
	if _sheet.has_method("set_section_names"):
		var names: PackedStringArray = cls.get_skilltree_section_names()
		if names.size() == 4:
			_sheet.call("set_section_names", names)

	# Build entries for each of the four sections AND collect defs to register
	var by_section_paths: Array = cls.list_ability_def_paths_by_section()  # [PackedStringArray, x4]
	var collected_defs: Array[AbilityDef] = []
	var section_index: int = 0
	while section_index < 4:
		var entries: Array = []
		if section_index < by_section_paths.size():
			var paths_any: Variant = by_section_paths[section_index]
			if typeof(paths_any) == TYPE_PACKED_STRING_ARRAY:
				var files: PackedStringArray = paths_any
				var j: int = 0
				while j < files.size():
					var path: String = files[j]
					var def: AbilityDef = _load_ability_def(path)
					if def != null:
						collected_defs.append(def)
						var entry: Dictionary = _entry_for_def(def)
						entries.append(entry)
					j += 1
		if _sheet.has_method("populate_panel"):
			_sheet.call("populate_panel", section_index, entries)
		section_index += 1

	# Mark defs as registered (no external calls while handlers are removed)
	_register_handlers_for_defs(collected_defs)

	_update_affordability_on_rows()

func _load_ability_def(res_path: String) -> AbilityDef:
	if res_path == "":
		return null
	var any_res: Variant = ResourceLoader.load(res_path)
	if any_res is AbilityDef:
		return any_res as AbilityDef
	if any_res is Resource:
		var r: Resource = any_res
		if r.has_method("get"):
			var v: Variant = r.get("ability_id")
			if typeof(v) == TYPE_STRING:
				return r as AbilityDef
	return null

func _entry_for_def(def: AbilityDef) -> Dictionary:
	var id_str: String = ""
	var show_name: String = ""
	var show_icon: Texture2D = null
	var cost: int = 1
	var show_desc: String = ""

	if def != null:
		id_str = def.ability_id
		show_name = def.display_name
		show_icon = def.icon
		show_desc = def.description
		cost = _get_unlock_cost(def)

	var unlocked: bool = _actor_has_ability(id_str)

	var entry: Dictionary = {
		"ability_id": id_str,
		"name": show_name,
		"cost": cost,
		"icon": show_icon,
		"unlocked": unlocked,
		"level": _get_level(def),
		"description": show_desc
	}
	return entry

func _get_current_class_def() -> ClassDefinition:
	if _level == null:
		return null
	# Prefer a method API on LevelComponent if it exists
	if _level.has_method("get_class_def"):
		var v: Variant = _level.call("get_class_def")
		if v is ClassDefinition:
			return v as ClassDefinition
	# Fall back to a property if the LevelComponent exposes it
	if "class_def" in _level:
		var cd: Variant = _level.get("class_def")
		if cd is ClassDefinition:
			return cd as ClassDefinition
	return null

# -------------------------------------------------------------------
# Actor ability storage (KnownAbilities first)
# -------------------------------------------------------------------
func _actor_has_ability(ability_id: String) -> bool:
	if _actor == null or ability_id == "":
		return false

	var kac: KnownAbilitiesComponent = _find_known_abilities_component(_actor)
	if kac != null:
		return kac.has_ability(ability_id)

	if _actor.has_method("has_ability"):
		var ok_any: Variant = _actor.call("has_ability", ability_id)
		if typeof(ok_any) == TYPE_BOOL:
			return bool(ok_any)

	if "known_abilities" in _actor:
		var arr_any: Variant = _actor.get("known_abilities")
		if typeof(arr_any) == TYPE_ARRAY:
			var arr: Array = arr_any
			return arr.has(ability_id)

	return false

func _add_ability_to_actor(ability_id: String) -> void:
	if _actor == null or ability_id == "":
		return
	if _actor_has_ability(ability_id):
		return

	var kac: KnownAbilitiesComponent = _ensure_known_component(_actor)
	if kac != null:
		kac.add_ability(ability_id)
		_emit_unlocked(ability_id)
		return

	if _actor.has_method("add_ability"):
		_actor.call("add_ability", ability_id)
		_emit_unlocked(ability_id)
		return

	if "known_abilities" in _actor:
		var arr_any2: Variant = _actor.get("known_abilities")
		if typeof(arr_any2) == TYPE_ARRAY:
			var arr2: Array = arr_any2
			if not arr2.has(ability_id):
				arr2.append(ability_id)
				_actor.set("known_abilities", arr2)
				_emit_unlocked(ability_id)

func _emit_unlocked(ability_id: String) -> void:
	emit_signal("ability_unlocked", _actor, ability_id)
	emit_signal("debug", "Unlocked: " + ability_id)

# UPDATED: prefer any existing KnownAbilitiesComponent, whatever its node name.
func _find_known_abilities_component(root: Node) -> KnownAbilitiesComponent:
	if root == null:
		return null

	# 1) Direct child named "KnownAbilities" (canonical)
	var direct: Node = root.get_node_or_null("KnownAbilities")
	if direct != null and direct is KnownAbilitiesComponent:
		return direct as KnownAbilitiesComponent

	# 2) Direct child named "KnownAbilitiesComponent" (older scenes)
	var compat: Node = root.get_node_or_null("KnownAbilitiesComponent")
	if compat != null and compat is KnownAbilitiesComponent:
		return compat as KnownAbilitiesComponent

	# 3) Deep search for a child named "KnownAbilities"
	var deep_named: Node = root.find_child("KnownAbilities", true, false)
	if deep_named != null and deep_named is KnownAbilitiesComponent:
		return deep_named as KnownAbilitiesComponent

	# 4) Fallback: BFS by type (any KnownAbilitiesComponent, any name)
	var queue: Array[Node] = [root]
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur is KnownAbilitiesComponent:
			return cur as KnownAbilitiesComponent
		for c in cur.get_children():
			queue.append(c)

	return null

func _ensure_known_component(actor: Node) -> KnownAbilitiesComponent:
	if actor == null:
		return null

	# Reuse any existing component first (prevents duplicate runtime nodes).
	var kac: KnownAbilitiesComponent = _find_known_abilities_component(actor)
	if kac != null:
		return kac

	# Only if none exists, create a new canonical node named "KnownAbilities"
	var n := KnownAbilitiesComponent.new()
	n.name = "KnownAbilities"
	actor.add_child(n)
	return n

# -------------------------------------------------------------------
# Affordability tint
# -------------------------------------------------------------------
func _update_affordability_on_rows() -> void:
	if _sheet == null:
		return

	var unspent: int = 0
	if _level != null and _level.has_method("get_unspent_skill_points"):
		unspent = _level.get_unspent_skill_points()

	var s: int = 0
	while s < 4:
		var vb: VBoxContainer = _get_panel_vbox(s)
		if vb != null:
			for c in vb.get_children():
				var cost: int = 0
				var locked: bool = false
				if c.has_method("get"):
					var cv: Variant = c.get("cost_points")
					if typeof(cv) == TYPE_INT:
						cost = int(cv)
					var lv: Variant = c.get("locked")
					if typeof(lv) == TYPE_BOOL:
						locked = bool(lv)
				if locked and c.has_method("set_affordable"):
					c.call("set_affordable", unspent >= cost)
		s += 1

func _get_panel_vbox(index: int) -> VBoxContainer:
	if not _sheet.has_method("get_panel_vbox"):
		return null
	var vb_any: Variant = _sheet.call("get_panel_vbox", index)
	if vb_any is VBoxContainer:
		return vb_any as VBoxContainer
	return null

# -------------------------------------------------------------------
# Purchase flow
# -------------------------------------------------------------------
func _on_sheet_purchase_requested(ability_id: String, cost_points: int) -> void:
	if _actor == null:
		return
	if ability_id == "":
		return

	if cost_points <= 0:
		_add_ability_to_actor(ability_id)
		_refresh_sheet_all()
		_push_points_to_sheet()
		return

	if _level == null:
		return
	if not _level.has_method("spend_skill_points"):
		return

	var ok: bool = _level.spend_skill_points(cost_points)
	if not ok:
		return

	_add_ability_to_actor(ability_id)
	_refresh_sheet_all()
	_push_points_to_sheet()

# -------------------------------------------------------------------
# Helpers for AbilityDef UI fields (unlock_cost/section_index/level)
# -------------------------------------------------------------------
func _get_unlock_cost(def: AbilityDef) -> int:
	if def == null:
		return 1
	if def.has_method("get"):
		var v: Variant = def.get("unlock_cost")
		if typeof(v) == TYPE_INT:
			return int(v)
	return 1

func _get_section_index(def: AbilityDef) -> int:
	if def == null:
		return 0
	if def.has_method("get"):
		var v: Variant = def.get("section_index")
		if typeof(v) == TYPE_INT:
			return int(v)
	return 0

func _safe_section_index(def: AbilityDef) -> int:
	var idx: int = _get_section_index(def)
	if idx < 0:
		idx = 0
	if idx > 3:
		idx = 3
	return idx

func _get_level(def: AbilityDef) -> int:
	if def == null:
		return 1
	if def.has_method("get"):
		var v: Variant = def.get("level")
		if typeof(v) == TYPE_INT:
			return int(v)
	return 1

# -------------------------------------------------------------------
# Zero-cost auto-unlock (inspector + class-driven)
# -------------------------------------------------------------------
func _auto_unlock_zero_cost_for_current_actor() -> void:
	if _actor == null:
		return
	var granted_any: bool = false

	# 1) Inspector-provided ability_defs
	var i: int = 0
	while i < ability_defs.size():
		var def: AbilityDef = ability_defs[i]
		if def != null and def.ability_id != "":
			_register_handlers_for_defs([def]) # still marks ids so we don't repeat work later
			var cost: int = _get_unlock_cost(def)
			if cost <= 0:
				if not _actor_has_ability(def.ability_id):
					_add_ability_to_actor(def.ability_id)
					granted_any = true
		i += 1

	# 2) Class-driven directories
	if populate_from_class:
		var cls: ClassDefinition = _get_current_class_def()
		if cls != null:
			var by_section_paths: Array = cls.list_ability_def_paths_by_section()
			var to_register: Array[AbilityDef] = []
			var s: int = 0
			while s < by_section_paths.size():
				var paths_any: Variant = by_section_paths[s]
				if typeof(paths_any) == TYPE_PACKED_STRING_ARRAY:
					var files: PackedStringArray = paths_any
					var j: int = 0
					while j < files.size():
						var path: String = files[j]
						var def2: AbilityDef = _load_ability_def(path)
						if def2 != null and def2.ability_id != "":
							to_register.append(def2)
							var c2: int = _get_unlock_cost(def2)
							if c2 <= 0:
								if not _actor_has_ability(def2.ability_id):
									_add_ability_to_actor(def2.ability_id)
									granted_any = true
						j += 1
				s += 1
			_register_handlers_for_defs(to_register)

	if granted_any:
		emit_signal("debug", "Zero-cost abilities granted; refreshing sheet.")
		_refresh_sheet_all()
		_push_points_to_sheet()
