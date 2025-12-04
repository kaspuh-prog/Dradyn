extends Node
class_name LevelUpToDamageNumbers

@export var message_template: String = "LEVEL UP!"   # supports "{level}"
@export var color: Color = Color(1.0, 0.9, 0.35)     # gold
@export var scale_mult: float = 1.25
@export var debug_logs: bool = false

func _ready() -> void:
	add_to_group("LevelUpPopups")  # LevelComponent already calls this group

func show_for_node(node2d: Node2D, new_level: int) -> void:
	if node2d == null or not is_instance_valid(node2d):
		return
	var msg := message_template
	if message_template.find("{level}") != -1:
		msg = message_template.replace("{level}", str(new_level))
	else:
		msg = "%s  (Lv. %d)" % [message_template, new_level]

	if debug_logs:
		print("[LevelUpToDNL] node=", node2d, " level=", new_level, " msg=", msg)

	get_tree().call_group("DamageNumberSpawners", "show_text_for_node", node2d, msg, color, scale_mult)
