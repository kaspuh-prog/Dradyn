extends CharacterBody2D

# -------- movement tunables ----------
const ACCEL: float = 10.0
const FRICTION: float = 12.0
const SPEED: float = 96.0
const SPRINT_MULT: float = 1.5

# -------- stamina / endurance ----------
@export var stamina_drain_per_sec: float = 12.0
@export var min_end_to_start_sprint: float = 6.0
@export var end_idle_regen_per_sec: float = 6.0

# -------- sfx ----------
const PITCH_JITTER: float = 0.05   # 0.95..1.05 pitch
const VOL_JITTER_DB: float = 1.5   # ±1.5 dB volume
var _step_cd: float = 0.0

# -------- nodes ----------
@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var stats: Node = $StatsComponent
@onready var follower: Node = ($CompanionFollow if has_node("CompanionFollow") else null)
@onready var sfx_foot: AudioStreamPlayer2D = ($Footstep if has_node("Footstep") else null)

# -------- control & ownership ----------
var _controlled: bool = false
var _owns_motion: bool = false
var _last_dir: Vector2 = Vector2.DOWN

# -------- input sampling ----------
var _input_dir: Vector2 = Vector2.ZERO
var _wants_sprint: bool = false

func _ready() -> void:
    _controlled = is_in_group("player_controlled")
    _apply_control_state(_controlled)
    if stats:
        stats.connect("damage_taken", Callable(self, "_on_damage_taken"))
    # print(name, " controlled? ", _controlled)

# Called by PartyManager
func on_control_gain() -> void:
    _controlled = true
    _apply_control_state(true)

func on_control_loss() -> void:
    _controlled = false
    _apply_control_state(false)

func _apply_control_state(v: bool) -> void:
    _owns_motion = v
    if follower:
        if follower.has_method("enable_follow"):
            follower.enable_follow(not v)
        if follower.has_method("set_motion_ownership"):
            follower.set_motion_ownership(not v)
    set_process_input(v)     # only read input when controlled
    set_physics_process(true)

# ---------- INPUT (sample only) ----------
func _input(event: InputEvent) -> void:
    if not _controlled:
        return
    _input_dir = Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
    _wants_sprint = Input.is_action_pressed("ui_shift")
    if _input_dir != Vector2.ZERO:
        _last_dir = _input_dir

# ---------- PHYSICS ----------
func _physics_process(dt: float) -> void:
    _step_cd = max(_step_cd - dt, 0.0)

    if _controlled:
        # speed & sprint gating
        var base_speed: float = SPEED
        if stats and stats.has_method("get_final_stat"):
            base_speed = float(stats.get_final_stat("MoveSpeed"))
        var can_sprint: bool = (stats == null) or (stats.current_stamina > min_end_to_start_sprint)
        var sprinting: bool = _wants_sprint and (_input_dir != Vector2.ZERO) and can_sprint
        var mult: float = (SPRINT_MULT if sprinting else 1.0)

        # target velocity from sampled input
        var target_vel: Vector2 = _input_dir * base_speed * mult

        # accel / friction (delta-safe)
        var speeding_up: bool = target_vel.length() > velocity.length()
        var rate: float = (ACCEL if speeding_up else FRICTION)
        velocity = velocity.lerp(target_vel, clamp(rate * dt, 0.0, 1.0))

        # stamina drain only while actually sprinting & moving
        if stats and sprinting and velocity.length() > 0.1:
            stats.change_stamina(-(stamina_drain_per_sec * dt))
    else:
        # not controlled: don't fight the follower; ease to stop if leftover velocity
        if velocity.length() > 0.1:
            velocity = velocity.lerp(Vector2.ZERO, clamp(FRICTION * dt, 0.0, 1.0))

    # only the motion owner moves the body this frame
    if _owns_motion:
        move_and_slide()

    # idle regen (works controlled or not)
    if stats and end_idle_regen_per_sec > 0.0 and velocity.length() < 0.1:
        stats.change_stamina(end_idle_regen_per_sec * dt)

    _update_anim_and_sfx()

# ---------- ANIM / SFX ----------
func _update_anim_and_sfx() -> void:
    var vlen := velocity.length()
    var moving := vlen > 1.0

    if anim:
        var base_speed: float = SPEED
        if stats and stats.has_method("get_final_stat"):
            base_speed = float(stats.get_final_stat("MoveSpeed"))
        anim.speed_scale = (clamp(vlen / base_speed, 0.6, 1.6) if (vlen > 0.1 and base_speed > 0.0) else 1.0)

        if moving:
            var dir := velocity.normalized()
            _last_dir = dir
            if abs(dir.x) > abs(dir.y):
                anim.flip_h = dir.x < 0.0
                anim.play("walk_side")
            elif dir.y > 0.0:
                anim.play("walk_down")
            else:
                anim.play("walk_up")
        else:
            if abs(_last_dir.x) > abs(_last_dir.y):
                anim.flip_h = _last_dir.x < 0.0
                anim.play("idle_side")
            elif _last_dir.y > 0.0:
                anim.play("idle_down")
            else:
                anim.play("idle_up")

    if sfx_foot:
        if moving:
            if _step_cd <= 0.0:
                _play_footstep()
                _step_cd = 0.28
        else:
            _step_cd = 0.0
            if sfx_foot.playing:
                sfx_foot.stop()

func _play_footstep() -> void:
    if sfx_foot == null:
        return
    var bs: float = SPEED
    if stats and stats.has_method("get_final_stat"):
        bs = float(stats.get_final_stat("MoveSpeed"))
    var speed_ratio: float = clampf(velocity.length() / (bs * SPRINT_MULT), 0.0, 1.0)
    sfx_foot.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
    sfx_foot.volume_db = lerpf(-2.0, 0.0, speed_ratio)
    sfx_foot.play()

# ---------- (optional) damage numbers ----------
@export var dmg_number_scene: PackedScene

func _on_damage_taken(amount: float, dmg_type: String, source: String) -> void:
    if dmg_number_scene == null:
        return
    var node: Node = dmg_number_scene.instantiate()
    var lbl: Label = node as Label
    if lbl == null:
        node.queue_free()
        return

    var vp: Viewport = get_viewport()
    var canvas_to_screen: Transform2D = vp.get_canvas_transform()
    var screen_pos: Vector2 = canvas_to_screen * (global_position + Vector2(0, -28))
    lbl.position = screen_pos

    var layer: CanvasLayer = get_tree().current_scene.get_node_or_null("DamageNumbersLayer") as CanvasLayer
    if layer != null:
        layer.add_child(lbl)
    else:
        get_tree().current_scene.add_child(lbl)

    var col: Color = Color.WHITE
    match dmg_type:
        "Fire":
            col = Color.ORANGE_RED
        "Ice":
            col = Color.CORNFLOWER_BLUE
        "Poison":
            col = Color.LIME_GREEN
        "Slash", "Pierce", "Blunt":
            col = Color.ANTIQUE_WHITE
        "Magic":
            col = Color.MEDIUM_ORCHID
        "Wind":
            col = Color.TURQUOISE
        "Light":
            col = Color.GOLD
        "Darkness":
            col = Color.BLACK
        _:
            pass

    lbl.modulate = col
    lbl.text = str(int(round(amount)))
    var t: Tween = lbl.create_tween()
    t.tween_property(lbl, "position", lbl.position + Vector2(0, -60), 0.8)
    t.parallel().tween_property(lbl, "modulate:a", 0.0, 0.6)
    t.tween_callback(lbl.queue_free)
