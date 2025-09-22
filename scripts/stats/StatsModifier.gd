extends Resource
class_name StatModifier
## Godot 4.5

@export var stat_name: StringName = ""
@export var add_value: float = 0.0
@export var mul_value: float = 1.0
@export var source_id: String = ""
@export var duration_sec: float = 0.0

var _time_left: float = 0.0

func _init() -> void:
	_time_left = duration_sec

func start() -> void:
	_time_left = duration_sec

func is_temporary() -> bool:
	return duration_sec > 0.0

func time_left() -> float:
	return _time_left

func tick(delta: float) -> void:
	if is_temporary():
		_time_left = max(0.0, _time_left - delta)

func expired() -> bool:
	return is_temporary() and _time_left <= 0.0

func to_dict() -> Dictionary:
	return {
		"stat_name": str(stat_name),
		"add_value": add_value,
		"mul_value": mul_value,
		"source_id": source_id,
		"duration_sec": duration_sec,
		"time_left": _time_left,
	}

func from_dict(d: Dictionary) -> void:
	stat_name    = StringName(d.get("stat_name", ""))
	add_value    = float(d.get("add_value", 0.0))
	mul_value    = float(d.get("mul_value", 1.0))
	source_id    = str(d.get("source_id", ""))
	duration_sec = float(d.get("duration_sec", 0.0))
	_time_left   = float(d.get("time_left", duration_sec))
