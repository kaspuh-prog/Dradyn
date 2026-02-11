extends AnimatedSprite2D
class_name AlchemyWitchAnimator

@export var brewing_animation: StringName = &"brewing"
@export var idle_animation: StringName = &"idle"

var _is_interacting: bool = false


func _ready() -> void:
	_is_interacting = false
	_play_brewing()


func set_interacting(interacting: bool) -> void:
	_is_interacting = interacting
	if _is_interacting:
		_play_idle()
	else:
		_play_brewing()


func _play_brewing() -> void:
	if sprite_frames != null and sprite_frames.has_animation(brewing_animation):
		play(brewing_animation)
	elif sprite_frames != null and sprite_frames.get_animation_names().size() > 0:
		var names: PackedStringArray = sprite_frames.get_animation_names()
		var first_name: StringName = names[0]
		play(first_name)


func _play_idle() -> void:
	if sprite_frames != null and sprite_frames.has_animation(idle_animation):
		play(idle_animation)
	else:
		_play_brewing()
