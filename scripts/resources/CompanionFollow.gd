extends Node2D
class_name CompanionFollow

@export var follow_speed: float = 140.0
@export var stop_distance: float = 24.0
@export var resume_distance: float = 48.0
@export var min_close_speed_mul: float = 0.5   # floor so followers still drift when close (0..1)

# Soft anti-overlap between followers (set >0 to enable)
@export var separation_radius: float = 48.0    # 40–56 works well for 24×32 sprites
@export var separation_strength: float = 220.0

# (Optional) extreme unstick pulse if someone gets pinned
@export var stuck_radius: float = 16.0
@export var stuck_time_threshold: float = 0.25
@export var unstick_push: float = 140.0

var _controlled: Node2D = null
var _owner_body: CharacterBody2D = null
var _active: bool = true

var follow_target: Node = null
var following: bool = true

var _stuck_timer: float = 0.0

# --- Collision layers (adjust if your project differs) ---
const LAYER_PLAYER := 1
const LAYER_WORLD  := 2
const LAYER_ENEMY  := 3
const LAYER_COMP   := 4

# ---------------------------------------------------------
# SPEED SOURCE (yours, preserved)
# ---------------------------------------------------------
func _get_move_speed() -> float:
    if owner and owner.has_method("get_move_speed"):
        return float(owner.get_move_speed())

    if "move_speed" in owner:
        return float(owner.move_speed)

    if owner and owner.has_node("StatsComponent"):
        var stats = owner.get_node("StatsComponent")
        if stats:
            if stats.has_method("get_move_speed"):
                return float(stats.get_move_speed())
            if "move_speed" in stats:
                return float(stats.move_speed)

    return follow_speed

# ---------------------------------------------------------
# PUBLIC API
# ---------------------------------------------------------
func set_follow_target(t: Node) -> void:
    follow_target = t
    following = true
    print("[CompanionFollow:", owner.name, "] now following: ", t.name)

# ---------------------------------------------------------
# READY / PARTY HOOK
# ---------------------------------------------------------
func _ready() -> void:
    _owner_body = owner as CharacterBody2D
    if not _owner_body:
        push_warning("CompanionFollow should be on a child of a CharacterBody2D.")
    if Engine.is_editor_hint():
        return

    # Followers cooperate for separation if enabled
    if separation_radius > 0.0 and not is_in_group("companions"):
        add_to_group("companions")

    if has_node("/root/Party"):
        var party := get_node("/root/Party") as PartyManager
        party.controlled_changed.connect(_on_controlled_changed)
        _on_controlled_changed(party.get_controlled())

    # Ensure a role is applied even if Party didn’t emit yet
    if _active:
        _apply_as_companion(false)
    else:
        _apply_as_leader()

func _on_controlled_changed(current: Node) -> void:
    _controlled = current as Node2D
    _active = (_controlled != owner)
    if _active:
        _apply_as_companion(false)  # followers ignore leader & each other
    else:
        _apply_as_leader()          # controlled character

# ---------------------------------------------------------
# COLLISION ROLE HELPERS
# ---------------------------------------------------------
func _apply_as_leader() -> void:
    if _owner_body == null:
        return
    for i in range(1, 33):
        _owner_body.set_collision_layer_value(i, i == LAYER_PLAYER)
    for i in range(1, 33):
        _owner_body.set_collision_mask_value(i, false)
    _owner_body.set_collision_mask_value(LAYER_WORLD, true)
    _owner_body.set_collision_mask_value(LAYER_ENEMY, true)
    if is_in_group("companions"):
        remove_from_group("companions")

func _apply_as_companion(collide_with_other_companions: bool = false) -> void:
    if _owner_body == null:
        return
    for i in range(1, 33):
        _owner_body.set_collision_layer_value(i, i == LAYER_COMP)
    for i in range(1, 33):
        _owner_body.set_collision_mask_value(i, false)
    _owner_body.set_collision_mask_value(LAYER_WORLD, true)
    _owner_body.set_collision_mask_value(LAYER_ENEMY, true)
    _owner_body.set_collision_mask_value(LAYER_COMP, collide_with_other_companions)
    if separation_radius > 0.0 and not is_in_group("companions"):
        add_to_group("companions")

# ---------------------------------------------------------
# FOLLOW LOGIC (simple follow + smooth approach + separation/unstick)
# ---------------------------------------------------------
func _physics_process(delta: float) -> void:
    if not following or follow_target == null or not _active:
        return

    var target_pos: Vector2 = follow_target.global_position
    var to_target: Vector2 = target_pos - _owner_body.global_position
    var dist: float = to_target.length()

    # Stop band: sit still when we’re close enough
    if dist <= stop_distance:
        _owner_body.velocity = Vector2.ZERO
        _owner_body.move_and_slide()
        _stuck_timer = 0.0
        return

    # Base speed from stats (respects your other scripts)
    var base_speed: float = _get_move_speed()
    var speed: float = base_speed

    # Smooth slow band near the target so we don't ram the leader
    if dist < resume_distance:
        var band: float = resume_distance - stop_distance
        if band < 0.001:
            band = 0.001
        var t: float = clamp((dist - stop_distance) / band, 0.0, 1.0)
        var speed_scale: float = max(min_close_speed_mul, t)
        speed = base_speed * speed_scale

    var dir: Vector2 = to_target.normalized()

    # Soft separation from other companions (not the leader)
    var sep: Vector2 = Vector2.ZERO
    if separation_radius > 0.0 and separation_strength > 0.0:
        for node in get_tree().get_nodes_in_group("companions"):
            if node == self or not (node is Node2D):
                continue
            var other := node as Node2D
            var dvec: Vector2 = _owner_body.global_position - other.global_position
            var d: float = dvec.length()
            if d > 0.001 and d < separation_radius:
                var factor: float = (1.0 - d / separation_radius)
                sep += dvec.normalized() * (separation_strength * factor)

    # Emergency unstick if we somehow get pinned at the exact spot
    if dist < stuck_radius:
        _stuck_timer += delta
        if _stuck_timer >= stuck_time_threshold:
            var away: Vector2 = (_owner_body.global_position - target_pos).normalized()
            if away.length() < 0.01:
                away = Vector2.RIGHT
            _owner_body.velocity = away * unstick_push
            _owner_body.move_and_slide()
            return
    else:
        _stuck_timer = 0.0

    _owner_body.velocity = (dir * speed) + (sep * delta)
    _owner_body.move_and_slide()
