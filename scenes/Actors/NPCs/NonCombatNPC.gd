extends Node2D
class_name NonCombatNPC

## Generic non-combat interactable NPC.
## Works with InteractionSystem (InteractionSys autoload) via:
##   - group "interactable"
##   - interact(actor)
##   - get_interact_radius()
##   - get_interact_prompt()
##   - set_interact_highlight(on)

signal merchant_requested(npc: NonCombatNPC, actor: Node)
signal inn_requested(npc: NonCombatNPC, actor: Node)
signal trainer_requested(npc: NonCombatNPC, actor: Node, trainer_id: StringName)
signal quest_requested(npc: NonCombatNPC, actor: Node, quest_giver_id: StringName)
signal service_requested(npc: NonCombatNPC, actor: Node, service_id: StringName)
signal talk_requested(npc: NonCombatNPC, actor: Node, line: String)

# ---------- Identity / role ----------
@export var npc_name: String = ""
@export var inn_price: int = -1
@export var inn_is_free: bool = false

@export_enum("merchant", "inn", "service", "trainer", "quest", "flavor")
var npc_role: String = "flavor"

@export var auto_register_group: bool = true

# ---------- InteractionSys compatibility ----------
@export var interact_radius_override: float = 32.0
func get_interact_radius() -> float:
	return interact_radius_override

# Used by InteractionSystem for selection highlighting.
@export var sprite_path: NodePath = ^"Sprite"
@export var highlight_modulate: Color = Color(1.3, 1.3, 1.3, 1.0)

# ---------- Prompts ----------
@export_group("Prompts")
## If non-empty, overrides the auto prompt text.
@export var override_prompt: String = ""

# ---------- Role IDs (for routing to systems/UI) ----------
@export_group("Role IDs")
## Generic service identifier (e.g. "respec", "blacksmith_repair")
@export var service_id: StringName = &""
## Trainer identifier (e.g. "warrior_trainer", "magician_trainer")
@export var trainer_id: StringName = &""
## Quest giver identifier (for your quest system)
@export var quest_giver_id: StringName = &""

# ---------- Flavor dialogue ----------
@export_group("Flavor Dialogue")
@export var talk_lines: PackedStringArray = PackedStringArray()
@export var cycle_talk_lines: bool = true

# ---------- Internals ----------
var _sprite: CanvasItem = null
var _orig_modulate: Color = Color(1.0, 1.0, 1.0, 1.0)
var _orig_modulate_set: bool = false
var _talk_index: int = 0

func _ready() -> void:
	if auto_register_group and not is_in_group("interactable"):
		add_to_group("interactable")

	if sprite_path != NodePath():
		_sprite = get_node_or_null(sprite_path) as CanvasItem
	else:
		_sprite = null

	if _sprite != null and not _orig_modulate_set:
		_orig_modulate = _sprite.modulate
		_orig_modulate_set = true

func _face_actor(actor: Node) -> void:
	if _sprite == null:
		return

	var actor_node2d: Node2D = actor as Node2D
	if actor_node2d == null:
		return

	var dir: Vector2 = actor_node2d.global_position - global_position
	if dir.length() < 0.001:
		return

	var anim: AnimatedSprite2D = _sprite as AnimatedSprite2D
	if anim != null:
		var abs_x: float = absf(dir.x)
		var abs_y: float = absf(dir.y)

		if abs_x >= abs_y:
			anim.play("idle_side")
			if dir.x < 0.0:
				anim.flip_h = true
			else:
				anim.flip_h = false
		else:
			if dir.y > 0.0:
				anim.play("idle_down")
			else:
				anim.play("idle_up")
			anim.flip_h = false
		return

	var sprite2d: Sprite2D = _sprite as Sprite2D
	if sprite2d != null:
		if dir.x < 0.0:
			sprite2d.flip_h = true
		else:
			sprite2d.flip_h = false

func interact(actor: Node) -> void:
	_face_actor(actor)

	match npc_role:
		"merchant":
			emit_signal("merchant_requested", self, actor)

		"inn":
			emit_signal("inn_requested", self, actor)

		"service":
			emit_signal("service_requested", self, actor, service_id)

		"trainer":
			emit_signal("trainer_requested", self, actor, trainer_id)

		"quest":
			emit_signal("quest_requested", self, actor, quest_giver_id)

		"flavor":
			var line: String = _next_talk_line()
			emit_signal("talk_requested", self, actor, line)

		_:
			var fallback: String = _next_talk_line()
			emit_signal("talk_requested", self, actor, fallback)


func get_interact_prompt() -> String:
	if override_prompt != "":
		return override_prompt

	match npc_role:
		"merchant":
			return "Shop"
		"inn":
			return "Rest"
		"service":
			return "Talk"
		"trainer":
			return "Train"
		"quest":
			return "Talk"
		"flavor":
			return "Talk"
		_:
			return "Talk"

func set_interact_highlight(on: bool) -> void:
	if _sprite == null:
		return
	if not _orig_modulate_set:
		_orig_modulate = _sprite.modulate
		_orig_modulate_set = true

	if on:
		_sprite.modulate = highlight_modulate
	else:
		_sprite.modulate = _orig_modulate

func _next_talk_line() -> String:
	if talk_lines.is_empty():
		# Basic fallback if you forgot to add lines.
		if npc_name != "":
			return "..."
		return "..."

	# Clamp index in range
	if _talk_index < 0 or _talk_index >= talk_lines.size():
		_talk_index = 0

	var line: String = String(talk_lines[_talk_index])

	if cycle_talk_lines:
		_talk_index += 1
		if _talk_index >= talk_lines.size():
			_talk_index = 0

	return line
