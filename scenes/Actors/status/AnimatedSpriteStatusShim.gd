extends AnimatedSprite2D
class_name AnimatedSpriteStatusShim
# Godot 4.5 — typed, no ternaries.
# Acts as an "animator" target for StatusVisualProxy:
#  - set_dead_visual(bool)
#  - set_invulnerable_visual(bool)
#  - set_status_tint(status_name: StringName, turn_on: bool, color: Color)
#  - set_status_tint_stack(tints: Dictionary, strength: float, fade_time: float)
# Plus placeholders for other flags (stunned, slowed, etc.)

# ----------------------------
# Dead anim swapping controls
# ----------------------------
@export var dead_suffix: String = "_dead"
@export var enforce_each_frame: bool = true

@export var promote_dead_walk_on_move: bool = true
@export var move_speed_threshold: float = 0.01
@export var move_distance_threshold_px: float = 0.05
@export var velocity_method_name: String = "get_velocity"
@export var velocity_property_name: String = "velocity"

# Enemy-safe gating (don’t swap to _dead for enemies unless you allow it)
@export var enable_dead_swap: bool = true
@export var dead_swap_group_blocklist: PackedStringArray = PackedStringArray(["Enemies"])
@export var require_group_for_dead_swap: StringName = StringName("") # leave empty to allow all

# ----------------------------
# Invulnerable blink
# ----------------------------
@export var invuln_blink_min_alpha: float = 0.6
@export var invuln_blink_speed: float = 6.0

# ----------------------------
# Tint controls (from StatusVisualProxy)
# ----------------------------
@export var tint_strength_default: float = 0.80   # 0..1
@export var tint_fade_time_default: float = 0.15  # seconds
@export var use_self_modulate_for_tint: bool = true

# Debug
@export var debug_log: bool = false

# ----------------------------
# Runtime state
# ----------------------------
var _dead_enabled: bool = false
var _invuln_enabled: bool = false
var _blink_tween: Tween = null

# Cache for movement detection
var _vel_source: Node = null
var _have_last_gpos: bool = false
var _last_gpos: Vector2 = Vector2.ZERO

# Tint state
var _active_tints: Dictionary = {}  # key: StringName -> Color
var _tint_strength: float = 0.80
var _tint_fade_time: float = 0.15
var _base_modulate: Color = Color(1, 1, 1, 1)
var _base_self_modulate: Color = Color(1, 1, 1, 1)

# -----------------------------------------------------------------------------
# Helpers (defined early so they exist when referenced)
# -----------------------------------------------------------------------------
func _idle_to_walk(base_name: String) -> String:
	if base_name.begins_with("idle_"):
#		"idle_down" -> "walk_down"
		return "walk_" + base_name.substr(5)
	return base_name

func _has_anim(name_str: String) -> bool:
	if sprite_frames == null:
		return false
	if sprite_frames.has_animation(name_str):
		return true
	return false

func _ends_with_suffix(s: StringName, suf: String) -> bool:
	return String(s).ends_with(suf)

func _strip_suffix(s: StringName, suf: String) -> String:
	var raw: String = String(s)
	if not raw.ends_with(suf):
		return raw
	return raw.substr(0, raw.length() - suf.length())

# -----------------------------------------------------------------------------
# Lifecycle
# -----------------------------------------------------------------------------
func _ready() -> void:
	# Cache base colors
	_base_modulate = modulate
	_base_self_modulate = self_modulate

	_tint_strength = clampf(tint_strength_default, 0.0, 1.0)
	_tint_fade_time = max(0.0, tint_fade_time_default)

	set_process(enforce_each_frame)
	_cache_velocity_source()
	_last_gpos = global_position
	_have_last_gpos = true

	_apply_dead_to_current_anim()
	_update_invuln_blink()

func _process(_delta: float) -> void:
	if enforce_each_frame:
		_apply_dead_to_current_anim()

# -----------------------------------------------------------------------------
# Public API (called by StatusVisualProxy)
# -----------------------------------------------------------------------------
func set_dead_visual(enabled: bool) -> void:
	_dead_enabled = enabled
	if debug_log:
		print("[AnimStatusShim] set_dead_visual=", enabled, " allowed=", _should_apply_dead())
	_apply_dead_to_current_anim()

func set_invulnerable_visual(enabled: bool) -> void:
	_invuln_enabled = enabled
	if debug_log:
		print("[AnimStatusShim] set_invulnerable_visual=", enabled)
	_update_invuln_blink()

# Single-tint toggle
func set_status_tint(status_name: StringName, turn_on: bool, color: Color) -> void:
	if turn_on:
		_active_tints[status_name] = color
	else:
		if _active_tints.has(status_name):
			_active_tints.erase(status_name)
	_tint_strength = clampf(tint_strength_default, 0.0, 1.0)
	_tint_fade_time = max(0.0, tint_fade_time_default)
	_apply_tint_from_stack()
	if debug_log:
		print("[AnimStatusShim] set_status_tint key=", status_name, " on=", turn_on, " color=", color, " actives=", _active_tints)

# Full tint stack replace
func set_status_tint_stack(tints: Dictionary, strength: float, fade_time: float) -> void:
	_active_tints = {}
	for k in tints.keys():
		var key: Variant = k
		var val: Variant = tints[k]
		if typeof(val) == TYPE_COLOR:
			if typeof(key) == TYPE_STRING_NAME:
				_active_tints[key] = val
			elif typeof(key) == TYPE_STRING:
				_active_tints[StringName(String(key))] = val
	_tint_strength = clampf(strength, 0.0, 1.0)
	_tint_fade_time = max(0.0, fade_time)
	_apply_tint_from_stack()
	if debug_log:
		print("[AnimStatusShim] set_status_tint_stack strength=", _tint_strength, " fade=", _tint_fade_time, " actives=", _active_tints)

# Placeholders for other flags (future-proof)
func set_stunned_visual(_on: bool) -> void: pass
func set_mesmerized_visual(_on: bool) -> void: pass
func set_confused_visual(_on: bool) -> void: pass
func set_transformed_visual(_on: bool) -> void: pass
func set_snared_visual(_on: bool) -> void: pass
func set_slowed_visual(_on: bool) -> void: pass
func set_broken_visual(_on: bool) -> void: pass

# -----------------------------------------------------------------------------
# Tint application
# -----------------------------------------------------------------------------
func _apply_tint_from_stack() -> void:
	# If no tints active, restore base colors
	if _active_tints.is_empty():
		_tween_tint(_base_modulate, _tint_fade_time)
		return

	# Blend all active colors toward base (simple cumulative blend)
	var target: Color = _base_modulate
	var count: int = _active_tints.size()
	var per_step: float = 0.0
	if count > 0:
		per_step = _tint_strength / float(count)

	for k in _active_tints.keys():
		var c: Color = _active_tints[k]
		target = target.lerp(c, clampf(per_step, 0.0, 1.0))

	_tween_tint(target, _tint_fade_time)

func _tween_tint(target: Color, fade_sec: float) -> void:
	var t: Tween = create_tween()
	if t == null:
		modulate = target
		if use_self_modulate_for_tint:
			self_modulate = target
		if debug_log:
			print("[AnimStatusShim] tint immediate ->", target)
		return

	t.set_trans(Tween.TRANS_SINE)
	t.set_ease(Tween.EASE_IN_OUT)
	t.tween_property(self, "modulate", target, fade_sec)
	if use_self_modulate_for_tint:
		t.tween_property(self, "self_modulate", target, fade_sec)
	if debug_log:
		print("[AnimStatusShim] tint tween ->", target, " fade=", fade_sec)

# -----------------------------------------------------------------------------
# Dead animation swap
# -----------------------------------------------------------------------------
func _should_apply_dead() -> bool:
	if not enable_dead_swap:
		return false

	# Require a group if specified
	if String(require_group_for_dead_swap) != "":
		var req: String = String(require_group_for_dead_swap)
		var owner_node: Node = get_parent()
		if owner_node == null:
			return false
		if not owner_node.is_in_group(req):
			return false

	# Blocklist (e.g., Enemies)
	if dead_swap_group_blocklist.size() > 0:
		var parent_node: Node = get_parent()
		if parent_node != null:
			var i: int = 0
			while i < dead_swap_group_blocklist.size():
				var g: String = dead_swap_group_blocklist[i]
				if g != "" and parent_node.is_in_group(g):
					return false
				i += 1

	# Respect flag from proxy
	if _dead_enabled:
		return true
	return false

func _apply_dead_to_current_anim() -> void:
	var cur: StringName = animation
	if String(cur) == "":
		return

	# If not allowed to apply dead for this actor, revert any _dead anim in use
	if not _should_apply_dead():
		if _ends_with_suffix(cur, dead_suffix):
			var base_name0: String = _strip_suffix(cur, dead_suffix)
			if _has_anim(base_name0):
				animation = base_name0
				play()
		return

	var base_name: String = String(cur)
	if _ends_with_suffix(cur, dead_suffix):
		base_name = _strip_suffix(cur, dead_suffix)

	var changed: bool = false

	# Promote idle_* -> walk_* if moving
	if promote_dead_walk_on_move and _is_moving_now():
		if base_name.begins_with("idle_"):
			var walk_name: String = _idle_to_walk(base_name)
			var walk_dead: String = walk_name + dead_suffix
			if _has_anim(walk_dead) and String(cur) != walk_dead:
				animation = walk_dead
				changed = true
			elif _has_anim(walk_name) and String(cur) != walk_name:
				animation = walk_name
				changed = true

	# Default suffix handling
	if not changed:
		var desired_dead: String = base_name + dead_suffix
		if _has_anim(desired_dead) and String(cur) != desired_dead:
			animation = desired_dead
			changed = true
		elif _ends_with_suffix(cur, dead_suffix) and not _has_anim(desired_dead) and _has_anim(base_name):
			animation = base_name
			changed = true

	if changed:
		if debug_log:
			print("[AnimStatusShim] swap -> ", animation)
		play()

# -----------------------------------------------------------------------------
# Invulnerable blink
# -----------------------------------------------------------------------------
func _update_invuln_blink() -> void:
	if _blink_tween != null and is_instance_valid(_blink_tween):
		_blink_tween.kill()
		_blink_tween = null
	self_modulate.a = 1.0
	if not _invuln_enabled or invuln_blink_speed <= 0.0:
		return
	_blink_tween = create_tween()
	_blink_tween.set_loops()
	var half_period: float = 0.5 / max(invuln_blink_speed, 0.01)
	_blink_tween.tween_property(self, "self_modulate:a", invuln_blink_min_alpha, half_period)
	_blink_tween.tween_property(self, "self_modulate:a", 1.0, half_period)

# -----------------------------------------------------------------------------
# Movement helpers
# -----------------------------------------------------------------------------
func _is_moving_now() -> bool:
	var speed_mag: float = 0.0
	if _vel_source != null and is_instance_valid(_vel_source):
		if _vel_source.has_method(velocity_method_name):
			var v_any: Variant = _vel_source.call(velocity_method_name)
			if typeof(v_any) == TYPE_VECTOR2:
				speed_mag = (v_any as Vector2).length()
		elif velocity_property_name in _vel_source:
			var vel_any: Variant = _vel_source.get(velocity_property_name)
			if typeof(vel_any) == TYPE_VECTOR2:
				speed_mag = (vel_any as Vector2).length()
	if speed_mag > move_speed_threshold:
		return true

	var dist: float = 0.0
	var cur_gpos: Vector2 = global_position
	if _have_last_gpos:
		dist = (cur_gpos - _last_gpos).length()
	_last_gpos = cur_gpos
	_have_last_gpos = true

	if dist > move_distance_threshold_px:
		return true
	return false

func _cache_velocity_source() -> void:
	var n: Node = self
	var depth: int = 0
	while n != null and depth < 6:
		if n.has_method(velocity_method_name) or (velocity_property_name in n):
			_vel_source = n
			return
		n = n.get_parent()
		depth += 1
