extends CharacterBody2D
class_name Player

const ACCEL: float = 10.0
const FRICTION: float = 12.0

@export var base_speed: float = 96.0
@export var sprint_mult: float = 1.5
@export var can_sprint: bool = true

var sprinting: bool = false
var _step_cd: float = 0.0

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

func _ready() -> void:
	if has_node("/root/Party"):
		get_node("/root/Party").add_member(self, true)

func _unhandled_input(event: InputEvent) -> void:
	# Only uses your existing Input Map bindings
	if event.is_action_pressed("party_next"):
		if has_node("/root/Party"):
			get_node("/root/Party").next()
			get_viewport().set_input_as_handled()

func _get_target_speed() -> float:
	var speed := base_speed
	# Guard in case "sprint" action is missing
	var sprint_down := InputMap.has_action("sprint") and Input.is_action_pressed("sprint")
	if can_sprint and sprint_down:
		speed *= sprint_mult
		sprinting = true
	else:
		sprinting = false
	return speed

func _physics_process(delta: float) -> void:
	var input_vec := Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	).normalized()

	var target_speed := _get_target_speed()
	var target_velocity := input_vec * target_speed

	# Smooth accel/decel
	var speeding_up := target_velocity.length() > velocity.length()
	var rate := (ACCEL if speeding_up else FRICTION) * delta
	velocity = velocity.move_toward(target_velocity, rate)
	move_and_slide()

	# Simple 4-dir anim (adjust to your clips)
	if anim:
		if velocity.length() > 2.0:
			if abs(velocity.x) > abs(velocity.y):
				anim.play("walk_right" if velocity.x > 0.0 else "walk_left")
			else:
				anim.play("walk_down" if velocity.y > 0.0 else "walk_up")
		else:
			anim.play("idle_down")
