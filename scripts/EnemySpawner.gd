extends Node2D
class_name EnemySpawner

# ------------- Setup -------------
@export var enemy_scene: PackedScene
@export var enemy_scenes: Array[PackedScene] = []
@export var enemy_weights: PackedInt32Array = []
@export var prefer_unique_on_first_fill: bool = true

@export var max_alive: int = 2
@export var respawn_delay_sec: float = 90.0
@export var respawn_delay_min_sec: float = 5.0
@export var max_alive_per_extra_member: int = 0
@export var respawn_delay_per_extra_member_sec: float = 0.0
@export var fill_on_ready: bool = true
@export var spawn_parent: NodePath
@export var spawn_points: Array[NodePath] = []

@export var jitter_px: float = 4.0

@export var enemy_level_component_path: NodePath
@export var scale_enemy_level_to_controlled: bool = true
@export var min_scaled_level: int = 1

@export var spawn_only_at_night: bool = false
@export var despawn_spawned_on_day: bool = false
@export var day_night_node_path: NodePath = NodePath("/root/DayandNight")

# ------------- Debug -------------
@export var debug_logs: bool = false

# ------------- Internals -------------
var _points: Array[Node2D] = []
var _alive: Array[Node] = []
var _slot_by_enemy: Dictionary = {}
var _enemy_by_slot: Dictionary = {}
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _timer: Timer

var _pool_cursor: int = 0
var _dn: Node = null
var _is_day_cached: bool = true

func _dlog(msg: String) -> void:
	if not debug_logs:
		return
	print("[EnemySpawner:%s] %s" % [name, msg])

func _ready() -> void:
	_rng.randomize()
	_collect_spawn_points()
	_setup_timer()
	_connect_daynight()

	_refresh_spawn_permission(true)

	_dlog("READY: points=%d enemy_scene=%s pool=%d fill_on_ready=%s night_only=%s is_day_cached=%s spawn_parent=%s"
		% [
			_points.size(),
			str(enemy_scene),
			enemy_scenes.size(),
			str(fill_on_ready),
			str(spawn_only_at_night),
			str(_is_day_cached),
			str(spawn_parent)
		]
	)

	if fill_on_ready:
		_fill_to_max()

# ------------- Day/Night hookup -------------
func _connect_daynight() -> void:
	_dn = get_node_or_null(day_night_node_path)
	if _dn == null:
		_dlog("DayNight not found at %s" % str(day_night_node_path))
		return

	if _dn.has_signal("phase_changed"):
		var cb: Callable = Callable(self, "_on_daynight_phase_changed")
		if not _dn.is_connected("phase_changed", cb):
			_dn.connect("phase_changed", cb)
			_dlog("Connected to DayNight.phase_changed.")

	if _dn.has_method("is_day"):
		var v: Variant = _dn.call("is_day")
		if v is bool:
			_is_day_cached = bool(v)
			_dlog("Primed is_day_cached=%s from DayNight.is_day()." % str(_is_day_cached))

func _on_daynight_phase_changed(is_day: bool) -> void:
	_is_day_cached = is_day
	_refresh_spawn_permission(false)

func _can_spawn_now() -> bool:
	if not spawn_only_at_night:
		return true
	if _is_day_cached:
		return false
	return true

func _refresh_spawn_permission(instant: bool) -> void:
	if not _can_spawn_now():
		if _timer != null and _timer.time_left > 0.0:
			_timer.stop()

		if despawn_spawned_on_day and _is_day_cached:
			_despawn_all_spawned()

		return

	if not instant:
		if fill_on_ready:
			_fill_to_max()
		else:
			_schedule_respawn_check()

func _despawn_all_spawned() -> void:
	_cancel_timer_safe()

	var to_remove: Array[Node] = []
	to_remove.assign(_alive)

	var i: int = 0
	while i < to_remove.size():
		var inst: Node = to_remove[i]
		if inst != null and is_instance_valid(inst):
			var slot_index: int = -1
			if _slot_by_enemy.has(inst):
				var sv: Variant = _slot_by_enemy[inst]
				if typeof(sv) == TYPE_INT:
					slot_index = int(sv)
			_remove_enemy(inst, slot_index)
			inst.queue_free()
		i += 1

func _cancel_timer_safe() -> void:
	if _timer == null:
		return
	if _timer.time_left > 0.0:
		_timer.stop()

# ------------- Spawn points discovery -------------
func _collect_spawn_points() -> void:
	_points.clear()

	if not spawn_points.is_empty():
		var i: int = 0
		while i < spawn_points.size():
			var np: NodePath = spawn_points[i]
			if np != NodePath() and has_node(np):
				var node: Node = get_node(np)
				if node is Node2D:
					_points.append(node as Node2D)
					_dlog("Point[%d] via spawn_points: %s pos=%s" % [i, node.name, str((node as Node2D).global_position)])
			i += 1
	else:
		var idx: int = 0
		for c in get_children():
			if c is Node2D:
				_points.append(c as Node2D)
				_dlog("Point[%d] via child: %s pos=%s" % [idx, c.name, str((c as Node2D).global_position)])
				idx += 1

	if _points.is_empty():
		push_warning("[EnemySpawner] No spawn points found. Assign spawn_points or add Marker2D/Node2D children.")
		_dlog("No spawn points found.")
		return

	_enemy_by_slot.clear()
	var i2: int = 0
	while i2 < _points.size():
		_enemy_by_slot[i2] = null
		i2 += 1

func _setup_timer() -> void:
	if _timer == null:
		_timer = Timer.new()
		_timer.one_shot = true
		_timer.autostart = false
		add_child(_timer)

	var cb: Callable = Callable(self, "_on_respawn_timeout")
	if not _timer.timeout.is_connected(cb):
		_timer.timeout.connect(cb)

# ------------- Spawning core -------------
func _fill_to_max() -> void:
	if not _can_spawn_now():
		_dlog("fill_to_max: blocked by night gate.")
		return
	if _points.is_empty():
		_dlog("fill_to_max: blocked, no points.")
		return
	if enemy_scene == null and enemy_scenes.is_empty():
		_dlog("fill_to_max: blocked, no scenes.")
		return

	var cap: int = _get_effective_max_alive()

	var prefer_unique: bool = false
	if prefer_unique_on_first_fill:
		if _alive.size() == 0:
			prefer_unique = true

	while _alive.size() < cap:
		var slot: int = _pick_free_slot()
		if slot < 0:
			break
		_spawn_at(slot, prefer_unique)

func _pick_free_slot() -> int:
	var i: int = 0
	while i < _points.size():
		if _enemy_by_slot.get(i) == null:
			return i
		i += 1
	return -1

func _spawn_at(slot_index: int, prefer_unique: bool) -> void:
	if not _can_spawn_now():
		return
	if slot_index < 0:
		return
	if slot_index >= _points.size():
		return

	var scene: PackedScene = _pick_enemy_scene(prefer_unique)
	if scene == null:
		_dlog("spawn_at: picked scene is null.")
		return

	var parent_node: Node = self.get_parent()
	if spawn_parent != NodePath() and has_node(spawn_parent):
		parent_node = get_node(spawn_parent)

	var inst: Node = scene.instantiate()
	if inst == null:
		_dlog("spawn_at: instantiate returned null.")
		return

	# Name it after the scene file for clarity
	if scene.resource_path != "":
		var base: String = scene.resource_path.get_file().get_basename()
		if base != "":
			inst.name = base

	# --- CRITICAL: prove whether it enters/exits the tree ---
	inst.tree_entered.connect(Callable(self, "_on_spawned_tree_entered").bind(inst))
	inst.tree_exited.connect(Callable(self, "_on_spawned_tree_exited").bind(inst))

	# Extra: mark it for easy group searching
	inst.add_to_group("SpawnedByEnemySpawner")

	if scale_enemy_level_to_controlled:
		_apply_level_scaling(inst)

	parent_node.add_child(inst)

	var base_pos: Vector2 = _points[slot_index].global_position
	if jitter_px > 0.0:
		var jx: float = _rng.randf_range(-jitter_px, jitter_px)
		var jy: float = _rng.randf_range(-jitter_px, jitter_px)
		base_pos += Vector2(jx, jy)

	if inst is Node2D:
		(inst as Node2D).global_position = base_pos

	_connect_enemy_lifecycle(inst, slot_index)

	_alive.append(inst)
	_slot_by_enemy[inst] = slot_index
	_enemy_by_slot[slot_index] = inst

	_dlog("Spawned(add_child called): %s class=%s pos=%s parent=%s"
		% [inst.name, inst.get_class(), str(base_pos), str(parent_node.get_path())]
	)

	# Next-frame verification
	call_deferred("_verify_spawn_next_frame", inst)

func _verify_spawn_next_frame(inst: Node) -> void:
	if not debug_logs:
		return

	if inst == null:
		_dlog("VerifyNextFrame: inst == null")
		return

	if not is_instance_valid(inst):
		_dlog("VerifyNextFrame: inst is NOT valid (freed).")
		return

	var parent_path: String = "<null>"
	if inst.get_parent() != null:
		parent_path = str(inst.get_parent().get_path())

	_dlog("VerifyNextFrame: inside_tree=%s path=%s parent=%s"
		% [str(inst.is_inside_tree()), str(inst.get_path()), parent_path]
	)

	# Also list group members so we can see if they exist but are hard to spot in Remote.
	var nodes: Array[Node] = get_tree().get_nodes_in_group("SpawnedByEnemySpawner")
	_dlog("VerifyNextFrame: SpawnedByEnemySpawner count=%d" % nodes.size())
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		if n != null and is_instance_valid(n):
			_dlog("  GroupNode[%d]: %s (%s) path=%s" % [i, n.name, n.get_class(), str(n.get_path())])
		i += 1

func _on_spawned_tree_entered(inst: Node) -> void:
	_dlog("tree_entered: %s path=%s" % [inst.name, str(inst.get_path())])

func _on_spawned_tree_exited(inst: Node) -> void:
	_dlog("tree_exited: %s" % inst.name)

# ------------- Scene selection (single / pool) -------------
func _pick_enemy_scene(prefer_unique: bool) -> PackedScene:
	if not enemy_scenes.is_empty():
		if prefer_unique:
			var idx: int = _pool_cursor % enemy_scenes.size()
			_pool_cursor += 1
			return enemy_scenes[idx]
		return _pick_weighted_scene(enemy_scenes, enemy_weights)
	return enemy_scene

func _pick_weighted_scene(pool: Array[PackedScene], weights: PackedInt32Array) -> PackedScene:
	var count: int = pool.size()
	if count <= 0:
		return null

	var use_uniform: bool = false
	if weights.size() != count:
		use_uniform = true
	else:
		var sumw: int = 0
		var i: int = 0
		while i < weights.size():
			var w: int = int(weights[i])
			if w < 0:
				use_uniform = true
			else:
				sumw += w
			i += 1
		if sumw <= 0:
			use_uniform = true

	if use_uniform:
		var idx: int = _rng.randi_range(0, count - 1)
		return pool[idx]

	var total_weight: int = 0
	var j: int = 0
	while j < weights.size():
		var w2: int = int(weights[j])
		if w2 > 0:
			total_weight += w2
		j += 1

	if total_weight <= 0:
		var idx2: int = _rng.randi_range(0, count - 1)
		return pool[idx2]

	var pick: int = _rng.randi_range(1, total_weight)
	var accum: int = 0
	var k: int = 0
	while k < count:
		var w3: int = int(weights[k])
		if w3 > 0:
			accum += w3
			if pick <= accum:
				return pool[k]
		k += 1

	return pool[count - 1]

# ------------- Level helpers -------------
func _get_controlled_actor_safe() -> Node:
	var party: Node = get_node_or_null("/root/Party")
	if party == null:
		return null
	if party.has_method("get_controlled"):
		var c: Variant = party.call("get_controlled")
		if typeof(c) == TYPE_OBJECT:
			return c
	return null

func _get_party_size() -> int:
	var party: Node = get_node_or_null("/root/Party")
	if party == null:
		return 1
	if party.has_method("get_members"):
		var v: Variant = party.call("get_members")
		if typeof(v) == TYPE_ARRAY:
			var arr: Array = v
			if arr.size() >= 1:
				return arr.size()
	return 1

func _get_effective_max_alive() -> int:
	var party_size: int = _get_party_size()
	var extra_members: int = 0
	if party_size > 1:
		extra_members = party_size - 1
	var effective: int = max_alive + max_alive_per_extra_member * extra_members
	if effective < 1:
		effective = 1
	return effective

func _get_effective_respawn_delay() -> float:
	var party_size: int = _get_party_size()
	var extra_members: int = 0
	if party_size > 1:
		extra_members = party_size - 1
	var delay: float = respawn_delay_sec - respawn_delay_per_extra_member_sec * float(extra_members)
	if delay < respawn_delay_min_sec:
		delay = respawn_delay_min_sec
	return delay

func _read_level_from_node(node_ref: Node) -> int:
	var lvl_node: Node = node_ref.find_child("LevelComponent", true, false)
	if lvl_node != null:
		if "level" in lvl_node:
			var v: Variant = lvl_node.get("level")
			if typeof(v) == TYPE_INT:
				return int(v)
	return 1

func _find_level_component_on_enemy(inst: Node) -> Node:
	if enemy_level_component_path != NodePath():
		var n: Node = inst.get_node_or_null(enemy_level_component_path)
		if n != null:
			return n
	var lv: Node = inst.find_child("LevelComponent", true, false)
	if lv != null:
		return lv
	return null

func _apply_level_scaling(inst: Node) -> void:
	var controlled: Node = _get_controlled_actor_safe()
	if controlled == null:
		return

	var controlled_level: int = _read_level_from_node(controlled)
	var desired: int = controlled_level - 1
	if desired < min_scaled_level:
		desired = min_scaled_level

	var enemy_lv: Node = _find_level_component_on_enemy(inst)
	if enemy_lv == null:
		return

	if "level" in enemy_lv:
		enemy_lv.set("level", desired)

# ------------- Lifecycle wiring -------------
func _connect_enemy_lifecycle(inst: Node, slot_index: int) -> void:
	# Keep your existing hooks
	if inst.has_signal("died"):
		inst.connect("died", Callable(self, "_on_enemy_died").bind(inst, slot_index))
	else:
		var sc: Node = inst.find_child("StatsComponent", true, false)
		if sc != null and sc.has_signal("died"):
			sc.connect("died", Callable(self, "_on_enemy_died").bind(inst, slot_index))

	inst.tree_exited.connect(Callable(self, "_on_enemy_exited").bind(inst, slot_index))

# ------------- Lifecycle handlers -------------
func _on_enemy_died(_who: Variant = null, inst: Node = null, slot_index: int = -1) -> void:
	_remove_enemy(inst, slot_index)
	_schedule_respawn_check()

func _on_enemy_exited(inst: Node, slot_index: int) -> void:
	_remove_enemy(inst, slot_index)
	_schedule_respawn_check()

func _remove_enemy(inst: Node, slot_index: int) -> void:
	if inst == null:
		return
	if _slot_by_enemy.has(inst):
		_slot_by_enemy.erase(inst)
	if _enemy_by_slot.get(slot_index) == inst:
		_enemy_by_slot[slot_index] = null
	_alive.erase(inst)

func _schedule_respawn_check() -> void:
	if not _can_spawn_now():
		_cancel_timer_safe()
		return
	if not is_inside_tree():
		return
	if _timer == null:
		return
	if not _timer.is_inside_tree():
		return

	if _alive.size() < _get_effective_max_alive():
		_timer.stop()
		_timer.start(_get_effective_respawn_delay())
	else:
		if _timer.time_left > 0.0:
			_timer.stop()

# ------------- Respawn timeout -------------
func _on_respawn_timeout() -> void:
	if not is_inside_tree():
		return
	if not _can_spawn_now():
		return
	_fill_to_max()
