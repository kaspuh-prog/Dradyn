extends Area2D
class_name FireflyCollectible
# Godot 4.5 — fully typed, no ternaries.

signal collected(actor: Node, added: int, leftover: int)

@export var auto_register_group: bool = true

# InteractionSystem will read this via exported property name fallback.
@export var interact_radius_override: float = 24.0
@export var prompt_text: String = "Collect Fireflies"

# What you actually “collect” (QuestDef can require/consume this item).
@export var item_def: ItemDef
@export var quantity: int = 1

# Optional: walk into it to collect (otherwise press Interact).
@export var auto_pickup_on_touch: bool = false
@export var require_actor_in_group: StringName = &"" # e.g. &"PartyMembers" (leave empty for no gate)

# Visual polish
@export var particles_path: NodePath = NodePath("FirefliesParticles")
@export var interact_anchor_path: NodePath = NodePath("InteractAnchor")

@export var highlight_modulate: Color = Color(1.2, 1.2, 1.2, 1.0)
@export var highlight_speed: float = 10.0

# -------------------------
# NEW: Brightness / glow
# -------------------------
@export var apply_particles_glow: bool = true
@export var particles_additive_blend: bool = true
@export var particles_color_tint: Color = Color(1.0, 1.0, 0.85, 1.0)
@export var particles_brightness: float = 1.75 # RGB multiplier (can be > 1.0)
@export var particles_self_modulate: bool = true

# -------------------------
# Lit / pulse gating
# -------------------------
@export var pulse_enabled: bool = true
@export var pulse_period_sec: float = 2.8
@export var pulse_phase_offset_sec: float = 0.0
@export var pulse_min_alpha: float = 0.0
@export var pulse_max_alpha: float = 1.0

# Only allow collecting while sufficiently “lit”.
@export var collect_only_when_lit: bool = true
@export var lit_collect_alpha_threshold: float = 0.85

# Hide interact prompt while not lit (recommended).
@export var prompt_only_when_lit: bool = true

# Cleanup
@export var disable_particles_on_collect: bool = true
@export var free_on_collect: bool = true
@export var free_delay_sec: float = 0.05

# Optional SFX
@export var collect_sfx_event: StringName = &""  # if set, AudioSys.play_sfx_event(event)

# -------------------------
# Particles safety net + “firefly” defaults (SAFE)
# -------------------------
@export var ensure_particles_exist: bool = true
@export var ensure_particles_configured: bool = true
@export var ensure_particles_emitting: bool = true

@export var default_particles_amount: int = 10
@export var default_particles_lifetime: float = 2.2

# Slow drift + local clump
@export var default_drift_speed_min: float = 2.0
@export var default_drift_speed_max: float = 8.0
@export var default_spawn_radius_px: float = 10.0

# Gentle “alive” movement bias (negative Y drifts upward)
@export var default_upward_bias: float = -3.0

# Mild per-particle size variation
@export var default_scale_min: float = 0.20
@export var default_scale_max: float = 0.35

@export var debug_particles: bool = false

var _collected: bool = false
var _highlight_on: bool = false

var _orig_modulate_set: bool = false
var _orig_modulate: Color = Color(1, 1, 1, 1)

var _pulse_time_sec: float = 0.0
var _pulse_alpha: float = 1.0

var _free_timer: Timer = null
var _default_texture: Texture2D = null

func _ready() -> void:
	if auto_register_group and not is_in_group("interactable"):
		add_to_group("interactable")

	if auto_pickup_on_touch:
		body_entered.connect(_on_body_entered)

	if ensure_particles_exist:
		_ensure_particles_node()

	if ensure_particles_configured:
		_ensure_particles_config()

	if ensure_particles_emitting:
		_ensure_particles_emitting()

	if apply_particles_glow:
		_apply_glow_settings()

	var vis: CanvasItem = _get_visual()
	if vis != null:
		_orig_modulate = vis.modulate
		_orig_modulate_set = true

	_pulse_alpha = _clamp_alpha(pulse_max_alpha)
	_apply_pulse_alpha()

func get_interact_radius() -> float:
	return interact_radius_override

func get_interact_prompt() -> String:
	if prompt_only_when_lit:
		if not _is_lit_enough():
			return ""
	return prompt_text

func set_interact_highlight(on: bool) -> void:
	_highlight_on = on
	if not _highlight_on:
		_apply_highlight_immediate(false)

func _process(delta: float) -> void:
	if _collected:
		return

	if pulse_enabled:
		_pulse_time_sec += delta
		_update_pulse_alpha()
		_apply_pulse_alpha()

	if _highlight_on:
		_apply_highlight_step(delta)

func interact(actor: Node) -> void:
	_try_collect(actor)

# -------------------------
# Collection
# -------------------------
func _on_body_entered(body: Node) -> void:
	if body == null:
		return
	_try_collect(body)

func _try_collect(actor: Node) -> void:
	if _collected:
		return

	if item_def == null:
		return

	if collect_only_when_lit:
		if not _is_lit_enough():
			return

	if String(require_actor_in_group) != "":
		if actor == null:
			return
		if not actor.is_in_group(String(require_actor_in_group)):
			return

	var inv: InventorySystem = _resolve_inventory()
	if inv == null:
		return

	var qty: int = quantity
	if qty <= 0:
		qty = 1

	var leftover: int = qty
	if inv.has_method("add_item_for") and actor != null:
		leftover = int(inv.call("add_item_for", actor, item_def, qty))
	else:
		leftover = int(inv.call("give_item", item_def, qty))

	var added: int = qty - leftover
	if added <= 0:
		return

	_collected = true
	_play_collect_sfx()
	_disable_visuals()

	collected.emit(actor, added, leftover)

	if free_on_collect:
		_queue_free_delayed()

func _play_collect_sfx() -> void:
	if StringName(collect_sfx_event) == StringName():
		return
	var audio: Node = get_node_or_null("/root/AudioSys")
	if audio == null:
		audio = get_node_or_null("/root/AudioSystem")
	if audio == null:
		return
	if audio.has_method("play_sfx_event"):
		audio.call("play_sfx_event", collect_sfx_event)

func _disable_visuals() -> void:
	if not disable_particles_on_collect:
		return
	var p: GPUParticles2D = _get_particles()
	if p != null:
		p.emitting = false

func _queue_free_delayed() -> void:
	if free_delay_sec <= 0.0:
		queue_free()
		return
	if _free_timer == null:
		_free_timer = Timer.new()
		_free_timer.one_shot = true
		add_child(_free_timer)
		_free_timer.timeout.connect(_on_free_timeout)

	free_delay_sec = maxf(free_delay_sec, 0.01)
	_free_timer.wait_time = free_delay_sec
	_free_timer.start()

func _on_free_timeout() -> void:
	queue_free()

# -------------------------
# Pulse / lit
# -------------------------
func _update_pulse_alpha() -> void:
	var period: float = pulse_period_sec
	if period <= 0.0:
		_pulse_alpha = _clamp_alpha(pulse_max_alpha)
		return

	var t: float = _pulse_time_sec + pulse_phase_offset_sec
	var phase: float = (t / period) * TAU
	var s: float = sin(phase)
	var u: float = (s + 1.0) * 0.5

	var a0: float = _clamp_alpha(pulse_min_alpha)
	var a1: float = _clamp_alpha(pulse_max_alpha)
	_pulse_alpha = lerpf(a0, a1, u)
	_pulse_alpha = _clamp_alpha(_pulse_alpha)

func _apply_pulse_alpha() -> void:
	var vis: CanvasItem = _get_visual()
	if vis == null:
		return
	var c: Color = vis.modulate
	c.a = _pulse_alpha
	vis.modulate = c

func _is_lit_enough() -> bool:
	return _pulse_alpha >= lit_collect_alpha_threshold

func _clamp_alpha(a: float) -> float:
	if a < 0.0:
		return 0.0
	if a > 1.0:
		return 1.0
	return a

# -------------------------
# Highlight visuals (preserve pulse alpha)
# -------------------------
func _apply_highlight_step(delta: float) -> void:
	var vis: CanvasItem = _get_visual()
	if vis == null:
		return

	if not _orig_modulate_set:
		_orig_modulate = vis.modulate
		_orig_modulate_set = true

	var cur: Color = vis.modulate
	var target: Color = highlight_modulate
	target.a = cur.a

	var t: float = clampf(delta * highlight_speed, 0.0, 1.0)
	var next: Color = cur.lerp(target, t)
	next.a = cur.a
	vis.modulate = next

func _apply_highlight_immediate(on: bool) -> void:
	var vis: CanvasItem = _get_visual()
	if vis == null:
		return

	if not _orig_modulate_set:
		_orig_modulate = vis.modulate
		_orig_modulate_set = true

	var c: Color = vis.modulate
	var a: float = c.a

	if on:
		var h: Color = highlight_modulate
		h.a = a
		vis.modulate = h
	else:
		var o: Color = _orig_modulate
		o.a = a
		vis.modulate = o

func _get_visual() -> CanvasItem:
	var p: GPUParticles2D = _get_particles()
	if p != null:
		return p
	var a: Node2D = get_node_or_null(interact_anchor_path) as Node2D
	if a != null:
		return a
	return self

# -------------------------
# Glow application
# -------------------------
func _apply_glow_settings() -> void:
	var p: GPUParticles2D = _get_particles()
	if p == null:
		return

	# Additive blend makes the “glow” read over dark backgrounds.
	if particles_additive_blend:
		var mat: CanvasItemMaterial = p.material as CanvasItemMaterial
		if mat == null:
			mat = CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		p.material = mat
	else:
		# If user disables additive, do not force any blend mode.
		pass

	# Brightness multiplier (RGB only). Keep alpha controlled by pulse.
	var b: float = particles_brightness
	if b < 0.0:
		b = 0.0

	var tint: Color = particles_color_tint
	var new_rgb: Color = Color(tint.r * b, tint.g * b, tint.b * b, 1.0)

	# We use (self_)modulate so your particle texture stays crisp/pixel-y.
	if particles_self_modulate:
		var sm: Color = p.self_modulate
		p.self_modulate = Color(new_rgb.r, new_rgb.g, new_rgb.b, sm.a)
	else:
		var m: Color = p.modulate
		p.modulate = Color(new_rgb.r, new_rgb.g, new_rgb.b, m.a)

# -------------------------
# Particles safety net + firefly config
# -------------------------
func _get_particles() -> GPUParticles2D:
	return get_node_or_null(particles_path) as GPUParticles2D

func _ensure_particles_node() -> void:
	var p: GPUParticles2D = _get_particles()
	if p != null:
		return

	var child_name: String = "FirefliesParticles"
	if String(particles_path) != "":
		var s: String = String(particles_path)
		if not s.contains("/"):
			child_name = s

	p = GPUParticles2D.new()
	p.name = child_name
	add_child(p)
	p.z_index = 2

	if debug_particles:
		print("FireflyCollectible: created missing GPUParticles2D child: ", p.name)

func _ensure_particles_config() -> void:
	var p: GPUParticles2D = _get_particles()
	if p == null:
		return

	# Don’t stomp user-authored values if they already exist.
	if p.amount <= 0:
		p.amount = max(default_particles_amount, 1)
	if p.lifetime <= 0.0:
		p.lifetime = maxf(default_particles_lifetime, 0.2)

	# If you authored a texture, keep it. If not, provide a tiny dot fallback.
	if p.texture == null:
		p.texture = _get_or_create_default_texture()

	# Use local coords so particles drift around the pickup itself.
	p.local_coords = true

	var mat: ParticleProcessMaterial = p.process_material as ParticleProcessMaterial
	if mat == null:
		mat = ParticleProcessMaterial.new()
		p.process_material = mat

	# Small local cloud
	mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	mat.emission_sphere_radius = maxf(default_spawn_radius_px, 0.0)

	# Slow random drift (wide spread = wandering)
	mat.direction = Vector3(0.0, -1.0, 0.0)
	mat.spread = 180.0
	mat.initial_velocity_min = maxf(default_drift_speed_min, 0.0)
	mat.initial_velocity_max = maxf(default_drift_speed_max, 0.0)

	# Slight upward bias to feel “alive”
	mat.gravity = Vector3(0.0, default_upward_bias, 0.0)

	# Size variance
	mat.scale_min = maxf(default_scale_min, 0.01)
	mat.scale_max = maxf(default_scale_max, 0.01)

	if debug_particles:
		print("FireflyCollectible: configured particles. amount=", p.amount, " lifetime=", p.lifetime, " tex=", p.texture)

func _ensure_particles_emitting() -> void:
	var p: GPUParticles2D = _get_particles()
	if p == null:
		return
	p.emitting = true

func _get_or_create_default_texture() -> Texture2D:
	if _default_texture != null:
		return _default_texture

	var img: Image = Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(1.0, 1.0, 0.6, 1.0))

	var tex: ImageTexture = ImageTexture.create_from_image(img)
	_default_texture = tex
	return _default_texture

# -------------------------
# Autoload resolution
# -------------------------
func _resolve_inventory() -> InventorySystem:
	var root: Node = get_tree().get_root()
	if root == null:
		return null

	var n: Node = root.get_node_or_null("InventorySystem")
	if n != null:
		return n as InventorySystem
	n = root.get_node_or_null("InventorySys")
	if n != null:
		return n as InventorySystem

	n = get_node_or_null("/root/InventorySystem")
	if n != null:
		return n as InventorySystem
	return get_node_or_null("/root/InventorySys") as InventorySystem
