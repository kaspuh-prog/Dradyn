extends Node
class_name TargetingSystem

signal enemy_target_changed(target: Node2D)
signal ally_target_changed(target: Node2D)

# --- Config ---
@export var enable_input: bool = true
@export var refresh_hz: float = 5.0

@export var enemy_group_names: PackedStringArray = ["Enemies", "Enemy"]
@export var party_group_names: PackedStringArray = ["PartyMembers"]

@export var chevron_timeout_sec: float = 3.0
@export var chevron_fade_sec: float = 0.35
@export var chevron_enemy_color: Color = Color(1.0, 0.25, 0.2, 0.95)
@export var chevron_ally_color: Color = Color(0.2, 0.95, 1.0, 0.95)
@export var chevron_size_px: float = 6.0
@export var chevron_offset_y: float = 2.0

# If true, free the chevron node when it finishes fading out.
@export var free_on_fade: bool = true

# --- Internals ---
var _enemy_list: Array[Node2D] = []
var _ally_list: Array[Node2D] = []
var _enemy_index: int = -1
var _ally_index: int = -1

var _enemy_chev: Node2D
var _ally_chev: Node2D
var _enemy_fade_tween: Tween
var _ally_fade_tween: Tween

var _enemy_last_set_time: float = -1.0
var _ally_last_set_time: float = -1.0

# NEW: prevent auto re-attach after inactivity fade
var _enemy_hidden: bool = false
var _ally_hidden: bool = false

var _accum_time: float = 0.0

func _ready() -> void:
	set_process(true)
	_try_connect_party()
	_connect_to_global_ability_system_if_present()

func _process(delta: float) -> void:
	# 1) Inactivity checks FIRST so we mark hidden before any validation can re-attach
	_check_enemy_inactivity()
	_check_ally_inactivity()

	# 2) Periodic refresh + validate
	_accum_time += delta
	var step: float = 1.0 / max(1.0, refresh_hz)
	if _accum_time >= step:
		_accum_time = 0.0
		_refresh_lists()
		_validate_current_targets()

func _unhandled_input(event: InputEvent) -> void:
	if not enable_input:
		return
	var key: InputEventKey = event as InputEventKey
	if key == null:
		return
	if not key.pressed:
		return
	if key.echo:
		return
	if key.keycode == KEY_TAB:
		if key.shift_pressed:
			_cycle_ally_target(1)
		else:
			_cycle_enemy_target(1)

# --- Public API --------------------------------------------------------------

func current_enemy_target() -> Node2D:
	if _enemy_index >= 0 and _enemy_index < _enemy_list.size():
		return _enemy_list[_enemy_index]
	return null

func current_ally_target() -> Node2D:
	if _ally_index >= 0 and _ally_index < _ally_list.size():
		return _ally_list[_ally_index]
	return null

func set_enemy_target(n: Node2D) -> void:
	if n == null:
		_clear_enemy_chevron()
		_enemy_index = -1
		_enemy_hidden = false
		emit_signal("enemy_target_changed", null)
		return
	var idx: int = _index_of_node(_enemy_list, n)
	if idx < 0:
		_clear_enemy_chevron()
		_enemy_index = -1
		_enemy_hidden = false
		emit_signal("enemy_target_changed", null)
		return
	_enemy_index = idx
	_enemy_hidden = false
	_enemy_last_set_time = _now_s()
	_attach_enemy_chevron(n)
	emit_signal("enemy_target_changed", n)

func set_ally_target(n: Node2D) -> void:
	if n == null:
		_clear_ally_chevron()
		_ally_index = -1
		_ally_hidden = false
		emit_signal("ally_target_changed", null)
		return
	var idx: int = _index_of_node(_ally_list, n)
	if idx < 0:
		_clear_ally_chevron()
		_ally_index = -1
		_ally_hidden = false
		emit_signal("ally_target_changed", null)
		return
	_ally_index = idx
	_ally_hidden = false
	_ally_last_set_time = _now_s()
	_attach_ally_chevron(n)
	emit_signal("ally_target_changed", n)

func note_activity(which: String) -> void:
	var now_s: float = _now_s()
	if which == "enemy":
		_enemy_last_set_time = now_s
		_enemy_hidden = false
		_fade_in_enemy()
	elif which == "ally":
		_ally_last_set_time = now_s
		_ally_hidden = false
		_fade_in_ally()
	else:
		_enemy_last_set_time = now_s
		_ally_last_set_time = now_s
		_enemy_hidden = false
		_ally_hidden = false
		_fade_in_enemy()
		_fade_in_ally()

# --- Lists / Validation ------------------------------------------------------

func _refresh_lists() -> void:
	_enemy_list.clear()
	_ally_list.clear()

	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var gi: int = 0
	while gi < enemy_group_names.size():
		var gname: String = String(enemy_group_names[gi])
		var arr: Array = tree.get_nodes_in_group(gname)
		var k: int = 0
		while k < arr.size():
			var n: Node = arr[k]
			if n is Node2D:
				_enemy_list.append(n)
			k += 1
		gi += 1

	gi = 0
	while gi < party_group_names.size():
		var g2: String = String(party_group_names[gi])
		var arr2: Array = tree.get_nodes_in_group(g2)
		var k2: int = 0
		while k2 < arr2.size():
			var n2: Node = arr2[k2]
			if n2 is Node2D:
				_ally_list.append(n2)
			k2 += 1
		gi += 1

	# Clamp indices
	if _enemy_index >= _enemy_list.size():
		_enemy_index = -1
	if _ally_index >= _ally_list.size():
		_ally_index = -1

func _validate_current_targets() -> void:
	# Enemy
	if _enemy_index < 0:
		_clear_enemy_chevron()
	else:
		var n: Node2D = current_enemy_target()
		if n == null:
			_clear_enemy_chevron()
		else:
			# Only attach if we are NOT hidden and either no chevron exists
			# or it is attached to a different parent.
			if not _enemy_hidden:
				if _enemy_chev == null or _enemy_chev.get_parent() != n:
					_attach_enemy_chevron(n)

	# Ally
	if _ally_index < 0:
		_clear_ally_chevron()
	else:
		var n2: Node2D = current_ally_target()
		if n2 == null:
			_clear_ally_chevron()
		else:
			if not _ally_hidden:
				if _ally_chev == null or _ally_chev.get_parent() != n2:
					_attach_ally_chevron(n2)

# --- Cycle helpers -----------------------------------------------------------

func _cycle_enemy_target(step: int) -> void:
	if _enemy_list.is_empty():
		_clear_enemy_chevron()
		_enemy_index = -1
		emit_signal("enemy_target_changed", null)
		return

	if _enemy_index < 0:
		_enemy_index = 0
	else:
		_enemy_index += step
		if _enemy_index >= _enemy_list.size():
			_enemy_index = 0
		if _enemy_index < 0:
			_enemy_index = _enemy_list.size() - 1

	var n: Node2D = current_enemy_target()
	if n != null:
		_enemy_last_set_time = _now_s()
		_enemy_hidden = false
		_attach_enemy_chevron(n)
		emit_signal("enemy_target_changed", n)

func _cycle_ally_target(step: int) -> void:
	if _ally_list.is_empty():
		_clear_ally_chevron()
		_ally_index = -1
		emit_signal("ally_target_changed", null)
		return

	if _ally_index < 0:
		_ally_index = 0
	else:
		_ally_index += step
		if _ally_index >= _ally_list.size():
			_ally_index = 0
		if _ally_index < 0:
			_ally_index = _ally_list.size() - 1

	var n: Node2D = current_ally_target()
	if n != null:
		_ally_last_set_time = _now_s()
		_ally_hidden = false
		_attach_ally_chevron(n)
		emit_signal("ally_target_changed", n)

# --- Inactivity logic --------------------------------------------------------

func _check_enemy_inactivity() -> void:
	if _enemy_chev == null:
		return
	if _enemy_last_set_time < 0.0:
		return
	if chevron_timeout_sec <= 0.0:
		return
	var now_s: float = _now_s()
	if now_s - _enemy_last_set_time >= chevron_timeout_sec:
		_enemy_hidden = true
		_enemy_last_set_time = -1.0
		_fade_out_enemy()

func _check_ally_inactivity() -> void:
	if _ally_chev == null:
		return
	if _ally_last_set_time < 0.0:
		return
	if chevron_timeout_sec <= 0.0:
		return
	var now_s: float = _now_s()
	if now_s - _ally_last_set_time >= chevron_timeout_sec:
		_ally_hidden = true
		_ally_last_set_time = -1.0
		_fade_out_ally()

# --- Chevron visuals ---------------------------------------------------------

func _attach_enemy_chevron(n: Node2D) -> void:
	if n == null:
		_clear_enemy_chevron()
		return
	if _enemy_chev == null:
		_enemy_chev = _make_chevron(chevron_enemy_color)
	_set_alpha(_enemy_chev, 1.0)
	_reparent_to(_enemy_chev, n)
	_position_chevron(_enemy_chev)
	_fade_in_enemy()  # ensures any in-flight fade is canceled

func _attach_ally_chevron(n: Node2D) -> void:
	if n == null:
		_clear_ally_chevron()
		return
	if _ally_chev == null:
		_ally_chev = _make_chevron(chevron_ally_color)
	_set_alpha(_ally_chev, 1.0)
	_reparent_to(_ally_chev, n)
	_position_chevron(_ally_chev)
	_fade_in_ally()

func _fade_in_enemy() -> void:
	_cancel_enemy_fade()
	if _enemy_chev == null:
		return
	_enemy_fade_tween = create_tween()
	_enemy_fade_tween.tween_property(_enemy_chev, "modulate:a", 1.0, chevron_fade_sec)

func _fade_in_ally() -> void:
	_cancel_ally_fade()
	if _ally_chev == null:
		return
	_ally_fade_tween = create_tween()
	_ally_fade_tween.tween_property(_ally_chev, "modulate:a", 1.0, chevron_fade_sec)

func _fade_out_enemy() -> void:
	_cancel_enemy_fade()
	if _enemy_chev == null:
		return
	_enemy_fade_tween = create_tween()
	_enemy_fade_tween.tween_property(_enemy_chev, "modulate:a", 0.0, chevron_fade_sec)
	_enemy_fade_tween.finished.connect(Callable(self, "_on_chevron_fade_done").bind("enemy"))

func _fade_out_ally() -> void:
	_cancel_ally_fade()
	if _ally_chev == null:
		return
	_ally_fade_tween = create_tween()
	_ally_fade_tween.tween_property(_ally_chev, "modulate:a", 0.0, chevron_fade_sec)
	_ally_fade_tween.finished.connect(Callable(self, "_on_chevron_fade_done").bind("ally"))

func _on_chevron_fade_done(which: String) -> void:
	if which == "enemy":
		if free_on_fade and _enemy_chev != null and is_instance_valid(_enemy_chev):
			_enemy_chev.queue_free()
			_enemy_chev = null
		_enemy_fade_tween = null
	else:
		if free_on_fade and _ally_chev != null and is_instance_valid(_ally_chev):
			_ally_chev.queue_free()
			_ally_chev = null
		_ally_fade_tween = null

func _clear_enemy_chevron() -> void:
	_cancel_enemy_fade()
	if _enemy_chev != null and is_instance_valid(_enemy_chev):
		_enemy_chev.queue_free()
	_enemy_chev = null

func _clear_ally_chevron() -> void:
	_cancel_ally_fade()
	if _ally_chev != null and is_instance_valid(_ally_chev):
		_ally_chev.queue_free()
	_ally_chev = null

func _cancel_enemy_fade() -> void:
	if _enemy_fade_tween != null and is_instance_valid(_enemy_fade_tween):
		_enemy_fade_tween.kill()
	_enemy_fade_tween = null

func _cancel_ally_fade() -> void:
	if _ally_fade_tween != null and is_instance_valid(_ally_fade_tween):
		_ally_fade_tween.kill()
	_ally_fade_tween = null

# --- Party / Ability integration --------------------------------------------

func _try_connect_party() -> void:
	# Try Party autoload first
	var party: Node = get_node_or_null("/root/Party")
	if party != null and party.has_signal("controlled_changed"):
		party.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
		_on_controlled_changed(_get_controlled_actor())
		return

	# Fallback PartyManager group
	var pm: Node = get_tree().get_first_node_in_group("PartyManager")
	if pm != null and pm.has_signal("controlled_changed"):
		pm.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
		_on_controlled_changed(_get_controlled_actor())

func _on_controlled_changed(_new_ctrl: Node) -> void:
	# no-op here; your input routes already call the cycle funcs
	pass

func _get_controlled_actor() -> Node:
	var party: Node = get_node_or_null("/root/Party")
	if party != null and party.has_method("get_controlled"):
		var c: Variant = party.call("get_controlled")
		if c is Node:
			return c
	var pm: Node = get_tree().get_first_node_in_group("PartyManager")
	if pm != null and pm.has_method("get_controlled"):
		var d: Variant = pm.call("get_controlled")
		if d is Node:
			return d
	return null

func _connect_to_global_ability_system_if_present() -> void:
	var global_as: Node = get_node_or_null("/root/AbilitySys")
	if global_as == null:
		return
	if global_as.has_signal("ability_cast"):
		global_as.connect("ability_cast", Callable(self, "_on_global_ability_cast"))
	elif global_as.has_signal("cast_started"):
		global_as.connect("cast_started", Callable(self, "_on_global_ability_cast"))
	elif global_as.has_signal("cast_succeeded"):
		global_as.connect("cast_succeeded", Callable(self, "_on_global_ability_cast"))

func _on_global_ability_cast(a: Variant = null, b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
	# If first or second arg is the user Node and it's the controlled actor, treat as activity.
	var user: Node = null
	if a is Node:
		user = a
	elif b is Node:
		user = b

	var controlled: Node = _get_controlled_actor()
	if controlled != null and user == controlled:
		_enemy_hidden = false
		_ally_hidden = false
		note_activity("both")

# --- Helpers ----------------------------------------------------------------

func _now_s() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

func _index_of_node(arr: Array, n: Node) -> int:
	var i: int = 0
	while i < arr.size():
		if arr[i] == n:
			return i
		i += 1
	return -1

func _make_chevron(col: Color) -> Node2D:
	var n2d: Node2D = Node2D.new()
	var line: Line2D = Line2D.new()
	line.width = 2.0
	line.default_color = col
	var half: float = chevron_size_px * 0.5
	var pts: PackedVector2Array = PackedVector2Array()
	pts.append(Vector2(-half, 0.0))
	pts.append(Vector2(0.0, -half))
	pts.append(Vector2(half, 0.0))
	line.points = pts
	n2d.add_child(line)
	_set_alpha(n2d, 0.0)
	return n2d

func _position_chevron(chev: Node2D) -> void:
	chev.position = Vector2(0.0, chevron_offset_y)

func _reparent_to(node: Node, new_parent: Node) -> void:
	var parent: Node = node.get_parent()
	if parent != null:
		parent.remove_child(node)
	new_parent.add_child(node)

func _set_alpha(ci: CanvasItem, a: float) -> void:
	var m: Color = ci.modulate
	m.a = a
	ci.modulate = m
