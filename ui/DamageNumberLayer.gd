extends CanvasLayer
class_name DamageNumberLayer
## Damage/heal popup spawner with dedupe + coalescing (Godot 4.x).

# --- Behavior ---
@export var follow_world: bool = true                 # true = world-locked
@export var scale_with_zoom: bool = false            # keep text size fixed on screen
@export var layer_order: int = 600
@export var debug_on_ready: bool = false

@export var show_heals: bool = false                 # hide green heals by default
@export var min_amount_to_show: float = 1.0          # ignore tiny drips

# Coalescing & de-duplication
@export var coalesce_window_sec: float = 0.10        # combine hits within this window
@export var suppress_hp_after_damage_sec: float = 0.05  # ignore hp_changed right after damage_taken

# --- Visuals ---
@export var font_px: int = 16
@export var base_scale: float = 0.85
@export var crit_scale: float = 1.20
@export var y_offset: float = -16.0
@export var rise_pixels: float = 24.0
@export var jitter_px: float = 6.0
@export var life_sec: float = 0.65
@export var damage_color: Color = Color(1.0, 0.35, 0.35)
@export var heal_color: Color   = Color(0.35, 1.0, 0.35)

# StatsComponent -> Node2D anchor / last HP / pending deltas / flush deadlines / suppression
var _anchors: Dictionary = {}
var _last_hp: Dictionary = {}
var _pending: Dictionary = {}
var _flush_at: Dictionary = {}
var _suppress_hp_until: Dictionary = {}

func _ready() -> void:
	layer = layer_order
	follow_viewport_enabled = follow_world
	follow_viewport_scale = scale_with_zoom
	add_to_group("DamageNumberSpawners")
	set_process(true)
	if debug_on_ready:
		call_deferred("_debug_center")

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------
func register_emitter(stats: Node, anchor: Node2D = null) -> void:
	if stats == null:
		return

	var anch: Node2D = anchor
	if anch == null:
		anch = _guess_anchor(stats)
	_anchors[stats] = anch

	# Baseline last HP (prevents the “max HP on spawn” popup)
	var curr_hp: float = 0.0
	if stats.has_method("current_hp"):
		curr_hp = float(stats.call("current_hp"))
	_last_hp[stats] = curr_hp

	# Idempotent connects
	if stats.has_signal("damage_taken"):
		var cb_damage: Callable = Callable(self, "_on_damage_taken").bind(stats)
		if not stats.damage_taken.is_connected(cb_damage):
			stats.damage_taken.connect(cb_damage)

	if stats.has_signal("hp_changed"):
		var cb_hp: Callable = Callable(self, "_on_hp_changed").bind(stats)
		if not stats.hp_changed.is_connected(cb_hp):
			stats.hp_changed.connect(cb_hp)

	# Optional generic fallback some projects use
	if stats.has_signal("stat_changed"):
		var cb_sc: Callable = Callable(self, "_on_stat_changed").bind(stats)
		if not stats.stat_changed.is_connected(cb_sc):
			stats.stat_changed.connect(cb_sc)

# World & node helpers
func show_for_world(world_pos: Vector2, amount: float, is_heal: bool, is_crit: bool = false) -> void:
	var pos: Vector2 = world_pos + Vector2(0.0, y_offset)
	# If we’re not following the camera, convert world->screen
	if not follow_viewport_enabled:
		var cam: Camera2D = get_viewport().get_camera_2d()
		if cam != null:
			if cam.has_method("unproject_position"):
				pos = cam.unproject_position(world_pos) + Vector2(0.0, y_offset)
			elif cam.has_method("project_position"):
				pos = cam.project_position(world_pos) + Vector2(0.0, y_offset)
	var txt: String = str(int(round(amount)))
	var col: Color = heal_color if is_heal else damage_color
	_spawn_popup(pos, txt, col, is_crit)

func show_for_node(node2d: Node2D, amount: float, is_heal: bool, is_crit: bool = false) -> void:
	if node2d == null:
		return
	show_for_world(node2d.global_position, amount, is_heal, is_crit)

func show_at_screen(screen_pos: Vector2, amount: float, is_heal: bool, is_crit: bool = false) -> void:
	var txt: String = str(int(round(amount)))
	var col: Color = heal_color if is_heal else damage_color
	_spawn_popup(screen_pos + Vector2(0.0, y_offset), txt, col, is_crit)

# -----------------------------------------------------------------------------
# Signal handlers (dedupe + coalesce)
# -----------------------------------------------------------------------------
func _on_damage_taken(amount: float, _dmg_type: String, _source: String, stats: Node) -> void:
	var now: float = _now()
	_suppress_hp_until[stats] = now + suppress_hp_after_damage_sec  # prefer this event
	_queue_delta(stats, -absf(amount))  # negative = damage

func _on_hp_changed(current_hp: float, _max_hp: float, stats: Node) -> void:
	# First signal for this actor: baseline only
	var had_prev: bool = _last_hp.has(stats)
	var prev: float = float(_last_hp.get(stats, current_hp))
	_last_hp[stats] = current_hp
	if not had_prev:
		return

	# Ignore the hp_changed that immediately follows damage_taken (prevents double popup)
	var now: float = _now()
	var suppress_until: float = float(_suppress_hp_until.get(stats, 0.0))
	if now < suppress_until:
		return

	var delta: float = current_hp - prev
	if !is_equal_approx(delta, 0.0):
		_queue_delta(stats, delta)

# Optional generic fallback: stat_changed("HP", new_value)
func _on_stat_changed(stat_name: String, new_value: float, stats: Node) -> void:
	if stat_name.to_lower() != "hp":
		return
	var had_prev: bool = _last_hp.has(stats)
	var prev: float = float(_last_hp.get(stats, new_value))
	_last_hp[stats] = new_value
	if not had_prev:
		return
	var delta: float = new_value - prev
	if !is_equal_approx(delta, 0.0):
		_queue_delta(stats, delta)

# Queue & flush
func _queue_delta(stats: Node, delta: float) -> void:
	var sum: float = float(_pending.get(stats, 0.0)) + delta
	_pending[stats] = sum
	_flush_at[stats] = _now() + coalesce_window_sec

func _process(_dt: float) -> void:
	if _pending.is_empty():
		return
	var now: float = _now()
	var to_flush: Array = []
	for stats in _pending.keys():
		var when: float = float(_flush_at.get(stats, now + 9999.0))
		if now >= when:
			to_flush.append(stats)
	for stats in to_flush:
		var sum: float = float(_pending.get(stats, 0.0))
		_pending.erase(stats)
		_flush_at.erase(stats)
		if !is_equal_approx(sum, 0.0):
			_emit_number(stats, sum)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
func _emit_number(stats: Node, delta: float) -> void:
	var is_heal: bool = delta > 0.0
	var amt: float = absf(delta)

	# Filters
	if amt < min_amount_to_show:
		return
	if is_heal and not show_heals:
		return

	var anchor: Node2D = (_anchors.get(stats) as Node2D)
	if anchor == null:
		anchor = _guess_anchor(stats)
		_anchors[stats] = anchor

	if anchor != null:
		show_for_node(anchor, amt, is_heal, false)
	else:
		var center: Vector2 = get_viewport().get_visible_rect().size * 0.5
		show_at_screen(center, amt, is_heal, false)

func _guess_anchor(stats: Node) -> Node2D:
	var n: Node = stats
	while n != null:
		if n is Node2D:
			return n as Node2D
		n = n.get_parent()
	return null

func _spawn_popup(pos: Vector2, text: String, col: Color, is_crit: bool) -> void:
	var label: Label = Label.new()
	add_child(label)

	# No theme background
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())

	# Compute pixel size from knobs; clamp so it’s never 0
	var scale_factor := (crit_scale if is_crit else 1.0)
	var px := int(round(float(font_px) * max(0.01, base_scale) * max(0.01, scale_factor)))
	px = clampi(px, 8, 96)
	label.add_theme_font_size_override("font_size", px)
	label.add_theme_color_override("font_color", col)

	# Never scale the Control (avoid zero-determinant transforms)
	label.scale = Vector2.ONE
	label.modulate = Color(1,1,1,0.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 200

	var jx: float = randf_range(-jitter_px, jitter_px)
	label.text = text
	label.position = pos + Vector2(jx, 0.0)

	var tw: Tween = create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "modulate:a", 1.0, 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "position:y", label.position.y - rise_pixels, life_sec).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, life_sec).set_delay(0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.finished.connect(func() -> void:
		if is_instance_valid(label):
			label.queue_free()
	)


func _debug_center() -> void:
	var center: Vector2 = get_viewport().get_visible_rect().size * 0.5
	show_at_screen(center, 77.0, false, false)

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
