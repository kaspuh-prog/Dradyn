extends Node
class_name SummonedPetsComponent
# Godot 4.5 — fully typed, no ternaries.
#
# Responsibilities:
# - Store shared pet mode for this summoner
# - Track active pets (FIFO)
# - Enforce max pets by level (1 + floor(level / unlock_step_levels), clamped)
# - Replace oldest pet when at cap
# - Keep pets from "staying behind" across area swaps by relocating them to summoner

enum PetMode {
	AGGRESSIVE = 0,
	DEFENSIVE = 1,
	PASSIVE = 2,
	SUPPORT = 3,
}

@export var debug_logs: bool = false

# Where to find the LevelComponent for this summoner.
# If empty, we’ll search on the owning actor.
@export var level_component_path: NodePath

# Baseline rules per GDD:
# - up to 3 pets (baseline)
# - +1 slot every 15 levels (lvl < 15 => 1, lvl 15 => 2, lvl 30 => 3)
@export var unlock_step_levels: int = 15
@export var baseline_cap: int = 3

# Future-proof: equipment/abilities can add slots later.
# For now keep this at 0.
@export var bonus_slots: int = 0

# NEW: If true, relocate active pets to the summoner when the area changes.
# This prevents pets from being left at old coordinates and ending up inside walls in the new area.
@export var relocate_pets_on_area_changed: bool = true

# NEW: How far (in pixels) to spread pets around the summoner after relocation.
@export var relocate_spread_px: float = 18.0

signal pet_mode_changed(mode: int)
signal pet_list_changed()

var _pet_mode: int = PetMode.AGGRESSIVE
var _active_pets: Array[Node] = []

var _scene_mgr: Node = null
var _scene_mgr_connected: bool = false

func _ready() -> void:
	# Ensure we start in a valid mode.
	_pet_mode = _clamp_mode(_pet_mode)

	_try_bind_scene_mgr()

func _exit_tree() -> void:
	# Defensive disconnect (harmless if not connected).
	_try_unbind_scene_mgr()

func get_pet_mode() -> int:
	return _pet_mode

func set_pet_mode(mode: int) -> void:
	var new_mode: int = _clamp_mode(mode)
	if new_mode == _pet_mode:
		return

	_pet_mode = new_mode
	if debug_logs:
		print("[SummonedPetsComponent] Mode set to: ", _mode_name(_pet_mode))

	emit_signal("pet_mode_changed", _pet_mode)
	_broadcast_mode_to_pets()

func get_active_pets() -> Array[Node]:
	# Return a shallow copy so callers can’t mutate our roster.
	var out: Array[Node] = []
	for p in _active_pets:
		out.append(p)
	return out

func max_pets_current() -> int:
	var level: int = _get_level()
	if level < 1:
		level = 1

	var step: int = unlock_step_levels
	if step < 1:
		step = 15

	var slots_from_level: int = 1 + int(floor(float(level) / float(step)))
	var cap_total: int = baseline_cap + bonus_slots
	if cap_total < 1:
		cap_total = 1

	if slots_from_level > cap_total:
		slots_from_level = cap_total

	return slots_from_level

func is_at_cap() -> bool:
	return _active_pets.size() >= max_pets_current()

func register_pet(pet: Node) -> void:
	if pet == null:
		return

	# Remove invalids before we enforce cap.
	_prune_invalid_pets()

	# FIFO replace policy when at cap.
	while _active_pets.size() >= max_pets_current():
		despawn_oldest_pet()

	# Avoid duplicates.
	if _active_pets.has(pet):
		return

	_active_pets.append(pet)

	# Auto-unregister when the pet leaves the tree.
	if not pet.tree_exited.is_connected(_on_pet_tree_exited.bind(pet)):
		pet.tree_exited.connect(_on_pet_tree_exited.bind(pet))

	# NEW: Bind summoner into the pet brain if supported.
	_bind_summoner_to_pet(pet)

	# Push current mode into the new pet immediately.
	_push_mode_to_pet(pet)

	# NEW: If we already have an active area (or are mid-session), optionally snap this pet near the summoner.
	if relocate_pets_on_area_changed:
		_relocate_single_pet_near_summoner(pet, _active_pets.size() - 1)

	if debug_logs:
		print("[SummonedPetsComponent] Registered pet. Count = ", _active_pets.size(), " / ", max_pets_current())

	emit_signal("pet_list_changed")

func unregister_pet(pet: Node) -> void:
	if pet == null:
		return

	var idx: int = _active_pets.find(pet)
	if idx == -1:
		return

	_active_pets.remove_at(idx)

	if debug_logs:
		print("[SummonedPetsComponent] Unregistered pet. Count = ", _active_pets.size(), " / ", max_pets_current())

	emit_signal("pet_list_changed")

func despawn_oldest_pet() -> void:
	_prune_invalid_pets()
	if _active_pets.size() == 0:
		return

	var oldest: Node = _active_pets[0]
	_active_pets.remove_at(0)

	if debug_logs:
		print("[SummonedPetsComponent] Despawning oldest pet (FIFO).")

	# Prefer a graceful despawn hook if you add one later.
	if oldest != null:
		if oldest.has_method("request_despawn"):
			oldest.call("request_despawn")
		elif oldest.has_method("despawn"):
			oldest.call("despawn")
		else:
			oldest.queue_free()

	emit_signal("pet_list_changed")

func despawn_all_pets() -> void:
	_prune_invalid_pets()
	while _active_pets.size() > 0:
		despawn_oldest_pet()

# --- Internal helpers ---

func _try_bind_scene_mgr() -> void:
	_scene_mgr = get_node_or_null("/root/SceneMgr")
	if _scene_mgr == null:
		if debug_logs:
			print("[SummonedPetsComponent] SceneMgr not found at /root/SceneMgr; pets will not auto-relocate on area change.")
		return

	# Connect to area changes so pets don't get left at old coordinates.
	if not _scene_mgr.has_signal("area_changed"):
		if debug_logs:
			print("[SummonedPetsComponent] SceneMgr has no signal 'area_changed'; pets will not auto-relocate on area change.")
		return

	if not _scene_mgr_connected:
		var callable: Callable = Callable(self, "_on_area_changed")
		if not _scene_mgr.is_connected("area_changed", callable):
			_scene_mgr.connect("area_changed", callable)
		_scene_mgr_connected = true

		if debug_logs:
			print("[SummonedPetsComponent] Bound to SceneMgr.area_changed for pet relocation.")

func _try_unbind_scene_mgr() -> void:
	if _scene_mgr == null:
		return
	if not _scene_mgr_connected:
		return
	if not _scene_mgr.has_signal("area_changed"):
		_scene_mgr_connected = false
		return

	var callable: Callable = Callable(self, "_on_area_changed")
	if _scene_mgr.is_connected("area_changed", callable):
		_scene_mgr.disconnect("area_changed", callable)

	_scene_mgr_connected = false

func _on_area_changed(_area: Node, _entry_tag: String) -> void:
	if not relocate_pets_on_area_changed:
		return

	_prune_invalid_pets()

	if _active_pets.size() == 0:
		return

	var actor: Node = _resolve_actor_root()
	if actor == null:
		return
	if not (actor is Node2D):
		return

	var summoner_2d: Node2D = actor as Node2D

	if debug_logs:
		print("[SummonedPetsComponent] Area changed; relocating pets to summoner: ", summoner_2d.name, " count=", _active_pets.size())

	# Move each pet near the summoner's (already teleported) position.
	var idx: int = 0
	for p in _active_pets:
		_relocate_single_pet_to_anchor(p, summoner_2d.global_position, idx)
		idx += 1

func _relocate_single_pet_near_summoner(pet: Node, idx: int) -> void:
	var actor: Node = _resolve_actor_root()
	if actor == null:
		return
	if not (actor is Node2D):
		return

	var summoner_2d: Node2D = actor as Node2D
	_relocate_single_pet_to_anchor(pet, summoner_2d.global_position, idx)

func _relocate_single_pet_to_anchor(pet: Node, anchor_global: Vector2, idx: int) -> void:
	if pet == null:
		return
	if not is_instance_valid(pet):
		return
	if not (pet is Node2D):
		return

	var pet_2d: Node2D = pet as Node2D

	# Deterministic spread pattern: cycle around the summoner in 8 directions.
	var spread: float = relocate_spread_px
	if spread < 0.0:
		spread = 0.0

	var offsets: Array[Vector2] = [
		Vector2(1.0, 0.0),
		Vector2(-1.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(0.0, -1.0),
		Vector2(1.0, 1.0),
		Vector2(-1.0, 1.0),
		Vector2(1.0, -1.0),
		Vector2(-1.0, -1.0),
	]

	var use_idx: int = idx % offsets.size()
	var dir: Vector2 = offsets[use_idx]
	if dir.length() > 0.0:
		dir = dir.normalized()

	var new_pos: Vector2 = anchor_global + (dir * spread)

	pet_2d.global_position = new_pos

	# Optional hooks for pet brains / navigation to reset after teleport.
	if pet.has_method("on_owner_area_changed"):
		pet.call("on_owner_area_changed")
	if pet.has_method("on_owner_teleported"):
		pet.call("on_owner_teleported")
	if pet.has_method("force_repath"):
		pet.call("force_repath")

func _on_pet_tree_exited(pet: Node) -> void:
	# Pet got freed or removed; keep roster clean.
	unregister_pet(pet)

func _broadcast_mode_to_pets() -> void:
	_prune_invalid_pets()
	for p in _active_pets:
		_push_mode_to_pet(p)

func _push_mode_to_pet(pet: Node) -> void:
	if pet == null:
		return

	# SummonedAI should implement one of these.
	if pet.has_method("on_owner_pet_mode_changed"):
		pet.call("on_owner_pet_mode_changed", _pet_mode)
	elif pet.has_method("set_pet_mode"):
		pet.call("set_pet_mode", _pet_mode)

func _bind_summoner_to_pet(pet: Node) -> void:
	if pet == null:
		return

	var actor: Node = _resolve_actor_root()
	if actor == null:
		return
	if not (actor is Node2D):
		return

	var summoner_2d: Node2D = actor as Node2D

	# SummonedAI uses set_summoner(Node2D).
	if pet.has_method("set_summoner"):
		pet.call("set_summoner", summoner_2d)
		if debug_logs:
			print("[SummonedPetsComponent] Bound summoner to pet: ", pet.name, " owner=", summoner_2d.name)

func _prune_invalid_pets() -> void:
	var i: int = _active_pets.size() - 1
	while i >= 0:
		var p: Node = _active_pets[i]
		if p == null:
			_active_pets.remove_at(i)
		elif not is_instance_valid(p):
			_active_pets.remove_at(i)
		i -= 1

func _get_level() -> int:
	var lc: Node = _resolve_level_component()
	if lc == null:
		return 1

	# LevelComponent.gd exports `level:int`, so try property first.
	if lc.has_method("get"):
		var v: Variant = lc.get("level")
		if typeof(v) == TYPE_INT:
			return int(v)

	# Fallback: if you ever add a getter, we’ll support it.
	if lc.has_method("get_level"):
		var vv: Variant = lc.call("get_level")
		if typeof(vv) == TYPE_INT:
			return int(vv)

	return 1

func _resolve_level_component() -> Node:
	var actor: Node = _resolve_actor_root()
	if actor == null:
		return null

	if level_component_path != NodePath():
		var n: Node = actor.get_node_or_null(level_component_path)
		if n != null:
			return n

	# Common convention in your actor scenes.
	var by_name: Node = actor.get_node_or_null("LevelComponent")
	if by_name != null:
		return by_name

	# BFS fallback (safe for odd scene layouts)
	var queue: Array[Node] = [actor]
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur.name == "LevelComponent" or cur.get_class() == "LevelComponent":
			return cur
		for c in cur.get_children():
			queue.push_back(c)

	return null

func _resolve_actor_root() -> Node:
	# Owning actor is normally the parent of this component; fall back to owner.
	if get_parent() != null:
		return get_parent()
	return owner

func _clamp_mode(mode: int) -> int:
	if mode < 0:
		return PetMode.AGGRESSIVE
	if mode > 3:
		return PetMode.SUPPORT
	return mode

func _mode_name(mode: int) -> String:
	if mode == PetMode.AGGRESSIVE:
		return "AGGRESSIVE"
	if mode == PetMode.DEFENSIVE:
		return "DEFENSIVE"
	if mode == PetMode.PASSIVE:
		return "PASSIVE"
	if mode == PetMode.SUPPORT:
		return "SUPPORT"
	return "UNKNOWN"
