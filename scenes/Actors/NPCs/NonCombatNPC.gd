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
## Merchant subtype identifier (e.g. "general", "alchemy", "blacksmith")
@export var merchant_id: StringName = &"general"

# ---------- Quest routing ----------
@export_group("Quest Routing")
## If true, and QuestSys says a quest interaction is currently applicable for this NPC,
## the NPC will emit quest_requested instead of its default npc_role signal.
@export var quest_can_override_role: bool = true

# ---------- Flavor dialogue ----------
@export_group("Flavor Dialogue")
@export var talk_lines: PackedStringArray = PackedStringArray()
@export var cycle_talk_lines: bool = true

# ---------- Internals ----------
var _sprite: CanvasItem = null
var _anim_sprite: AnimatedSprite2D = null
var _orig_modulate: Color = Color(1.0, 1.0, 1.0, 1.0)
var _orig_modulate_set: bool = false
var _talk_index: int = 0


func _ready() -> void:
	if auto_register_group and not is_in_group("interactable"):
		add_to_group("interactable")

	if sprite_path != NodePath():
		var node: Node = get_node_or_null(sprite_path)
		_sprite = node as CanvasItem
		_anim_sprite = node as AnimatedSprite2D
	else:
		_sprite = null
		_anim_sprite = null

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

	var anim: AnimatedSprite2D = _anim_sprite
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

	# If this NPC's sprite has a script with set_interacting(bool), use it
	# (e.g. AlchemyWitchAnimator on an AnimatedSprite2D that stirs/ idles).
	if _anim_sprite != null and _anim_sprite.has_method("set_interacting"):
		_anim_sprite.call("set_interacting", true)

	# Quest override: route to quest only when QuestSys says it's applicable right now.
	if _should_route_to_quest(actor):
		emit_signal("quest_requested", self, actor, quest_giver_id)
		return

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


func reset_interaction_animation() -> void:
	# Helper so external systems (e.g. MerchantController) can tell the NPC
	# to revert any special interaction animation (e.g. witch back to brewing).
	if _anim_sprite != null and _anim_sprite.has_method("set_interacting"):
		_anim_sprite.call("set_interacting", false)


# -------------------------------------------------
# Quest routing helper
# -------------------------------------------------
func _should_route_to_quest(actor: Node) -> bool:
	if not quest_can_override_role:
		return false
	if quest_giver_id == &"":
		return false

	var quest_sys: Node = get_node_or_null("/root/QuestSys")
	if quest_sys == null:
		return false
	if not quest_sys.has_method("should_route_to_quest"):
		return false

	var result: Variant = quest_sys.call("should_route_to_quest", self, actor, quest_giver_id)
	if result is bool:
		return bool(result)

	return false
