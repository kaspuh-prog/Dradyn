extends Node2D
class_name WindowBeams2D

# ===== DEBUG CONTROLS =========================================================
@export var debug_logging: bool = true
@export var log_non_window_cells: bool = false
@export var spawn_debug_beacon: bool = false
@export var force_day_debug: bool = false
@export var force_high_energy_debug: bool = false

# ===== TILEMAPLAYER PATHS =====================================================
@export_node_path("TileMapLayer") var window_layer_path: NodePath
@export_node_path("TileMapLayer") var collider_layer_path: NodePath

# ===== GEOMETRY / RANGES ======================================================
@export var tile_size: Vector2 = Vector2(16.0, 16.0)
@export var beam_max_tiles: int = 12
@export var edge_inset_px: float = 0.0

# Beam anchoring:
#  - anchor_fraction_along_length: 0.0 = near edge at window, 0.5 = center at window, 1.0 = far edge at window
#  - start_offset_px: extra push into the room (negative pulls back)
@export var anchor_from_window_edge: bool = true
@export_range(0.0, 1.0, 0.01) var anchor_fraction_along_length: float = 0.0
@export var start_offset_px: float = 0.0

# Trim the far end to avoid soft cookie spill past blockers.
@export var end_clip_px: float = 8.0

# ===== LIGHT LOOK =============================================================
@export var light_texture: Texture2D
@export var light_color: Color = Color(1.0, 0.96, 0.85, 1.0)
@export_range(0.0, 8.0, 0.01) var light_energy_day: float = 1.6
@export_range(0.0, 8.0, 0.01) var light_energy_dawn_dusk: float = 0.7
@export var use_additive_blend: bool = true

# ===== LIGHT SIZING ===========================================================
@export var beam_base_width_px: float = 28.0
@export var beam_length_per_tile_px: float = 16.0

# ===== COOKIE AXIS & OFFSET ===================================================
const AXIS_X: int = 0
const AXIS_Y: int = 1
@export var cookie_length_axis: int = AXIS_Y
@export_range(-360.0, 360.0, 1.0) var cookie_angle_offset_deg: float = 0.0

# ===== SHADOWS ================================================================
@export var shadows_enabled: bool = true
@export var shadow_color: Color = Color(0.0, 0.0, 0.0, 0.6)

# ===== MASKING (who is lit) ===================================================
# Only CanvasItems with matching "Light Mask" bits will be affected.
# Example: floors/furniture use bit 1; actors use bit 2. Keep this on 1 to avoid lighting actors.
@export var affect_item_mask_bits: int = 1

# ===== BRIGHTNESS BOOSTS ======================================================
# Global multiplier for the main beam’s energy.
@export var beam_brightness_scale: float = 1.0

# Optional narrow, high-energy “core” stacked on top of the main beam to make it pop.
@export var beam_core_boost_enabled: bool = true
@export var beam_core_energy_scale: float = 2.0
@export_range(0.05, 1.0, 0.01) var beam_core_width_ratio: float = 0.4

# ===== WINDOW GLOW (at the tile itself) ======================================
@export var window_glow_enabled: bool = true
@export var window_glow_energy: float = 3.0
@export var window_glow_radius_px: float = 18.0
@export var window_glow_color: Color = Color(1.0, 0.95, 0.8, 1.0)
# Positive pushes the glow slightly into the room, negative tucks into the wall.
@export var window_glow_inset_px: float = 2.0
# If you have a custom glow texture, assign it; otherwise we build a soft radial.
@export var window_glow_texture: Texture2D

const KEY_WINDOW_DIR: String = "window_dir"

var _win: TileMapLayer = null
var _col: TileMapLayer = null
var _dn: Node = null

func _ready() -> void:
	if debug_logging:
		print("[WindowBeams2D] _ready begin on ", name)
	_resolve_nodes()
	_connect_signals()
	_rebuild_lights()
	_apply_day_state()
	if debug_logging:
		print("[WindowBeams2D] _ready done on ", name)

# ===== NODE RESOLUTION / SIGNALS =============================================

func _resolve_nodes() -> void:
	_win = null
	_col = null
	_dn = null

	if window_layer_path != NodePath():
		_win = get_node_or_null(window_layer_path) as TileMapLayer
	if collider_layer_path != NodePath():
		_col = get_node_or_null(collider_layer_path) as TileMapLayer

	_dn = get_node_or_null("/root/DayandNight")

	if debug_logging:
		print("[WindowBeams2D] window_layer = ", str(_win))
		print("[WindowBeams2D] collider_layer = ", str(_col))
		print("[WindowBeams2D] DayandNight = ", str(_dn))

	if _win == null:
		push_error("[WindowBeams2D] Window TileMapLayer not found. Set 'window_layer_path'.")

func _connect_signals() -> void:
	if _win != null and _win.has_signal("changed"):
		if not _win.is_connected("changed", Callable(self, "_on_tiles_changed")):
			_win.connect("changed", Callable(self, "_on_tiles_changed"))

	if _col != null and _col.has_signal("changed"):
		if not _col.is_connected("changed", Callable(self, "_on_tiles_changed")):
			_col.connect("changed", Callable(self, "_on_tiles_changed"))

	if _dn != null and _dn.has_signal("phase_changed"):
		if not _dn.is_connected("phase_changed", Callable(self, "_on_phase_changed")):
			_dn.connect("phase_changed", Callable(self, "_on_phase_changed"))

# ===== RESPONDERS =============================================================

func _on_tiles_changed() -> void:
	if debug_logging:
		print("[WindowBeams2D] TileMapLayer changed → rebuilding lights…")
	_rebuild_lights()
	_apply_day_state()

func _on_phase_changed(_is_day: bool) -> void:
	if debug_logging:
		print("[WindowBeams2D] Day/Night changed → applying day state…")
	_apply_day_state()

# ===== PUBLIC =================================================================

func refresh_now() -> void:
	_rebuild_lights()
	_apply_day_state()

# ===== CORE BUILD =============================================================

func _rebuild_lights() -> void:
	_clear_children()

	if spawn_debug_beacon:
		_spawn_debug_beacon_light()

	if _win == null:
		if debug_logging:
			printerr("[WindowBeams2D] No window TileMapLayer; abort.")
		return

	var cookie: Texture2D = light_texture
	if cookie == null:
		cookie = _make_default_cookie()

	var used: Array[Vector2i] = _win.get_used_cells()
	var cells_scanned: int = used.size()
	var windows_with_dir: int = 0
	var spawned_lights: int = 0

	if debug_logging:
		print("[WindowBeams2D] Used cell count on window layer = ", cells_scanned)

	for cell in used:
		var dir: Vector2 = _get_window_dir(cell)
		if dir == Vector2.ZERO:
			if debug_logging and log_non_window_cells:
				print("[WindowBeams2D] cell ", cell, " has no '", KEY_WINDOW_DIR, "'")
			continue

		windows_with_dir += 1
		var length_tiles: int = _trace_open_tiles(cell, dir)
		if length_tiles <= 0:
			if debug_logging:
				print("[WindowBeams2D] cell ", cell, " blocked immediately; skipping")
			continue

		_spawn_light_for_window(cell, dir, length_tiles, cookie)
		spawned_lights += 1

	if debug_logging:
		print("[WindowBeams2D] cells_scanned=", cells_scanned,
			" windows_with_dir=", windows_with_dir,
			" spawned_lights=", spawned_lights)

func _clear_children() -> void:
	var kids: Array[Node] = get_children()
	for c in kids:
		c.queue_free()

# ===== LIGHTS =================================================================

func _spawn_debug_beacon_light() -> void:
	var l: PointLight2D = PointLight2D.new()
	add_child(l)
	l.texture = _make_default_cookie()
	l.color = Color(1.0, 0.9, 0.7, 1.0)
	if force_high_energy_debug:
		l.energy = 4.0
	else:
		l.energy = 2.0
	l.shadow_enabled = false
	l.blend_mode = Light2D.BLEND_MODE_ADD
	l.scale = Vector2(1.0, 1.0)
	l.position = Vector2.ZERO
	l.z_index = 10
	l.range_item_cull_mask = affect_item_mask_bits
	l.range_layer_min = -100
	l.range_layer_max = 100
	if debug_logging:
		print("[WindowBeams2D] Spawned DEBUG BEACON light at node origin")

func _spawn_light_for_window(cell: Vector2i, dir: Vector2, length_tiles: int, cookie: Texture2D) -> void:
	# === MAIN BEAM ============================================================
	var light: PointLight2D = PointLight2D.new()
	add_child(light)

	light.texture = cookie
	light.color = light_color

	var desired_energy: float = light_energy_day * max(0.0, beam_brightness_scale)
	if force_high_energy_debug and desired_energy < 3.5:
		desired_energy = 3.5
	light.energy = desired_energy

	light.shadow_enabled = shadows_enabled
	light.shadow_color = shadow_color
	light.shadow_filter = Light2D.SHADOW_FILTER_PCF13
	light.shadow_filter_smooth = 1.0

	if use_additive_blend:
		light.blend_mode = Light2D.BLEND_MODE_ADD
	else:
		light.blend_mode = Light2D.BLEND_MODE_MIX

	light.range_item_cull_mask = affect_item_mask_bits
	light.range_layer_min = -100
	light.range_layer_max = 100

	var raw_length_px: float = float(length_tiles) * beam_length_per_tile_px
	var length_px: float = max(0.0, raw_length_px - max(0.0, end_clip_px))
	var base_width_px: float = beam_base_width_px

	var tex_w: float = 256.0
	var tex_h: float = 256.0
	if light.texture != null:
		tex_w = float(light.texture.get_width())
		tex_h = float(light.texture.get_height())
	if tex_w <= 0.0:
		tex_w = 256.0
	if tex_h <= 0.0:
		tex_h = 256.0

	var len_denom: float = tex_h
	var wid_denom: float = tex_w
	if cookie_length_axis == AXIS_X:
		len_denom = tex_w
		wid_denom = tex_h

	var scale_x: float = base_width_px / wid_denom
	var scale_y: float = length_px / len_denom
	light.scale = Vector2(scale_x, scale_y)

	var angle: float = _angle_for_dir(dir) + deg_to_rad(cookie_angle_offset_deg)
	light.rotation = angle

	var window_center_local: Vector2 = _cell_center_local(_win, cell)
	var edge_offset: Vector2 = _edge_offset_for_dir(dir)
	var inset: Vector2 = dir * edge_inset_px
	var base_pos: Vector2 = window_center_local + edge_offset + inset
	if anchor_from_window_edge:
		var along: float = (length_px * anchor_fraction_along_length) + start_offset_px
		base_pos = base_pos + (dir * along)
	light.position = base_pos
	light.z_index = 5

	if debug_logging:
		print("[WindowBeams2D] Beam@ cell ", cell, " len_px=", length_px, " pos=", light.position)

	# === CORE BOOST (narrow, bright overlay) ==================================
	if beam_core_boost_enabled:
		var core: PointLight2D = PointLight2D.new()
		add_child(core)

		core.texture = cookie
		core.color = light_color
		var core_energy: float = light.energy * beam_core_energy_scale
		if force_high_energy_debug and core_energy < 3.5:
			core_energy = 3.5
		core.energy = core_energy

		core.shadow_enabled = shadows_enabled
		core.shadow_color = shadow_color
		core.shadow_filter = Light2D.SHADOW_FILTER_PCF13
		core.shadow_filter_smooth = 1.0

		if use_additive_blend:
			core.blend_mode = Light2D.BLEND_MODE_ADD
		else:
			core.blend_mode = Light2D.BLEND_MODE_MIX

		core.range_item_cull_mask = affect_item_mask_bits
		core.range_layer_min = -100
		core.range_layer_max = 100

		var core_scale_x: float = scale_x * clamp(beam_core_width_ratio, 0.05, 1.0)
		var core_scale_y: float = scale_y
		core.scale = Vector2(core_scale_x, core_scale_y)
		core.rotation = angle
		core.position = base_pos
		core.z_index = 6

	# === WINDOW GLOW (soft radial at the tile) ================================
	if window_glow_enabled:
		var glow: PointLight2D = PointLight2D.new()
		add_child(glow)

		if window_glow_texture != null:
			glow.texture = window_glow_texture
		else:
			glow.texture = _make_window_glow_cookie()

		glow.color = window_glow_color
		var glow_energy: float = window_glow_energy
		if force_high_energy_debug and glow_energy < 3.5:
			glow_energy = 3.5
		glow.energy = glow_energy

		glow.shadow_enabled = false
		glow.blend_mode = Light2D.BLEND_MODE_ADD
		glow.range_item_cull_mask = affect_item_mask_bits
		glow.range_layer_min = -100
		glow.range_layer_max = 100

		# Scale the radial cookie to requested radius.
		var gw: float = 256.0
		var gh: float = 256.0
		if glow.texture != null:
			gw = float(glow.texture.get_width())
			gh = float(glow.texture.get_height())
		if gw <= 0.0:
			gw = 256.0
		if gh <= 0.0:
			gh = 256.0
		var glow_scale: float = (window_glow_radius_px * 2.0) / max(gw, gh)
		glow.scale = Vector2(glow_scale, glow_scale)

		# Place at the window edge, nudged slightly into the room.
		var glow_pos: Vector2 = window_center_local + edge_offset + (dir * max(0.0, window_glow_inset_px))
		glow.position = glow_pos
		glow.z_index = 6

		if debug_logging:
			print("[WindowBeams2D] Glow@ cell ", cell, " r_px=", window_glow_radius_px, " pos=", glow.position)

# ===== HELPERS ================================================================

func _get_window_dir(cell: Vector2i) -> Vector2:
	var td: TileData = _win.get_cell_tile_data(cell)
	if td == null:
		return Vector2.ZERO
	if not td.has_custom_data(KEY_WINDOW_DIR):
		return Vector2.ZERO

	var code_v: Variant = td.get_custom_data(KEY_WINDOW_DIR)
	if not (code_v is String):
		return Vector2.ZERO

	var code: String = code_v as String
	var dir: Vector2 = Vector2.ZERO
	if code == "N":
		dir = Vector2(0.0, -1.0)
	elif code == "E":
		dir = Vector2(1.0, 0.0)
	elif code == "S":
		dir = Vector2(0.0, 1.0)
	elif code == "W":
		dir = Vector2(-1.0, 0.0)
	return dir

func _angle_for_dir(dir: Vector2) -> float:
	if dir.y < 0.0:
		return -PI * 0.5
	if dir.y > 0.0:
		return PI * 0.5
	if dir.x > 0.0:
		return 0.0
	if dir.x < 0.0:
		return PI
	return 0.0

func _edge_offset_for_dir(dir: Vector2) -> Vector2:
	if dir.y < 0.0:
		return Vector2(0.0, -tile_size.y * 0.5)
	if dir.y > 0.0:
		return Vector2(0.0, tile_size.y * 0.5)
	if dir.x > 0.0:
		return Vector2(tile_size.x * 0.5, 0.0)
	if dir.x < 0.0:
		return Vector2(-tile_size.x * 0.5, 0.0)
	return Vector2.ZERO

func _trace_open_tiles(start_cell: Vector2i, dir: Vector2) -> int:
	if _col == null:
		return beam_max_tiles

	var steps: int = 0
	var cursor: Vector2i = start_cell
	var delta: Vector2i = Vector2i(int(dir.x), int(dir.y))

	while steps < beam_max_tiles:
		cursor = cursor + delta
		var sid: int = _col.get_cell_source_id(cursor)
		if sid != -1:
			break
		steps += 1
	return steps

func _cell_center_local(layer: TileMapLayer, cell: Vector2i) -> Vector2:
	var map_local: Vector2 = layer.map_to_local(cell)
	var map_global: Vector2 = layer.to_global(map_local)
	var my_local: Vector2 = to_local(map_global)
	return my_local

# ===== DAY / NIGHT ============================================================

func _apply_day_state() -> void:
	var is_day: bool = true
	if _dn != null and _dn.has_method("is_day"):
		var v: Variant = _dn.call("is_day")
		if v is bool:
			is_day = v
	if force_day_debug:
		is_day = true

	var kids: Array[Node] = get_children()
	for n in kids:
		var l: PointLight2D = n as PointLight2D
		if l == null:
			continue
		l.visible = is_day
		if is_day:
			var target_energy: float = light_energy_day * max(0.0, beam_brightness_scale)
			if force_high_energy_debug and target_energy < 3.5:
				target_energy = 3.5
			l.energy = target_energy
		else:
			l.energy = 0.0

# ===== DEFAULT COOKIES ========================================================

func _make_default_cookie() -> Texture2D:
	var grad: Gradient = Gradient.new()
	grad.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	grad.offsets = PackedFloat32Array([0.0, 1.0])

	var gt: GradientTexture2D = GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	return gt

func _make_window_glow_cookie() -> Texture2D:
	var grad: Gradient = Gradient.new()
	# Bright center → soft edge
	grad.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, 1.0),
		Color(1.0, 1.0, 1.0, 0.0)
	])
	grad.offsets = PackedFloat32Array([0.0, 1.0])

	var gt: GradientTexture2D = GradientTexture2D.new()
	gt.gradient = grad
	gt.width = 256
	gt.height = 256
	gt.fill = GradientTexture2D.FILL_RADIAL
	return gt
