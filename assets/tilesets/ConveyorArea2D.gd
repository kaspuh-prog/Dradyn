extends Area2D
class_name ConveyorArea2D

const EXTERNAL_ID: StringName = &"conveyor"

enum Direction { EAST, WEST, NORTH, SOUTH }

@export var direction: Direction = Direction.EAST
@export var speed_px_per_sec: float = 60.0

# Optional: set mask in code to only detect actors (ALLY+ENEMY by your project convention).
@export var configure_collision_in_code: bool = true
@export var detect_layer_bits: PackedInt32Array = PackedInt32Array([1, 2, 3])

@export var debug_prints: bool = false

# Track bodies currently affected so we can always clear them safely.
var _tracked: Array[CharacterBody2D] = []

func _ready() -> void:
	monitoring = true
	monitorable = true

	if configure_collision_in_code:
		collision_layer = 0
		collision_mask = _mask_from_bits(detect_layer_bits)

	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		body_entered.connect(Callable(self, "_on_body_entered"))
	if not is_connected("body_exited", Callable(self, "_on_body_exited")):
		body_exited.connect(Callable(self, "_on_body_exited"))

	if debug_prints:
		print("[ConveyorArea2D] ready name=", name, " dir=", _dir_name(), " spd=", speed_px_per_sec, " mask=", collision_mask)

func _exit_tree() -> void:
	# Failsafe: if the conveyor is removed while bodies are on it, clear their external velocity.
	_clear_all_tracked()

func _on_body_entered(body: Node) -> void:
	if body == null or not is_instance_valid(body):
		return

	var cb: CharacterBody2D = body as CharacterBody2D
	if cb == null:
		# Ignore world bodies (TileMap collision etc.)
		return

	if _tracked.has(cb):
		return

	_tracked.append(cb)
	_apply_to_actor(cb)

	if debug_prints:
		print("[ConveyorArea2D] ENTER actor=", cb.name, " v=", _conveyor_velocity())

func _on_body_exited(body: Node) -> void:
	if body == null:
		return

	var cb: CharacterBody2D = body as CharacterBody2D
	if cb == null:
		return

	if _tracked.has(cb):
		_tracked.erase(cb)

	_clear_from_actor(cb)

	if debug_prints and is_instance_valid(cb):
		print("[ConveyorArea2D] EXIT clear actor=", cb.name)

func _apply_to_actor(actor: CharacterBody2D) -> void:
	var v: Vector2 = _conveyor_velocity()

	if actor.has_method("set_external_velocity"):
		actor.call("set_external_velocity", EXTERNAL_ID, v)
		return

	# Fallback for companions (kept for safety)
	var cf: Node = actor.find_child("CompanionFollow", true, false)
	if cf != null and is_instance_valid(cf) and cf.has_method("set_external_velocity"):
		cf.call("set_external_velocity", EXTERNAL_ID, v)

func _clear_from_actor(actor: CharacterBody2D) -> void:
	if actor == null or not is_instance_valid(actor):
		return

	if actor.has_method("clear_external_velocity"):
		actor.call("clear_external_velocity", EXTERNAL_ID)
		return

	var cf: Node = actor.find_child("CompanionFollow", true, false)
	if cf != null and is_instance_valid(cf) and cf.has_method("clear_external_velocity"):
		cf.call("clear_external_velocity", EXTERNAL_ID)

func _clear_all_tracked() -> void:
	var i: int = 0
	while i < _tracked.size():
		var a: CharacterBody2D = _tracked[i]
		if a != null and is_instance_valid(a):
			_clear_from_actor(a)
		i += 1
	_tracked.clear()

func _conveyor_velocity() -> Vector2:
	var spd: float = speed_px_per_sec
	if spd < 0.0:
		spd = 0.0

	if direction == Direction.EAST:
		return Vector2(spd, 0.0)
	if direction == Direction.WEST:
		return Vector2(-spd, 0.0)
	if direction == Direction.NORTH:
		return Vector2(0.0, -spd)
	return Vector2(0.0, spd)

func _mask_from_bits(bits: PackedInt32Array) -> int:
	var mask: int = 0
	var i: int = 0
	while i < bits.size():
		var b: int = bits[i]
		if b >= 1 and b <= 32:
			mask |= 1 << (b - 1)
		i += 1
	return mask

func _dir_name() -> String:
	if direction == Direction.EAST:
		return "EAST"
	if direction == Direction.WEST:
		return "WEST"
	if direction == Direction.NORTH:
		return "NORTH"
	return "SOUTH"
