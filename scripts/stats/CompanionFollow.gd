extends Node2D
class_name CompanionFollow

@export var follow_speed: float = 140.0
@export var stop_distance: float = 24.0
@export var resume_distance: float = 48.0

var _controlled: Node2D = null
var _owner_body: CharacterBody2D = null
var _active: bool = true

var follow_target: Node = null
var following: bool = true  # or whatever you use to enable/disable

func set_follow_target(t: Node) -> void:
    follow_target = t
    following = true  # ensure it resumes if it was paused
    
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
    # If I am the controlled character, disable follow
    _active = (_controlled != owner)

func _physics_process(delta: float) -> void:
   if not following or follow_target == null:
    return

    var to_target: Vector2 = _controlled.global_position - _owner_body.global_position
    var dist: float = to_target.length()

    # Simple hysteresis so they don't jitter at the edge
    if dist <= stop_distance:
        _owner_body.velocity = Vector2.ZERO
        _owner_body.move_and_slide()
        return
    if dist > resume_distance:
        var dir: Vector2 = to_target.normalized()
        _owner_body.velocity = dir * follow_speed
    else:
        # Approaching — slow down a bit
        var dir2: Vector2 = to_target.normalized()
        _owner_body.velocity = dir2 * (follow_speed * 0.6)

    _owner_body.move_and_slide()
