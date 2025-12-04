extends Area2D
class_name Projectile
# Godot 4.5 — fully typed, no ternaries.
# Generic, reusable projectile spawned by AbilityExecutor for ability_type="PROJECTILE".

signal hit(target: Node)
signal expired

@export var speed_px_per_sec: float = 260.0
@export var max_lifetime_sec: float = 1.6
@export var max_distance_px: float = 480.0
@export var can_pierce: int = 0
@export var destroy_on_wall: bool = true

# Target gating (groups are used AFTER physics overlap happens)
@export var hit_groups: PackedStringArray = ["Enemy", "Enemies"]
@export var damage_type: String = "magic"
@export var ignore_group: String = "Party"

# Visuals
@onready var sprite: AnimatedSprite2D = $Sprite
@onready var collision: CollisionShape2D = $Collision

# Debug
@export var debug_projectile: bool = true

# Runtime
var _dir: Vector2 = Vector2.RIGHT
var _origin: Vector2 = Vector2.ZERO
var _lived: float = 0.0
var _traveled: float = 0.0
var _pierces_left: int = 0
var _caster: Node = null
var _ability_id: String = ""
var _base_damage: float = 0.0

func _ready() -> void:
	# Safety: make sure we actually generate overlaps.
	monitoring = true
	monitorable = true

	_pierces_left = can_pierce
	_origin = global_position

	if sprite != null:
		if sprite.has_method("play"):
			if sprite.sprite_frames != null:
				if sprite.sprite_frames.has_animation("fly"):
					sprite.play("fly")
				elif sprite.sprite_frames.has_animation("idle"):
					sprite.play("idle")

	connect("body_entered", Callable(self, "_on_body_entered"))
	connect("area_entered", Callable(self, "_on_area_entered"))

	if debug_projectile:
		var groups_psa: PackedStringArray = get_groups()
		var groups_list: Array[String] = []
		var gi: int = 0
		while gi < groups_psa.size():
			groups_list.append(String(groups_psa[gi]))
			gi += 1
		var groups_str: String = ", ".join(groups_list)

		var msg: String = "[Projectile] ready layer=%d mask=%d groups=[%s]" % [
			int(collision_layer),
			int(collision_mask),
			groups_str
		]
		print(msg)


func setup(user: Node, ability_id: String, direction: Vector2, damage_amount: float) -> void:
	# Called by AbilityExecutor immediately after instancing.
	_caster = user
	_ability_id = ability_id
	_dir = direction.normalized()
	_base_damage = max(0.0, damage_amount)
	if auto_orient:
		_apply_sprite_orientation(_dir)

func set_direction(direction: Vector2) -> void:
	_dir = direction.normalized()

# Public helper so the executor can orient explicitly even if auto_orient=false
func orient_from_dir(direction: Vector2) -> void:
	_apply_sprite_orientation(direction.normalized())

# Orientation options
@export var auto_orient: bool = true
@export var orientation_mode: String = "FOUR_WAY"  # "FOUR_WAY" or "FREE_ROTATE"

func _physics_process(delta: float) -> void:
	# Lifetime
	_lived += delta
	if _lived >= max_lifetime_sec:
		_emit_and_free()
		return

	# Movement
	var step: float = speed_px_per_sec * delta
	global_position += _dir * step
	_traveled += step
	if _traveled >= max_distance_px:
		_emit_and_free()
		return

func _on_body_entered(body: Node) -> void:
	if debug_projectile:
		print("[Projectile] body_entered: ", body)
	_try_hit(body)

func _on_area_entered(area: Area2D) -> void:
	if debug_projectile:
		print("[Projectile] area_entered: ", area)
	# Only destroy on walls/solids if desired; tag solid collision Areas with "WorldSolid"
	if destroy_on_wall:
		if area != null and area.is_in_group("WorldSolid"):
			_emit_and_free()

func _try_hit(target: Node) -> void:
	if target == null:
		return

	# Avoid hitting the caster or allies (by group)
	if _caster != null:
		if target == _caster:
			return
		if ignore_group != "" and target.is_in_group(ignore_group):
			return

	# Must match one of the intended groups unless target exposes a StatsComponent
	var group_ok: bool = _matches_hit_groups(target)
	var stats := _find_stats_component(target)
	if not group_ok and stats == null:
		return

	# Apply damage through StatsComponent if available
	if stats != null:
		var packet := {
			"amount": _base_damage,
			"types": {damage_type: 1.0},
			"source": _ability_id,
			"is_crit": false
		}
		if stats.has_method("apply_damage_packet"):
			stats.apply_damage_packet(packet)

	if debug_projectile:
		print("[Projectile] HIT target=", target, " group_ok=", group_ok, " stats=", stats)

	emit_signal("hit", target)

	# Handle piercing
	if _pierces_left > 0:
		_pierces_left -= 1
		return

	_emit_and_free()

func _matches_hit_groups(n: Node) -> bool:
	var i: int = 0
	while i < hit_groups.size():
		var g: String = hit_groups[i]
		if g != "" and n.is_in_group(g):
			return true
		i += 1
	return false

func _find_stats_component(n: Node) -> Node:
	if n.has_node("StatsComponent"):
		var s := n.get_node("StatsComponent")
		if s is Node:
			return s
	for c in n.get_children():
		if c is Node and c.name == "StatsComponent":
			return c
	return null

func _apply_sprite_orientation(dir: Vector2) -> void:
	if sprite == null:
		return
	if orientation_mode == "FREE_ROTATE":
		rotation = atan2(dir.y, dir.x)
		if sprite is AnimatedSprite2D:
			sprite.flip_h = false
	else:
		# FOUR_WAY: keep crisp pixels (flip for left; rotate 90° for up/down)
		if abs(dir.x) >= abs(dir.y):
			rotation = 0.0
			if dir.x >= 0.0:
				if sprite is AnimatedSprite2D:
					sprite.flip_h = false
			else:
				if sprite is AnimatedSprite2D:
					sprite.flip_h = true
		else:
			if sprite is AnimatedSprite2D:
				sprite.flip_h = false
			if dir.y < 0.0:
				rotation = -PI * 0.5
			else:
				rotation = PI * 0.5

func _emit_and_free() -> void:
	emit_signal("expired")
	queue_free()
