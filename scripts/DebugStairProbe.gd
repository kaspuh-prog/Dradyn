extends Node
class_name DebugStairProbe

@export var poll_seconds: float = 0.5
@export var enable_logs: bool = false

var _timer: Timer

func _ready() -> void:
	if not enable_logs:
		return

	print("[DebugStairProbe] READY")
	_print_all_triggers()

	_timer = Timer.new()
	_timer.one_shot = false
	_timer.wait_time = poll_seconds
	add_child(_timer)
	_timer.timeout.connect(_on_tick)
	_timer.start()

func _on_tick() -> void:
	if not enable_logs:
		return
	_print_overlaps()

func _print_all_triggers() -> void:
	var nodes: Array = get_tree().get_nodes_in_group("StairTriggerNodes")
	if nodes.is_empty():
		print("[DebugStairProbe] No StairTriggerNodes found in scene tree.")
		return

	print("[DebugStairProbe] Found ", nodes.size(), " StairTrigger(s).")
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		if n is Area2D:
			var a: Area2D = n as Area2D
			print("  • ", a.get_path(), " pos=", a.global_position, " monitoring=", a.monitoring, " monitorable=", a.monitorable, " layer=", a.collision_layer, " mask=", a.collision_mask)
		else:
			print("  • ", n.get_path(), " (not Area2D?)")
		i += 1

func _print_overlaps() -> void:
	var nodes: Array = get_tree().get_nodes_in_group("StairTriggerNodes")
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		if n is Area2D:
			var a: Area2D = n as Area2D
			if a.monitoring:
				var bodies: Array = a.get_overlapping_bodies()
				var areas: Array = a.get_overlapping_areas()
				if bodies.size() > 0 or areas.size() > 0:
					print("[DebugStairProbe] Overlaps @", a.get_path(), " bodies=", bodies.size(), " areas=", areas.size())
		i += 1
