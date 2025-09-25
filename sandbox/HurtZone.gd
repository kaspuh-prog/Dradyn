extends Area2D
class_name HurtZone

@export var amount: float = 10.0
@export var dmg_type: String = "Slash"
@export var tick_rate: float = 1

# Optional filters
@export var require_stats_component: bool = true
@export var required_group: StringName = &""   # e.g. &"player" to only hit the player

@onready var _timer: Timer = $Timer
@onready var _shape: CollisionShape2D = $CollisionShape2D

# Track only valid victims (id -> StatsComponent)
var _victims: Dictionary = {}   # id -> StatsComponent


func _ready() -> void:
	# Layers/masks: Area on 2, listens to 1 (your Player)
	monitoring = true
	monitorable = true
	set_collision_layer(0); set_collision_mask(0)
	set_collision_layer_value(2, true)
	set_collision_mask_value(1, true)

	# Make sure we have a shape (auto-make one if missing)
	if _shape and _shape.shape == null:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(96, 96)
		_shape.shape = rect

	connect("body_entered", Callable(self, "_on_body_entered"))
	connect("body_exited",  Callable(self, "_on_body_exited"))

	_timer.wait_time = tick_rate
	_timer.start()
	_timer.connect("timeout", Callable(self, "_on_tick"))

func _on_body_entered(body: Node) -> void:
	if required_group != &"" and not body.is_in_group(required_group):
		return
	var sc: StatsComponent = body.get_node_or_null("StatsComponent") as StatsComponent
	if require_stats_component and sc == null:
		return
	# store the StatsComponent itself (typed)
	_victims[body.get_instance_id()] = sc


func _on_body_exited(body: Node) -> void:
	_victims.erase(body.get_instance_id())

func _on_tick() -> void:
	var to_remove: Array = []
	for id in _victims.keys():
		var target: StatsComponent = _victims[id] as StatsComponent
		if target == null or not is_instance_valid(target):
			to_remove.append(id)
			continue
		target.apply_damage(amount, dmg_type)  # safe: method exists on StatsComponent
	for id in to_remove:
		_victims.erase(id)
