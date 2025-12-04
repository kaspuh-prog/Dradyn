extends Label
class_name StatusPointsLabel

@export var prefix: String = "Points: "
@export var value: int = 0

@export var sheet_root_path: NodePath
@export var level_component_path: NodePath
@export var stats_component_path: NodePath
@export var party_autoload_name: String = "Party"

@export var hook_plus_buttons: bool = true
@export var auto_disable_minus_buttons: bool = true

@export var label_mouse_ignore: bool = true
@export var log_debug: bool = true
@export var allow_direct_stat_fallback: bool = false

const STAT_KEYS: Array[String] = ["STR", "DEX", "STA", "INT", "WIS", "LCK"]

var _sheet_root: Node = null
var _level: Node = null
var _stats: Node = null
var _value_labels: Dictionary = {}      # String -> Label
var _plus_buttons: Dictionary = {}      # String -> BaseButton
var _minus_buttons: Dictionary = {}     # String -> BaseButton

func _ready() -> void:
	if label_mouse_ignore == true:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	_resolve_sheet_root()
	_cache_value_labels()
	_hook_buttons()
	_bind_sources()
	_update_text()
	_refresh_button_states()

	call_deferred("_bind_sources")
	call_deferred("_refresh_button_states")

	var party: Node = _get_party_node()
	if party != null:
		if party.has_signal("controlled_changed"):
			if not party.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
				party.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
		if party.has_signal("party_changed"):
			if not party.is_connected("party_changed", Callable(self, "_on_party_changed")):
				party.connect("party_changed", Callable(self, "_on_party_changed"))

	var sm: Node = get_tree().root.find_child("SceneManager", true, false)
	if sm != null and sm.has_signal("area_changed"):
		if not sm.is_connected("area_changed", Callable(self, "_on_area_changed_rebind")):
			sm.connect("area_changed", Callable(self, "_on_area_changed_rebind"))

func _exit_tree() -> void:
	_unbind_signals()

# --------------------------
# Setup / binding
# --------------------------
func _resolve_sheet_root() -> void:
	if sheet_root_path != NodePath() and has_node(sheet_root_path):
		_sheet_root = get_node(sheet_root_path)
	else:
		_sheet_root = get_parent()
	if log_debug:
		print("[StatusPointsLabel] sheet_root = ", _sheet_root)

func _bind_sources() -> void:
	_unbind_signals()
	_level = null
	_stats = null

	if level_component_path != NodePath() and has_node(level_component_path):
		_level = get_node(level_component_path)
	if stats_component_path != NodePath() and has_node(stats_component_path):
		_stats = get_node(stats_component_path)

	if _level == null or _stats == null:
		var party: Node = _get_party_node()
		if party != null and party.has_method("get_controlled"):
			var actor_v: Variant = party.call("get_controlled")
			var actor: Node = actor_v as Node
			if actor != null:
				if _level == null:
					_level = _find_child_component(actor, "LevelComponent")
				if _stats == null:
					_stats = _find_child_component(actor, "StatsComponent")

	if log_debug:
		print("[StatusPointsLabel] bound _level = ", _level, "  _stats = ", _stats)

	if _level != null:
		if _level.has_signal("points_changed"):
			if not _level.is_connected("points_changed", Callable(self, "_on_points_changed")):
				_level.connect("points_changed", Callable(self, "_on_points_changed"))
		if _level.has_signal("level_up"):
			if not _level.is_connected("level_up", Callable(self, "_on_level_up")):
				_level.connect("level_up", Callable(self, "_on_level_up"))
		if _level.has_signal("xp_changed"):
			if not _level.is_connected("xp_changed", Callable(self, "_on_xp_changed")):
				_level.connect("xp_changed", Callable(self, "_on_xp_changed"))

	if _stats != null and _stats.has_signal("stat_changed"):
		if not _stats.is_connected("stat_changed", Callable(self, "_on_stat_changed")):
			_stats.connect("stat_changed", Callable(self, "_on_stat_changed"))

	_refresh_points_from_level()
	_refresh_all_values_from_stats()
	_update_text()
	_refresh_button_states()

func _unbind_signals() -> void:
	if _level != null:
		if _level.has_signal("points_changed"):
			if _level.is_connected("points_changed", Callable(self, "_on_points_changed")):
				_level.disconnect("points_changed", Callable(self, "_on_points_changed"))
		if _level.has_signal("level_up"):
			if _level.is_connected("level_up", Callable(self, "_on_level_up")):
				_level.disconnect("level_up", Callable(self, "_on_level_up"))
		if _level.has_signal("xp_changed"):
			if _level.is_connected("xp_changed", Callable(self, "_on_xp_changed")):
				_level.disconnect("xp_changed", Callable(self, "_on_xp_changed"))
	if _stats != null and _stats.has_signal("stat_changed"):
		if _stats.is_connected("stat_changed", Callable(self, "_on_stat_changed")):
			_stats.disconnect("stat_changed", Callable(self, "_on_stat_changed"))

# --------------------------
# Party + component lookup
# --------------------------
func _get_party_node() -> Node:
	var root: Node = get_tree().root
	var by_name: Node = root.get_node_or_null(party_autoload_name)
	if by_name != null:
		return by_name
	return get_tree().get_first_node_in_group("PartyManager")

func _find_child_component(root: Node, name: String) -> Node:
	if root == null:
		return null
	var direct: Node = root.get_node_or_null(name)
	if direct != null:
		return direct
	return root.find_child(name, true, false)

# --------------------------
# UI wires (buttons + labels)
# --------------------------
func _cache_value_labels() -> void:
	_value_labels.clear()
	if _sheet_root == null:
		return
	for key in STAT_KEYS:
		var path_str: String = "Value_" + key
		var n: Node = _sheet_root.get_node_or_null(path_str)
		if n != null and n is Label:
			_value_labels[key] = n
	if log_debug:
		print("[StatusPointsLabel] cached value labels: ", _value_labels.keys())

func _hook_buttons() -> void:
	_plus_buttons.clear()
	_minus_buttons.clear()
	if hook_plus_buttons == false:
		return
	if _sheet_root == null:
		return

	for key in STAT_KEYS:
		var plus_name: String = "Plus_" + key
		var plus_node: Node = _sheet_root.get_node_or_null(plus_name)
		if plus_node != null and plus_node is BaseButton:
			var bb: BaseButton = plus_node as BaseButton
			# Critical: ensure the button is actually able to receive input
			bb.mouse_filter = Control.MOUSE_FILTER_STOP
			bb.focus_mode = Control.FOCUS_ALL
			bb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

			if not bb.pressed.is_connected(Callable(self, "_on_plus_pressed").bind(key)):
				bb.pressed.connect(Callable(self, "_on_plus_pressed").bind(key))
			# Diagnostics
			if not bb.mouse_entered.is_connected(Callable(self, "_on_plus_hover").bind(plus_name)):
				bb.mouse_entered.connect(Callable(self, "_on_plus_hover").bind(plus_name))
			if not bb.gui_input.is_connected(Callable(self, "_on_plus_gui_input").bind(plus_name)):
				bb.gui_input.connect(Callable(self, "_on_plus_gui_input").bind(plus_name))

			_plus_buttons[key] = bb
			if log_debug:
				print("[StatusPointsLabel] connected ", plus_name)

		var minus_name: String = "Minus_" + key
		var minus_node: Node = _sheet_root.get_node_or_null(minus_name)
		if minus_node != null and minus_node is BaseButton:
			var mb: BaseButton = minus_node as BaseButton
			mb.mouse_filter = Control.MOUSE_FILTER_STOP
			mb.focus_mode = Control.FOCUS_ALL
			_minus_buttons[key] = mb
			if auto_disable_minus_buttons == true:
				mb.disabled = true

# --------------------------
# Value/Label helpers
# --------------------------
func set_points(v: int) -> void:
	value = v
	_update_text()
	_refresh_button_states()

func _update_text() -> void:
	text = prefix + str(value)

func _refresh_button_states() -> void:
	var enable_plus: bool = value > 0
	for key in _plus_buttons.keys():
		var bb: BaseButton = _plus_buttons[key]
		if bb != null:
			# Force-enable when we have points
			bb.disabled = not enable_plus

# --------------------------
# Handlers
# --------------------------
func _on_points_changed(unspent: int) -> void:
	if log_debug:
		print("[StatusPointsLabel] points_changed -> ", unspent)
	set_points(unspent)

func _on_level_up(_lvl: int, _gained: int) -> void:
	if log_debug:
		print("[StatusPointsLabel] level_up")
	_refresh_points_from_level()
	_refresh_all_values_from_stats()

func _on_xp_changed(_cxp: int, _to_next: int, _lvl: int) -> void:
	pass

func _on_stat_changed(_name: String, _value: float) -> void:
	if log_debug:
		print("[StatusPointsLabel] stat_changed: ", _name, " -> ", _value)
	_refresh_all_values_from_stats()

func _on_plus_hover(btn_name: String) -> void:
	if log_debug:
		print("[StatusPointsLabel] hover: ", btn_name)

func _on_plus_gui_input(event: InputEvent, btn_name: String) -> void:
	if log_debug:
		print("[StatusPointsLabel] gui_input @", btn_name, " -> ", event)

func _on_plus_pressed(stat_key: String) -> void:
	if log_debug:
		print("[StatusPointsLabel] plus pressed: ", stat_key)
	if _level == null:
		return

	var can_spend: bool = true
	if _level.has_method("get_unspent_points"):
		var v: Variant = _level.call("get_unspent_points")
		if v == null or int(v) <= 0:
			can_spend = false
	elif "unspent_points" in _level:
		var p: Variant = _level.get("unspent_points")
		if p == null or int(p) <= 0:
			can_spend = false
	if can_spend == false:
		return

	if _level.has_method("allocate_stat_point"):
		_level.call("allocate_stat_point", stat_key, 1)
		return
	if _level.has_method("allocate_points"):
		var d: Dictionary = {}
		d[stat_key] = 1
		_level.call("allocate_points", d)
		return

	if allow_direct_stat_fallback and _stats != null:
		var done: bool = false
		if _stats.has_method("add_base_stat"):
			_stats.call("add_base_stat", stat_key, 1)
			done = true
		elif _stats.has_method("add_base"):
			_stats.call("add_base", stat_key, 1)
			done = true
		if done:
			if _level.has_method("consume_unspent_points"):
				_level.call("consume_unspent_points", 1)
			elif "unspent_points" in _level:
				var cur: int = int(_level.get("unspent_points"))
				_level.set("unspent_points", max(0, cur - 1))
			_refresh_points_from_level()
			_refresh_all_values_from_stats()

# --------------------------
# Pull current values
# --------------------------
func _refresh_points_from_level() -> void:
	if _level == null:
		set_points(0)
		return
	if _level.has_method("get_unspent_points"):
		var v: Variant = _level.call("get_unspent_points")
		if v != null:
			set_points(int(v))
			return
	if "unspent_points" in _level:
		var p: Variant = _level.get("unspent_points")
		if p != null:
			set_points(int(p))

func _refresh_all_values_from_stats() -> void:
	if _stats == null:
		return
	var dict_any: Variant = null
	if _stats.has_method("get_all_final_stats"):
		dict_any = _stats.call("get_all_final_stats")
	if dict_any is Dictionary:
		var final_stats: Dictionary = dict_any as Dictionary
		for key in STAT_KEYS:
			if final_stats.has(key) and _value_labels.has(key):
				var lbl: Label = _value_labels[key]
				var v: Variant = final_stats[key]
				var num: int = 0
				if v != null:
					num = int(round(float(v)))
				lbl.text = str(num)

# --------------------------
# Party/Scene change hooks
# --------------------------
func _on_party_controlled_changed(_current: Node) -> void:
	if log_debug:
		print("[StatusPointsLabel] party controlled changed; rebinding.")
	_bind_sources()

func _on_party_changed(_members: Array) -> void:
	if log_debug:
		print("[StatusPointsLabel] party changed; rebinding.")
	_bind_sources()

func _on_area_changed_rebind(_area: Node, _entry_tag: String) -> void:
	if log_debug:
		print("[StatusPointsLabel] area changed; rebinding.")
	_bind_sources()
