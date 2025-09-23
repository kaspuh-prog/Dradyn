extends Control

# You can wire these in the Inspector; if empty, we'll auto-detect by name.
@export var stats_path: NodePath
@export var hp_bar_path: NodePath
@export var mp_bar_path: NodePath
@export var end_bar_path: NodePath
@export var debug_logs: bool = true

var stats: Node = null
var hp_bar: ProgressBar
var mp_bar: ProgressBar
var end_bar: ProgressBar

func _ready() -> void:
	_resolve_bars()
	if hp_bar: hp_bar.show_percentage = false
	if mp_bar: mp_bar.show_percentage = false
	if end_bar: end_bar.show_percentage = false

	# single-panel mode (when set in the editor)
	if stats_path != NodePath(""):
		var n: Node = get_node_or_null(stats_path)
		if n != null:
			_bind_stats(n)

# called by HUDRoot after duplicating the panel
func set_stats_node(n: Node) -> void:
	if n == null:
		return
	_bind_stats(n)
	stats_path = n.get_path()

# -------------------- binding --------------------
func _bind_stats(n: Node) -> void:
	if stats != null:
		_disconnect(stats)

	stats = n
	_resolve_bars()  # in case this clone resolves late

	# initial fill
	_on_hp_changed(_get_prop_num("current_hp"), _call_num("max_hp", 100.0))
	_on_mp_changed(_get_prop_num("current_mp"), _call_num("max_mp", 30.0))
	_on_end_changed(_get_prop_num("current_end"), _call_num("max_end", 100.0))

	# live updates
	_connect_signal(stats, "hp_changed", Callable(self, "_on_hp_changed"))
	_connect_signal(stats, "mp_changed", Callable(self, "_on_mp_changed"))
	_connect_signal(stats, "end_changed", Callable(self, "_on_end_changed"))

	if debug_logs:
		var who: String = "<null>"
		if stats != null:
			who = stats.name
		print("[PartyPanel:", name, "] bound to:", who,
			" hp=", _get_prop_num("current_hp"), "/", _call_num("max_hp", 0.0),
			" mp=", _get_prop_num("current_mp"), "/", _call_num("max_mp", 0.0),
			" end=", _get_prop_num("current_end"), "/", _call_num("max_end", 0.0))

func _connect_signal(obj: Object, sig: String, c: Callable) -> void:
	if obj.has_signal(sig) and not obj.is_connected(sig, c):
		obj.connect(sig, c)

func _disconnect(obj: Object) -> void:
	var c: Callable = Callable(self, "_on_hp_changed")
	if obj.has_signal("hp_changed") and obj.is_connected("hp_changed", c):
		obj.disconnect("hp_changed", c)
	c = Callable(self, "_on_mp_changed")
	if obj.has_signal("mp_changed") and obj.is_connected("mp_changed", c):
		obj.disconnect("mp_changed", c)
	c = Callable(self, "_on_end_changed")
	if obj.has_signal("end_changed") and obj.is_connected("end_changed", c):
		obj.disconnect("end_changed", c)

# -------------------- handlers --------------------
func _on_hp_changed(current: float, max_value: float) -> void:
	if hp_bar:
		hp_bar.max_value = max_value
		_tween_bar_value(hp_bar, current)
	elif debug_logs:
		print("[PartyPanel:", name, "] hp_bar missing")

func _on_mp_changed(current: float, max_value: float) -> void:
	if mp_bar:
		mp_bar.max_value = max_value
		_tween_bar_value(mp_bar, current)
	elif debug_logs:
		print("[PartyPanel:", name, "] mp_bar missing")

func _on_end_changed(current: float, max_value: float) -> void:
	if end_bar:
		end_bar.max_value = max_value
		_tween_bar_value(end_bar, current)
	elif debug_logs:
		print("[PartyPanel:", name, "] end_bar missing")

# -------------------- helpers --------------------
func _get_prop_num(prop: String) -> float:
	if stats == null:
		return 0.0
	var v: Variant = stats.get(prop)
	var t: int = typeof(v)
	if t == TYPE_INT or t == TYPE_FLOAT:
		return float(v)
	return 0.0

func _call_num(method: String, fallback: float) -> float:
	if stats != null and stats.has_method(method):
		var v: Variant = stats.call(method)
		var t: int = typeof(v)
		if t == TYPE_INT or t == TYPE_FLOAT:
			return float(v)
	return fallback

func _tween_bar_value(bar: ProgressBar, target: float, dur: float = 0.18) -> void:
	if bar == null:
		return
	var twn: Tween = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	twn.tween_property(bar, "value", target, dur)

func _resolve_bars() -> void:
	# prefer explicit paths on the template
	if hp_bar == null and hp_bar_path != NodePath(""):
		hp_bar = get_node_or_null(hp_bar_path) as ProgressBar
	if mp_bar == null and mp_bar_path != NodePath(""):
		mp_bar = get_node_or_null(mp_bar_path) as ProgressBar
	if end_bar == null and end_bar_path != NodePath(""):
		end_bar = get_node_or_null(end_bar_path) as ProgressBar

	# auto-detect by common names (deep search)
	if hp_bar == null:
		hp_bar = _match_bar(self, ["hp","health"])
	if mp_bar == null:
		mp_bar = _match_bar(self, ["mp","mana"])
	if end_bar == null:
		end_bar = _match_bar(self, ["end","endurance"])

	if debug_logs:
		print("[PartyPanel:", name, "] bars -> HP:", _node_info(hp_bar),
			" MP:", _node_info(mp_bar), " END:", _node_info(end_bar))

func _match_bar(node: Node, hints: Array) -> ProgressBar:
	# depth-first search for a ProgressBar whose name contains any hint
	var pb: ProgressBar = node as ProgressBar
	if pb != null:
		var nm: String = pb.name.to_lower()
		for h in hints:
			var hs: String = String(h).to_lower()
			if nm.find(hs) != -1:
				return pb
	for ch in node.get_children():
		var res: ProgressBar = _match_bar(ch, hints)
		if res != null:
			return res
	return null

func _node_info(n: Node) -> String:
	if n != null:
		return n.name
	return "<null>"
