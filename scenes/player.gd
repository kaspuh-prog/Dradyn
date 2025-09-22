extends CharacterBody2D
class_name Player

# Snappy JRPG feel (pixels per second^2)
const ACCEL: float = 2200.0
const FRICTION: float = 2800.0

@export var base_speed: float = 120.0
@export var sprint_mult: float = 1.45
@export var can_sprint: bool = true
@export var make_controlled_on_start: bool = false   # set TRUE on exactly one character
@export var side_faces_right: bool = true            # if your side animations face LEFT by default, set this to false

var sprinting: bool = false
var _step_cd: float = 0.0
var _last_dir: Vector2 = Vector2(0, 1)  # remember last movement to pick idle (default: down)

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D

func _enter_tree() -> void:
	# Visual: controlled = normal; follower = slightly dim
	if has_node("/root/Party"):
		var p: PartyManager = get_node("/root/Party") as PartyManager
		if not p.controlled_changed.is_connected(_on_controlled_changed):
			p.controlled_changed.connect(_on_controlled_changed)
		_on_controlled_changed(p.get_controlled())
	else:
		_on_controlled_changed(self)

func _ready() -> void:
	if has_node("/root/Party"):
		var p: PartyManager = get_node("/root/Party") as PartyManager
		p.add_member(self, make_controlled_on_start)

func _unhandled_input(event: InputEvent) -> void:
	# You mapped this to QuoteLeft
	if event.is_action_pressed("party_next"):
		if has_node("/root/Party"):
			var p: PartyManager = get_node("/root/Party") as PartyManager
			p.next()
			get_viewport().set_input_as_handled()

func _is_controlled() -> bool:
	if not has_node("/root/Party"):
		return true
	var p: PartyManager = get_node("/root/Party") as PartyManager
	return p.get_controlled() == self

func _get_target_speed() -> float:
	var speed: float = base_speed
	var sprint_down: bool = InputMap.has_action("sprint") and Input.is_action_pressed("sprint")
	if can_sprint and sprint_down:
		speed *= sprint_mult
		sprinting = true
	else:
		sprinting = false
	return speed

func _physics_process(delta: float) -> void:
	# Followers do NOT run player movement (prevents double-driving)
	if has_node("/root/Party") and not _is_controlled():
		return

	var input_vec: Vector2 = Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	).normalized()

	var target_speed: float = _get_target_speed()
	var target_velocity: Vector2 = input_vec * target_speed

	# Smooth accel/decel
	var speeding_up: bool = target_velocity.length() > velocity.length()
	var rate: float = (ACCEL if speeding_up else FRICTION) * delta
	velocity = velocity.move_toward(target_velocity, rate)

	move_and_slide()
	_update_anim()

func _update_anim() -> void:
	if anim == null:
		return

	# Moving?
	if velocity.length() > 2.0:
		_last_dir = velocity
		if abs(velocity.x) > abs(velocity.y):
			# SIDE — use one clip, flip for L/R
			if anim.sprite_frames.has_animation("walk_side"):
				anim.play("walk_side")
				if side_faces_right:
					anim.flip_h = velocity.x < 0.0
				else:
					anim.flip_h = velocity.x > 0.0
			else:
				# Fallback (if walk_side missing)
				if velocity.x > 0.0 and anim.sprite_frames.has_animation("walk_right"):
					anim.play("walk_right")
					anim.flip_h = false
				elif anim.sprite_frames.has_animation("walk_left"):
					anim.play("walk_left")
					anim.flip_h = false
		else:
			# UP/DOWN
			if velocity.y > 0.0 and anim.sprite_frames.has_animation("walk_down"):
				anim.play("walk_down")
				anim.flip_h = false
			elif anim.sprite_frames.has_animation("walk_up"):
				anim.play("walk_up")
				anim.flip_h = false
	else:
		# IDLE — choose by last direction and flip side as needed
		if abs(_last_dir.x) > abs(_last_dir.y):
			if anim.sprite_frames.has_animation("idle_side"):
				anim.play("idle_side")
				if side_faces_right:
					anim.flip_h = _last_dir.x < 0.0
				else:
					anim.flip_h = _last_dir.x > 0.0
			else:
				# Fallback if idle_side doesn't exist
				if _last_dir.x > 0.0 and anim.sprite_frames.has_animation("idle_right"):
					anim.play("idle_right")
					anim.flip_h = false
				elif anim.sprite_frames.has_animation("idle_left"):
					anim.play("idle_left")
					anim.flip_h = false
		else:
			if _last_dir.y > 0.0 and anim.sprite_frames.has_animation("idle_down"):
				anim.play("idle_down")
				anim.flip_h = false
			elif anim.sprite_frames.has_animation("idle_up"):
				anim.play("idle_up")
				anim.flip_h = false

func _on_controlled_changed(current: Node) -> void:
	# Tint to make control obvious when testing
	modulate = Color(1, 1, 1, 1) if current == self else Color(0.82, 0.82, 0.82, 1)
