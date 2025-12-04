extends Node2D
class_name TileTorchLights
# Auto-spawn flickering point lights on torch tiles inside a TileMapLayer.
# Night-aware energy boost + emissive color compensation so flames stay vivid under night overlay.
# Listens to "NightOverlayListeners" broadcasts from NightDarkenOverlay2D.

# --- Configuration: Tiles -----------------------------------------------------
@export var target_layer_path: NodePath
@export var custom_data_key: String = "torch"
@export var torch_source_ids: Array[int] = []
@export var torch_atlas_coords: Array[Vector2i] = []

# --- Configuration: Light look ------------------------------------------------
@export var light_radius_pixels: int = 160
@export var light_energy_base: float = 1.1
@export var light_energy_variation: float = 0.18
@export var use_shadows: bool = false
@export var affect_mask: int = 1

@export var cell_center_offset: Vector2 = Vector2(8.0, 8.0)
@export var sprite_vertical_nudge: float = -2.0

@export var flicker_speed_hz: float = 18.0
@export var position_jitter_pixels: float = 0.6

# --- Night awareness (match overlay windows) ---------------------------------
@export var day_night_node_path: NodePath = NodePath("/root/DayandNight")
@export_range(0.0, 1.0, 0.001) var dusk_start: float = 0.72
@export_range(0.0, 1.0, 0.001) var night_start: float = 0.80
@export_range(0.0, 1.0, 0.001) var night_end: float = 0.20
@export_range(0.0, 1.0, 0.001) var dawn_end: float = 0.28
@export var use_curve: bool = false
@export var night_factor_curve: Curve
@export var night_energy_boost_at_full: float = 2.0
@export var night_boost_power: float = 1.0

# --- Emissive compensation (shader on the torch TileMapLayer) ----------------
@export_range(0.0, 1.0, 0.01) var emissive_threshold: float = 0.55
@export_range(0.0, 1.0, 0.01) var emissive_softness: float = 0.20
@export_range(0.8, 3.0, 0.01) var emissive_max_boost: float = 1.75

const LIGHT_BLEND_ADD: Light2D.BlendMode = Light2D.BLEND_MODE_ADD

var _layer: TileMapLayer = null
var _lights: Array[PointLight2D] = []
var _orig_positions: Array[Vector2] = []
var _phases: Array[float] = []
var _shared_light_texture: Texture2D = null

var _dn: Node = null
var _night_factor: float = 0.0
var _is_day_cached: bool = true

var _emissive_shader: Shader = null
var _emissive_mat: ShaderMaterial = null

func _ready() -> void:
	add_to_group("NightOverlayListeners") # <-- listen for overlay RGB
	_layer = get_node_or_null(target_layer_path) as TileMapLayer
	if _layer == null:
		push_error("[TileTorchLights] target_layer_path is not set or not a TileMapLayer.")
		return

	_install_emissive_compensation_material()
	_build_or_refresh_lights()

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

	var is_day_now: bool = true
	if _dn != null and _dn.has_method("is_day"):
		var v: Variant = _dn.call("is_day")
		if v is bool:
			is_day_now = v
	_is_day_cached = is_day_now
	if is_day_now:
		_night_factor = 0.0
	else:
		_night_factor = 1.0
		if _dn != null and _dn.has_method("get_normalized_time"):
			var t_v: Variant = _dn.call("get_normalized_time")
			if t_v is float:
				_night_factor = _time_to_factor(t_v)

	set_process(true)

func _exit_tree() -> void:
	if is_in_group("NightOverlayListeners"):
		remove_from_group("NightOverlayListeners")

func _process(delta: float) -> void:
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
			if energy < 0.05:
				energy = 0.05
			energy = energy * boost
			L.energy = energy

			var offx: float = (_noise_hashi(Time.get_ticks_msec() * 13 + i * 131) - 0.5) * 2.0
			var offy: float = (_noise_hashi(Time.get_ticks_msec() * 17 + i * 173) - 0.5) * 2.0
			var jitter: Vector2 = Vector2(offx, offy) * position_jitter_pixels
			L.position = _orig_positions[i] + jitter
		i += 1

# --- Emissive compensation material ------------------------------------------

func _install_emissive_compensation_material() -> void:
	# CanvasItem shader: compensates overlay only on bright (flame) pixels.
	# Reads a regular uniform u_overlay_rgb that we update from overlay broadcasts.
	if _emissive_shader == null:
		_emissive_shader = Shader.new()
		_emissive_shader.code = """
shader_type canvas_item;

uniform vec3 u_overlay_rgb = vec3(1.0, 1.0, 1.0);
uniform float u_emissive_threshold : hint_range(0.0, 1.0) = 0.55;
uniform float u_emissive_softness  : hint_range(0.0, 1.0) = 0.20;
uniform float u_emissive_max_boost : hint_range(0.8, 3.0) = 1.75;

float luminance(vec3 c) {
	return dot(c, vec3(0.299, 0.587, 0.114));
}

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	float lum = luminance(src.rgb);
	float k = smoothstep(u_emissive_threshold - u_emissive_softness,
	                     u_emissive_threshold + u_emissive_softness, lum);

	// Compensation factor: inverse of overlay RGB, clamped to avoid blowout.
	vec3 inv = 1.0 / max(u_overlay_rgb, vec3(0.001));
	inv = clamp(inv, vec3(1.0), vec3(u_emissive_max_boost));

	vec3 compensated = mix(src.rgb, src.rgb * inv, k);
	COLOR = vec4(compensated, src.a);
}
"""
	if _emissive_mat == null:
		_emissive_mat = ShaderMaterial.new()
		_emissive_mat.shader = _emissive_shader

	_emissive_mat.set_shader_parameter("u_emissive_threshold", emissive_threshold)
	_emissive_mat.set_shader_parameter("u_emissive_softness", emissive_softness)
	_emissive_mat.set_shader_parameter("u_emissive_max_boost", emissive_max_boost)
	_emissive_mat.set_shader_parameter("u_overlay_rgb", Vector3(1.0, 1.0, 1.0))

	_layer.material = _emissive_mat

# Called by the overlay via SceneTree.call_group("NightOverlayListeners", ...).
func _night_overlay_rgb_changed(rgb: Vector3) -> void:
	if _emissive_mat != null:
		_emissive_mat.set_shader_parameter("u_overlay_rgb", rgb)

# --- Day/Night hooks ----------------------------------------------------------

func _on_phase_changed(is_day: bool) -> void:
	_is_day_cached = is_day
	if is_day:
		_night_factor = 0.0
	else:
		_night_factor = 1.0
		if _dn != null and _dn.has_method("get_normalized_time"):
			var v: Variant = _dn.call("get_normalized_time")
			if v is float:
				_night_factor = _time_to_factor(v)

func _on_time_changed(normalized_time: float) -> void:
	if _is_day_cached:
		return
	_night_factor = _time_to_factor(normalized_time)

# --- Torch building / teardown ------------------------------------------------

func _on_layer_changed() -> void:
	_build_or_refresh_lights()

func _build_or_refresh_lights() -> void:
	_clear_lights()

	if _shared_light_texture == null:
		_shared_light_texture = _make_radial_texture(light_radius_pixels)

	var used: Array[Vector2i] = _layer.get_used_cells()
	for cell in used:
		var td: TileData = _layer.get_cell_tile_data(cell)
		if td == null:
			continue
		if not _cell_is_torch(cell, td):
			continue

		var pos: Vector2 = _layer.map_to_local(cell) + cell_center_offset + Vector2(0.0, sprite_vertical_nudge)

		var L: PointLight2D = PointLight2D.new()
		L.blend_mode = LIGHT_BLEND_ADD
		L.texture = _shared_light_texture
		L.energy = light_energy_base
		L.shadow_enabled = use_shadows
		L.range_item_cull_mask = affect_mask
		L.range_layer_min = -100
		L.range_layer_max = 100
		L.z_as_relative = true
		L.z_index = 1

		if L.texture != null and L.texture.get_width() > 0:
			L.texture_scale = float(light_radius_pixels) / float(L.texture.get_width()) * 2.0

		add_child(L)
		L.position = pos

		_lights.append(L)
		_orig_positions.append(pos)
		_phases.append(randf() * PI * 2.0)

# --- Torch detection ----------------------------------------------------------

func _cell_is_torch(cell: Vector2i, td: TileData) -> bool:
	if td.has_custom_data(custom_data_key):
		var v: Variant = td.get_custom_data(custom_data_key)
		var b: bool = false
		if typeof(v) == TYPE_BOOL:
			b = bool(v)
		elif typeof(v) == TYPE_INT:
			b = int(v) != 0
		elif typeof(v) == TYPE_STRING:
			b = String(v).to_lower() == "true"
		if b:
			return true

	var sid: int = _layer.get_cell_source_id(cell)
	var i: int = 0
	while i < torch_source_ids.size():
		if sid == torch_source_ids[i]:
			return true
		i += 1

	var coord: Vector2i = _layer.get_cell_atlas_coords(cell)
	i = 0
	while i < torch_atlas_coords.size():
		if coord == torch_atlas_coords[i]:
			return true
		i += 1

	return false

# --- Teardown -----------------------------------------------------------------

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

# --- Helpers ------------------------------------------------------------------

func _make_radial_texture(radius_px: int) -> Texture2D:
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
			var a: float = pow(t, 2.2)
			var rr: float = 1.0
			var gg: float = 0.85 + 0.15 * t
			var bb: float = 0.6 + 0.2 * t
			img.set_pixel(x, y, Color(rr, gg, bb, a))
			x += 1
		y += 1

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	return tex

func _noise_hashi(n: int) -> float:
	var x: int = int(n)
	x = ((x >> 13) ^ x)
	var v: int = (x * (x * x * 15731 + 789221) + 1376312589) & 0x7fffffff
	return float(v) / 1073741824.0

# --- Night factor -------------------------------------------------------------

func _time_to_factor(t: float) -> float:
	if use_curve and night_factor_curve != null:
		var s: float = night_factor_curve.sample_baked(t)
		if s < 0.0:
			s = 0.0
		if s > 1.0:
			s = 1.0
		return s

	if t >= dusk_start and t <= night_start:
		var span: float = night_start - dusk_start
		if span <= 0.0:
			return 1.0
		return (t - dusk_start) / span

	if t >= night_start or t <= night_end:
		return 1.0

	if t > night_end and t <= dawn_end:
		var span2: float = dawn_end - night_end
		if span2 <= 0.0:
			return 0.0
		return 1.0 - ((t - night_end) / span2)

	return 0.0
