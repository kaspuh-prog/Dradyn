extends Node2D
class_name EnemySpawner

# ------------- Setup -------------
@export var enemy_scene: PackedScene
@export var max_alive: int = 2
@export var respawn_delay_sec: float = 90.0
@export var fill_on_ready: bool = true
@export var spawn_parent: NodePath  # optional: where to add spawned enemies
@export var spawn_points: Array[NodePath] = []  # optional: explicit spawn point nodes

# Slight random jitter so they don't overlap perfectly (0 = off)
@export var jitter_px: float = 4.0

# ------------- Internals -------------
var _points: Array[Node2D] = []
var _alive: Array[Node] = []
var _slot_by_enemy: Dictionary = {}     # enemy -> slot index
var _enemy_by_slot: Dictionary = {}     # slot index -> enemy (or null)
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _timer: Timer

func _ready() -> void:
	_rng.randomize()
	_collect_spawn_points()
	_setup_timer()

	# Pre-fill if requested
	if fill_on_ready:
		_fill_to_max()

func _collect_spawn_points() -> void:
	_points.clear()

	# 1) Use explicit NodePaths if provided
	for p in spawn_points:
		var n := get_node_or_null(p)
		if n is Node2D:
			_points.append(n as Node2D)

	# 2) Fallback: any Marker2D/Position2D children directly under this spawner
	if _points.is_empty():
		for c in get_children():
			if c is Node2D and (c is Marker2D or c.get_class() == "Position2D" or c.get_class() == "Node2D"):
				_points.append(c as Node2D)

	if _points.is_empty():
		push_warning("[EnemySpawner] No spawn points found. Assign spawn_points or add Marker2D children.")
		return

	# Initialize slot map
	_enemy_by_slot.clear()
	for i in _points.size():
		_enemy_by_slot[i] = null

func _setup_timer() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.autostart = false
	_timer.wait_time = respawn_delay_sec
	add_child(_timer)
	_timer.timeout.connect(_on_respawn_timeout)

# ------------- Spawning core -------------
func _fill_to_max() -> void:
	if enemy_scene == null or _points.is_empty():
		return

	while _alive.size() < max_alive:
		var slot := _pick_free_slot()
		if slot < 0:
			# All slots are occupied; break out
			break
		_spawn_at(slot)

	# If we reached the cap, ensure the timer is off.
	if _alive.size() >= max_alive and _timer.time_left > 0.0:
		_timer.stop()

func _pick_free_slot() -> int:
	# Prefer empty slots
	for i in _points.size():
		if _enemy_by_slot.get(i) == null:
			return i
	# If all slots are full (shouldn't happen if _alive < max), return -1
	return -1

func _spawn_at(slot_index: int) -> void:
	if enemy_scene == null:
		return
	if slot_index < 0 or slot_index >= _points.size():
		return

	var parent_node: Node = self.get_parent()
	if spawn_parent != NodePath() and has_node(spawn_parent):
		parent_node = get_node(spawn_parent)

	var inst := enemy_scene.instantiate()
	parent_node.add_child(inst)

	# Position with a tiny jitter so two enemies don't overlap perfectly
	var base_pos: Vector2 = _points[slot_index].global_position
	if jitter_px > 0.0:
		base_pos += Vector2(_rng.randf_range(-jitter_px, jitter_px), _rng.randf_range(-jitter_px, jitter_px))
	if inst is Node2D:
		(inst as Node2D).global_position = base_pos

	# Group safety (your EnemyBase already adds itself to "Enemies"; this is just a safety net)
	if not inst.is_in_group("Enemies"):
		inst.add_to_group("Enemies")

	# Listen for death and cleanup
	_connect_enemy_lifecycle(inst, slot_index)

	_alive.append(inst)
	_slot_by_enemy[inst] = slot_index
	_enemy_by_slot[slot_index] = inst

func _connect_enemy_lifecycle(inst: Node, slot_index: int) -> void:
	# Prefer EnemyBase "died" if present
	if inst.has_signal("died"):
		inst.connect("died", Callable(self, "_on_enemy_died").bind(inst, slot_index))
	else:
		# Otherwise try StatsComponent under it
		var sc := inst.find_child("StatsComponent", true, false)
		if sc != null and sc.has_signal("died"):
			sc.connect("died", Callable(self, "_on_enemy_died").bind(inst, slot_index))

	# Fallback: always clean up on tree exit
	inst.tree_exited.connect(Callable(self, "_on_enemy_exited").bind(inst, slot_index))

# ------------- Lifecycle handlers -------------
func _on_enemy_died(_who, inst: Node, slot_index: int) -> void:
	# Will also call _on_enemy_exited when it frees, but we clean early just in case.
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
	# Start (or restart) the 90s timer only if we're under the cap.
	if _alive.size() < max_alive:
		_timer.stop()
		_timer.start(respawn_delay_sec)
	else:
		# If we somehow reached the cap again, make sure timer is off.
		if _timer.time_left > 0.0:
			_timer.stop()

func _on_respawn_timeout() -> void:
	# If still below max, spawn to cap
	if _alive.size() < max_alive:
		_fill_to_max()
