# scripts/camera/LeaderCamera.gd
extends Camera2D
class_name LeaderCamera

@export var smoothing_enabled: bool = true
@export var smoothing_speed: float = 8.0

var _target: Node2D

func _ready() -> void:
	add_to_group("LeaderCamera")  # lets PartyManager find it
	make_current()                # no need to find "Current" in Inspector

func set_target(t: Node2D) -> void:
	_target = t

func _process(delta: float) -> void:
	if _target == null:
		return
	if smoothing_enabled:
		var a := 1.0 - pow(0.001, smoothing_speed * delta) # framerate-independent smoothing
		global_position = global_position.lerp(_target.global_position, a)
	else:
		global_position = _target.global_position
