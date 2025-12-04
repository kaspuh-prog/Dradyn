extends Node
class_name StatsHeaderBinder

@export var name_label_path: NodePath
@export var level_label_path: NodePath
@export var class_label_path: NodePath
@export var points_label_path: NodePath

@export var actor_path: NodePath
@export var level_component_path: NodePath

var _actor: Node = null
var _lc: Node = null

var _name_lbl: Label = null
var _level_lbl: Label = null
var _class_lbl: Label = null
var _points_lbl: Label = null

func _ready() -> void:
	_name_lbl = get_node_or_null(name_label_path)
	_level_lbl = get_node_or_null(level_label_path)
	_class_lbl = get_node_or_null(class_label_path)
	_points_lbl = get_node_or_null(points_label_path)

	_actor = get_node_or_null(actor_path)
	_lc = get_node_or_null(level_component_path)
	if _lc == null and _actor != null:
		_lc = _actor.get_node_or_null("LevelComponent")

	_set_name_text(_derive_actor_name())
	_set_level_text(_derive_level())
	_set_class_text(_derive_class_title())
	_set_points_text(_derive_unspent_points())

	_connect_level_component_signals()

func set_actor(actor: Node) -> void:
	_actor = actor
	_lc = null
	if _actor != null:
		_lc = _actor.get_node_or_null("LevelComponent")
	_set_name_text(_derive_actor_name())
	_set_level_text(_derive_level())
	_set_class_text(_derive_class_title())
	_set_points_text(_derive_unspent_points())
	_connect_level_component_signals()

# ---------- signals ----------

func _connect_level_component_signals() -> void:
	if _lc == null:
		return
	if _lc.has_signal("xp_changed"):
		if _lc.is_connected("xp_changed", Callable(self, "_on_xp_changed")) == false:
			_lc.connect("xp_changed", Callable(self, "_on_xp_changed"))
	if _lc.has_signal("level_up"):
		if _lc.is_connected("level_up", Callable(self, "_on_level_up")) == false:
			_lc.connect("level_up", Callable(self, "_on_level_up"))

func _on_xp_changed(current_xp: int, xp_to_next: int, level: int) -> void:
	_set_level_text(level)
	_set_points_text(_derive_unspent_points())

func _on_level_up(new_level: int, levels_gained: int) -> void:
	_set_level_text(new_level)
	_set_points_text(_derive_unspent_points())

# ---------- readers (typed, no inference) ----------

func _derive_actor_name() -> String:
	if _actor == null:
		return "Unknown"
	if _actor.has_method("get_name"):
		return str(_actor.get_name())
	return str(_actor.name)

func _derive_level() -> int:
	if _lc == null:
		return 1
	var v: Variant = null
	if _lc.has_method("get"):
		v = _lc.get("level")
	if v == null:
		return 1
	return int(v)

func _derive_class_title() -> String:
	if _lc == null:
		return "Class"
	var cd_var: Variant = _lc.get("class_def")
	if cd_var == null:
		return "Class"
	var cd_obj: Object = cd_var as Object
	if cd_obj == null:
		return "Class"
	var title_var: Variant = cd_obj.get("class_title")
	if title_var == null:
		return "Class"
	var title_str: String = str(title_var)
	return title_str

func _derive_unspent_points() -> int:
	if _lc == null:
		return 0
	var v: Variant = _lc.get("unspent_points")
	if v == null:
		return 0
	return int(v)

# ---------- label setters ----------

func _set_name_text(val: String) -> void:
	if _name_lbl != null:
		_name_lbl.text = val

func _set_level_text(val: int) -> void:
	if _level_lbl != null:
		_level_lbl.text = "Level: " + str(val)

func _set_class_text(val: String) -> void:
	if _class_lbl != null:
		_class_lbl.text = val

func _set_points_text(val: int) -> void:
	if _points_lbl == null:
		return
	if _points_lbl.has_method("set_points"):
		_points_lbl.call("set_points", val)
	else:
		_points_lbl.text = "Points: " + str(val)
