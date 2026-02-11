extends Node
class_name DayNight

signal time_changed(normalized_time: float)
signal phase_changed(is_day: bool)

# NEW: continuous factor for visuals.
# 0.0 = full day, 1.0 = full night.
signal night_factor_changed(night_factor: float)

# NEW: overlay-specific factor (0..1). This is what your overlay should use.
signal overlay_factor_changed(overlay_factor: float)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("dn_force_day"):
		rest_until_dawn()
	if event.is_action_pressed("dn_force_night"):
		rest_until_dusk()

@export_range(5, 360, 1)
var cycle_minutes: int = 90

@export_range(0.0, 1.0, 0.001)
var sunrise: float = 0.25

@export_range(0.0, 1.0, 0.001)
var sunset: float = 0.75

@export_range(0.0, 1.0, 0.001)
var start_time_normalized: float = 0.40

# Width of dawn/dusk blend (in normalized time, wraps safely).
@export_range(0.0, 0.25, 0.001)
var twilight_width: float = 0.05

# Throttle time_changed emissions (Hz). 0 = every frame.
@export_range(0.0, 60.0, 0.1)
var emit_time_changed_hz: float = 20.0

# Optional shaping for night factor. 1.0 linear. >1 = stronger night sooner.
@export_range(0.25, 4.0, 0.01)
var night_factor_power: float = 1.0

# NEW: Overlay policy
# - If true: overlay is ZERO any time is_day() is true.
@export var overlay_disabled_in_day: bool = true

# NEW: Overlay policy
# - Force overlay factor to 0 for the first X in-game minutes after sunrise.
#   Example: 30.0 means "first 30 minutes after sunrise".
@export_range(0.0, 180.0, 1.0)
var overlay_free_minutes_after_dawn: float = 30.0

var _time_normalized: float = 0.0
var _is_day: bool = true
var _running: bool = true
var _time_scale: float = 1.0

var _night_factor: float = 0.0
var _overlay_factor: float = 0.0

var _emit_accum: float = 0.0
var _emit_period: float = 0.0

func _ready() -> void:
	set_process(true)

	_time_normalized = clampf(start_time_normalized, 0.0, 1.0)
	_is_day = _compute_is_day(_time_normalized)

	_night_factor = _compute_night_factor(_time_normalized)
	_overlay_factor = _compute_overlay_factor(_time_normalized, _night_factor, _is_day)

	_recompute_emit_period()

	emit_signal("time_changed", _time_normalized)
	emit_signal("phase_changed", _is_day)
	emit_signal("night_factor_changed", _night_factor)
	emit_signal("overlay_factor_changed", _overlay_factor)

	set_process_unhandled_input(true)

func _process(delta: float) -> void:
	if not _running:
		return

	var cycle_seconds: float = float(cycle_minutes) * 60.0
	if cycle_seconds <= 0.0:
		return

	var advance: float = (delta * _time_scale) / cycle_seconds
	_time_normalized += advance

	if _time_normalized >= 1.0:
		_time_normalized -= 1.0
	if _time_normalized < 0.0:
		_time_normalized = 1.0 + _time_normalized

	# Throttle time_changed if configured.
	if emit_time_changed_hz <= 0.0:
		emit_signal("time_changed", _time_normalized)
	else:
		_emit_accum += delta
		if _emit_accum >= _emit_period:
			_emit_accum -= _emit_period
			emit_signal("time_changed", _time_normalized)

	# Phase changed (day/night boolean).
	var now_is_day: bool = _compute_is_day(_time_normalized)
	if now_is_day != _is_day:
		_is_day = now_is_day
		emit_signal("phase_changed", _is_day)

	# Night factor changed (continuous).
	var nf: float = _compute_night_factor(_time_normalized)
	if absf(nf - _night_factor) >= 0.0005:
		_night_factor = nf
		emit_signal("night_factor_changed", _night_factor)

	# Overlay factor (policy applied).
	var of: float = _compute_overlay_factor(_time_normalized, _night_factor, _is_day)
	if absf(of - _overlay_factor) >= 0.0005:
		_overlay_factor = of
		emit_signal("overlay_factor_changed", _overlay_factor)

func _compute_is_day(t: float) -> bool:
	if sunrise <= sunset:
		if t >= sunrise and t < sunset:
			return true
		return false

	# Wrap-around: day spans 1.0→0.0 boundary.
	if t >= sunrise or t < sunset:
		return true
	return false

# 0.0 = day, 1.0 = night, with smooth dawn/dusk ramps.
func _compute_night_factor(t: float) -> float:
	var w: float = clampf(twilight_width, 0.0, 0.25)

	# If no twilight, return hard factor.
	if w <= 0.0:
		if _compute_is_day(t):
			return 0.0
		return 1.0

	var day: bool = _compute_is_day(t)

	var dusk_start: float = _wrap01(sunset - w)
	var dusk_end: float = _wrap01(sunset + w)

	var dawn_start: float = _wrap01(sunrise - w)
	var dawn_end: float = _wrap01(sunrise + w)

	# Dusk ramp: 0 -> 1 around sunset.
	var in_dusk: bool = _in_wrapped_range(t, dusk_start, dusk_end)
	if in_dusk:
		var u: float = _wrapped_inverse_lerp(dusk_start, dusk_end, t)
		var f0: float = _smoothstep(u)
		f0 = _apply_power(f0)
		return f0

	# Dawn ramp: 1 -> 0 around sunrise.
	var in_dawn: bool = _in_wrapped_range(t, dawn_start, dawn_end)
	if in_dawn:
		var v: float = _wrapped_inverse_lerp(dawn_start, dawn_end, t)
		var s: float = _smoothstep(v)
		s = _apply_power(s)
		var f1: float = 1.0 - s
		return f1

	# Outside ramps: pure day/night.
	if day:
		return 0.0
	return 1.0

func _compute_overlay_factor(t: float, night_factor: float, is_day_now: bool) -> float:
	# Rule 1: day = no overlay (if enabled).
	if overlay_disabled_in_day and is_day_now:
		return 0.0

	# Rule 2: after dawn, hold overlay at 0 for X in-game minutes.
	var mins: float = overlay_free_minutes_after_dawn
	if mins <= 0.0:
		return night_factor

	var window_norm: float = mins / maxf(1.0, float(cycle_minutes))
	if window_norm <= 0.0:
		return night_factor

	var start_t: float = sunrise
	var end_t: float = _wrap01(sunrise + window_norm)

	var in_window: bool = _in_wrapped_range(t, start_t, end_t)
	if in_window:
		return 0.0

	return night_factor

func _apply_power(x: float) -> float:
	var p: float = night_factor_power
	if absf(p - 1.0) <= 0.00001:
		return x
	return pow(clampf(x, 0.0, 1.0), maxf(0.0001, p))

func _smoothstep(x: float) -> float:
	var t: float = clampf(x, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func _wrap01(x: float) -> float:
	var v: float = x
	while v >= 1.0:
		v -= 1.0
	while v < 0.0:
		v += 1.0
	return v

func _in_wrapped_range(t: float, a: float, b: float) -> bool:
	# Range [a, b] possibly wrapping.
	if a <= b:
		if t >= a and t <= b:
			return true
		return false

	# Wrapped: [a,1] U [0,b]
	if t >= a or t <= b:
		return true
	return false

func _wrapped_inverse_lerp(a: float, b: float, t: float) -> float:
	if a <= b:
		return inverse_lerp(a, b, t)

	var total: float = (1.0 - a) + b
	var dist: float = 0.0
	if t >= a:
		dist = t - a
	else:
		dist = (1.0 - a) + t

	if total <= 0.000001:
		return 0.0
	return clampf(dist / total, 0.0, 1.0)

func is_day() -> bool:
	return _is_day

func get_time_normalized() -> float:
	return _time_normalized

func get_night_factor() -> float:
	return _night_factor

func get_overlay_factor() -> float:
	return _overlay_factor

func set_time_normalized(value: float) -> void:
	_time_normalized = clampf(value, 0.0, 1.0)

	emit_signal("time_changed", _time_normalized)

	var now_is_day: bool = _compute_is_day(_time_normalized)
	if now_is_day != _is_day:
		_is_day = now_is_day
		emit_signal("phase_changed", _is_day)

	var nf: float = _compute_night_factor(_time_normalized)
	_night_factor = nf
	emit_signal("night_factor_changed", _night_factor)

	var of: float = _compute_overlay_factor(_time_normalized, _night_factor, _is_day)
	_overlay_factor = of
	emit_signal("overlay_factor_changed", _overlay_factor)

func set_cycle_minutes(minutes: int) -> void:
	if minutes < 1:
		minutes = 1
	cycle_minutes = minutes
	_recompute_emit_period()

func set_running(running: bool) -> void:
	_running = running

func set_time_scale(scale: float) -> void:
	if scale < 0.0:
		scale = 0.0
	_time_scale = scale

func rest_until_dawn() -> void:
	# Jump just after sunrise so phase flips to DAY and signals fire.
	var t: float = sunrise + 0.001
	if t >= 1.0:
		t -= 1.0
	set_time_normalized(t)

func rest_until_dusk() -> void:
	# Jump just after sunset so phase flips to NIGHT and signals fire.
	var t: float = sunset + 0.001
	if t >= 1.0:
		t -= 1.0
	set_time_normalized(t)

func _recompute_emit_period() -> void:
	if emit_time_changed_hz <= 0.0:
		_emit_period = 0.0
		return
	_emit_period = 1.0 / emit_time_changed_hz
	if _emit_period < 0.001:
		_emit_period = 0.001
