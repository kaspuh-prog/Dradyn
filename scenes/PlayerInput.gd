extends CharacterBody2D

@export var move_speed: float = 140.0
@onready var sprite: AnimatedSprite2D = $Sprite
@onready var sfx_foot: AudioStreamPlayer = $Footsteps
@onready var follower: Node = $CompanionFollow if has_node("CompanionFollow") else null

var _controlled: bool = false

func _ready():
	# decide initial control via groups
	_controlled = is_in_group("player_controlled")
	_apply_control_state(_controlled)

func on_control_gain() -> void:
	_controlled = true
	_apply_control_state(true)

func on_control_loss() -> void:
	_controlled = false
	_apply_control_state(false)

func _apply_control_state(v: bool) -> void:
	# toggle systems
	if follower and follower.has_method("enable_follow"):
		follower.enable_follow(!v)  # follow when NOT controlled
	set_process_input(v)
	set_physics_process(true)  # movement always runs (controlled or following)

func _input(event):
	if !_controlled: return
	# map your inputs here; simple 8-way for now
	var dir := Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	).normalized()
	velocity = dir * move_speed

func _physics_process(delta):
	move_and_slide()
	_update_anim_and_sfx()

func _update_anim_and_sfx():
	var moving := velocity.length() > 1.0
	if sprite:
		sprite.play("run") if moving else sprite.play("idle")
		if moving:
			sprite.flip_h = velocity.x < 0.0
	if sfx_foot:
		# simple loop-on-move; upgrade to timed steps later
		if moving and !sfx_foot.playing:
			sfx_foot.play()
		elif !moving and sfx_foot.playing:
			sfx_foot.stop()
