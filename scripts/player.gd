extends CharacterBody2D

# --- References ---
@onready var stats = $StatsComponent       # make sure the node exists on the Player
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D   # optional (only used for per-footstep drain)

# --- Tuning ---
@export var sprint_mul: float = 1.3                   # how much faster when sprinting
@export var stamina_cost_per_second: float = 12.0     # continuous drain while sprinting + moving
@export var sprint_step_cost: float = 3.0             # extra drain on footfalls (frames 0 & 3), set 0 to disable
@export var accel_lerp: float = 0.18                  # smoothing for accel/decel (0..1)

const SPEED_FALLBACK: float = 96.0                    # used only if StatsComponent is missing

var _sprinting: bool = false

func _ready() -> void:
	# hook footsteps if you want per-step stamina cost
	if is_instance_valid(sprite):
		sprite.connect("frame_changed", Callable(self, "_on_sprite_frame_changed"))

func _physics_process(delta: float) -> void:
	# input
	var dir := Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
	)
	if dir.length_squared() > 1.0:
		dir = dir.normalized()

	# speed from stats (fallback if stats node missing)
	var base_speed: float = SPEED_FALLBACK
	if is_instance_valid(stats):
		base_speed = stats.get_final_stat("MoveSpeed")

	# sprint state (needs stamina > 0)
	_sprinting = Input.is_action_pressed("sprint") and is_instance_valid(stats) and stats.current_stamina > 0.0

	var target_speed: float = base_speed * (sprint_mul if _sprinting else 1.0)
	var desired: Vector2 = dir * target_speed

	# smooth accel/decel
	velocity = velocity.lerp(desired, accel_lerp)
	move_and_slide()

	# continuous stamina drain only when moving + sprinting
	if _sprinting and dir != Vector2.ZERO and is_instance_valid(stats):
		stats.change_stamina(-(stamina_cost_per_second * delta))

func _on_sprite_frame_changed() -> void:
	# optional: small burst of drain on audible footsteps (your walk anim uses frames 0 & 3)
	if not _sprinting or not is_instance_valid(stats):
		return
	if sprite.animation == "walk":
		var f := sprite.frame
		if (f == 0 or f == 3) and sprint_step_cost > 0.0:
			stats.change_stamina(-sprint_step_cost)
