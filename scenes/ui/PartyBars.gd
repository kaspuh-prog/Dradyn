extends Control
class_name PartyBars

@export var hp_path: NodePath = ^"HpBar"
@export var mp_path: NodePath = ^"MpBar"
@export var end_path: NodePath = ^"EndBar"
@export var debug_logs: bool = false

var _stats: Node = null
var _hp_bar: TextureProgressBar = null
var _mp_bar: TextureProgressBar = null
var _end_bar: TextureProgressBar = null

func _ready() -> void:
	_resolve_bars()

func set_stats(stats: Node) -> void:
	if stats == null:
		if debug_logs:
			push_warning("[PartyBars] set_stats called with null")
		return
	_disconnect_signals()
	_stats = stats
	_connect_signals()
	_initialize_values()

func set_stats_node(stats: Node) -> void:
	set_stats(stats)

func _resolve_bars() -> void:
	_hp_bar = get_node_or_null(hp_path) as TextureProgressBar
	_mp_bar = get_node_or_null(mp_path) as TextureProgressBar
	_end_bar = get_node_or_null(end_path) as TextureProgressBar
	if debug_logs:
		print("[PartyBars] hp=", _hp_bar, " mp=", _mp_bar, " end=", _end_bar)

func _connect_signals() -> void:
	if _stats == null:
		return
	_safe_connect(_stats, "hp_changed", Callable(self, "_on_hp_changed"))
	_safe_connect(_stats, "mp_changed", Callable(self, "_on_mp_changed"))
	_safe_connect(_stats, "end_changed", Callable(self, "_on_end_changed"))

func _disconnect_signals() -> void:
	if _stats == null:
		return
	_safe_disconnect(_stats, "hp_changed", Callable(self, "_on_hp_changed"))
	_safe_disconnect(_stats, "mp_changed", Callable(self, "_on_mp_changed"))
	_safe_disconnect(_stats, "end_changed", Callable(self, "_on_end_changed"))

func _safe_connect(emitter: Object, sig: StringName, cb: Callable) -> void:
	if not emitter.is_connected(sig, cb):
		emitter.connect(sig, cb)

func _safe_disconnect(emitter: Object, sig: StringName, cb: Callable) -> void:
	if emitter.is_connected(sig, cb):
		emitter.disconnect(sig, cb)

func _initialize_values() -> void:
	_init_hp()
	_init_mp()
	_init_end()

func _init_hp() -> void:
	if _stats == null or _hp_bar == null:
		return
	# max_* are real methods on StatsComponent
	if _stats.has_method("max_hp"):
		_hp_bar.max_value = float(_stats.call("max_hp"))
	# current_* are variables on StatsComponent; read via get()
	var v: Variant = _stats.get("current_hp")
	if v != null:
		_hp_bar.value = float(v)

func _init_mp() -> void:
	if _stats == null or _mp_bar == null:
		return
	if _stats.has_method("max_mp"):
		_mp_bar.max_value = float(_stats.call("max_mp"))
	var v: Variant = _stats.get("current_mp")
	if v != null:
		_mp_bar.value = float(v)

func _init_end() -> void:
	if _stats == null or _end_bar == null:
		return
	if _stats.has_method("max_end"):
		_end_bar.max_value = float(_stats.call("max_end"))
	var v: Variant = _stats.get("current_end")
	if v != null:
		_end_bar.value = float(v)

# --- Signal callbacks from StatsComponent ---

func _on_hp_changed(current: float, max_value: float) -> void:
	if _hp_bar == null:
		return
	_hp_bar.max_value = max_value
	_hp_bar.value = current

func _on_mp_changed(current: float, max_value: float) -> void:
	if _mp_bar == null:
		return
	_mp_bar.max_value = max_value
	_mp_bar.value = current

func _on_end_changed(current: float, max_value: float) -> void:
	if _end_bar == null:
		return
	_end_bar.max_value = max_value
	_end_bar.value = current
