extends Control
class_name StatsSheet

signal request_spend_point(stat_id: String) # Step 2: HUDRoot/GameRoot can route this to LevelComponent/StatsComponent

@onready var _points_label: Label = %Points
@onready var _stats_list: GridContainer = %StatsList

var _unspent_points: int = 0

func _ready() -> void:
	_render_stub()

func set_unspent_points(points: int) -> void:
	_unspent_points = max(points, 0)
	if is_inside_tree():
		_points_label.text = "Unspent Points: %d" % _unspent_points

func _render_stub() -> void:
	_points_label.text = "Unspent Points: %d" % _unspent_points

	# Placeholder rows; Step 2 replaces with real data from StatsComponent/DerivedFormulas
	_stats_list.free_children()

	var names: Array[String] = ["STR", "DEX", "INT", "WIS", "STA", "LCK"]
	for n in names:
		var stat_label := Label.new()
		stat_label.text = "%s: (value…)" % n
		_stats_list.add_child(stat_label)

		var plus := Button.new()
		plus.text = "+"
		plus.disabled = (_unspent_points <= 0)
		plus.pressed.connect(func():
			emit_signal("request_spend_point", n)
		)
		_stats_list.add_child(plus)
