extends CanvasLayer
class_name LevelUpPopup

@export var layer_order: int = 700
@export var text: String = "LEVEL UP!"
@export var color: Color = Color(1.0, 0.9, 0.2)
@export var outline_color: Color = Color(0, 0, 0, 1)
@export var font_px: int = 36
@export var outline_size: int = 4
@export var rise_pixels: float = 48.0
@export var life_sec: float = 1.2

func _ready() -> void:
	layer = layer_order

# Call once per actor you care about (e.g., on the player)
func register_level_source(level_component: Node) -> void:
	if level_component == null:
		return
	if level_component.has_signal("level_up"):
		if not level_component.level_up.is_connected(_on_level_up):
			level_component.level_up.connect(_on_level_up)

func _on_level_up(new_level: int, _gained: int) -> void:
	_spawn_center_label(text + "  " + str(new_level))

func _spawn_center_label(txt: String) -> void:
	var label := Label.new()
	add_child(label)
	label.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	label.add_theme_font_size_override("font_size", font_px)
	label.add_theme_color_override("font_color", color)
	label.add_theme_constant_override("outline_size", outline_size)
	label.add_theme_color_override("font_outline_color", outline_color)
	label.modulate = Color(1,1,1,0.0)
	label.z_index = 999
	label.text = txt
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var rect := get_viewport().get_visible_rect()
	label.position = rect.size * 0.5

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(label, "modulate:a", 1.0, 0.12)
	tw.tween_property(label, "position:y", label.position.y - rise_pixels, life_sec).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(label, "modulate:a", 0.0, life_sec).set_delay(0.25)
	tw.finished.connect(func():
		if is_instance_valid(label):
			label.queue_free()
	)
