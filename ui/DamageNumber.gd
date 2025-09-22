extends Label
class_name DamageNumber

@export var lifetime: float = 0.6
@export var rise: float = 14.0
@export var drift: float = 6.0    # sideways drift

func pop(amount: float, color: Color = Color.WHITE, prefix: String = "", is_crit: bool = false, is_heal: bool = false) -> void:
	var val: int = int(round(amount))
	text = (prefix if prefix != "" else ("+" if is_heal else "")) + str(val)
	modulate = color
	scale = Vector2(1.2, 1.2) if is_crit else Vector2.ONE   # <-- fixed ternary

	var start: Vector2 = position
	var end: Vector2 = start + Vector2(randf_range(-drift, drift), -rise)

	var t := create_tween()
	t.tween_property(self, "position", end, lifetime)
	t.parallel().tween_property(self, "modulate:a", 0.0, lifetime)
	if is_crit:
		t.parallel().tween_property(self, "scale", Vector2.ONE, lifetime * 0.6)
	t.tween_callback(queue_free)
