extends Node2D
class_name CompanionFollow

@export var follow_speed: float = 140.0
@export var stop_distance: float = 24.0
@export var resume_distance: float = 48.0

var _controlled: Node2D = null
var _owner_body: CharacterBody2D = null
var _active: bool = true

var follow_target: Node = null
var following: bool = true

func set_follow_target(t: Node) -> void:
	follow_target = t
	following = true
	print("[CompanionFollow:", owner.name, "] now following: ", t.name)

func _ready() -> void:
	_owner_body = owner as CharacterBody2D
	if not _owner_body:
		push_warning("CompanionFollow should be on a child of a CharacterBody2D.")
	if Engine.is_editor_hint():
		return
	if has_node("/root/Party"):
		var party := get_node("/root/Party") as PartyManager
		party.controlled_changed.connect(_on_controlled_changed)
		_on_controlled_changed(party.get_controlled())

func _on_controlled_changed(current: Node) -> void:
	_controlled = current as Node2D
	_active = (_controlled != owner)

func _physics_process(delta: float) -> void:
	if not following or follow_target == null or not _active:
		return

	var to_target: Vector2 = follow_target.global_position - _owner_body.global_position
	var dist: float = to_target.length()

	if dist <= stop_distance:
		_owner_body.velocity = Vector2.ZERO
		_owner_body.move_and_slide()
		return

	var dir := to_target.normalized()
	var speed := follow_speed if dist > resume_distance else follow_speed * 0.5
	_owner_body.velocity = dir * speed
	_owner_body.move_and_slide()
