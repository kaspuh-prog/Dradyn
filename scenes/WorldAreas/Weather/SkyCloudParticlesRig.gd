@tool
extends Node2D
class_name SkyCloudParticlesRig
# Godot 4.5 — typed, no ternaries.
# Particle-based parallax cloud layer:
# Parallax2D (camera-relative parallax) + GPUParticles2D (drifting wisps).
#
# Expected node tree:
#   SkyCloudParticlesRig (Node2D)
#     CloudParallax (Parallax2D)
#       Clouds (GPUParticles2D)

@export_group("Render / Parallax")
@export var rig_z_index: int = 20
@export var scroll_scale: Vector2 = Vector2(0.05, 0.00)
@export var autoscroll_px_per_sec: Vector2 = Vector2(0.0, 0.0)
@export var show_in_game: bool = true
@export var update_in_editor: bool = true

@export_group("Follow Camera")
@export var follow_camera: bool = true
@export var follow_camera_use_leader_group: bool = true

@export_group("Particles")
@export var cloud_particle_texture: Texture2D
@export_range(16, 1000, 1) var particle_amount: int = 220
@export_range(1.0, 60.0, 0.1) var particle_lifetime_sec: float = 18.0
@export var emission_box_size_px: Vector2 = Vector2(2200.0, 1400.0)

@export_range(0.0, 60.0, 0.1) var drift_speed_min: float = 4.0
@export_range(0.0, 60.0, 0.1) var drift_speed_max: float = 12.0
@export_range(0.0, 360.0, 0.1) var drift_direction_deg: float = 0.0
@export_range(0.0, 45.0, 0.1) var drift_spread_deg: float = 6.0

@export_range(0.1, 6.0, 0.01) var particle_scale_min: float = 1.3
@export_range(0.1, 6.0, 0.01) var particle_scale_max: float = 2.6

@export_range(0.0, 1.0, 0.001) var base_alpha: float = 0.10
@export var base_rgb: Color = Color(1.0, 1.0, 1.0, 1.0)

@export_group("Flipbook Random Shape")
@export var use_flipbook: bool = false
@export_range(1, 64, 1) var flipbook_h_frames: int = 4
@export_range(1, 64, 1) var flipbook_v_frames: int = 4
@export var flipbook_loop: bool = false
@export var flipbook_random_frame_on_emit: bool = true
@export var particles_blend_mode: CanvasItemMaterial.BlendMode = CanvasItemMaterial.BLEND_MODE_MIX

@export_group("Time Of Day Tint (subtle)")
@export var use_time_of_day_tint: bool = true
@export_range(0.0, 1.0, 0.01) var tint_strength: float = 0.25
@export_range(0.0, 0.25, 0.001) var tint_fade_width_normalized: float = 0.06
@export var day_tint: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var dusk_tint: Color = Color(1.0, 0.92, 0.82, 1.0)
@export var night_tint: Color = Color(0.72, 0.80, 1.0, 1.0)

var _parallax: Parallax2D
var _particles: GPUParticles2D

var _dn: DayNight
var _cached_time: float = 0.0
var _cached_cam: Node2D
var _last_signature: int = 0

func _ready() -> void:
	_cache_nodes()
	_resolve_daynight()
	_refresh_camera_cache()
	_update_follow_camera()
	_apply_all()

func _exit_tree() -> void:
	_disconnect_daynight()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		if update_in_editor == false:
			return
		var sig: int = _compute_signature()
		if sig == _last_signature:
			return
		_cache_nodes()
		_apply_all()
		return

	if follow_camera:
		_update_follow_camera()

func _cache_nodes() -> void:
	_parallax = get_node_or_null("CloudParallax") as Parallax2D
	if _parallax == null:
		_particles = null
		return
	_particles = get_node_or_null("CloudParallax/Clouds") as GPUParticles2D

func _refresh_camera_cache() -> void:
	_cached_cam = null

	if follow_camera_use_leader_group:
		var cam_node: Node = get_tree().get_first_node_in_group("LeaderCamera")
		if cam_node != null:
			var cam2d: Node2D = cam_node as Node2D
			if cam2d != null:
				_cached_cam = cam2d
				return

	var vp_cam: Camera2D = get_viewport().get_camera_2d()
	if vp_cam != null:
		_cached_cam = vp_cam

func _update_follow_camera() -> void:
	if _cached_cam == null:
		_refresh_camera_cache()
	if _cached_cam == null:
		return
	global_position = _cached_cam.global_position

func _resolve_daynight() -> void:
	_disconnect_daynight()

	var n: Node = get_node_or_null("/root/DayandNight")
	if n == null:
		_dn = null
		return

	_dn = n as DayNight
	if _dn == null:
		return

	if _dn.is_connected("time_changed", Callable(self, "_on_time_changed")) == false:
		_dn.connect("time_changed", Callable(self, "_on_time_changed"))

	_cached_time = _dn.get_time_normalized()

func _disconnect_daynight() -> void:
	if _dn == null:
		return
	if _dn.is_connected("time_changed", Callable(self, "_on_time_changed")):
		_dn.disconnect("time_changed", Callable(self, "_on_time_changed"))
	_dn = null

func _on_time_changed(t: float) -> void:
	_cached_time = t
	_apply_time_tint()

func _apply_all() -> void:
	_last_signature = _compute_signature()

	visible = show_in_game

	if _parallax == null:
		push_warning("SkyCloudParticlesRig: Missing child node 'CloudParallax' (Parallax2D).")
		return
	if _particles == null:
		push_warning("SkyCloudParticlesRig: Missing child node 'CloudParallax/Clouds' (GPUParticles2D).")
		return

	_parallax.z_index = rig_z_index
	_parallax.follow_viewport = false
	_parallax.ignore_camera_scroll = true
	_parallax.scroll_scale = scroll_scale
	_parallax.autoscroll = autoscroll_px_per_sec

	_particles.emitting = true
	_particles.one_shot = false
	_particles.amount = particle_amount
	_particles.lifetime = particle_lifetime_sec
	_particles.preprocess = particle_lifetime_sec
	_particles.speed_scale = 1.0
	_particles.randomness = 1.0
	_particles.local_coords = true
	_particles.texture = cloud_particle_texture
	_particles.visibility_rect = _compute_visibility_rect()

	_configure_flipbook_material()

	var pm: ParticleProcessMaterial = _get_or_create_process_material()
	_apply_process_material(pm)
	_apply_time_tint()

func _configure_flipbook_material() -> void:
	# Flipbook requires a CanvasItemMaterial on GPUParticles2D.material.
	var cim: CanvasItemMaterial = _particles.material as CanvasItemMaterial
	if cim == null:
		cim = CanvasItemMaterial.new()
		_particles.material = cim

	cim.blend_mode = particles_blend_mode

	if use_flipbook == false:
		cim.particles_animation = false
		return

	cim.particles_animation = true
	cim.particles_anim_h_frames = max(1, flipbook_h_frames)
	cim.particles_anim_v_frames = max(1, flipbook_v_frames)
	cim.particles_anim_loop = flipbook_loop

func _get_or_create_process_material() -> ParticleProcessMaterial:
	var pm: ParticleProcessMaterial = _particles.process_material as ParticleProcessMaterial
	if pm != null:
		return pm

	pm = ParticleProcessMaterial.new()
	_particles.process_material = pm
	return pm

func _apply_process_material(pm: ParticleProcessMaterial) -> void:
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(emission_box_size_px.x * 0.5, emission_box_size_px.y * 0.5, 0.0)

	var dir: Vector2 = Vector2.RIGHT.rotated(deg_to_rad(drift_direction_deg))
	pm.direction = Vector3(dir.x, dir.y, 0.0)
	pm.spread = drift_spread_deg

	pm.gravity = Vector3(0.0, 0.0, 0.0)
	pm.initial_velocity_min = drift_speed_min
	pm.initial_velocity_max = drift_speed_max

	pm.scale_min = particle_scale_min
	pm.scale_max = particle_scale_max

	var c: Color = base_rgb
	c.a = base_alpha
	pm.color = c

	# Flipbook randomization: pick a random frame on emission (no playback).
	# Godot docs: set Speed Min/Max to 0, set Offset Max to 1. :contentReference[oaicite:1]{index=1}
	if use_flipbook and flipbook_random_frame_on_emit:
		pm.anim_speed_min = 0.0
		pm.anim_speed_max = 0.0
		pm.anim_offset_min = 0.0
		pm.anim_offset_max = 1.0
	elif use_flipbook:
		# Default to simple linear playback across lifetime if user enables flipbook but disables random frame.
		pm.anim_speed_min = 1.0
		pm.anim_speed_max = 1.0
		pm.anim_offset_min = 0.0
		pm.anim_offset_max = 0.0

func _apply_time_tint() -> void:
	if use_time_of_day_tint == false:
		return
	if _particles == null:
		return

	var pm: ParticleProcessMaterial = _particles.process_material as ParticleProcessMaterial
	if pm == null:
		return

	var tcol: Color = _compute_time_tint(_cached_time)

	var base: Color = base_rgb
	var out: Color = base
	out.r = lerpf(base.r, base.r * tcol.r, tint_strength)
	out.g = lerpf(base.g, base.g * tcol.g, tint_strength)
	out.b = lerpf(base.b, base.b * tcol.b, tint_strength)
	out.a = base_alpha

	pm.color = out

func _compute_time_tint(t: float) -> Color:
	var sunrise: float = 0.25
	var sunset: float = 0.75
	if _dn != null:
		sunrise = _dn.sunrise
		sunset = _dn.sunset

	var w: float = clampf(tint_fade_width_normalized, 0.0, 0.25)

	if sunrise < sunset:
		if t < (sunrise - w) or t > (sunset + w):
			return night_tint

		if t >= (sunrise - w) and t <= (sunrise + w):
			var u: float = inverse_lerp(sunrise - w, sunrise + w, t)
			if u < 0.5:
				return night_tint.lerp(dusk_tint, u * 2.0)
			return dusk_tint.lerp(day_tint, (u - 0.5) * 2.0)

		if t >= (sunset - w) and t <= (sunset + w):
			var v: float = inverse_lerp(sunset - w, sunset + w, t)
			if v < 0.5:
				return day_tint.lerp(dusk_tint, v * 2.0)
			return dusk_tint.lerp(night_tint, (v - 0.5) * 2.0)

		return day_tint

	var is_day_wrap: bool = false
	if t >= sunrise:
		is_day_wrap = true
	if t < sunset:
		is_day_wrap = true

	if is_day_wrap:
		return day_tint
	return night_tint

func _compute_visibility_rect() -> Rect2:
	var w: float = maxf(256.0, emission_box_size_px.x)
	var h: float = maxf(256.0, emission_box_size_px.y)
	var pad_x: float = w * 0.25
	var pad_y: float = h * 0.25
	return Rect2(Vector2(-w * 0.5 - pad_x, -h * 0.5 - pad_y), Vector2(w + pad_x * 2.0, h + pad_y * 2.0))

func _compute_signature() -> int:
	var h: int = 17
	h = int(h * 31 + rig_z_index)

	h = int(h * 31 + int(scroll_scale.x * 1000.0))
	h = int(h * 31 + int(scroll_scale.y * 1000.0))
	h = int(h * 31 + int(autoscroll_px_per_sec.x * 1000.0))
	h = int(h * 31 + int(autoscroll_px_per_sec.y * 1000.0))

	h = int(h * 31 + particle_amount)
	h = int(h * 31 + int(particle_lifetime_sec * 1000.0))
	h = int(h * 31 + int(emission_box_size_px.x))
	h = int(h * 31 + int(emission_box_size_px.y))

	h = int(h * 31 + int(drift_speed_min * 1000.0))
	h = int(h * 31 + int(drift_speed_max * 1000.0))
	h = int(h * 31 + int(drift_direction_deg * 1000.0))
	h = int(h * 31 + int(drift_spread_deg * 1000.0))

	h = int(h * 31 + int(particle_scale_min * 1000.0))
	h = int(h * 31 + int(particle_scale_max * 1000.0))

	h = int(h * 31 + int(base_alpha * 1000.0))
	h = int(h * 31 + int(base_rgb.r * 255.0))
	h = int(h * 31 + int(base_rgb.g * 255.0))
	h = int(h * 31 + int(base_rgb.b * 255.0))

	if use_flipbook:
		h = int(h * 31 + 1)
	else:
		h = int(h * 31 + 0)

	if flipbook_random_frame_on_emit:
		h = int(h * 31 + 1)
	else:
		h = int(h * 31 + 0)

	h = int(h * 31 + flipbook_h_frames)
	h = int(h * 31 + flipbook_v_frames)

	if cloud_particle_texture != null:
		h = int(h * 31 + cloud_particle_texture.get_rid().get_id())

	return h
