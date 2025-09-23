extends CharacterBody2D

# --- References ---
@onready var stats: Node = $StatsComponent
@onready var sprite: AnimatedSprite2D = $AnimatedSprite2D

# --- Config / Exports ---
@export var is_leader: bool = false : set = _set_is_leader, get = _get_is_leader
@export var sprint_mul: float = 1.35
@export var stamina_cost_per_second: float = 2.0
@export var sprint_step_cost: float = .2
@export var accel_lerp: float = 0.18
@export var resume_sprint_end: float = 1.0   

const SPRINT_ACTION := "sprint"
const SPRINT_ACTION_ALT := "ui_sprint"

var _party: Node = null
var _registered: bool = false
var _is_leader_cache: bool = false
var _sprinting: bool = false

const SPEED_FALLBACK: float = 96.0

# --- State ---
var controlled: bool = false
var last_move_dir: Vector2 = Vector2.DOWN

# -------------------- Lifecycle --------------------
func _ready() -> void:
    if is_instance_valid(sprite):
        sprite.frame_changed.connect(_on_sprite_frame_changed)

    _party = get_node_or_null("/root/Party")
    if _party != null and _party.has_signal("controlled_changed"):
        _party.controlled_changed.connect(_on_controlled_changed)
    elif _party == null:
        push_warning("[Player] /root/Party not found — defaulting to controlled=true")
        controlled = true

    call_deferred("_join_party")

func _join_party() -> void:
    if _registered:
        return
    if _party == null:
        _party = get_node_or_null("/root/Party")
        if _party == null:
            return
        if _party.has_signal("controlled_changed"):
            _party.controlled_changed.connect(_on_controlled_changed)

    if stats == null:
        push_warning("[Player] StatsComponent missing under " + name)

    _party.call("add_member", self, is_leader)
    _registered = true

# -------------------- Leader <-> Control link --------------------
func _set_is_leader(v: bool) -> void:
    _is_leader_cache = v
    if v and _party != null and _party.has_method("set_controlled"):
        _party.call("set_controlled", self)

func _get_is_leader() -> bool:
    return _is_leader_cache

# Called by Party when control changes
func set_controlled(v: bool) -> void:
    controlled = v
    set_process_input(v)
    print("[", name, "] controlled=", v)

func _on_controlled_changed(current: Node) -> void:
    _is_leader_cache = (current == self)
    if controlled:
        modulate = Color(1, 1, 1, 1)
    else:
        modulate = Color(0.82, 0.82, 0.82, 1)

# -------------------- Movement / Sprint --------------------
func _physics_process(delta: float) -> void:
    var dir: Vector2 = Vector2.ZERO

    if controlled:
        dir = Vector2(
            Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
            Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
        )
        if dir.length_squared() > 1.0:
            dir = dir.normalized()

        _sprinting = _is_sprint_pressed() and (dir != Vector2.ZERO)

        if _sprinting and stats != null and stats.has_method("spend_end"):
            var drain: float = stamina_cost_per_second * delta
            var ok: bool = stats.call("spend_end", drain)
            if not ok:
                _sprinting = false

        var base_speed: float = SPEED_FALLBACK
        if stats != null and stats.has_method("get_final_stat"):
            var v_any: Variant = stats.call("get_final_stat", "MoveSpeed")
            var v_type: int = typeof(v_any)
            var v_f: float = 0.0
            if v_type == TYPE_INT or v_type == TYPE_FLOAT:
                v_f = float(v_any)
            if v_f > 0.0:
                base_speed = v_f

        var target_speed: float = base_speed
        if _sprinting:
            target_speed *= sprint_mul

        var desired: Vector2 = dir * target_speed
        velocity = velocity.lerp(desired, accel_lerp)
        move_and_slide()

        if sprite != null:
            if _sprinting:
                sprite.speed_scale = 1.25
            else:
                sprite.speed_scale = 1.0

    _update_animation()

func _is_sprint_pressed() -> bool:
    var pressed: bool = false
    if InputMap.has_action(SPRINT_ACTION) and Input.is_action_pressed(SPRINT_ACTION):
        pressed = true
    elif InputMap.has_action(SPRINT_ACTION_ALT) and Input.is_action_pressed(SPRINT_ACTION_ALT):
        pressed = true
    return pressed

# -------------------- Animation --------------------
func _update_animation() -> void:
    if not is_instance_valid(sprite):
        return

    var v: Vector2 = velocity
    var speed: float = v.length()
    var moving: bool = speed > 1.0
    if moving:
        last_move_dir = v / max(speed, 0.001)

    var use_side: bool = abs(last_move_dir.x) >= abs(last_move_dir.y)
    var anim_name: String = ""
    var flip_h: bool = false

    if moving:
        if use_side:
            anim_name = "walk_side"
            flip_h = last_move_dir.x < 0.0
        else:
            anim_name = "walk_up" if last_move_dir.y < 0.0 else "walk_down"
    else:
        if use_side:
            anim_name = "idle_side"
            flip_h = last_move_dir.x < 0.0
        else:
            anim_name = "idle_up" if last_move_dir.y < 0.0 else "idle_down"

    if sprite.animation != anim_name:
        sprite.flip_h = flip_h
        sprite.play(anim_name)
    else:
        if anim_name.ends_with("_side"):
            sprite.flip_h = flip_h

func _on_sprite_frame_changed() -> void:
    if not (_sprinting and controlled and is_instance_valid(sprite)):
        return
    if sprint_step_cost <= 0.0:
        return
    var anim: String = sprite.animation
    if anim.begins_with("walk_"):
        var f: int = sprite.frame
        if f == 0 or f == 3:
            if stats != null and stats.has_method("spend_end"):
                stats.call("spend_end", sprint_step_cost)
