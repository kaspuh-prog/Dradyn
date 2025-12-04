extends Node
class_name LightingController

signal phase_applied(is_day: bool)

@export var debug_logging: bool = true

# ---------------------- TORCH TILES (L1_Details) ----------------------
@export_node_path("Node") var torch_tiles_path: NodePath
@export var torch_lit_source_id: int = 0
@export var torch_lit_atlas: Vector2i = Vector2i(0, 0)
@export var torch_unlit_source_id: int = 0
@export var torch_unlit_atlas: Vector2i = Vector2i(0, 0)
@export var torch_use_manual_cells: bool = false
@export var torch_manual_cells: Array[Vector2i] = []

# ---------------------- WINDOW TILES (L1_Details) ---------------------
@export_node_path("Node") var window_tiles_path: NodePath
@export var window_day_source_id: int = 0
@export var window_day_atlas: Vector2i = Vector2i(0, 0)
@export var window_night_source_id: int = 0
@export var window_night_atlas: Vector2i = Vector2i(0, 0)
@export var window_use_manual_cells: bool = false
@export var window_manual_cells: Array[Vector2i] = []

# ---------------------- FIREPLACE TILES (L2_Colliders) ----------------
@export_node_path("Node") var fireplace_tiles_path: NodePath
@export var fireplace_lit_source_id: int = 0
@export var fireplace_lit_atlas: Vector2i = Vector2i(0, 0)
@export var fireplace_unlit_source_id: int = 0
@export var fireplace_unlit_atlas: Vector2i = Vector2i(0, 0)
@export var fireplace_use_manual_cells: bool = false
@export var fireplace_manual_cells: Array[Vector2i] = []

# --- Optional: TorchLights helper that builds PointLight2D from tiles ---
@export_node_path("Node") var torch_lights_node_path: NodePath

var _dn: Node = null
var _torch_layer: Node = null
var _window_layer: Node = null
var _fireplace_layer: Node = null
var _torch_lights: Node = null

var _torch_cells_cache: Array[Vector2i] = []
var _window_cells_cache: Array[Vector2i] = []
var _fireplace_cells_cache: Array[Vector2i] = []

func _ready() -> void:
	_resolve_nodes()
	_resolve_dayandnight()
	_cache_torch_cells()
	_cache_window_cells()
	_cache_fireplace_cells()
	_connect_dayandnight() # ← name as you already had it
	_apply_current_phase()

# ------------------------------ boot helpers ------------------------------
func _resolve_nodes() -> void:
	if torch_tiles_path != NodePath():
		_torch_layer = get_node_or_null(torch_tiles_path)
	if window_tiles_path != NodePath():
		_window_layer = get_node_or_null(window_tiles_path)
	if fireplace_tiles_path != NodePath():
		_fireplace_layer = get_node_or_null(fireplace_tiles_path)
	if torch_lights_node_path != NodePath():
		_torch_lights = get_node_or_null(torch_lights_node_path)

func _resolve_dayandnight() -> void:
	_dn = get_node_or_null("/root/DayandNight")
	if _dn == null and debug_logging:
		printerr("[LightingController] Missing /root/DayandNight autoload.")

func _connect_dayandnight() -> void:
	if _dn == null:
		return
	if _dn.has_signal("phase_changed"):
		var already: bool = _dn.is_connected("phase_changed", Callable(self, "_on_phase_changed"))
		if not already:
			_dn.connect("phase_changed", Callable(self, "_on_phase_changed"))
	if _dn.has_signal("time_changed"):
		var already2: bool = _dn.is_connected("time_changed", Callable(self, "_on_time_changed"))
		if not already2:
			_dn.connect("time_changed", Callable(self, "_on_time_changed"))

func _apply_current_phase() -> void:
	if _dn == null:
		return
	if _dn.has_method("is_day"):
		var is_day: bool = _dn.call("is_day")
		_apply_phase(is_day)

# ------------------------------ signals ------------------------------
func _on_phase_changed(is_day: bool) -> void:
	_apply_phase(is_day)

func _on_time_changed(_t: float) -> void:
	# Reserved for future smooth fades if desired.
	pass

# ------------------------------ core apply ------------------------------
func _apply_phase(is_day: bool) -> void:
	# Swap tiles first so any dependent nodes rebuild from correct state.
	_swap_torch_tiles(is_day)
	_swap_window_tiles(is_day)
	_swap_fireplace_tiles(is_day)

	# Let TorchLights rebuild from new tiles if present.
	_rebuild_torch_lights()

	emit_signal("phase_applied", is_day)

# ============================== TORCHES ==============================
func _cache_torch_cells() -> void:
	_torch_cells_cache.clear()
	if torch_use_manual_cells:
		for c in torch_manual_cells:
			_torch_cells_cache.append(c)
		if debug_logging:
			print("[LightingController] Torch cells: manual (", _torch_cells_cache.size(), ").")
		return

	if _torch_layer == null:
		return
	if not _torch_layer.has_method("get_used_cells"):
		if debug_logging:
			printerr("[LightingController] Torch layer lacks get_used_cells().")
		return

	var cells: Array = _torch_layer.call("get_used_cells")
	for cell in cells:
		var v: Vector2i = cell
		if _cell_is_torch_lit(v):
			_torch_cells_cache.append(v)

	if debug_logging:
		print("[LightingController] Torch cells auto: ", _torch_cells_cache.size())

func _cell_is_torch_lit(cell: Vector2i) -> bool:
	if _torch_layer == null:
		return false
	if not _torch_layer.has_method("get_cell_source_id"):
		return false
	if not _torch_layer.has_method("get_cell_atlas_coords"):
		return false

	var sid: int = _torch_layer.call("get_cell_source_id", cell)
	if sid != torch_lit_source_id:
		return false

	var coords: Vector2i = _torch_layer.call("get_cell_atlas_coords", cell)
	if coords == torch_lit_atlas:
		return true
	return false

func _swap_torch_tiles(is_day: bool) -> void:
	if _torch_layer == null:
		return
	if _torch_cells_cache.is_empty():
		return
	if not _torch_layer.has_method("set_cell"):
		if debug_logging:
			printerr("[LightingController] Torch layer lacks set_cell().")
		return

	var target_source: int = torch_lit_source_id
	var target_coords: Vector2i = torch_lit_atlas
	if is_day:
		target_source = torch_unlit_source_id
		target_coords = torch_unlit_atlas

	for cell in _torch_cells_cache:
		_torch_layer.call("set_cell", cell, target_source, target_coords, 0)

# ============================== WINDOWS ==============================
func _cache_window_cells() -> void:
	_window_cells_cache.clear()
	if window_use_manual_cells:
		for c in window_manual_cells:
			_window_cells_cache.append(c)
		if debug_logging:
			print("[LightingController] Window cells: manual (", _window_cells_cache.size(), ").")
		return

	if _window_layer == null:
		return
	if not _window_layer.has_method("get_used_cells"):
		if debug_logging:
			printerr("[LightingController] Window layer lacks get_used_cells().")
		return

	# Auto-detect as either day or night tile.
	var cells: Array = _window_layer.call("get_used_cells")
	for cell in cells:
		var v: Vector2i = cell
		if _cell_is_window_day(v) or _cell_is_window_night(v):
			_window_cells_cache.append(v)

	if debug_logging:
		print("[LightingController] Window cells auto: ", _window_cells_cache.size())

func _cell_is_window_day(cell: Vector2i) -> bool:
	if _window_layer == null:
		return false
	if not _window_layer.has_method("get_cell_source_id"):
		return false
	if not _window_layer.has_method("get_cell_atlas_coords"):
		return false

	var sid: int = _window_layer.call("get_cell_source_id", cell)
	if sid != window_day_source_id:
		return false

	var coords: Vector2i = _window_layer.call("get_cell_atlas_coords", cell)
	if coords == window_day_atlas:
		return true
	return false

func _cell_is_window_night(cell: Vector2i) -> bool:
	if _window_layer == null:
		return false
	if not _window_layer.has_method("get_cell_source_id"):
		return false
	if not _window_layer.has_method("get_cell_atlas_coords"):
		return false

	var sid: int = _window_layer.call("get_cell_source_id", cell)
	if sid != window_night_source_id:
		return false

	var coords: Vector2i = _window_layer.call("get_cell_atlas_coords", cell)
	if coords == window_night_atlas:
		return true
	return false

func _swap_window_tiles(is_day: bool) -> void:
	if _window_layer == null:
		return
	if _window_cells_cache.is_empty():
		return
	if not _window_layer.has_method("set_cell"):
		if debug_logging:
			printerr("[LightingController] Window layer lacks set_cell().")
		return

	var target_source: int = window_day_source_id
	var target_coords: Vector2i = window_day_atlas
	if not is_day:
		target_source = window_night_source_id
		target_coords = window_night_atlas

	for cell in _window_cells_cache:
		_window_layer.call("set_cell", cell, target_source, target_coords, 0)

# ============================== FIREPLACES ==============================
func _cache_fireplace_cells() -> void:
	_fireplace_cells_cache.clear()
	if fireplace_use_manual_cells:
		for c in fireplace_manual_cells:
			_fireplace_cells_cache.append(c)
		if debug_logging:
			print("[LightingController] Fireplace cells: manual (", _fireplace_cells_cache.size(), ").")
		return

	if _fireplace_layer == null:
		return
	if not _fireplace_layer.has_method("get_used_cells"):
		if debug_logging:
			printerr("[LightingController] Fireplace layer lacks get_used_cells().")
		return

	var cells: Array = _fireplace_layer.call("get_used_cells")
	for cell in cells:
		var v: Vector2i = cell
		if _cell_is_fireplace_lit(v) or _cell_is_fireplace_unlit(v):
			_fireplace_cells_cache.append(v)

	if debug_logging:
		print("[LightingController] Fireplace cells auto: ", _fireplace_cells_cache.size())

func _cell_is_fireplace_lit(cell: Vector2i) -> bool:
	if _fireplace_layer == null:
		return false
	if not _fireplace_layer.has_method("get_cell_source_id"):
		return false
	if not _fireplace_layer.has_method("get_cell_atlas_coords"):
		return false

	var sid: int = _fireplace_layer.call("get_cell_source_id", cell)
	if sid != fireplace_lit_source_id:
		return false

	var coords: Vector2i = _fireplace_layer.call("get_cell_atlas_coords", cell)
	if coords == fireplace_lit_atlas:
		return true
	return false

func _cell_is_fireplace_unlit(cell: Vector2i) -> bool:
	if _fireplace_layer == null:
		return false
	if not _fireplace_layer.has_method("get_cell_source_id"):
		return false
	if not _fireplace_layer.has_method("get_cell_atlas_coords"):
		return false

	var sid: int = _fireplace_layer.call("get_cell_source_id", cell)
	if sid != fireplace_unlit_source_id:
		return false

	var coords: Vector2i = _fireplace_layer.call("get_cell_atlas_coords", cell)
	if coords == fireplace_unlit_atlas:
		return true
	return false

func _swap_fireplace_tiles(is_day: bool) -> void:
	if _fireplace_layer == null:
		return
	if _fireplace_cells_cache.is_empty():
		return
	if not _fireplace_layer.has_method("set_cell"):
		if debug_logging:
			printerr("[LightingController] Fireplace layer lacks set_cell().")
		return

	var target_source: int = fireplace_lit_source_id
	var target_coords: Vector2i = fireplace_lit_atlas
	if is_day:
		target_source = fireplace_unlit_source_id
		target_coords = fireplace_unlit_atlas

	for cell in _fireplace_cells_cache:
		_fireplace_layer.call("set_cell", cell, target_source, target_coords, 0)

# --------------------------- TorchLights rebuild ---------------------------
func _rebuild_torch_lights() -> void:
	if _torch_lights == null:
		return
	if _torch_lights.has_method("_build_or_refresh_lights"):
		_torch_lights.call("_build_or_refresh_lights")
