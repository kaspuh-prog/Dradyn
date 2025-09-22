extends Control
@export var panel_size := Vector2(127, 67)
@export var bottom_margin := 1
@export var left_margin := 1

func _ready() -> void:
	_place_panel()
	get_viewport().size_changed.connect(_place_panel)

func _place_panel() -> void:
	var holder: Control = $Panel1Holder
	holder.size = panel_size
	var vp_h := get_viewport_rect().size.y
	holder.position = Vector2(
		left_margin,
		vp_h - bottom_margin - panel_size.y
	)
