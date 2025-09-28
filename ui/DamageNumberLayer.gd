extends CanvasLayer
class_name DamageNumberLayer

# --- Behavior ---
@export var follow_world: bool = false      # we project world->screen ourselves
@export var scale_with_zoom: bool = false
@export var layer_order: int = 600
@export var debug_log: bool = false

@export var show_heals: bool = false
@export var min_amount_to_show: float = 1.0

# Coalescing & de-duplication
@export var coalesce_window_sec: float = 0.10
@export var suppress_hp_after_damage_sec: float = 0.12   # >= coalesce to avoid double-first-hit
@export var crit_immediate: bool = true                  # draw crits instantly (no coalesce)

# --- Visuals (numbers) ---
@export var font_px: int = 16
@export var base_scale: float = 0.95
@export var crit_scale: float = 1.75
@export var y_offset: float = -16.0
@export var rise_pixels: float = 26.0
@export var jitter_px: float = 6.0
@export var life_sec: float = 0.70
@export var damage_color: Color = Color(1.0, 0.35, 0.35)
@export var heal_color: Color   = Color(0.35, 1.0, 0.35)

# If your bitmap font ignores font_color, tint via self_modulate instead.
@export var use_self_modulate_coloring: bool = true

# Outline
@export var use_outline: bool = true
@export var outline_size: int = 2
@export var outline_color: Color = Color(0, 0, 0, 1)
@export var crit_outline_boost: int = 2
@export var crit_outline_color: Color = Color(0.12, 0.07, 0.0, 1)

# Crit styling (number only)
@export var crit_text_color: Color = Color(1.0, 0.85, 0.2)      # gold
@export var crit_flash_color: Color = Color(1.0, 1.0, 0.6)
@export var crit_flash_time: float = 0.10
@export var crit_shake_px: float = 5.0
@export var crit_shake_cycles: int = 3
@export var crit_shake_speed: float = 0.04
@export var crit_scale_punch: float = 1.20

# Internals
var _anchors: Dictionary = {}
var _last_hp: Dictionary = {}
var _pending: Dictionary = {}           # key -> {"sum": float, "crit": bool}
var _flush_at: Dictionary = {}
var _suppress_hp_until: Dictionary = {}

func _ready() -> void:
	layer = layer_order
	follow_viewport_enabled = follow_world
	follow_viewport_scale = scale_with_zoom
	add_to_group("DamageNumberSpawners")
	set_process(true)

# -----------------------------------------------------------------------------
# World -> Screen helper (Camera2D-accurate)
# -----------------------------------------------------------------------------
func _world_to_screen(world_pos: Vector2) -> Vector2:
	var vp := get_viewport()
	var cam: Camera2D = vp.get_camera_2d()
	if cam != null:
		if cam.has_method("project_position"):
			return cam.project_position(world_pos)
		var center: Vector2 = cam.get_screen_center_position() if cam.has_method("get_screen_center_position") else cam.global_position
		var zoom: Vector2 = cam.zoom if cam.has_method("get_zoom") else Vector2.ONE
		var vp_size: Vector2 = vp.get_visible_rect().size
		return (world_pos - center) * zoom + vp_size * 0.5
	return world_pos

func _clamp_to_viewport(p: Vector2, margin: float = 4.0) -> Vector2:
	var r := get_viewport().get_visible_rect()
	var minp := r.position + Vector2(margin, margin)
	var maxp := r.position + r.size - Vector2(margin, margin)
	return Vector2(clamp(p.x, minp.x, maxp.x), clamp(p.y, minp.y, maxp.y))

# -----------------------------------------------------------------------------
# Public API
# -----------------------------------------------------------------------------
func register_emitter(stats: Node, anchor: Node2D = null) -> void:
	if stats == null: return

	var cb_exit: Callable = Callable(self, "_on_stats_tree_exiting").bind(stats)
	if not stats.tree_exiting.is_connected(cb_exit):
		stats.tree_exiting.connect(cb_exit)

	var anch: Node2D = anchor if anchor != null else _guess_anchor(stats)
	_anchors[stats] = anch

	var curr_hp: float = 0.0
	if stats.has_method("current_hp"):
		var v_m = stats.call("current_hp")
		if typeof(v_m) == TYPE_INT or typeof(v_m) == TYPE_FLOAT:
			curr_hp = float(v_m)
	else:
		var v_p = stats.get("current_hp")
		if typeof(v_p) == TYPE_INT or typeof(v_p) == TYPE_FLOAT:
			curr_hp = float(v_p)
	_last_hp[stats] = curr_hp

	if stats.has_signal("damage_taken_ex"):
		var cb1: Callable = Callable(self, "_on_damage_taken_ex").bind(stats)
		if not stats.damage_taken_ex.is_connected(cb1):
			stats.damage_taken_ex.connect(cb1)
	elif stats.has_signal("damage_taken"):
		var cb2: Callable = Callable(self, "_on_damage_taken").bind(stats)
		if not stats.damage_taken.is_connected(cb2):
			stats.damage_taken.connect(cb2)

	if stats.has_signal("hp_changed"):
		var cb_hp: Callable = Callable(self, "_on_hp_changed").bind(stats)
		if not stats.hp_changed.is_connected(cb_hp):
			stats.hp_changed.connect(cb_hp)

	if stats.has_signal("stat_changed"):
		var cb_sc: Callable = Callable(self, "_on_stat_changed").bind(stats)
		if not stats.stat_changed.is_connected(cb_sc):
			stats.stat_changed.connect(cb_sc)

func show_for_world(world_pos: Vector2, amount: float, is_heal: bool, is_crit: bool = false) -> void:
	var screen: Vector2 = _world_to_screen(world_pos) + Vector2(0.0, y_offset)
	screen = _clamp_to_viewport(screen, 4.0)
	var txt: String = str(int(round(amount)))
	var col: Color = damage_color if not is_heal else heal_color
	_spawn_popup(screen, txt, col, is_crit)

func show_for_node(node2d: Node2D, amount: float, is_heal: bool, is_crit: bool = false) -> void:
	if node2d == null: return
	show_for_world(node2d.global_position, amount, is_heal, is_crit)

func show_at_screen(screen_pos: Vector2, amount: float, is_heal: bool, is_crit: bool = false) -> void:
	var txt: String = str(int(round(amount)))
	var col: Color = damage_color if not is_heal else heal_color
	_spawn_popup(_clamp_to_viewport(screen_pos + Vector2(0.0, y_offset), 4.0), txt, col, is_crit)

# -----------------------------------------------------------------------------
# Signals
# -----------------------------------------------------------------------------
func _on_damage_taken(amount: float, _dmg_type: String, _source: String, stats: Node) -> void:
	var now: float = _now()
	_suppress_hp_until[stats] = now + suppress_hp_after_damage_sec
	_queue_delta(stats, -absf(amount), false)

func _on_damage_taken_ex(amount: float, _dmg_type: String, _source: String, is_crit: bool, stats: Node) -> void:
	var now: float = _now()
	_suppress_hp_until[stats] = now + suppress_hp_after_damage_sec
	if debug_log:
		print("[DNL] dmg_ex amount=", amount, " is_crit=", is_crit, " stats=", stats)
	if crit_immediate and is_crit:
		_flush_now_for(stats)  # keep ordering sane
		_emit_number(stats, -absf(amount), true)
	else:
		_queue_delta(stats, -absf(amount), is_crit)

# Heals only from HP changes
func _on_hp_changed(current_hp: float, _max_hp: float, stats: Node) -> void:
	var had_prev: bool = _last_hp.has(stats)
	var prev: float = float(_last_hp.get(stats, current_hp))
	_last_hp[stats] = current_hp
	if not had_prev: return
	var now: float = _now()
	if now < float(_suppress_hp_until.get(stats, 0.0)): return
	var delta: float = current_hp - prev
	if delta > 0.0: _queue_delta(stats, delta, false)

func _on_stat_changed(stat_name: String, new_value: float, stats: Node) -> void:
	if stat_name.to_lower() != "hp": return
	var had_prev: bool = _last_hp.has(stats)
	var prev: float = float(_last_hp.get(stats, new_value))
	_last_hp[stats] = new_value
	if not had_prev: return
	var delta: float = new_value - prev
	if delta > 0.0: _queue_delta(stats, delta, false)

# -----------------------------------------------------------------------------
# Queue & flush
# -----------------------------------------------------------------------------
func _queue_delta(stats: Node, delta: float, is_crit: bool) -> void:
	var val = _pending.get(stats, null)
	if typeof(val) == TYPE_DICTIONARY:
		var entry: Dictionary = val
		entry["sum"] = float(entry.get("sum", 0.0)) + delta
		entry["crit"] = bool(entry.get("crit", false)) or is_crit
		_pending[stats] = entry
	else:
		_pending[stats] = {"sum": delta, "crit": is_crit}
	_flush_at[stats] = _now() + coalesce_window_sec

func _flush_now_for(stats_key) -> void:
	var val = _pending.get(stats_key, null)
	if val == null: return
	_pending.erase(stats_key)
	_flush_at.erase(stats_key)
	var sum: float = 0.0
	var crit: bool = false
	if typeof(val) == TYPE_DICTIONARY:
		sum = float(val.get("sum", 0.0))
		crit = bool(val.get("crit", false))
	else:
		sum = float(val)
		crit = false
	if !is_equal_approx(sum, 0.0):
		_emit_number(stats_key, sum, crit)

func _process(_dt: float) -> void:
	if _pending.is_empty(): return
	var now: float = _now()
	var to_flush: Array = []
	for k in _pending.keys():
		if now >= float(_flush_at.get(k, now + 9999.0)):
			to_flush.append(k)
	for k in to_flush:
		var val = _pending.get(k, null)
		_pending.erase(k)
		_flush_at.erase(k)
		if val == null: continue
		var sum: float = 0.0
		var crit: bool = false
		if typeof(val) == TYPE_DICTIONARY:
			sum = float(val.get("sum", 0.0))
			crit = bool(val.get("crit", false))
		else:
			sum = float(val)
			crit = false
		if !is_equal_approx(sum, 0.0):
			_emit_number(k, sum, crit)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
func _emit_number(stats_key, delta: float, is_crit: bool) -> void:
	var is_valid_obj: bool = (typeof(stats_key) == TYPE_OBJECT) and is_instance_valid(stats_key)

	var anchor: Node2D = null
	if is_valid_obj:
		var from_map = _anchors.get(stats_key)
		if typeof(from_map) == TYPE_OBJECT and is_instance_valid(from_map):
			anchor = from_map
		else:
			anchor = _guess_anchor(stats_key)

	if not is_valid_obj or anchor == null or not is_instance_valid(anchor):
		_cleanup_stats_key(stats_key)
		return

	var is_heal: bool = delta > 0.0
	var amt: float = absf(delta)
	if amt < min_amount_to_show: return
	if is_heal and not show_heals: return

	if debug_log:
		print("[DNL] flush delta=", delta, " is_crit=", is_crit, " anchor=", anchor)

	show_for_node(anchor, amt, is_heal, is_crit)

func _cleanup_stats_key(stats_key) -> void:
	_anchors.erase(stats_key)
	_last_hp.erase(stats_key)
	_pending.erase(stats_key)
	_flush_at.erase(stats_key)
	_suppress_hp_until.erase(stats_key)

func _on_stats_tree_exiting(stats: Node) -> void:
	_cleanup_stats_key(stats)

func _guess_anchor(stats: Node) -> Node2D:
	var n: Node = stats
	while n != null:
		if n is Node2D:
			return n as Node2D
		n = n.get_parent()
	return null

# -----------------------------------------------------------------------------
# Spawning (number only)
# -----------------------------------------------------------------------------
func _spawn_popup(pos: Vector2, text: String, base_col: Color, is_crit: bool) -> void:
	if debug_log:
		print("[DNL] spawn pos=", pos, " text=", text, " crit=", is_crit)

	var label := Label.new()
	add_child(label)
	label.top_level = true
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())

	# size
	var scale_factor: float = base_scale if not is_crit else base_scale * crit_scale
	var px: int = int(round(float(font_px) * max(0.01, scale_factor)))
	px = clampi(px, 8, 96)

	# colors
	var face_col: Color = base_col if not is_crit else crit_text_color
	var outsize: int = outline_size + (crit_outline_boost if is_crit else 0)
	var outcol: Color = outline_color if not is_crit else crit_outline_color

	# theming
	label.add_theme_font_size_override("font_size", px)
	label.add_theme_color_override("font_color", face_col)
	if use_outline and outline_size > 0:
		label.add_theme_constant_override("outline_size", outsize)
		label.add_theme_color_override("font_outline_color", outcol)

	# ensure color even with bitmap fonts
	if use_self_modulate_coloring:
		label.add_theme_color_override("font_color", Color(1,1,1,1))
		label.self_modulate = face_col
	else:
		label.self_modulate = Color(1,1,1,1)

	# initial state
	label.scale = Vector2.ONE
	label.modulate = Color(1, 1, 1, 0.0)  # alpha
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.z_index = 220 if is_crit else 200
	label.text = text
	var jx: float = randf_range(-jitter_px, jitter_px)
	label.global_position = pos + Vector2(jx, 0.0)

	# main tween (rise + fade)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "modulate:a", 1.0, 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "global_position:y", label.global_position.y - rise_pixels, life_sec).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, life_sec).set_delay(0.15).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tw.finished.connect(func() -> void:
		if is_instance_valid(label): label.queue_free()
	)

	# crit extras: scale punch + flash + shake (no banner)
	if is_crit:
		# scale punch
		var punch := create_tween()
		punch.tween_property(label, "scale", Vector2(crit_scale_punch, crit_scale_punch), 0.06).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		punch.tween_property(label, "scale", Vector2.ONE, 0.08).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)

		# flash using self_modulate so it doesn't fight alpha
		var start_sm: Color = label.self_modulate
		var flash_sm: Color = Color(crit_flash_color.r, crit_flash_color.g, crit_flash_color.b, start_sm.a)
		var flash := create_tween()
		flash.tween_property(label, "self_modulate", flash_sm, crit_flash_time).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		flash.tween_property(label, "self_modulate", start_sm, crit_flash_time * 1.25).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

		# shake
		var sx: float = label.global_position.x
		var shake := create_tween()
		var cycles: int = max(1, crit_shake_cycles)
		var i: int = 0
		while i < cycles:
			shake.tween_property(label, "global_position:x", sx + crit_shake_px, crit_shake_speed)
			shake.tween_property(label, "global_position:x", sx - crit_shake_px, crit_shake_speed)
			i += 1
		shake.tween_property(label, "global_position:x", sx, crit_shake_speed)

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
