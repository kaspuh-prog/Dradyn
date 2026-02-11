extends ColorRect
class_name NightDarkenOverlay2D

@export var debug_logging: bool = true

# Night tint that will be multiplied into the scene as night strengthens (RGB only).
@export var night_tint_color: Color = Color(0.12, 0.16, 0.28, 1.0)

# Blend strength from WHITE -> night_tint_color at full night (0..1).
@export_range(0.0, 1.0, 0.01) var night_strength_at_max: float = 0.40

# Extra darkness: mix the tinted result toward black at full night (0..1).
@export_range(0.0, 1.0, 0.01) var night_black_mix_at_max: float = 0.25

# Dusk/Night/Dawn windows (normalized 0..1). (Legacy fallback if DayNight doesn't provide overlay_factor.)
@export_range(0.0, 1.0, 0.001) var dusk_start: float = 0.72
@export_range(0.0, 1.0, 0.001) var night_start: float = 0.80
@export_range(0.0, 1.0, 0.001) var night_end: float = 0.20
@export_range(0.0, 1.0, 0.001) var dawn_end: float = 0.28

# Optional smoothing curve (x = time, y = factor 0..1). (Legacy fallback.)
@export var use_curve: bool = false
@export var night_factor_curve: Curve

# Global toggles.
@export var enabled_overlay: bool = true
@export var force_night_debug: bool = false

# Smooth night-only transitions (seconds). 0 = instant.
@export_range(0.0, 3.0, 0.01) var smooth_transition_sec: float = 0.15

# ------------------------------------------------------------------------------
# Screen-grade mode that preserves highlights (keeps lights looking good).
# If false, uses the legacy multiply ColorRect.
@export var use_screen_grade_shader: bool = true

# Luminance threshold where we start preserving highlights (0..1).
@export_range(0.0, 1.0, 0.01) var highlight_preserve_start: float = 0.55

# How strongly to preserve highlights (0..1). 1 = preserve fully above threshold.
@export_range(0.0, 1.0, 0.01) var highlight_preserve_strength: float = 0.85

# ------------------------------------------------------------------------------
# NEW: behavior policy
# If true, when factor==0 we hard reset to WHITE and optionally hide the overlay rect.
@export var hard_reset_when_day: bool = true
@export var hide_when_day: bool = true

# ------------------------------------------------------------------------------
var _dn: Node = null

var _mul_mat: CanvasItemMaterial = null
var _grade_mat: ShaderMaterial = null

var _is_day_cached: bool = true
var _active_tween: Tween = null

var _last_factor: float = -1.0

func _ready() -> void:
	# Fullscreen overlay; put this node under a CanvasLayer between world and HUD.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 0

	# IMPORTANT: never receive 2D lights.
	light_mask = 0

	# Start neutral.
	color = Color(1.0, 1.0, 1.0, 1.0)

	_build_materials()
	_connect_daynight()
	_sync_from_daynight_initial()

	if debug_logging:
		print("[NightDarkenOverlay2D] Ready. mode=", _mode_string(), " smooth=", smooth_transition_sec)

func _mode_string() -> String:
	if use_screen_grade_shader:
		return "screen_grade"
	return "multiply"

func _build_materials() -> void:
	_mul_mat = CanvasItemMaterial.new()
	_mul_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_MUL

	_grade_mat = ShaderMaterial.new()
	_grade_mat.shader = _make_screen_grade_shader()

	_apply_material_choice()

func _apply_material_choice() -> void:
	if use_screen_grade_shader:
		material = _grade_mat
		_update_grade_uniforms()
	else:
		material = _mul_mat

func _update_grade_uniforms() -> void:
	if _grade_mat == null:
		return

	var preserve_start: float = highlight_preserve_start
	if preserve_start < 0.0:
		preserve_start = 0.0
	if preserve_start > 1.0:
		preserve_start = 1.0

	var preserve_strength: float = highlight_preserve_strength
	if preserve_strength < 0.0:
		preserve_strength = 0.0
	if preserve_strength > 1.0:
		preserve_strength = 1.0

	_grade_mat.set_shader_parameter("u_preserve_start", preserve_start)
	_grade_mat.set_shader_parameter("u_preserve_strength", preserve_strength)

	# The multiplier is driven by this node's ColorRect.color (RGB).
	_grade_mat.set_shader_parameter("u_mul_rgb", Vector3(color.r, color.g, color.b))

func _make_screen_grade_shader() -> Shader:
	var s: Shader = Shader.new()
	s.code = """
shader_type canvas_item;

uniform sampler2D u_screen_tex : hint_screen_texture, filter_nearest;

uniform vec3 u_mul_rgb = vec3(1.0, 1.0, 1.0);
uniform float u_preserve_start = 0.55;
uniform float u_preserve_strength = 0.85;

float luminance(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void fragment() {
	vec4 src = texture(u_screen_tex, SCREEN_UV);

	vec3 mul_rgb = COLOR.rgb;
	if (mul_rgb.r <= 0.0 && mul_rgb.g <= 0.0 && mul_rgb.b <= 0.0) {
		mul_rgb = u_mul_rgb;
	}

	vec3 graded = src.rgb * mul_rgb;

	float lum = luminance(src.rgb);
	float preserve = smoothstep(u_preserve_start, 1.0, lum) * u_preserve_strength;

	vec3 out_rgb = mix(graded, src.rgb, preserve);
	COLOR = vec4(out_rgb, 1.0);
}
"""
	return s

# --- Signal hookups ------------------------------------------------------------

func _connect_daynight() -> void:
	_dn = get_node_or_null("/root/DayandNight")
	if _dn == null:
		if debug_logging:
			print("[NightDarkenOverlay2D] No /root/DayandNight found.")
		return

	# Prefer overlay_factor_changed if available (new sane pipeline).
	if _dn.has_signal("overlay_factor_changed"):
		if not _dn.is_connected("overlay_factor_changed", Callable(self, "_on_overlay_factor_changed")):
			_dn.connect("overlay_factor_changed", Callable(self, "_on_overlay_factor_changed"))
	else:
		# Legacy fallback: time_changed drives factor math here.
		if _dn.has_signal("time_changed"):
			if not _dn.is_connected("time_changed", Callable(self, "_on_time_changed")):
				_dn.connect("time_changed", Callable(self, "_on_time_changed"))

	# Still listen for phase_changed to hard reset on day if desired.
	if _dn.has_signal("phase_changed"):
		if not _dn.is_connected("phase_changed", Callable(self, "_on_phase_changed")):
			_dn.connect("phase_changed", Callable(self, "_on_phase_changed"))

func _sync_from_daynight_initial() -> void:
	var is_day_now: bool = true
	if _dn != null and _dn.has_method("is_day"):
		var v: Variant = _dn.call("is_day")
		if v is bool:
			is_day_now = bool(v)

	_is_day_cached = is_day_now

	# If DayNight can provide overlay factor, use it.
	if _dn != null and _dn.has_method("get_overlay_factor"):
		var ov: Variant = _dn.call("get_overlay_factor")
		if ov is float:
			_apply_factor(float(ov), true)
			return

	# Else fall back to time->factor
	if _dn != null and _dn.has_method("get_time_normalized"):
		var tv: Variant = _dn.call("get_time_normalized")
		if tv is float:
			var f: float = _time_to_factor(float(tv))
			_apply_factor(f, true)
			return

	_apply_factor(0.0, true)

# --- DayNight signals ----------------------------------------------------------

func _on_phase_changed(is_day: bool) -> void:
	_is_day_cached = is_day
	if hard_reset_when_day and is_day:
		_hard_reset_day()

func _on_overlay_factor_changed(overlay_factor: float) -> void:
	_apply_factor(overlay_factor, false)

func _on_time_changed(normalized_time: float) -> void:
	# Legacy path: we compute factor ourselves.
	var f: float = _time_to_factor(normalized_time)
	_apply_factor(f, false)

# --- Factor computation (legacy fallback) -------------------------------------

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

	# Default: piecewise linear dusk -> night -> dawn with wrap support.
	if dusk_start < night_start and dusk_start < 1.0:
		if t >= dusk_start and t < night_start:
			var span: float = night_start - dusk_start
			if span <= 0.0:
				return 0.0
			return (t - dusk_start) / span

	if night_start <= night_end:
		if t >= night_start and t <= night_end:
			return 1.0
	else:
		if t >= night_start or t <= night_end:
			return 1.0

	if t > night_end and t <= dawn_end:
		var span2: float = dawn_end - night_end
		if span2 <= 0.0:
			return 0.0
		return 1.0 - ((t - night_end) / span2)

	return 0.0

# --- Apply factor + broadcast --------------------------------------------------

func _apply_factor(factor_0_to_1: float, instant: bool) -> void:
	if not enabled_overlay:
		visible = false
		return

	var f: float = factor_0_to_1
	if f < 0.0:
		f = 0.0
	if f > 1.0:
		f = 1.0

	# If day/no overlay: hard reset so we never “stick” slightly dark.
	if hard_reset_when_day:
		if _is_effectively_zero(f):
			_hard_reset_day()
			return

	visible = true
	_last_factor = f
	_set_night_factor(f, instant)

func _hard_reset_day() -> void:
	_cancel_tween_if_any()
	_last_factor = 0.0

	# Neutral multiplier.
	_set_overlay_color(Color(1.0, 1.0, 1.0, 1.0))

	if hide_when_day:
		visible = false
	else:
		visible = true

	# Broadcast factor 0 to listeners so they match.
	var rgb: Vector3 = Vector3(1.0, 1.0, 1.0)
	_broadcast_overlay(rgb, 0.0)

func _is_effectively_zero(v: float) -> bool:
	if v <= 0.0005:
		return true
	return false

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

	r = lerp(r, 0.0, black_strength)
	g = lerp(g, 0.0, black_strength)
	b = lerp(b, 0.0, black_strength)

	var target: Color = Color(r, g, b, 1.0)

	if instant or smooth_transition_sec <= 0.0:
		_cancel_tween_if_any()
		_set_overlay_color(target)
		var rgb_now: Vector3 = Vector3(target.r, target.g, target.b)
		_broadcast_overlay(rgb_now, f)
		return

	_start_color_tween_to(target, smooth_transition_sec, f)

func _set_overlay_color(c: Color) -> void:
	color = c
	if use_screen_grade_shader:
		_update_grade_uniforms()

func _start_color_tween_to(target: Color, dur_sec: float, factor: float) -> void:
	_cancel_tween_if_any()

	_active_tween = create_tween()
	if _active_tween == null:
		_set_overlay_color(target)
		var rgb_now: Vector3 = Vector3(target.r, target.g, target.b)
		_broadcast_overlay(rgb_now, factor)
		return

	_active_tween.tween_property(self, "color", target, dur_sec).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_active_tween.finished.connect(_on_tween_finished.bind(target, factor))

func _on_tween_finished(target: Color, factor: float) -> void:
	_set_overlay_color(target)
	var rgb_now: Vector3 = Vector3(target.r, target.g, target.b)
	_broadcast_overlay(rgb_now, factor)

func _cancel_tween_if_any() -> void:
	if _active_tween != null:
		if _active_tween.is_running():
			_active_tween.kill()
		_active_tween = null

func _broadcast_overlay(rgb: Vector3, factor: float) -> void:
	if get_tree() == null:
		return

	# New path (preferred): listeners can apply factor consistently.
	get_tree().call_group("NightOverlayListeners", "set_overlay_factor", rgb, factor)

	# Legacy path: keep compatibility for any old listeners.
	get_tree().call_group("NightOverlayListeners", "_night_overlay_rgb_changed", rgb)

# If you toggle the mode in the editor while running.
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		return
	if what == NOTIFICATION_READY:
		return
