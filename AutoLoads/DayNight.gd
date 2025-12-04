extends Node
class_name DayNight

signal time_changed(normalized_time: float)
signal phase_changed(is_day: bool)

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

var _time_normalized: float = 0.0
var _is_day: bool = true
var _running: bool = true
var _time_scale: float = 1.0

func _ready() -> void:
	set_process(true)
	_time_normalized = clampf(start_time_normalized, 0.0, 1.0)
	_is_day = _compute_is_day(_time_normalized)
	emit_signal("time_changed", _time_normalized)
	emit_signal("phase_changed", _is_day)
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

	emit_signal("time_changed", _time_normalized)

	var now_is_day: bool = _compute_is_day(_time_normalized)
	if now_is_day != _is_day:
		_is_day = now_is_day
		emit_signal("phase_changed", _is_day)

func _compute_is_day(t: float) -> bool:
	if sunrise <= sunset:
		if t >= sunrise and t < sunset:
			return true
		else:
			return false
	else:
		# Handles wrap-around cases where day spans the 1.0→0.0 boundary.
		if t >= sunrise or t < sunset:
			return true
		else:
			return false

func is_day() -> bool:
	return _is_day

func get_time_normalized() -> float:
	return _time_normalized

func set_time_normalized(value: float) -> void:
	_time_normalized = clampf(value, 0.0, 1.0)
	emit_signal("time_changed", _time_normalized)
	var now_is_day: bool = _compute_is_day(_time_normalized)
	if now_is_day != _is_day:
		_is_day = now_is_day
		emit_signal("phase_changed", _is_day)

func set_cycle_minutes(minutes: int) -> void:
	if minutes < 1:
		minutes = 1
	cycle_minutes = minutes

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
