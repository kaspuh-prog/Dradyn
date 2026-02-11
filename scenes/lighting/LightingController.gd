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

# New (multi-variant): if any of these arrays are non-empty, LightingController will treat them
# as *paired* lit/unlit variants (index-aligned).
# - author your map with the LIT variants placed
# - day => swaps to UNLIT
# - night => swaps to LIT
@export var torch_lit_source_ids: Array[int] = []
@export var torch_lit_atlases: Array[Vector2i] = []
@export var torch_unlit_source_ids: Array[int] = []
@export var torch_unlit_atlases: Array[Vector2i] = []

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

# Multi-variant torch mapping (cell -> pair index)
var _torch_cell_pair_index: Dictionary = {}

# Resolved torch pairs used at runtime (always at least 1 entry)
var _torch_pairs_lit_source: Array[int] = []
var _torch_pairs_lit_atlas: Array[Vector2i] = []
var _torch_pairs_unlit_source: Array[int] = []
var _torch_pairs_unlit_atlas: Array[Vector2i] = []

func _ready() -> void:
	_resolve_nodes()
	_resolve_dayandnight()
	_resolve_torch_pairs()
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
func _resolve_torch_pairs() -> void:
	_torch_pairs_lit_source.clear()
	_torch_pairs_lit_atlas.clear()
	_torch_pairs_unlit_source.clear()
	_torch_pairs_unlit_atlas.clear()

	var use_multi: bool = false
	if not torch_lit_source_ids.is_empty():
		use_multi = true
	if not torch_lit_atlases.is_empty():
		use_multi = true
	if not torch_unlit_source_ids.is_empty():
		use_multi = true
	if not torch_unlit_atlases.is_empty():
		use_multi = true

	if not use_multi:
		_torch_pairs_lit_source.append(torch_lit_source_id)
		_torch_pairs_lit_atlas.append(torch_lit_atlas)
		_torch_pairs_unlit_source.append(torch_unlit_source_id)
		_torch_pairs_unlit_atlas.append(torch_unlit_atlas)
		return

	var pair_count: int = torch_lit_source_ids.size()
	if torch_lit_atlases.size() < pair_count:
		pair_count = torch_lit_atlases.size()
	if torch_unlit_source_ids.size() < pair_count:
		pair_count = torch_unlit_source_ids.size()
	if torch_unlit_atlases.size() < pair_count:
		pair_count = torch_unlit_atlases.size()

	if pair_count <= 0:
		# Misconfigured arrays; fall back to legacy single-pair exports.
		_torch_pairs_lit_source.append(torch_lit_source_id)
		_torch_pairs_lit_atlas.append(torch_lit_atlas)
		_torch_pairs_unlit_source.append(torch_unlit_source_id)
		_torch_pairs_unlit_atlas.append(torch_unlit_atlas)
		if debug_logging:
			printerr("[LightingController] Torch multi-variant arrays are empty/mismatched; falling back to legacy torch_* fields.")
		return

	var i: int = 0
	while i < pair_count:
		_torch_pairs_lit_source.append(torch_lit_source_ids[i])
		_torch_pairs_lit_atlas.append(torch_lit_atlases[i])
		_torch_pairs_unlit_source.append(torch_unlit_source_ids[i])
		_torch_pairs_unlit_atlas.append(torch_unlit_atlases[i])
		i += 1

	if debug_logging:
		print("[LightingController] Torch pairs resolved: ", pair_count)

func _cache_torch_cells() -> void:
	_torch_cells_cache.clear()
	_torch_cell_pair_index.clear()

	if torch_use_manual_cells:
		for c in torch_manual_cells:
			_torch_cells_cache.append(c)
			_torch_cell_pair_index[c] = 0
		if debug_logging:
			print("[LightingController] Torch cells: manual (", _torch_cells_cache.size(), ").")
		return

	if _torch_layer == null:
		return
	if not _torch_layer.has_method("get_used_cells"):
		if debug_logging:
			printerr("[LightingController] Torch layer lacks get_used_cells().")
		return

	var used: Array = _torch_layer.call("get_used_cells")
	for cell in used:
		var v: Variant = cell
		if v is Vector2i:
			var c2: Vector2i = v
			var pair_index: int = _torch_lit_pair_index_for_cell(c2)
			if pair_index >= 0:
				_torch_cells_cache.append(c2)
				_torch_cell_pair_index[c2] = pair_index

	if debug_logging:
		print("[LightingController] Torch cells cached: ", _torch_cells_cache.size(), ".")

func _torch_lit_pair_index_for_cell(cell: Vector2i) -> int:
	if _torch_layer == null:
		return -1
	if not _torch_layer.has_method("get_cell_source_id"):
		return -1
	if not _torch_layer.has_method("get_cell_atlas_coords"):
		return -1

	var sid: int = _torch_layer.call("get_cell_source_id", cell)
	var coords: Vector2i = _torch_layer.call("get_cell_atlas_coords", cell)

	var i: int = 0
	while i < _torch_pairs_lit_source.size():
		var lit_sid: int = _torch_pairs_lit_source[i]
		if sid == lit_sid:
			var lit_coords: Vector2i = _torch_pairs_lit_atlas[i]
			if coords == lit_coords:
				return i
		i += 1

	return -1

func _swap_torch_tiles(is_day: bool) -> void:
	if _torch_layer == null:
		return
	if _torch_cells_cache.is_empty():
		return
	if not _torch_layer.has_method("set_cell"):
		if debug_logging:
			printerr("[LightingController] Torch layer lacks set_cell().")
		return

	for cell in _torch_cells_cache:
		var pair_index: int = 0
		if _torch_cell_pair_index.has(cell):
			var v: Variant = _torch_cell_pair_index[cell]
			if v is int:
				pair_index = v

		# Clamp pair index defensively.
		if pair_index < 0:
			pair_index = 0
		if pair_index >= _torch_pairs_lit_source.size():
			pair_index = 0

		var target_source: int = _torch_pairs_lit_source[pair_index]
		var target_coords: Vector2i = _torch_pairs_lit_atlas[pair_index]
		if is_day:
			target_source = _torch_pairs_unlit_source[pair_index]
			target_coords = _torch_pairs_unlit_atlas[pair_index]

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

	var used: Array = _window_layer.call("get_used_cells")
	for cell in used:
		var v: Variant = cell
		if v is Vector2i:
			var c2: Vector2i = v
			if _cell_is_window_night(c2):
				_window_cells_cache.append(c2)

	if debug_logging:
		print("[LightingController] Window cells cached: ", _window_cells_cache.size(), ".")

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

	var used: Array = _fireplace_layer.call("get_used_cells")
	for cell in used:
		var v: Variant = cell
		if v is Vector2i:
			var c2: Vector2i = v
			if _cell_is_fireplace_lit(c2):
				_fireplace_cells_cache.append(c2)

	if debug_logging:
		print("[LightingController] Fireplace cells cached: ", _fireplace_cells_cache.size(), ".")

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
