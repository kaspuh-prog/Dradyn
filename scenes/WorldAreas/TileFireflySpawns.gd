extends Node2D
class_name TileFireflySpawns
# Auto-spawn FireflyCollectible scenes on tiles marked with custom data.
# Godot 4.5 — fully typed, no ternaries.

# --- Configuration: Tiles -----------------------------------------------------
@export var target_layer_path: NodePath
@export var custom_data_key: String = "firefly_spawn"

# --- Configuration: What to spawn --------------------------------------------
@export var firefly_scene: PackedScene
@export var spawn_parent_path: NodePath  # optional; if empty, spawns under an auto-created child root

# Positioning on the cell
@export var cell_center_offset: Vector2 = Vector2(8.0, 8.0)
@export var sprite_vertical_nudge: float = -2.0

# Density / randomness
@export_range(0.0, 1.0, 0.001) var spawn_chance: float = 1.0
@export var max_spawns_total: int = 0 # 0 = unlimited

# Refresh behavior
@export var rebuild_on_layer_changed: bool = true

# IMPORTANT:
# Runtime layer "changed" can create rebuild loops if your spawn parent is a TileMapLayer.
# So by default, we only live-rebuild in the editor.
@export var allow_runtime_layer_changed_rebuild: bool = false

# --- NEW: Night gating --------------------------------------------------------
@export var only_spawn_at_night: bool = true
@export var clear_when_day: bool = true

# Render ordering (matches your project conventions: actors around z 0/1)
@export var spawned_z_index: int = 2
@export var spawned_z_as_relative: bool = false

# --- Debug -------------------------------------------------------------------
@export var debug_logging: bool = false
@export var log_non_spawn_cells: bool = false

# ----------------------------- runtime ---------------------------------------
var _layer: TileMapLayer
var _spawn_parent: Node
var _spawned: Array[Node2D] = []

var _is_rebuilding: bool = false
var _connected_changed: bool = false

var _daynight: DayNight = null
var _connected_daynight: bool = false

func _ready() -> void:
	_layer = get_node_or_null(target_layer_path) as TileMapLayer
	if _layer == null:
		push_error("[TileFireflySpawns] target_layer_path is not set or not a TileMapLayer.")
		return

	_spawn_parent = _resolve_spawn_parent_safe()
	_resolve_daynight()
	_connect_daynight()

	# Initial build depends on day/night.
	if _should_spawn_now():
		_rebuild()
	else:
		if clear_when_day:
			_clear_spawned()

	_maybe_connect_layer_changed()

func _exit_tree() -> void:
	_disconnect_layer_changed()
	_disconnect_daynight()
	_clear_spawned()

# --- Day/Night ---------------------------------------------------------------
func _resolve_daynight() -> void:
	# Autoload is named "DayandNight" in project.godot.
	var n: Node = get_node_or_null("/root/DayandNight")
	if n == null:
		_daynight = null
		if debug_logging:
			print("[TileFireflySpawns] DayandNight autoload not found; night gating will be ignored.")
		return
	_daynight = n as DayNight

func _connect_daynight() -> void:
	if _daynight == null:
		return
	if _connected_daynight:
		return

	if _daynight.has_signal("phase_changed"):
		if not _daynight.is_connected("phase_changed", Callable(self, "_on_phase_changed")):
			_daynight.connect("phase_changed", Callable(self, "_on_phase_changed"))
			_connected_daynight = true

func _disconnect_daynight() -> void:
	if _daynight == null:
		return
	if not _connected_daynight:
		return
	if _daynight.has_signal("phase_changed"):
		if _daynight.is_connected("phase_changed", Callable(self, "_on_phase_changed")):
			_daynight.disconnect("phase_changed", Callable(self, "_on_phase_changed"))
	_connected_daynight = false

func _on_phase_changed(is_day: bool) -> void:
	if not only_spawn_at_night:
		# If gating is disabled, do nothing (spawns are controlled by rebuild calls).
		return

	if is_day:
		if clear_when_day:
			_clear_spawned()
		if debug_logging:
			print("[TileFireflySpawns] Day phase entered; fireflies cleared/disabled.")
	else:
		# Night entered: spawn.
		_rebuild()
		if debug_logging:
			print("[TileFireflySpawns] Night phase entered; fireflies spawned.")

func _should_spawn_now() -> bool:
	if not only_spawn_at_night:
		return true
	if _daynight == null:
		# If missing, default to spawning so we don't mysteriously break scenes.
		return true
	return not _daynight.is_day()

# --- Refresh -----------------------------------------------------------------
func _maybe_connect_layer_changed() -> void:
	if not rebuild_on_layer_changed:
		return
	if _layer == null:
		return

	var can_runtime: bool = allow_runtime_layer_changed_rebuild
	if Engine.is_editor_hint():
		can_runtime = true

	if not can_runtime:
		return

	if _layer.has_signal("changed"):
		if not _layer.is_connected("changed", Callable(self, "_on_layer_changed")):
			_layer.connect("changed", Callable(self, "_on_layer_changed"))
			_connected_changed = true
			if debug_logging:
				print("[TileFireflySpawns] Connected to TileMapLayer.changed (editor/runtime allowed).")

func _disconnect_layer_changed() -> void:
	if _layer == null:
		return
	if not _connected_changed:
		return
	if _layer.has_signal("changed"):
		if _layer.is_connected("changed", Callable(self, "_on_layer_changed")):
			_layer.disconnect("changed", Callable(self, "_on_layer_changed"))
	_connected_changed = false

func _on_layer_changed() -> void:
	# Guard against re-entrant loops
	if _is_rebuilding:
		return

	if not _should_spawn_now():
		# If day, don't rebuild.
		return

	_rebuild()

func _rebuild() -> void:
	if _is_rebuilding:
		return
	if not _should_spawn_now():
		return

	_is_rebuilding = true

	_clear_spawned()

	if firefly_scene == null:
		push_error("[TileFireflySpawns] firefly_scene is not set.")
		_is_rebuilding = false
		return

	if _layer == null:
		_is_rebuilding = false
		return

	# Re-resolve in case scene hierarchy changed
	_spawn_parent = _resolve_spawn_parent_safe()

	var used: Array[Vector2i] = _layer.get_used_cells()
	var count_spawned: int = 0

	for cell in used:
		if max_spawns_total > 0 and count_spawned >= max_spawns_total:
			break

		var td: TileData = _layer.get_cell_tile_data(cell)
		if td == null:
			continue

		if not _cell_is_firefly_spawn(cell, td):
			continue

		if spawn_chance < 1.0:
			var r: float = randf()
			if r > spawn_chance:
				continue

		var pos: Vector2 = _layer.map_to_local(cell) + cell_center_offset + Vector2(0.0, sprite_vertical_nudge)

		var inst: Node = firefly_scene.instantiate()
		var n2d: Node2D = inst as Node2D
		if n2d == null:
			if debug_logging:
				print("[TileFireflySpawns] firefly_scene root is not Node2D; skipping at ", cell)
			inst.queue_free()
			continue

		_spawn_parent.add_child(n2d)
		n2d.position = pos
		n2d.z_as_relative = spawned_z_as_relative
		n2d.z_index = spawned_z_index

		_spawned.append(n2d)
		count_spawned += 1

	if debug_logging:
		print("[TileFireflySpawns] spawned ", count_spawned, " fireflies from custom_data_key='", custom_data_key, "'")

	_is_rebuilding = false

func _clear_spawned() -> void:
	var i: int = 0
	while i < _spawned.size():
		var n: Node2D = _spawned[i]
		if n != null and is_instance_valid(n):
			n.queue_free()
		i += 1
	_spawned.clear()

# --- Tile detection -----------------------------------------------------------
func _cell_is_firefly_spawn(cell: Vector2i, td: TileData) -> bool:
	if td.has_custom_data(custom_data_key):
		var v: Variant = td.get_custom_data(custom_data_key)

		var b: bool = false
		if typeof(v) == TYPE_BOOL:
			b = bool(v)
		elif typeof(v) == TYPE_INT:
			b = int(v) != 0
		elif typeof(v) == TYPE_FLOAT:
			b = float(v) >= 0.5
		else:
			b = false

		if b:
			return true

		if log_non_spawn_cells and debug_logging:
			print("[TileFireflySpawns] custom_data_key present but false at ", cell)
		return false

	if log_non_spawn_cells and debug_logging:
		print("[TileFireflySpawns] no custom_data_key at ", cell)
	return false

# --- Spawn parent resolution (SAFE) ------------------------------------------
func _resolve_spawn_parent_safe() -> Node:
	# If user provided an explicit spawn parent and it is NOT a TileMapLayer, we can use it.
	if String(spawn_parent_path) != "":
		var n: Node = get_node_or_null(spawn_parent_path)
		if n != null:
			var as_layer: TileMapLayer = n as TileMapLayer
			if as_layer == null:
				return n
			if debug_logging:
				print("[TileFireflySpawns] spawn_parent is a TileMapLayer; using safe local root instead (prevents changed-loop).")

	# Otherwise, use (or create) a dedicated child root under this spawner node.
	var existing: Node = get_node_or_null("FirefliesRoot")
	if existing != null:
		return existing

	var root: Node2D = Node2D.new()
	root.name = "FirefliesRoot"
	add_child(root)
	return root
