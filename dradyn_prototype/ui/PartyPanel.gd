extends Control

# --- Assign these in the Inspector on the PartyPanel instance ---
@export var stats_path: NodePath
@export var hp_bar_path: NodePath
@export var mp_bar_path: NodePath
@export var end_bar_path: NodePath   # your ENDBar

@onready var stats = get_node_or_null(stats_path)
@onready var hp_bar: ProgressBar  = get_node_or_null(hp_bar_path)
@onready var mp_bar: ProgressBar  = get_node_or_null(mp_bar_path)
@onready var end_bar: ProgressBar = get_node_or_null(end_bar_path)

func _ready() -> void:
	# Hide % if visible
	if hp_bar:  hp_bar.show_percentage = false
	if mp_bar:  mp_bar.show_percentage = false
	if end_bar: end_bar.show_percentage = false

	if stats:
		# initial fill
		_on_hp_changed(stats.current_hp, _max_hp())
		_on_mp_changed(stats.current_mp, _max_mp())
		_on_end_changed(stats.current_stamina, _max_end())

		# live updates
		stats.hp_changed.connect(_on_hp_changed)
		stats.mp_changed.connect(_on_mp_changed)
		stats.stamina_changed.connect(_on_end_changed) # stamina -> END bar

func _on_hp_changed(current: float, max_value: float) -> void:
	if hp_bar:
		hp_bar.max_value = max_value
		_tween_bar_value(hp_bar, current)

func _on_mp_changed(current: float, max_value: float) -> void:
	if mp_bar:
		mp_bar.max_value = max_value
		_tween_bar_value(mp_bar, current)

func _on_end_changed(current: float, max_value: float) -> void:
	if end_bar:
		end_bar.max_value = max_value
		_tween_bar_value(end_bar, current)

# Helpers
func _max_hp() -> float:
	return stats.max_hp() if stats and stats.has_method("max_hp") else 100.0

func _max_mp() -> float:
	return stats.max_mp() if stats and stats.has_method("max_mp") else 30.0

func _max_end() -> float:
	return stats.max_stamina() if stats and stats.has_method("max_stamina") else 100.0

func _tween_bar_value(bar: ProgressBar, target: float, dur := 0.18) -> void:
	if bar == null: return
	var t := create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(bar, "value", target, dur)
