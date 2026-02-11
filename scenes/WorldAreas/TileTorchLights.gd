extends Node2D
class_name TileTorchLights
# Auto-spawn flickering point lights on torch tiles inside a TileMapLayer.
# Night-aware energy boost (optional) + torch detection.
# Listens to "NightOverlayListeners" broadcasts from NightDarkenOverlay2D.

# --- Configuration: Tiles -----------------------------------------------------
@export var target_layer_path: NodePath
@export var custom_data_key: String = "torch"
@export var torch_source_ids: Array[int] = []
@export var torch_atlas_coords: Array[Vector2i] = []

# --- Configuration: Light look ------------------------------------------------
@export var light_radius_pixels: int = 160

# Conservative defaults for pixel art.
@export var light_energy_base: float = 0.32
@export var light_energy_variation: float = 0.06
@export var use_shadows: bool = false
@export var affect_mask: int = 1

# NEW: Occlusion / shadow interaction control.
# Turning off TileMapLayer "Occlusion" fixed your issue, which strongly suggests occluder polygons
# from that layer are clipping these torch lights. This lets torches ignore occluders while keeping
# occlusion enabled for other lights.
@export var ignore_occluders_for_torches: bool = true
@export var shadow_item_cull_mask: int = 1

@export var light_color: Color = Color(1.0, 0.82, 0.62, 1.0)

@export var cell_center_offset: Vector2 = Vector2(8.0, 8.0)
@export var sprite_vertical_nudge: float = -2.0

@export var flicker_speed_hz: float = 14.0
@export var flicker_amplitude_pixels: float = 0.45

# --- Night awareness (match overlay windows) ---------------------------------
@export var day_night_node_path: NodePath = NodePath("/root/DayandNight")
@export_range(0.0, 1.0, 0.001) var dusk_start: float = 0.72
@export_range(0.0, 1.0, 0.001) var night_start: float = 0.80
@export_range(0.0, 1.0, 0.001) var night_end: float = 0.20
@export_range(0.0, 1.0, 0.001) var dawn_end: float = 0.28
@export var use_curve: bool = true
@export var night_factor_curve: Curve

@export var night_energy_boost_at_full: float = 1.25
@export var night_boost_power: float = 1.0

# Daytime control + smoother glow
@export var disable_in_day: bool = true
@export var linear_filter_for_glow: bool = true
@export var day_energy_multiplier: float = 0.0

# Blend mode: ADD gives actual “glow”. MIX can produce dark-fog artifacts.
@export var use_additive_blend: bool = true

# --- Emissive compensation (optional) ----------------------------------------
# IMPORTANT: This feature swaps the TileMapLayer material and can affect daylight rendering.
# Default OFF to avoid global darkening.
@export var install_emissive_compensation_material: bool = false
@export var emissive_strength_at_full_night: float = 0.75
@export var emissive_color: Color = Color(1.0, 0.72, 0.35, 1.0)

# --- Debug -------------------------------------------------------------------
@export var debug_logging: bool = false
@export var log_non_torch_cells: bool = false
@export var debug_log_layer_changed_events: bool = false
@export var debug_log_rebuild_counts: bool = false
@export var debug_log_rebuild_diffs: bool = false
@export var debug_diff_max_cells: int = 12

# If your lights flicker on/off in a rectangle, enable the flags above to see whether
# the TileMapLayer is emitting 'changed' while you walk (which forces a rebuild).

# ----------------------------- runtime ---------------------------------------
var _layer: TileMapLayer
var _dn: Node
var _lights: Array[PointLight2D] = []
var _orig_positions: Array[Vector2] = []
var _phases: Array[float] = []
var _shared_light_texture: Texture2D

var _night_factor: float = 0.0
var _is_day_cached: bool = true

# Rebuild diagnostics
var _last_rebuild_torch_cells: Dictionary = {}
var _rebuild_counter: int = 0
var _last_rebuild_time_sec: float = 0.0

# Emissive compensation material
var _emissive_mat: ShaderMaterial
var _original_material: Material
var _material_overridden: bool = false

func _ready() -> void:
	add_to_group("NightOverlayListeners") # <-- listen for overlay RGB
	_layer = get_node_or_null(target_layer_path) as TileMapLayer
	if _layer == null:
		push_error("[TileTorchLights] target_layer_path is not set or not a TileMapLayer.")
		return

	_install_emissive_compensation_material()
	_build_or_refresh_lights()
	_apply_phase_visibility()

	if _layer.has_signal("changed"):
		if not _layer.is_connected("changed", Callable(self, "_on_layer_changed")):
			_layer.connect("changed", Callable(self, "_on_layer_changed"))

	_dn = get_node_or_null(day_night_node_path)
	if _dn != null:
		if _dn.has_signal("phase_changed"):
			if not _dn.is_connected("phase_changed", Callable(self, "_on_phase_changed")):
				_dn.connect("phase_changed", Callable(self, "_on_phase_changed"))
		if _dn.has_signal("time_changed"):
			if not _dn.is_connected("time_changed", Callable(self, "_on_time_changed")):
				_dn.connect("time_changed", Callable(self, "_on_time_changed"))

		# Prime from current phase/time so first frame is correct.
		if _dn.has_method("is_day"):
			var d: Variant = _dn.call("is_day")
			if d is bool:
				_on_phase_changed(bool(d))
		if not _is_day_cached and _dn.has_method("get_time_normalized"):
			var tn: Variant = _dn.call("get_time_normalized")
			if tn is float:
				_on_time_changed(float(tn))

func _exit_tree() -> void:
	# If we ever swapped the TileMapLayer material, restore it on teardown.
	if _layer != null and _material_overridden:
		_layer.material = _original_material
		_material_overridden = false

func _process(delta: float) -> void:
	if disable_in_day and _is_day_cached:
		return

	var i: int = 0
	while i < _lights.size():
		var L: PointLight2D = _lights[i]
		if L != null and is_instance_valid(L):
			_phases[i] += delta * flicker_speed_hz * 2.0 * PI

			var s: float = (sin(_phases[i]) + 1.0) * 0.5
			var r: float = _noise_hashi(Time.get_ticks_msec() + i * 97)

			var boost_linear: float = 1.0 + _night_factor * (max(1.0, night_energy_boost_at_full) - 1.0)
			var boost: float = boost_linear
			if night_boost_power != 1.0:
				var t: float = _night_factor
				if t < 0.0:
					t = 0.0
				if t > 1.0:
					t = 1.0
				var shaped: float = pow(t, max(0.0001, night_boost_power))
				boost = 1.0 + shaped * (max(1.0, night_energy_boost_at_full) - 1.0)

			var energy: float = light_energy_base + (s - 0.5) * light_energy_variation * 0.8 + (r - 0.5) * light_energy_variation * 0.2
			if energy < 0.02:
				energy = 0.02
			energy = energy * boost
			if _is_day_cached:
				energy = energy * day_energy_multiplier
			L.energy = energy

			var nudge: float = (s - 0.5) * flicker_amplitude_pixels
			L.position = _orig_positions[i] + Vector2(nudge, -nudge * 0.7)
		i += 1

# --- Overlay listener hook ----------------------------------------------------
# Called by NightDarkenOverlay2D via group broadcast.
func set_overlay_factor(rgb: Vector3, factor: float) -> void:
	_night_factor = clamp(factor, 0.0, 1.0)
	_update_emissive_compensation()

# --- Emissive compensation ----------------------------------------------------
func _install_emissive_compensation_material() -> void:
	# Default OFF to avoid affecting daylight rendering.
	if not install_emissive_compensation_material:
		return
	if _layer == null:
		return

	_original_material = _layer.material
	_emissive_mat = ShaderMaterial.new()
	_emissive_mat.shader = _make_emissive_shader()
	_layer.material = _emissive_mat
	_material_overridden = true
	_update_emissive_compensation()

func _update_emissive_compensation() -> void:
	if _emissive_mat == null:
		return
	var strength: float = emissive_strength_at_full_night * _night_factor
	_emissive_mat.set_shader_parameter("u_emissive_strength", strength)
	_emissive_mat.set_shader_parameter("u_emissive_color", emissive_color)

func _make_emissive_shader() -> Shader:
	var code: String = ""
	code += "shader_type canvas_item;\n"
	code += "uniform float u_emissive_strength = 0.0;\n"
	code += "uniform vec4 u_emissive_color : source_color = vec4(1.0, 0.7, 0.35, 1.0);\n"
	code += "void fragment() {\n"
	code += "\tvec4 c = texture(TEXTURE, UV) * COLOR;\n"
	code += "\tc.rgb += u_emissive_color.rgb * u_emissive_strength * c.a;\n"
	code += "\tCOLOR = c;\n"
	code += "}\n"
	var sh: Shader = Shader.new()
	sh.code = code
	return sh

# --- Day/Night signals --------------------------------------------------------
func _on_phase_changed(is_day: bool) -> void:
	_is_day_cached = is_day
	if is_day:
		_night_factor = 0.0
	else:
		_night_factor = 1.0
		if _dn != null and (_dn.has_method("get_time_normalized") or _dn.has_method("get_normalized_time")):
			var method_name: StringName = StringName("")
			if _dn.has_method("get_time_normalized"):
				method_name = StringName("get_time_normalized")
			elif _dn.has_method("get_normalized_time"):
				method_name = StringName("get_normalized_time")
			if method_name != StringName(""):
				var v: Variant = _dn.call(method_name)
				if v is float:
					_night_factor = _time_to_factor(v)

	_update_emissive_compensation()
	_apply_phase_visibility()

func _on_time_changed(t: float) -> void:
	if _is_day_cached:
		return
	_night_factor = _time_to_factor(t)
	_update_emissive_compensation()

func _time_to_factor(t: float) -> float:
	var tn: float = t
	if tn < 0.0:
		tn = 0.0
	if tn > 1.0:
		tn = 1.0

	if use_curve and night_factor_curve != null:
		return clamp(night_factor_curve.sample_baked(tn), 0.0, 1.0)

	# Piecewise linear, wrapping across midnight:
	# dusk_start -> night_start ramps 0..1
	# night_start -> night_end stays 1 (across midnight)
	# night_end -> dawn_end ramps 1..0
	if dusk_start <= night_start and tn >= dusk_start and tn <= night_start:
		return (tn - dusk_start) / max(0.0001, (night_start - dusk_start))

	var in_night_block: bool = false
	if night_start < night_end:
		# night does not cross midnight
		if tn >= night_start and tn <= night_end:
			in_night_block = true
	else:
		# crosses midnight
		if tn >= night_start or tn <= night_end:
			in_night_block = true

	if in_night_block:
		return 1.0

	if dawn_end >= night_end and tn >= night_end and tn <= dawn_end:
		var t2: float = (tn - night_end) / max(0.0001, (dawn_end - night_end))
		return 1.0 - t2

	return 0.0

func _apply_phase_visibility() -> void:
	if not disable_in_day:
		# Always visible; energy handles day multiplier.
		var i: int = 0
		while i < _lights.size():
			var L: PointLight2D = _lights[i]
			if L != null and is_instance_valid(L):
				L.visible = true
			i += 1
		return

	if _is_day_cached:
		var j: int = 0
		while j < _lights.size():
			var L2: PointLight2D = _lights[j]
			if L2 != null and is_instance_valid(L2):
				L2.visible = false
			j += 1
	else:
		var k: int = 0
		while k < _lights.size():
			var L3: PointLight2D = _lights[k]
			if L3 != null and is_instance_valid(L3):
				L3.visible = true
			k += 1

# --- Torch building / teardown ------------------------------------------------
func _on_layer_changed() -> void:
	_rebuild_counter += 1
	_last_rebuild_time_sec = Time.get_ticks_msec() / 1000.0
	if debug_logging and debug_log_layer_changed_events:
		print("[TileTorchLights] layer changed -> rebuild #", _rebuild_counter, " t=", _last_rebuild_time_sec, " node=", _layer.name)
	_build_or_refresh_lights()
	_apply_phase_visibility()

func _build_or_refresh_lights() -> void:
	var old_set: Dictionary = _last_rebuild_torch_cells.duplicate()
	_last_rebuild_torch_cells.clear()
	_clear_lights()

	if _shared_light_texture == null:
		_shared_light_texture = _make_radial_texture(light_radius_pixels)

	var used: Array[Vector2i] = _layer.get_used_cells()

	var torch_count: int = 0
	for cell in used:
		var td: TileData = _layer.get_cell_tile_data(cell)
		if td == null:
			continue
		if not _cell_is_torch(cell, td):
			continue

		torch_count += 1
		_last_rebuild_torch_cells[cell] = true

		var pos: Vector2 = _layer.map_to_local(cell) + cell_center_offset + Vector2(0.0, sprite_vertical_nudge)

		var L: PointLight2D = PointLight2D.new()
		if use_additive_blend:
			L.blend_mode = Light2D.BLEND_MODE_ADD
		else:
			L.blend_mode = Light2D.BLEND_MODE_MIX

		L.color = light_color
		L.texture = _shared_light_texture
		if linear_filter_for_glow:
			L.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

		L.energy = light_energy_base

		# Lighting targets.
		L.range_item_cull_mask = affect_mask
		L.range_layer_min = -100
		L.range_layer_max = 100

		# Shadow/occluder behavior:
		# - If ignore_occluders_for_torches is true, these lights will never be clipped by occluders,
		#   even if the TileMapLayer has occlusion enabled.
		# - If false, you can opt-in to shadows with use_shadows and control which occluders apply via shadow_item_cull_mask.
		if ignore_occluders_for_torches:
			L.shadow_enabled = false
			L.shadow_item_cull_mask = 0
		else:
			L.shadow_enabled = use_shadows
			L.shadow_item_cull_mask = shadow_item_cull_mask

		L.z_as_relative = true
		L.z_index = 1

		if L.texture != null and L.texture.get_width() > 0:
			L.texture_scale = float(light_radius_pixels) / float(L.texture.get_width()) * 2.0

		add_child(L)
		L.position = pos

		_lights.append(L)
		_orig_positions.append(pos)
		_phases.append(randf() * PI * 2.0)

	if debug_logging and debug_log_rebuild_counts:
		print("[TileTorchLights] rebuild #", _rebuild_counter, " used=", used.size(), " torch=", torch_count, " lights=", _lights.size())
	if debug_logging and debug_log_rebuild_diffs:
		_log_rebuild_diff(old_set, _last_rebuild_torch_cells)

func _clear_lights() -> void:
	var i: int = 0
	while i < _lights.size():
		var L: PointLight2D = _lights[i]
		if L != null and is_instance_valid(L):
			L.queue_free()
		i += 1
	_lights.clear()
	_orig_positions.clear()
	_phases.clear()

# --- Diagnostics -------------------------------------------------------------
func _log_rebuild_diff(old_set: Dictionary, new_set: Dictionary) -> void:
	var added: Array[Vector2i] = []
	var removed: Array[Vector2i] = []

	for k_any in new_set.keys():
		if not old_set.has(k_any):
			if k_any is Vector2i:
				added.append(k_any)

	for k2_any in old_set.keys():
		if not new_set.has(k2_any):
			if k2_any is Vector2i:
				removed.append(k2_any)

	if added.is_empty() and removed.is_empty():
		print("[TileTorchLights] torch-cell set unchanged.")
		return

	var a_txt: String = _cells_to_string_limited(added, debug_diff_max_cells)
	var r_txt: String = _cells_to_string_limited(removed, debug_diff_max_cells)
	print("[TileTorchLights] torch-cell diff added=", added.size(), " ", a_txt, " removed=", removed.size(), " ", r_txt)

func _cells_to_string_limited(cells: Array[Vector2i], max_cells: int) -> String:
	var n: int = cells.size()
	if n <= 0:
		return "[]"
	var limit: int = max_cells
	if limit < 1:
		limit = 1
	if limit > n:
		limit = n

	var s: String = "["
	var i: int = 0
	while i < limit:
		s += str(cells[i])
		if i < limit - 1:
			s += ", "
		i += 1
	if n > limit:
		s += ", ..."
	s += "]"
	return s

# --- Torch detection ----------------------------------------------------------
func _cell_is_torch(cell: Vector2i, td: TileData) -> bool:
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
		if log_non_torch_cells and debug_logging:
			print("[TileTorchLights] custom_data_key present but false at ", cell)
		return false

	# fallback: source_id + atlas list match
	var sid: int = _layer.get_cell_source_id(cell)
	var coords: Vector2i = _layer.get_cell_atlas_coords(cell)

	var i: int = 0
	while i < torch_source_ids.size() and i < torch_atlas_coords.size():
		if sid == torch_source_ids[i] and coords == torch_atlas_coords[i]:
			return true
		i += 1

	if log_non_torch_cells and debug_logging:
		print("[TileTorchLights] non-torch cell ", cell, " sid=", sid, " coords=", coords)
	return false

# --- Texture ------------------------------------------------------------------
func _make_radial_texture(radius_px: int) -> Texture2D:
	# Alpha “cookie”: keep RGB white, use alpha for falloff; tint comes from light_color.
	var size: int = max(32, radius_px)
	var dim: int = size * 2
	var img: Image = Image.create(dim, dim, false, Image.FORMAT_RGBA8)

	var center: Vector2 = Vector2(float(size), float(size))
	var max_r: float = float(size)

	var y: int = 0
	while y < dim:
		var x: int = 0
		while x < dim:
			var p: Vector2 = Vector2(float(x), float(y))
			var d: float = p.distance_to(center)
			var t: float = clamp(1.0 - (d / max_r), 0.0, 1.0)

			var a: float = pow(t, 2.6)
			a = a * 0.80

			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
			x += 1
		y += 1

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	return tex

func _noise_hashi(n: int) -> float:
	var x: int = int(n)
	x = ((x >> 13) ^ x)
	var v: int = (x * (x * x * 15731 + 789221) + 1376312589) & 0x7fffffff
	return float(v) / 2147483647.0
