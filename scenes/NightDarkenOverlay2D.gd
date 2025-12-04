extends ColorRect
class_name NightDarkenOverlay2D

@export var debug_logging: bool = true

# Night tint that will be multiplied into the scene as night strengthens (RGB only).
@export var night_tint_color: Color = Color(0.12, 0.16, 0.28, 1.0)

# Blend strength from WHITE -> night_tint_color at full night (0..1).
@export_range(0.0, 1.0, 0.01) var night_strength_at_max: float = 0.40

# Extra darkness: mix the tinted result toward black at full night (0..1).
@export_range(0.0, 1.0, 0.01) var night_black_mix_at_max: float = 0.25

# Dusk/Night/Dawn windows (normalized 0..1).
@export_range(0.0, 1.0, 0.001) var dusk_start: float = 0.72
@export_range(0.0, 1.0, 0.001) var night_start: float = 0.80
@export_range(0.0, 1.0, 0.001) var night_end: float = 0.20
@export_range(0.0, 1.0, 0.001) var dawn_end: float = 0.28

# Optional smoothing curve (x = time, y = factor 0..1).
@export var use_curve: bool = false
@export var night_factor_curve: Curve

# Global toggles.
@export var enabled_overlay: bool = true
@export var force_night_debug: bool = false

# Smooth night-only transitions (seconds). 0 = instant.
@export_range(0.0, 3.0, 0.01) var smooth_transition_sec: float = 0.15

var _dn: Node = null
var _mat: CanvasItemMaterial = null
var _is_day_cached: bool = true
var _active_tween: Tween = null

func _ready() -> void:
	# Fullscreen overlay; put this node under a CanvasLayer between world and HUD.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 0

	_mat = CanvasItemMaterial.new()
	_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL
	material = _mat

	# IMPORTANT: never receive 2D lights.
	light_mask = 0

	# Neutral color; visibility decides if it draws.
	color = Color(1.0, 1.0, 1.0, 1.0)

	_connect_daynight()
	_sync_from_daynight_initial()

	if debug_logging:
		print("[NightDarkenOverlay2D] Ready. light_mask=0, smooth=", smooth_transition_sec)

# --- Signal hookups -----------------------------------------------------------

func _connect_daynight() -> void:
	_dn = get_node_or_null("/root/DayandNight")
	if _dn == null:
		return
	if _dn.has_signal("phase_changed"):
		if not _dn.is_connected("phase_changed", Callable(self, "_on_phase_changed")):
			_dn.connect("phase_changed", Callable(self, "_on_phase_changed"))
	if _dn.has_signal("time_changed"):
		if not _dn.is_connected("time_changed", Callable(self, "_on_time_changed")):
			_dn.connect("time_changed", Callable(self, "_on_time_changed"))

func _sync_from_daynight_initial() -> void:
	var is_day_now: bool = true
	if _dn != null and _dn.has_method("is_day"):
		var v: Variant = _dn.call("is_day")
		if v is bool:
			is_day_now = v
	_is_day_cached = is_day_now

	if is_day_now or not enabled_overlay:
		_cancel_tween_if_any()
		visible = false
		_set_overlay_color(Color(1.0, 1.0, 1.0, 1.0))
	else:
		visible = true
		var f: float = 1.0
		if _dn != null and _dn.has_method("get_normalized_time"):
			var t_v: Variant = _dn.call("get_normalized_time")
			if t_v is float:
				f = _time_to_factor(t_v)
		_set_night_factor(f, true)

# --- Day/Night ----------------------------------------------------------------

func _on_phase_changed(is_day: bool) -> void:
	_is_day_cached = is_day

	if not enabled_overlay:
		visible = false
		_set_overlay_color(Color(1.0, 1.0, 1.0, 1.0))
		return

	if is_day:
		_cancel_tween_if_any()
		visible = false
		_set_overlay_color(Color(1.0, 1.0, 1.0, 1.0))
		if debug_logging:
			print("[NightDarkenOverlay2D] Phase DAY → overlay hidden")
	else:
		visible = true
		var f: float = 1.0
		if _dn != null and _dn.has_method("get_normalized_time"):
			var v: Variant = _dn.call("get_normalized_time")
			if v is float:
				f = _time_to_factor(v)
		_set_night_factor(f, false)
		if debug_logging:
			print("[NightDarkenOverlay2D] Phase NIGHT → factor=", f, " overlay shown")

func _on_time_changed(normalized_time: float) -> void:
	if _is_day_cached:
		return
	if not enabled_overlay:
		return
	if not visible:
		return

	var f: float = _time_to_factor(normalized_time)
	_set_night_factor(f, false)

# --- Factor computation -------------------------------------------------------

func _time_to_factor(t: float) -> float:
	if force_night_debug:
		return 1.0
	if use_curve and night_factor_curve != null:
		var s: float = night_factor_curve.sample_baked(t)
		if s < 0.0:
			s = 0.0
		if s > 1.0:
			s = 1.0
		return s

	# Dusk ramp: [dusk_start, night_start] → 0..1
	if t >= dusk_start and t <= night_start:
		var span: float = night_start - dusk_start
		if span <= 0.0:
			return 1.0
		return (t - dusk_start) / span

	# Full night across midnight: [night_start,1] ∪ [0,night_end]
	if t >= night_start or t <= night_end:
		return 1.0

	# Dawn ramp: [night_end, dawn_end] → 1..0
	if t > night_end and t <= dawn_end:
		var span2: float = dawn_end - night_end
		if span2 <= 0.0:
			return 0.0
		return 1.0 - ((t - night_end) / span2)

	# Daytime
	return 0.0

# --- Apply color + broadcast --------------------------------------------------

func _set_night_factor(factor_0_to_1: float, instant: bool) -> void:
	var f: float = factor_0_to_1
	if f < 0.0:
		f = 0.0
	if f > 1.0:
		f = 1.0

	var tint_strength: float = f * night_strength_at_max
	if tint_strength < 0.0:
		tint_strength = 0.0
	if tint_strength > 1.0:
		tint_strength = 1.0

	var r: float = lerp(1.0, night_tint_color.r, tint_strength)
	var g: float = lerp(1.0, night_tint_color.g, tint_strength)
	var b: float = lerp(1.0, night_tint_color.b, tint_strength)

	var black_strength: float = f * night_black_mix_at_max
	if black_strength < 0.0:
		black_strength = 0.0
	if black_strength > 1.0:
		black_strength = 1.0

	if black_strength > 0.0:
		r = lerp(r, 0.0, black_strength)
		g = lerp(g, 0.0, black_strength)
		b = lerp(b, 0.0, black_strength)

	var target: Color = Color(r, g, b, 1.0)

	if instant or smooth_transition_sec <= 0.0:
		_cancel_tween_if_any()
		_set_overlay_color(target)
	else:
		_start_color_tween_to(target, smooth_transition_sec)

func _set_overlay_color(c: Color) -> void:
	color = c
	# Broadcast current RGB to listeners (torch layers, etc.).
	var rgb: Vector3 = Vector3(c.r, c.g, c.b)
	if get_tree() != null:
		get_tree().call_group("NightOverlayListeners", "_night_overlay_rgb_changed", rgb)

func _start_color_tween_to(target: Color, dur_sec: float) -> void:
	_cancel_tween_if_any()
	_active_tween = create_tween()
	if _active_tween == null:
		_set_overlay_color(target)
		return
	_active_tween.tween_property(self, "color", target, dur_sec).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_active_tween.finished.connect(_on_tween_finished.bind(target))

func _on_tween_finished(target: Color) -> void:
	_set_overlay_color(target)

func _cancel_tween_if_any() -> void:
	if _active_tween != null:
		if _active_tween.is_running():
			_active_tween.kill()
		_active_tween = null
