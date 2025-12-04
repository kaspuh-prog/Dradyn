# File: res://ui/menus/StatsSheetBinder.gd
extends Node
class_name StatsSheetBinder

@export var name_label_path: NodePath
@export var level_label_path: NodePath
@export var class_label_path: NodePath
@export var points_label_path: NodePath
@export var log_debug: bool = false

const _CORE_KEYS: Array[String] = ["STR", "DEX", "STA", "INT", "WIS", "LCK"]

# Actor + components
var _actor: Node = null
var _stats: Node = null            # StatsComponent
var _level: Node = null            # LevelComponent
var _class_def: Resource = null    # ClassDefinition

# Header labels
var _name_lbl: Label = null
var _level_lbl: Label = null
var _class_lbl: Label = null
var _points_lbl: Node = null       # Label or StatusPointsLabel

# Left column nodes
var _value_labels: Dictionary = {}     # key -> Label
var _plus_buttons: Dictionary = {}     # key -> BaseButton
var _minus_buttons: Dictionary = {}    # key -> BaseButton

# Right panel
var _right_panel: Node = null

# Debounce: guard re-entrancy during a single input cycle
var _spend_guard: bool = false

func _ready() -> void:
	_cache_header_nodes()
	_cache_left_column_nodes()
	_cache_right_panel()
	_autobind_party_and_refresh()

func _exit_tree() -> void:
	_disconnect_prev_signals()

# ---------------- Cache nodes ----------------
func _cache_header_nodes() -> void:
	if name_label_path != NodePath():
		_name_lbl = get_node_or_null(name_label_path) as Label
	else:
		_name_lbl = get_node_or_null("../NameLabel") as Label

	if level_label_path != NodePath():
		_level_lbl = get_node_or_null(level_label_path) as Label
	else:
		_level_lbl = get_node_or_null("../LevelLabel") as Label

	if class_label_path != NodePath():
		_class_lbl = get_node_or_null(class_label_path) as Label
	else:
		_class_lbl = get_node_or_null("../ClassLabel") as Label

	if points_label_path != NodePath():
		_points_lbl = get_node_or_null(points_label_path)
	else:
		_points_lbl = get_node_or_null("../PointsLabel")

func _cache_left_column_nodes() -> void:
	var root: Node = get_parent()
	if root == null:
		return
	var i: int = 0
	while i < _CORE_KEYS.size():
		var key: String = _CORE_KEYS[i]
		_value_labels[key] = root.get_node_or_null("Value_%s" % key) as Label

		var plus: BaseButton = root.get_node_or_null("Plus_%s" % key) as BaseButton
		var minus: BaseButton = root.get_node_or_null("Minus_%s" % key) as BaseButton
		_plus_buttons[key] = plus
		_minus_buttons[key] = minus

		if plus != null:
			plus.mouse_filter = Control.MOUSE_FILTER_STOP
			plus.focus_mode = Control.FOCUS_ALL
			var cb_plus: Callable = Callable(self, "_on_plus_pressed").bind(key, plus)
			_retake_pressed(plus, cb_plus)

		if minus != null:
			minus.mouse_filter = Control.MOUSE_FILTER_STOP
			minus.focus_mode = Control.FOCUS_ALL
			var cb_minus: Callable = Callable(self, "_on_minus_pressed").bind(key, minus)
			_retake_pressed(minus, cb_minus)
		i += 1

func _cache_right_panel() -> void:
	var root: Node = get_parent()
	if root == null:
		return
	_right_panel = root.get_node_or_null("RightPanel/RightPanelBG")

# Force our handler to be the only one connected to `pressed`.
func _retake_pressed(btn: BaseButton, to_connect: Callable) -> void:
	if btn == null:
		return
	var conns: Array = btn.get_signal_connection_list("pressed")
	var j: int = 0
	while j < conns.size():
		var c: Dictionary = conns[j]
		if c.has("callable"):
			var call_any: Variant = c["callable"]
			if call_any is Callable:
				var call: Callable = call_any
				if btn.pressed.is_connected(call):
					btn.pressed.disconnect(call)
		j += 1
	if not btn.pressed.is_connected(to_connect):
		btn.pressed.connect(to_connect)

# ---------------- Party bind ----------------
func _autobind_party_and_refresh() -> void:
	var party: Node = get_tree().root.get_node_or_null("Party")
	if party == null:
		party = get_tree().get_first_node_in_group("PartyManager")
	if party == null:
		if log_debug:
			print("[StatsSheetBinder] Party not found; will not bind yet.")
		return

	if party.has_signal("controlled_changed"):
		if not party.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
			party.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))

	var a_v: Variant = null
	if party.has_method("get_controlled"):
		a_v = party.call("get_controlled")
	_bind_actor(a_v as Node)

func _on_party_controlled_changed(current: Node) -> void:
	_bind_actor(current)

func _bind_actor(actor: Node) -> void:
	_disconnect_prev_signals()
	_actor = actor
	_stats = null
	_level = null
	_class_def = null

	if _actor != null:
		_stats = _actor.get_node_or_null("StatsComponent")
		_level = _actor.get_node_or_null("LevelComponent")
		var cd_v: Variant = _actor.get("class_def")
		if cd_v != null and cd_v is Resource:
			_class_def = cd_v as Resource

	_connect_new_signals()
	_refresh_all()

func _disconnect_prev_signals() -> void:
	if _level != null:
		if _level.has_signal("xp_changed") and _level.is_connected("xp_changed", Callable(self, "_on_xp_changed")):
			_level.disconnect("xp_changed", Callable(self, "_on_xp_changed"))
		if _level.has_signal("level_up") and _level.is_connected("level_up", Callable(self, "_on_level_up")):
			_level.disconnect("level_up", Callable(self, "_on_level_up"))
		if _level.has_signal("points_changed") and _level.is_connected("points_changed", Callable(self, "_on_points_changed")):
			_level.disconnect("points_changed", Callable(self, "_on_points_changed"))
	if _stats != null:
		if _stats.has_signal("stat_changed") and _stats.is_connected("stat_changed", Callable(self, "_on_stat_changed")):
			_stats.disconnect("stat_changed", Callable(self, "_on_stat_changed"))

func _connect_new_signals() -> void:
	if _level != null:
		if _level.has_signal("xp_changed"):
			_level.connect("xp_changed", Callable(self, "_on_xp_changed"))
		if _level.has_signal("level_up"):
			_level.connect("level_up", Callable(self, "_on_level_up"))
		if _level.has_signal("points_changed"):
			_level.connect("points_changed", Callable(self, "_on_points_changed"))
	if _stats != null:
		if _stats.has_signal("stat_changed"):
			_stats.connect("stat_changed", Callable(self, "_on_stat_changed"))

# ---------------- Refresh ----------------
func _refresh_all() -> void:
	_refresh_header()
	_refresh_points()
	_refresh_core_rows()

func _refresh_header() -> void:
	if _name_lbl != null:
		_name_lbl.text = _derive_actor_name()
	if _level_lbl != null:
		_level_lbl.text = "Level: " + str(_derive_level())
	if _class_lbl != null:
		_class_lbl.text = _derive_class_title()

func _refresh_points() -> void:
	var pts: int = _derive_unspent_points()
	if _points_lbl != null:
		if _points_lbl.has_method("set_points"):
			_points_lbl.call("set_points", pts)
		else:
			if _points_lbl is Label:
				var lbl: Label = _points_lbl as Label
				lbl.text = "Points: " + str(pts)

	var has_points: bool = pts > 0
	var i: int = 0
	while i < _CORE_KEYS.size():
		var key: String = _CORE_KEYS[i]
		var plus: BaseButton = _plus_buttons.get(key, null)
		if plus != null:
			plus.disabled = not has_points
		i += 1

func _refresh_core_rows() -> void:
	if _stats == null:
		_fill_value_labels_with_placeholders()
		return
	var dict_v: Variant = _stats.call("get_all_final_stats")
	var values: Dictionary = {}
	if typeof(dict_v) == TYPE_DICTIONARY:
		values = dict_v
	var i: int = 0
	while i < _CORE_KEYS.size():
		var key: String = _CORE_KEYS[i]
		var val: float = 0.0
		if values.has(key):
			var v: Variant = values[key]
			if v != null:
				val = float(v)
		var lbl: Label = _value_labels.get(key, null)
		if lbl != null:
			lbl.text = str(int(round(val)))
		i += 1

func _fill_value_labels_with_placeholders() -> void:
	var i: int = 0
	while i < _CORE_KEYS.size():
		var key: String = _CORE_KEYS[i]
		var lbl: Label = _value_labels.get(key, null)
		if lbl != null:
			lbl.text = "--"
		i += 1

# ---------------- Live updates ----------------
func _on_xp_changed(_cur_xp: int, _to_next: int, _level_now: int) -> void:
	_refresh_header()

func _on_level_up(_new_level: int, _points_gained: int) -> void:
	_refresh_header()
	_refresh_points()

func _on_points_changed(_unspent: int) -> void:
	_refresh_points()

func _on_stat_changed(_name: String, _value: float) -> void:
	_refresh_core_rows()

# ---------------- Button handlers ----------------
func _on_plus_pressed(stat_id: String, _source_btn: BaseButton) -> void:
	if _spend_guard:
		return
	_spend_guard = true
	call_deferred("_clear_spend_guard")

	if log_debug:
		print("[StatsSheetBinder] + ", stat_id)
	if _level == null:
		return

	var can_spend: bool = false
	if _level.has_method("get_unspent_points"):
		var v: Variant = _level.call("get_unspent_points")
		if v != null and int(v) > 0:
			can_spend = true
	elif "unspent_points" in _level:
		var p: Variant = _level.get("unspent_points")
		if p != null and int(p) > 0:
			can_spend = true
	if not can_spend:
		return

	if _level.has_method("allocate_stat_point"):
		_level.call("allocate_stat_point", stat_id, 1)
	elif _level.has_method("allocate_points"):
		var d: Dictionary = {}
		d[stat_id] = 1
		_level.call("allocate_points", d)
	else:
		return

	_refresh_points() # defensive; points_changed will also fire

func _on_minus_pressed(_stat_id: String, _source_btn: BaseButton) -> void:
	# No refund implemented.
	pass

func _clear_spend_guard() -> void:
	_spend_guard = false

# ---------------- Derivers ----------------
func _derive_actor_name() -> String:
	if _actor == null:
		return "Unknown"
	return str(_actor.name)

func _derive_level() -> int:
	if _level == null:
		return 1
	var v: Variant = _level.get("level")
	if v == null:
		return 1
	return int(v)

func _derive_class_title() -> String:
	if _class_def == null:
		return "Class"
	var title_v: Variant = _class_def.get("class_title")
	if title_v == null:
		return "Class"
	return str(title_v)

func _derive_unspent_points() -> int:
	if _level == null:
		return 0
	var v: Variant = _level.get("unspent_points")
	if v == null:
		return 0
	return int(v)
