extends Node
class_name StatusVisualProxy

signal visual_flags_changed()
signal hint_forwarded(name: StringName, data: Dictionary)

@export var status_path: NodePath
@export var animator_path: NodePath

# NEW (Choice B + layered rig):
# If set, StatusVisualProxy tints ONLY this node.
# Leave empty to auto-discover (VisualRoot/BodySprite preferred).
@export var tint_target_path: NodePath

# Optional: if you decide a name later, you can set this and leave tint_target_path empty.
# Example: "BodySprite"
@export var tint_target_name: StringName = StringName("BodySprite")

@export var tint_strength: float = 0.80
@export var tint_fade_time: float = 0.15
@export var use_self_modulate: bool = true
@export var debug_prints: bool = true

# -----------------------------
# Hit flash (on damage taken)
# -----------------------------
@export var hit_flash_enabled: bool = true
@export var hit_flash_color: Color = Color(1.0, 0.0, 0.0, 1.0) # red
@export var hit_flash_time_sec: float = 0.08

# Filter out DoT/status tick sources (StatusConditions uses "Status:...")
@export var hit_flash_on_status_ticks: bool = false
@export var hit_flash_status_source_prefix: String = "Status:"

# Optional: explicit stats path (leave empty to auto-find)
@export var stats_path: NodePath

# Godot 4.x: Color8 is deprecated. Keep hex as const, convert to linear at runtime.
const COLOR_POISONED_SRGB: Color = Color("#a64bd6")
const COLOR_BURNING_SRGB: Color = Color("#e44a00")
const COLOR_FROZEN_SRGB:  Color = Color("#66ccff")

# Runtime (linear) equivalents (cannot be const because srgb_to_linear() is not const-evaluable)
var COLOR_POISONED: Color = Color(1, 1, 1, 1)
var COLOR_BURNING: Color  = Color(1, 1, 1, 1)
var COLOR_FROZEN: Color   = Color(1, 1, 1, 1)

var _status: Node = null
var _animator: Node = null

# NOTE:
# _sprite is now the SINGLE target that we tint/flash (Body layer preferred).
var _sprite: AnimatedSprite2D = null

var _stats: Node = null

var _base_modulate: Color = Color(1, 1, 1, 1)
var _base_self_modulate: Color = Color(1, 1, 1, 1)

var _active_tints: Dictionary = {}

var is_dead_visual: bool = false
var is_invulnerable_visual: bool = false
var is_burning_visual: bool = false
var is_poisoned_visual: bool = false
var is_frozen_visual: bool = false
var is_stunned_visual: bool = false
var is_mesmerized_visual: bool = false
var is_confused_visual: bool = false
var is_transformed_visual: bool = false
var is_snared_visual: bool = false
var is_slowed_visual: bool = false

var _hit_flash_seq: int = 0
var _is_flashing: bool = false

func _ready() -> void:
	# Compute linear tint colors once (fixes "weird" look under linear rendering).
	COLOR_POISONED = COLOR_POISONED_SRGB.srgb_to_linear()
	COLOR_BURNING = COLOR_BURNING_SRGB.srgb_to_linear()
	COLOR_FROZEN = COLOR_FROZEN_SRGB.srgb_to_linear()

	_autowire_nodes()
	_try_connect_signals()
	_debug_report("ready() initial")

	# Race-safe: try again next frame in case the StatusConditions was added after us
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.create_timer(0.01).timeout.connect(func() -> void:
			# FIX: timer can fire after we got freed / removed from tree.
			if not is_instance_valid(self):
				return
			if not is_inside_tree():
				return
			_autowire_nodes()
			_try_connect_signals()
			_debug_report("ready() post-timer")
		)

func _autowire_nodes() -> void:
	# FIX: never probe paths when not inside the tree (prevents get_path assertions + stale nodes).
	if not is_inside_tree():
		return

	if status_path != NodePath():
		_status = get_node_or_null(status_path)
	else:
		_status = _find_status_node()

	if animator_path != NodePath():
		_animator = get_node_or_null(animator_path)
	else:
		_animator = _find_animator()

	if stats_path != NodePath():
		_stats = get_node_or_null(stats_path)
	else:
		_stats = _find_stats_node()

	_sprite = _find_tint_sprite()

	# Cache base colors
	if _sprite != null:
		_base_modulate = _sprite.modulate
		_base_self_modulate = _sprite.self_modulate
		if _base_modulate == null:
			_base_modulate = Color(1.0, 1.0, 1.0, 1.0)
		if _base_self_modulate == null:
			_base_self_modulate = Color(1.0, 1.0, 1.0, 1.0)

	# Prime flags if status exposes helpers
	if _status != null:
		if _status.has_method("is_dead"):
			is_dead_visual = bool(_status.call("is_dead"))
		if _status.has_method("is_invulnerable"):
			is_invulnerable_visual = bool(_status.call("is_invulnerable"))

func _try_connect_signals() -> void:
	if _status == null:
		return
	# Connect animation_state_hint
	if _status.has_signal("animation_state_hint"):
		var c1: Callable = Callable(self, "_on_anim_hint")
		if not _status.is_connected("animation_state_hint", c1):
			_status.connect("animation_state_hint", c1)
	# Connect status_applied (for guaranteed trace + potential future visuals)
	if _status.has_signal("status_applied"):
		var c2: Callable = Callable(self, "_on_status_applied")
		if not _status.is_connected("status_applied", c2):
			_status.connect("status_applied", c2)
	# Connect dead change
	if _status.has_signal("dead_state_changed"):
		var c3: Callable = Callable(self, "_on_dead_changed")
		if not _status.is_connected("dead_state_changed", c3):
			_status.connect("dead_state_changed", c3)

	# Connect to damage signals for hit flash
	if _stats != null and hit_flash_enabled:
		if _stats.has_signal("damage_taken_ex"):
			var c4: Callable = Callable(self, "_on_damage_taken_ex")
			if not _stats.is_connected("damage_taken_ex", c4):
				_stats.connect("damage_taken_ex", c4)
		if _stats.has_signal("damage_taken"):
			var c5: Callable = Callable(self, "_on_damage_taken")
			if not _stats.is_connected("damage_taken", c5):
				_stats.connect("damage_taken", c5)

func _debug_report(tag: String) -> void:
	if not debug_prints:
		return
	# FIX: get_path() asserts when not inside tree
	var path_str: String = "<not-in-tree>"
	if is_inside_tree():
		path_str = String(self.get_path())

	print("[SVP]", tag,
		" node=", path_str,
		" status=", (_status if _status != null else "null"),
		" animator=", (_animator if _animator != null else "null"),
		" stats=", (_stats if _stats != null else "null"),
		" sprite=", (_sprite if _sprite != null else "null"))
	if _status != null:
		print("[SVP] signals:",
			" has_hint=", _status.has_signal("animation_state_hint"),
			" has_applied=", _status.has_signal("status_applied"),
			" connected_hint=", _status.is_connected("animation_state_hint", Callable(self, "_on_anim_hint")),
			" connected_applied=", _status.is_connected("status_applied", Callable(self, "_on_status_applied")))
	if _stats != null:
		print("[SVP] stats signals:",
			" has_damage_ex=", _stats.has_signal("damage_taken_ex"),
			" has_damage=", _stats.has_signal("damage_taken"))

# ----------------------------------------------------------------------------- #
# Signal handlers
# ----------------------------------------------------------------------------- #
func _on_status_applied(id: StringName, data: Dictionary) -> void:
	if debug_prints:
		print("[SVP] status_applied:", id, " data=", data)

func _on_dead_changed(dead_now: bool) -> void:
	is_dead_visual = dead_now
	_apply_animator_flags()
	emit_signal("visual_flags_changed")

	# When entering the dead/ghost state, clear any active status tints
	if dead_now:
		_active_tints.clear()
		_refresh_tint()
	else:
		_refresh_tint()

	if debug_prints:
		print("[SVP] dead_state_changed ->", dead_now)

func _on_anim_hint(name: StringName, data: Dictionary) -> void:
	if debug_prints:
		print("[SVP] anim_hint:", name, " data=", data)

	var payload_color: Color = Color(1, 1, 1, 1)
	var has_color: bool = false
	if data.has("color"):
		var v: Variant = data["color"]
		if typeof(v) == TYPE_COLOR:
			payload_color = v
			has_color = true

	# invuln passthrough
	if name == StringName("invulnerable_on"):
		is_invulnerable_visual = true
		_apply_animator_flags()
		emit_signal("visual_flags_changed")
		emit_signal("hint_forwarded", name, data)
		return
	elif name == StringName("invulnerable_off"):
		is_invulnerable_visual = false
		_apply_animator_flags()
		emit_signal("visual_flags_changed")
		emit_signal("hint_forwarded", name, data)
		return

	# toggles -> tint stack
	if name == StringName("burn_on"):
		is_burning_visual = true
		var col: Color = COLOR_BURNING
		if has_color:
			col = payload_color
		_push_tint(StringName("burn"), col)
	elif name == StringName("burn_off"):
		is_burning_visual = false
		_pop_tint(StringName("burn"))
	elif name == StringName("poison_on"):
		is_poisoned_visual = true
		var colp: Color = COLOR_POISONED
		if has_color:
			colp = payload_color
		_push_tint(StringName("poison"), colp)
	elif name == StringName("poison_off"):
		is_poisoned_visual = false
		_pop_tint(StringName("poison"))
	elif name == StringName("frozen_on"):
		is_frozen_visual = true
		var colf: Color = COLOR_FROZEN
		if has_color:
			colf = payload_color
		_push_tint(StringName("frozen"), colf)
	elif name == StringName("frozen_off"):
		is_frozen_visual = false
		_pop_tint(StringName("frozen"))
	# others just update flags
	elif name == StringName("stunned_on"):
		is_stunned_visual = true
	elif name == StringName("stunned_off"):
		is_stunned_visual = false
	elif name == StringName("mesmerized_on"):
		is_mesmerized_visual = true
	elif name == StringName("mesmerized_off"):
		is_mesmerized_visual = false
	elif name == StringName("confused_on"):
		is_confused_visual = true
	elif name == StringName("confused_off"):
		is_confused_visual = false
	elif name == StringName("transformed_on"):
		is_transformed_visual = true
	elif name == StringName("transformed_off"):
		is_transformed_visual = false
	elif name == StringName("snared_on"):
		is_snared_visual = true
	elif name == StringName("snared_off"):
		is_snared_visual = false
	elif name == StringName("slowed_on"):
		is_slowed_visual = true
	elif name == StringName("slowed_off"):
		is_slowed_visual = false

	_apply_animator_flags()
	emit_signal("hint_forwarded", name, data)

# ----------------------------------------------------------------------------- #
# Damage-driven hit flash
# ----------------------------------------------------------------------------- #
func _on_damage_taken_ex(amount: float, _dmg_type: String, source: String, _is_crit: bool) -> void:
	if amount <= 0.0:
		return
	if not hit_flash_on_status_ticks:
		if hit_flash_status_source_prefix != "":
			if source.begins_with(hit_flash_status_source_prefix):
				return
	_do_hit_flash()

func _on_damage_taken(amount: float, _dmg_type: String, source: String) -> void:
	if amount <= 0.0:
		return
	if not hit_flash_on_status_ticks:
		if hit_flash_status_source_prefix != "":
			if source.begins_with(hit_flash_status_source_prefix):
				return
	_do_hit_flash()

func _do_hit_flash() -> void:
	if not hit_flash_enabled:
		return
	if _sprite == null:
		return

	_hit_flash_seq += 1
	var seq: int = _hit_flash_seq
	_is_flashing = true

	_apply_flash_now(hit_flash_color)

	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var t: float = max(0.01, hit_flash_time_sec)
	tree.create_timer(t).timeout.connect(func() -> void:
		if not is_instance_valid(self):
			return
		if not is_inside_tree():
			return
		if seq != _hit_flash_seq:
			return
		_is_flashing = false
		_refresh_tint_immediate()
	)

func _apply_flash_now(col: Color) -> void:
	var safe_col: Color = col
	if safe_col == null:
		safe_col = Color(1.0, 0.0, 0.0, 1.0)

	# Flash should be “unsticky”: use self_modulate if possible.
	if use_self_modulate:
		_sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)
		_sprite.self_modulate = safe_col
	else:
		_sprite.modulate = safe_col
		_sprite.self_modulate = Color(1.0, 1.0, 1.0, 1.0)

# ----------------------------------------------------------------------------- #
# Tint stack helpers
# ----------------------------------------------------------------------------- #
func _push_tint(key: StringName, color: Color) -> void:
	_active_tints[key] = color
	_refresh_tint()

func _pop_tint(key: StringName) -> void:
	if _active_tints.has(key):
		_active_tints.erase(key)
	_refresh_tint()

func _refresh_tint() -> void:
	# If we're mid-flash, don't fight it. We'll restore after the flash ends.
	if _is_flashing:
		return

	# Prefer animator override
	if _animator != null and _animator.has_method("set_status_tint_stack"):
		_animator.call("set_status_tint_stack", _active_tints.duplicate(true), tint_strength, tint_fade_time)
		return

	# Sprite fallback (single-layer target)
	if _sprite == null:
		return

	# Choose last-entered tint and blend against base
	var target_col: Color = _base_modulate
	var last_key: StringName = StringName("")
	for k in _active_tints.keys():
		last_key = k
	if String(last_key) != "":
		var tint_col: Color = _active_tints[last_key]
		var amt: float = clampf(tint_strength, 0.0, 1.0)
		target_col = _base_modulate.lerp(tint_col, amt)

	# IMPORTANT: avoid double-tinting by setting BOTH modulate and self_modulate
	var tw: Tween = create_tween()
	if tw == null:
		if use_self_modulate:
			_sprite.modulate = _base_modulate
			_sprite.self_modulate = target_col
		else:
			_sprite.modulate = target_col
			_sprite.self_modulate = _base_self_modulate
	else:
		tw.set_trans(Tween.TRANS_SINE)
		tw.set_ease(Tween.EASE_IN_OUT)

		if use_self_modulate:
			tw.tween_property(_sprite, "modulate", _base_modulate, max(0.0, tint_fade_time))
			tw.tween_property(_sprite, "self_modulate", target_col, max(0.0, tint_fade_time))
		else:
			tw.tween_property(_sprite, "modulate", target_col, max(0.0, tint_fade_time))
			tw.tween_property(_sprite, "self_modulate", _base_self_modulate, max(0.0, tint_fade_time))

	if debug_prints:
		print("[SVP] tint target =", target_col, " actives=", _active_tints)

func _refresh_tint_immediate() -> void:
	# Immediate restore (no tween). This prevents “stuck red”.
	if _sprite == null:
		return

	# If animator override exists, reapply instantly through it (zero fade).
	if _animator != null and _animator.has_method("set_status_tint_stack"):
		_animator.call("set_status_tint_stack", _active_tints.duplicate(true), tint_strength, 0.0)
		return

	var target_col: Color = _base_modulate
	var last_key: StringName = StringName("")
	for k in _active_tints.keys():
		last_key = k
	if String(last_key) != "":
		var tint_col: Color = _active_tints[last_key]
		var amt: float = clampf(tint_strength, 0.0, 1.0)
		target_col = _base_modulate.lerp(tint_col, amt)

	if use_self_modulate:
		_sprite.modulate = _base_modulate
		_sprite.self_modulate = target_col
	else:
		_sprite.modulate = target_col
		_sprite.self_modulate = _base_self_modulate

# ----------------------------------------------------------------------------- #
# Animator flag hooks
# ----------------------------------------------------------------------------- #
func _apply_animator_flags() -> void:
	if _animator == null:
		return
	if _animator.has_method("set_dead_visual"):
		_animator.call("set_dead_visual", is_dead_visual)
	if _animator.has_method("set_invulnerable_visual"):
		_animator.call("set_invulnerable_visual", is_invulnerable_visual)
	if _animator.has_method("set_stunned_visual"):
		_animator.call("set_stunned_visual", is_stunned_visual)
	if _animator.has_method("set_mesmerized_visual"):
		_animator.call("set_mesmerized_visual", is_mesmerized_visual)
	if _animator.has_method("set_confused_visual"):
		_animator.call("set_confused_visual", is_confused_visual)
	if _animator.has_method("set_transformed_visual"):
		_animator.call("set_transformed_visual", is_transformed_visual)
	if _animator.has_method("set_snared_visual"):
		_animator.call("set_snared_visual", is_snared_visual)
	if _animator.has_method("set_slowed_visual"):
		_animator.call("set_slowed_visual", is_slowed_visual)

# ----------------------------------------------------------------------------- #
# Node lookups
# ----------------------------------------------------------------------------- #
func _find_status_node() -> Node:
	var p: Node = self
	while p != null:
		if p.has_node("StatusConditions"):
			return p.get_node("StatusConditions")
		var i: int = 0
		while i < p.get_child_count():
			var c: Node = p.get_child(i)
			if c != null and c.name == "StatusConditions":
				return c
			i += 1
		p = p.get_parent()
	return null

func _find_animator() -> Node:
	var p: Node = self
	while p != null:
		if p.has_node("AnimationBridge"):
			return p.get_node("AnimationBridge")
		var i: int = 0
		while i < p.get_child_count():
			var c: Node = p.get_child(i)
			if c != null and c.name == "AnimationBridge":
				return c
			i += 1
		p = p.get_parent()
	return null

func _find_stats_node() -> Node:
	var p: Node = self
	while p != null:
		if p.has_node("StatsComponent"):
			return p.get_node("StatsComponent")
		var i: int = 0
		while i < p.get_child_count():
			var c: Node = p.get_child(i)
			if c != null:
				if c.has_signal("damage_taken_ex") or c.has_signal("damage_taken"):
					return c
			i += 1
		p = p.get_parent()
	return null

# Find the SINGLE sprite to tint (body layer preferred)
func _find_tint_sprite() -> AnimatedSprite2D:
	# 1) explicit override
	if tint_target_path != NodePath():
		var n0: Node = get_node_or_null(tint_target_path)
		if n0 != null:
			var s0: AnimatedSprite2D = n0 as AnimatedSprite2D
			if s0 != null:
				return s0

	# Find actor root (walk parents until Node2D/CharacterBody2D)
	var actor: Node = self
	var pp: Node = self
	while pp != null:
		if pp is Node2D:
			actor = pp
		if pp is CharacterBody2D:
			actor = pp
			break
		pp = pp.get_parent()

	# 2) Rig contract: VisualRoot + (tint_target_name)
	var vr: Node = null
	if actor != null:
		vr = actor.find_child("VisualRoot", true, false)
	if vr != null:
		if tint_target_name != StringName(""):
			var by_name: Node = (vr as Node).find_child(String(tint_target_name), true, false)
			if by_name != null:
				var sbn: AnimatedSprite2D = by_name as AnimatedSprite2D
				if sbn != null:
					return sbn

		# 3) VisualRoot fallback: first AnimatedSprite2D under VisualRoot
		var found_vr: AnimatedSprite2D = _find_first_sprite_under(vr)
		if found_vr != null:
			return found_vr

	# 4) Legacy fallback: first AnimatedSprite2D under actor
	if actor != null:
		return _find_first_sprite_under(actor)

	return null

func _find_first_sprite_under(root: Node) -> AnimatedSprite2D:
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n == null:
			continue
		var s: AnimatedSprite2D = n as AnimatedSprite2D
		if s != null and s.sprite_frames != null:
			return s
		var i: int = 0
		while i < n.get_child_count():
			stack.push_back(n.get_child(i))
			i += 1
	return null

# ----------------------------------------------------------------------------- #
# Manual test helper
# ----------------------------------------------------------------------------- #
func force_ping() -> void:
	_debug_report("force_ping")
	_refresh_tint()
