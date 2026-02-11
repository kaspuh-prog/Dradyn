extends Node
class_name HotbarSystem
# Godot 4.5 — fully typed, no ternaries.
# Autoload provider for “what’s in the hotbar?” so Player.gd (and others) can query by index.
# Mirrors the scene Hotbar via signals; avoids poking at its internals.

signal slot_changed(slot_index: int, entry_type: String, entry_id: String)
signal slot_triggered(slot_index: int, entry_type: String, entry_id: String)
signal hotbar_bound(hotbar_path: NodePath)

@export var debug_log: bool = true
@export var default_slot_count: int = 8

# Optional: limit to abilities only (ignores other entry types if you add them later).
@export var abilities_only: bool = true

# Cached model of the CURRENTLY ACTIVE ACTOR'S hotbar (ability ids per slot index).
var _ability_ids: Array[String] = []
var _slot_count: int = 0

# Per-actor profiles: actor_key -> Array[String] of ability_ids
var _profiles: Dictionary = {}

# Which actor's profile is currently active?
var _active_actor_key: String = ""

# Bound scene Hotbar (class_name Hotbar from your project)
var _hotbar: Node = null

# Guard to prevent UI programmatic assigns from writing back into profiles via signals.
var _applying_profile_to_ui: bool = false

func _ready() -> void:
	_reset_model(default_slot_count)
	_hook_party_signals()
	# Try to bind immediately, then also watch the tree for late spawns / area swaps.
	_try_bind_automatically()
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.node_added.connect(_on_node_added)
		tree.node_removed.connect(_on_node_removed)

# -------------------------------------------------------------------------
# Public API (provider used by Player.gd)
# -------------------------------------------------------------------------
func get_slot_count() -> int:
	return _slot_count

func get_ability_id_at(index: int) -> String:
	if index < 0:
		return ""
	if index >= _ability_ids.size():
		return ""
	return _ability_ids[index]

# Convenience: let callers bind explicitly if they have a reference.
func bind_to_hotbar(node: Node) -> void:
	_bind_to_hotbar(node)

# -------------------------------------------------------------------------
# NEW: Save/Load helpers (stable by PARTY ORDER, not by actor key)
# -------------------------------------------------------------------------
func get_profile_for_actor(actor: Node) -> Array[String]:
	var key: String = _make_actor_key(actor)
	if key == "":
		return _make_empty_profile(_slot_count)

	if not _profiles.has(key):
		_profiles[key] = _make_empty_profile(_slot_count)

	var any: Variant = _profiles[key]
	if typeof(any) != TYPE_ARRAY:
		_profiles[key] = _make_empty_profile(_slot_count)

	var arr: Array = _profiles[key]
	return _copy_profile_array(_array_to_string_array(arr), _slot_count)

func set_profile_for_actor(actor: Node, profile: Array[String]) -> void:
	var key: String = _make_actor_key(actor)
	if key == "":
		return

	_profiles[key] = _copy_profile_array(profile, _slot_count)

	# If this actor is currently active, apply immediately.
	if key == _active_actor_key:
		var prof_any: Variant = _profiles[key]
		var prof: Array = []
		if typeof(prof_any) == TYPE_ARRAY:
			prof = prof_any as Array
		_apply_profile_to_model(prof)
		_apply_profile_to_hotbar_ui(prof)

func export_party_profiles(party_members: Array) -> Array:
	# Returns Array where each entry is Array[String] for that party index.
	# SaveSystem should store this array alongside the party member list/order.
	var out: Array = []

	# Make sure we persist the current active profile before exporting.
	_save_active_profile()

	var i: int = 0
	while i < party_members.size():
		var actor: Node = party_members[i] as Node
		var prof: Array[String] = get_profile_for_actor(actor)
		out.append(prof)
		i += 1

	return out

func import_party_profiles(party_members: Array, saved_profiles: Array) -> void:
	# Apply profiles by party order. Extra entries ignored. Missing entries -> empty.
	var i: int = 0
	while i < party_members.size():
		var actor: Node = party_members[i] as Node
		if actor == null:
			i += 1
			continue

		var prof: Array[String] = _make_empty_profile(_slot_count)
		if i < saved_profiles.size():
			var any: Variant = saved_profiles[i]
			if typeof(any) == TYPE_ARRAY:
				var arr: Array = any as Array
				prof = _copy_profile_array(_array_to_string_array(arr), _slot_count)

		set_profile_for_actor(actor, prof)
		i += 1

	# Re-apply active actor to UI/model after imports.
	var party := get_node_or_null("/root/Party")
	if party != null and party.has_method("get_controlled"):
		var cur_any: Variant = party.call("get_controlled")
		var cur: Node = cur_any as Node
		_switch_active_actor(cur)

# -------------------------------------------------------------------------
# Internal: Party wiring (follow the controlled member)
# -------------------------------------------------------------------------
func _hook_party_signals() -> void:
	# Autoload name is "Party" (project.godot -> Party="*res://AutoLoads/PartyManager.gd")
	var party := get_node_or_null("/root/Party")
	if party != null:
		if not party.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
			party.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
		# Initialize from current controlled if available
		if party.has_method("get_controlled"):
			var cur_any: Variant = party.call("get_controlled")
			var cur: Node = cur_any as Node
			_switch_active_actor(cur)
	else:
		# Fallback: try group lookup if autoload not ready yet
		var pm := get_tree().get_first_node_in_group("PartyManager")
		if pm != null:
			if not pm.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
				pm.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
			if pm.has_method("get_controlled"):
				var cur2_any: Variant = pm.call("get_controlled")
				var cur2: Node = cur2_any as Node
				_switch_active_actor(cur2)

func _on_party_controlled_changed(current: Node) -> void:
	_switch_active_actor(current)

func _switch_active_actor(actor: Node) -> void:
	var key: String = _make_actor_key(actor)
	if key == _active_actor_key:
		return

	# Save current active profile before switching (ensure we keep changes)
	_save_active_profile()

	_active_actor_key = key

	# Load or init the new actor's profile
	if not _profiles.has(_active_actor_key):
		_profiles[_active_actor_key] = _make_empty_profile(_slot_count)

	var prof: Array = _profiles[_active_actor_key]
	_apply_profile_to_model(prof)
	_apply_profile_to_hotbar_ui(prof)

	if debug_log:
		print("[HotbarSys] Active actor switched to key=", _active_actor_key, " size=", str(_ability_ids.size()))

func _make_actor_key(actor: Node) -> String:
	if actor == null:
		return "GLOBAL"
	# Unique per instance (correct gameplay behavior). SaveSystem will store hotbars by party order.
	var name_part: String = actor.name
	var iid_part: String = str(actor.get_instance_id())
	return "Actor:" + name_part + "#iid:" + iid_part

func _save_active_profile() -> void:
	if _active_actor_key == "":
		return
	# Ensure the profile dictionary exists and matches slot count
	_profiles[_active_actor_key] = _copy_profile_array(_ability_ids, _slot_count)

func _make_empty_profile(count: int) -> Array[String]:
	var arr: Array[String] = []
	var i: int = 0
	while i < count:
		arr.append("")
		i += 1
	return arr

func _copy_profile_array(src: Array[String], count: int) -> Array[String]:
	var out: Array[String] = []
	var i: int = 0
	while i < count and i < src.size():
		out.append(src[i])
		i += 1
	# Pad if needed
	while i < count:
		out.append("")
		i += 1
	return out

func _array_to_string_array(arr: Array) -> Array[String]:
	var out: Array[String] = []
	var i: int = 0
	while i < arr.size():
		out.append(String(arr[i]))
		i += 1
	return out

# -------------------------------------------------------------------------
# Internal: binding & model sync
# -------------------------------------------------------------------------
func _try_bind_automatically() -> void:
	# Strategy: find the first node that “looks like” your Hotbar (class_name Hotbar or has the three hotbar signals).
	var root: Node = get_tree().root
	if root == null:
		return

	# Breadth-first to find closest UI hotbar.
	var queue: Array[Node] = [root]
	while queue.size() > 0:
		var n: Node = queue.pop_front()
		if _looks_like_hotbar(n):
			_bind_to_hotbar(n)
			return
		for c in n.get_children():
			queue.push_back(c)

func _looks_like_hotbar(n: Node) -> bool:
	if n == null:
		return false
	# Best: type check on your class_name
	if n.get_class() == "Hotbar":
		return true
	# Fallback: signal signature checks.
	var has_assign: bool = n.has_signal("slot_assigned")
	var has_clear: bool = n.has_signal("slot_cleared")
	var has_trig: bool = n.has_signal("slot_triggered")
	if has_assign and has_clear and has_trig:
		return true
	return false

func _bind_to_hotbar(n: Node) -> void:
	_unbind_hotbar()

	if n == null:
		return

	_hotbar = n
	# Determine slot count from the Hotbar if possible (based on its exported slot_positions).
	var count: int = default_slot_count
	if "slot_positions" in _hotbar:
		var v: Variant = _hotbar.get("slot_positions")
		if typeof(v) == TYPE_PACKED_VECTOR2_ARRAY:
			var arr: PackedVector2Array = v
			if arr.size() > 0:
				count = arr.size()

	_reset_model(count)

	# Connect signals
	if _hotbar.has_signal("slot_assigned"):
		if not _hotbar.is_connected("slot_assigned", Callable(self, "_on_hotbar_slot_assigned")):
			_hotbar.connect("slot_assigned", Callable(self, "_on_hotbar_slot_assigned"))

	if _hotbar.has_signal("slot_cleared"):
		if not _hotbar.is_connected("slot_cleared", Callable(self, "_on_hotbar_slot_cleared")):
			_hotbar.connect("slot_cleared", Callable(self, "_on_hotbar_slot_cleared"))

	if _hotbar.has_signal("slot_triggered"):
		if not _hotbar.is_connected("slot_triggered", Callable(self, "_on_hotbar_slot_triggered")):
			_hotbar.connect("slot_triggered", Callable(self, "_on_hotbar_slot_triggered"))

	if debug_log:
		print("[HotbarSys] Bound to: ", _hotbar.get_path())
	hotbar_bound.emit(_hotbar.get_path())

	# Apply current actor profile onto this newly bound UI
	if _active_actor_key == "":
		# If we haven't picked an actor yet, try now
		_hook_party_signals()
	if _active_actor_key != "":
		if not _profiles.has(_active_actor_key):
			_profiles[_active_actor_key] = _make_empty_profile(_slot_count)
		var prof: Array = _profiles[_active_actor_key]
		_apply_profile_to_model(prof)
		_apply_profile_to_hotbar_ui(prof)

func _unbind_hotbar() -> void:
	if _hotbar == null:
		return
	if _hotbar.has_signal("slot_assigned"):
		if _hotbar.is_connected("slot_assigned", Callable(self, "_on_hotbar_slot_assigned")):
			_hotbar.disconnect("slot_assigned", Callable(self, "_on_hotbar_slot_assigned"))
	if _hotbar.has_signal("slot_cleared"):
		if _hotbar.is_connected("slot_cleared", Callable(self, "_on_hotbar_slot_cleared")):
			_hotbar.disconnect("slot_cleared", Callable(self, "_on_hotbar_slot_cleared"))
	if _hotbar.has_signal("slot_triggered"):
		if _hotbar.is_connected("slot_triggered", Callable(self, "_on_hotbar_slot_triggered")):
			_hotbar.disconnect("slot_triggered", Callable(self, "_on_hotbar_slot_triggered"))
	_hotbar = null

func _reset_model(count: int) -> void:
	_slot_count = max(0, count)
	_ability_ids.clear()
	var i: int = 0
	while i < _slot_count:
		_ability_ids.append("")
		i += 1

# -------------------------------------------------------------------------
# Profile <-> Model/UI application
# -------------------------------------------------------------------------
func _apply_profile_to_model(profile: Array) -> void:
	# Copy into _ability_ids respecting slot_count
	var i: int = 0
	while i < _slot_count:
		if i < profile.size():
			var v: Variant = profile[i]
			if typeof(v) == TYPE_STRING:
				_ability_ids[i] = String(v)
			else:
				_ability_ids[i] = ""
		else:
			_ability_ids[i] = ""
		i += 1

func _apply_profile_to_hotbar_ui(profile: Array) -> void:
	if _hotbar == null:
		return
	# Programmatically assign/clear each slot to match the profile.
	var has_assign: bool = _hotbar.has_method("_assign")
	var has_clear: bool = _hotbar.has_method("_clear")
	if not has_assign or not has_clear:
		if debug_log:
			print("[HotbarSys] Hotbar lacks _assign/_clear; UI won’t reflect profile programmatically.")
		return

	_applying_profile_to_ui = true

	var i: int = 0
	while i < _slot_count:
		var id_str: String = ""
		if i < profile.size():
			var v: Variant = profile[i]
			if typeof(v) == TYPE_STRING:
				id_str = String(v)

		if id_str == "":
			_hotbar.call("_clear", i)
		else:
			_hotbar.call("_assign", i, "ability", id_str)
		i += 1

	_applying_profile_to_ui = false

# -------------------------------------------------------------------------
# Hotbar signal handlers
# -------------------------------------------------------------------------
func _on_hotbar_slot_assigned(slot_index: int, entry_type: String, entry_id: String) -> void:
	if _applying_profile_to_ui:
		return

	if debug_log:
		print("[HotbarSys] assigned idx=", slot_index, " type=", entry_type, " id=", entry_id)
	if slot_index < 0:
		return
	if slot_index >= _slot_count:
		return

	if abilities_only:
		if entry_type != "ability":
			# Track only abilities; empty the provider slot for other kinds.
			_ability_ids[slot_index] = ""
			slot_changed.emit(slot_index, entry_type, entry_id)
			# Persist into the active profile too
			_write_back_active_profile(slot_index, "")
			return

	_ability_ids[slot_index] = entry_id
	_write_back_active_profile(slot_index, entry_id)
	slot_changed.emit(slot_index, entry_type, entry_id)

func _on_hotbar_slot_cleared(slot_index: int) -> void:
	if _applying_profile_to_ui:
		return

	if debug_log:
		print("[HotbarSys] cleared idx=", slot_index)
	if slot_index < 0:
		return
	if slot_index >= _slot_count:
		return
	_ability_ids[slot_index] = ""
	_write_back_active_profile(slot_index, "")
	slot_changed.emit(slot_index, "", "")

func _on_hotbar_slot_triggered(slot_index: int, entry_type: String, entry_id: String) -> void:
	# We forward this in case other systems want to react (e.g., tutorial pips).
	slot_triggered.emit(slot_index, entry_type, entry_id)

func _write_back_active_profile(slot_index: int, ability_id: String) -> void:
	if _active_actor_key == "":
		return
	if not _profiles.has(_active_actor_key):
		_profiles[_active_actor_key] = _make_empty_profile(_slot_count)
	var arr: Array = _profiles[_active_actor_key]
	# Ensure size
	var i: int = arr.size()
	while i < _slot_count:
		arr.append("")
		i += 1
	arr[slot_index] = ability_id
	_profiles[_active_actor_key] = arr

# -------------------------------------------------------------------------
# Tree watchers (rebind on area swaps / scene changes)
# -------------------------------------------------------------------------
func _on_node_added(n: Node) -> void:
	# If we have no hotbar, try binding to this one.
	if _hotbar == null and _looks_like_hotbar(n):
		_bind_to_hotbar(n)

func _on_node_removed(n: Node) -> void:
	if n == _hotbar:
		if debug_log:
			print("[HotbarSys] hotbar removed; waiting to rebind…")
		_unbind_hotbar()
		_reset_model(default_slot_count)
