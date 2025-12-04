extends Node
class_name StatusVisualProxy

signal visual_flags_changed()
signal hint_forwarded(name: StringName, data: Dictionary)

@export var status_path: NodePath
@export var animator_path: NodePath

@export var tint_strength: float = 0.80
@export var tint_fade_time: float = 0.15
@export var use_self_modulate: bool = true
@export var debug_prints: bool = true

const COLOR_POISONED: Color = Color8(0xA6, 0x4B, 0xD6, 0xFF)
const COLOR_BURNING: Color  = Color8(0xFF, 0x8A, 0x00, 0xFF)
const COLOR_FROZEN: Color   = Color8(0x66, 0xCC, 0xFF, 0xFF)

var _status: Node = null
var _animator: Node = null
var _sprite: AnimatedSprite2D = null

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

func _ready() -> void:
	_autowire_nodes()
	_try_connect_signals()
	_debug_report("ready() initial")

	# Race-safe: try again next frame in case the StatusConditions was added after us
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.create_timer(0.01).timeout.connect(func() -> void:
			_autowire_nodes()
			_try_connect_signals()
			_debug_report("ready() post-timer")
		)

func _autowire_nodes() -> void:
	if status_path != NodePath():
		_status = get_node_or_null(status_path)
	else:
		_status = _find_status_node()

	if animator_path != NodePath():
		_animator = get_node_or_null(animator_path)
	else:
		_animator = _find_animator()

	_sprite = _find_sprite()

	# Cache base colors
	if _sprite != null:
		_base_modulate = _sprite.modulate
		_base_self_modulate = _sprite.self_modulate

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

func _debug_report(tag: String) -> void:
	if not debug_prints:
		return
	print("[SVP]", tag,
		" node=", self.get_path(),
		" status=", (_status if _status != null else "null"),
		" animator=", (_animator if _animator != null else "null"),
		" sprite=", (_sprite if _sprite != null else "null"))
	if _status != null:
		print("[SVP] signals:",
			" has_hint=", _status.has_signal("animation_state_hint"),
			" has_applied=", _status.has_signal("status_applied"),
			" connected_hint=", _status.is_connected("animation_state_hint", Callable(self, "_on_anim_hint")),
			" connected_applied=", _status.is_connected("status_applied", Callable(self, "_on_status_applied")))

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
	# (burning, poison, frozen, etc.) so the ghost palette is clean.
	# We keep the logical StatusConditions entries; this is purely visual.
	if dead_now:
		_active_tints.clear()
		_refresh_tint()
	else:
		# On revive, recompute tint from whatever statuses remain.
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
	# Prefer animator override
	if _animator != null and _animator.has_method("set_status_tint_stack"):
		_animator.call("set_status_tint_stack", _active_tints.duplicate(true), tint_strength, tint_fade_time)
		return

	# Sprite fallback
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

	var tw: Tween = create_tween()
	if tw == null:
		_sprite.modulate = target_col
		if use_self_modulate:
			_sprite.self_modulate = target_col
	else:
		tw.set_trans(Tween.TRANS_SINE)
		tw.set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(_sprite, "modulate", target_col, max(0.0, tint_fade_time))
		if use_self_modulate:
			tw.tween_property(_sprite, "self_modulate", target_col, max(0.0, tint_fade_time))

	if debug_prints:
		print("[SVP] tint target =", target_col, " actives=", _active_tints)

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
			if c != null and c.get_class() == "AnimationBridge":
				return c
			i += 1
		p = p.get_parent()
	return null

func _find_sprite() -> AnimatedSprite2D:
	var p: Node = self
	while p != null:
		if p.has_node("Anim"):
			var n: Node = p.get_node("Anim")
			if n is AnimatedSprite2D:
				return n as AnimatedSprite2D
		var i: int = 0
		while i < p.get_child_count():
			var c: Node = p.get_child(i)
			if c != null and c is AnimatedSprite2D:
				return c as AnimatedSprite2D
			i += 1
		p = p.get_parent()
	return null

# ----------------------------------------------------------------------------- #
# Manual test helper
# ----------------------------------------------------------------------------- #
func force_ping() -> void:
	_debug_report("force_ping")
	_refresh_tint()
