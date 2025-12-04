extends Node2D
class_name EnemySpawner

# ------------- Setup -------------
@export var enemy_scene: PackedScene
# Optional pool (if set, this takes precedence over enemy_scene)
@export var enemy_scenes: Array[PackedScene] = []
@export var enemy_weights: PackedInt32Array = [] # optional; if empty or mismatched length, selection is uniform

@export var prefer_unique_on_first_fill: bool = true # new: fill pass will cycle scenes uniquely before repeats

@export var max_alive: int = 2
@export var respawn_delay_sec: float = 90.0
@export var fill_on_ready: bool = true
@export var spawn_parent: NodePath  # optional: where to add spawned enemies
@export var spawn_points: Array[NodePath] = []  # optional: explicit spawn point nodes

# Slight random jitter so they don't overlap perfectly (0 = off)
@export var jitter_px: float = 4.0

# Where to find a LevelComponent on spawned enemies (optional convenience)
# If empty, we will search recursively for a node named/class LevelComponent.
@export var enemy_level_component_path: NodePath

# Scale enemies to (controlled - 1)
@export var scale_enemy_level_to_controlled: bool = true
@export var min_scaled_level: int = 1

# ------------- Internals -------------
var _points: Array[Node2D] = []
var _alive: Array[Node] = []
var _slot_by_enemy: Dictionary = {}     # enemy -> slot index
var _enemy_by_slot: Dictionary = {}     # slot index -> enemy (or null)
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _timer: Timer

var _pool_cursor: int = 0 # new: for round-robin unique selection on first fill

func _ready() -> void:
	_rng.randomize()
	_collect_spawn_points()
	_setup_timer()

	# Pre-fill if requested
	if fill_on_ready:
		_fill_to_max()

# ------------- Spawn points discovery -------------
func _collect_spawn_points() -> void:
	_points.clear()

	# 1) Use explicit NodePaths if provided
	for p in spawn_points:
		var n: Node = get_node_or_null(p)
		if n is Node2D:
			_points.append(n as Node2D)

	# 2) Fallback: any Node2D children directly under this spawner
	if _points.is_empty():
		for c in get_children():
			if c is Node2D:
				_points.append(c as Node2D)

	if _points.is_empty():
		push_warning("[EnemySpawner] No spawn points found. Assign spawn_points or add Marker2D/Node2D children.")
		return

	# Initialize slot map
	_enemy_by_slot.clear()
	var i: int = 0
	while i < _points.size():
		_enemy_by_slot[i] = null
		i += 1

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
	if _points.is_empty():
		return
	if enemy_scene == null and enemy_scenes.is_empty():
		return

	# If this is the very first fill (no alive yet), prefer unique cycle if enabled.
	var prefer_unique: bool = false
	if prefer_unique_on_first_fill:
		if _alive.size() == 0:
			prefer_unique = true

	while _alive.size() < max_alive:
		var slot: int = _pick_free_slot()
		if slot < 0:
			break
		_spawn_at(slot, prefer_unique)

	# If we reached the cap, ensure the timer is off.
	if _alive.size() >= max_alive:
		if _timer.time_left > 0.0:
			_timer.stop()

func _pick_free_slot() -> int:
	# Prefer empty slots
	var i: int = 0
	while i < _points.size():
		if _enemy_by_slot.get(i) == null:
			return i
		i += 1
	# If all slots are full (shouldn't happen if _alive < max), return -1
	return -1

func _spawn_at(slot_index: int, prefer_unique: bool) -> void:
	if slot_index < 0:
		return
	if slot_index >= _points.size():
		return

	var scene: PackedScene = _pick_enemy_scene(prefer_unique)
	if scene == null:
		return

	var parent_node: Node = self.get_parent()
	if spawn_parent != NodePath() and has_node(spawn_parent):
		parent_node = get_node(spawn_parent)

	var inst: Node = scene.instantiate()

	# Level scaling BEFORE add_child so the component starts correct on ready
	if scale_enemy_level_to_controlled:
		_apply_level_scaling(inst)

	parent_node.add_child(inst)

	# Position WITH parent set (important so global coords resolve correctly)
	var base_pos: Vector2 = _points[slot_index].global_position
	if jitter_px > 0.0:
		var jx: float = _rng.randf_range(-jitter_px, jitter_px)
		var jy: float = _rng.randf_range(-jitter_px, jitter_px)
		base_pos += Vector2(jx, jy)
	if inst is Node2D:
		(inst as Node2D).global_position = base_pos

	# Group safety (your EnemyBase already adds itself to "Enemies"; this is a safety net)
	if not inst.is_in_group("Enemies"):
		inst.add_to_group("Enemies")

	# Listen for death and cleanup
	_connect_enemy_lifecycle(inst, slot_index)

	_alive.append(inst)
	_slot_by_enemy[inst] = slot_index
	_enemy_by_slot[slot_index] = inst

# ------------- Scene selection (single / pool) -------------
func _pick_enemy_scene(prefer_unique: bool) -> PackedScene:
	if not enemy_scenes.is_empty():
		if prefer_unique:
			# Round-robin the pool for deterministic one-of-each on first fill
			var idx: int = _pool_cursor % enemy_scenes.size()
			_pool_cursor += 1
			return enemy_scenes[idx]
		return _pick_weighted_scene(enemy_scenes, enemy_weights)
	return enemy_scene

func _pick_weighted_scene(pool: Array[PackedScene], weights: PackedInt32Array) -> PackedScene:
	# If weights are bad/mismatched/zero-sum, fall back to uniform
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
		var idx_u: int = _rng.randi_range(0, count - 1)
		return pool[idx_u]

	# Weighted pick
	var total: int = 0
	var j: int = 0
	while j < weights.size():
		total += int(weights[j])
		j += 1

	var pick: int = _rng.randi_range(1, total)
	var k: int = 0
	while k < count:
		pick -= int(weights[k])
		if pick <= 0:
			return pool[k]
		k += 1

	# Extremely unlikely fallback
	return pool[0]

# ------------- Level scaling -------------
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

	# Set exported property directly; LevelComponent has @export var level:int
	if "level" in enemy_lv:
		enemy_lv.set("level", desired)

func _get_controlled_actor_safe() -> Node:
	# Project rule: reference autoloads directly
	var party: Node = get_node_or_null("/root/Party")
	if party == null:
		return null
	if party.has_method("get_controlled"):
		var c: Variant = party.call("get_controlled")
		if typeof(c) == TYPE_OBJECT:
			return c
	return null

func _read_level_from_node(node_ref: Node) -> int:
	# Prefer a LevelComponent child on the controlled actor
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
	# Fallback: search by common name/class
	var lv: Node = inst.find_child("LevelComponent", true, false)
	if lv != null:
		return lv
	return null

# ------------- Lifecycle wiring -------------
func _connect_enemy_lifecycle(inst: Node, slot_index: int) -> void:
	# Prefer EnemyBase "died" if present
	if inst.has_signal("died"):
		inst.connect("died", Callable(self, "_on_enemy_died").bind(inst, slot_index))
	else:
		# Otherwise try StatsComponent under it
		var sc: Node = inst.find_child("StatsComponent", true, false)
		if sc != null and sc.has_signal("died"):
			sc.connect("died", Callable(self, "_on_enemy_died").bind(inst, slot_index))

	# Fallback: always clean up on tree exit
	inst.tree_exited.connect(Callable(self, "_on_enemy_exited").bind(inst, slot_index))

# ------------- Lifecycle handlers -------------
func _on_enemy_died(_who: Variant, inst: Node, slot_index: int) -> void:
	_remove_enemy(inst, slot_index)
	_schedule_respawn_check()

func _on_enemy_exited(inst: Node, slot_index: int) -> void:
	_remove_enemy(inst, slot_index)
	_schedule_respawn_check()

func _remove_enemy(inst: Node, slot_index: int) -> void:
	if _slot_by_enemy.has(inst):
		_slot_by_enemy.erase(inst)
	if _enemy_by_slot.get(slot_index) == inst:
		_enemy_by_slot[slot_index] = null
	_alive.erase(inst)

func _schedule_respawn_check() -> void:
	# If this spawner (or its timer) is not in the tree anymore,
	# do nothing. This can happen during area unload / scene change.
	if not is_inside_tree():
		return
	if _timer == null:
		return
	if not _timer.is_inside_tree():
		return

	# Start (or restart) the timer only if we're under the cap.
	if _alive.size() < max_alive:
		_timer.stop()
		_timer.start(respawn_delay_sec)
	else:
		if _timer.time_left > 0.0:
			_timer.stop()

# ------------- Respawn timeout -------------
func _on_respawn_timeout() -> void:
	# Extra safety: only refill if this spawner is still active in the tree.
	if not is_inside_tree():
		return

	_fill_to_max()
