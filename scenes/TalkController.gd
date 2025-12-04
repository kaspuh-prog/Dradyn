extends Control
class_name TalkController

@export var dialogue_box_scene: PackedScene

var _dialogue: DialogueBox = null
var _current_npc: NonCombatNPC = null
var _current_actor: Node = null


func _ready() -> void:
	add_to_group("talk_ui")
	set_process(true)

	_instantiate_dialogue_box()
	_connect_existing_npcs()
	get_tree().node_added.connect(_on_node_added)


# -------------------------------------------------
# Setup helpers
# -------------------------------------------------

func _instantiate_dialogue_box() -> void:
	if dialogue_box_scene == null:
		push_warning("TalkController: dialogue_box_scene is not assigned.")
		return

	var inst: Control = dialogue_box_scene.instantiate()
	_dialogue = inst as DialogueBox
	if _dialogue == null:
		push_error("TalkController: dialogue_box_scene does not instantiate a DialogueBox.")
		add_child(inst)
		return

	add_child(_dialogue)
	_dialogue.visible = false

	_dialogue.choice_selected.connect(_on_dialog_choice_selected)
	_dialogue.dialogue_closed.connect(_on_dialogue_closed)


func _connect_existing_npcs() -> void:
	var nodes: Array[Node] = get_tree().get_nodes_in_group("interactable")
	var i: int = 0
	while i < nodes.size():
		var node: Node = nodes[i]
		if node is NonCombatNPC:
			_connect_npc(node as NonCombatNPC)
		i += 1


func _on_node_added(node: Node) -> void:
	if node is NonCombatNPC:
		_connect_npc(node as NonCombatNPC)


func _connect_npc(npc: NonCombatNPC) -> void:
	if npc.talk_requested.is_connected(_on_npc_talk_requested):
		return
	npc.talk_requested.connect(_on_npc_talk_requested)


# -------------------------------------------------
# Entry from NPC
# -------------------------------------------------

func _on_npc_talk_requested(npc: NonCombatNPC, actor: Node, line: String) -> void:
	_current_npc = npc
	_current_actor = actor
	_open_talk_dialogue(npc, line)


func _open_talk_dialogue(npc: NonCombatNPC, line: String) -> void:
	if _dialogue == null:
		return

	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = line

	# Single little arrow instead of "OK"
	var choices: Array[String] = []
	choices.append("▶")

	var ids: Array[StringName] = []
	ids.append(StringName("ok"))

	_dialogue.show_message(text, speaker, choices, ids)


func _get_npc_speaker_name(npc: NonCombatNPC) -> String:
	if npc == null:
		return ""
	if npc.npc_name != "":
		return npc.npc_name
	return ""


func close_dialogue() -> void:
	if _dialogue != null:
		_dialogue.close_dialogue()
	_reset_state()


func _reset_state() -> void:
	_current_npc = null
	_current_actor = null


# -------------------------------------------------
# Dialogue callbacks
# -------------------------------------------------

func _on_dialog_choice_selected(index: int, id_value: StringName) -> void:
	var id_str: String = String(id_value)

	if id_str == "ok":
		close_dialogue()
	else:
		close_dialogue()


func _on_dialogue_closed() -> void:
	_reset_state()


# -------------------------------------------------
# Close conditions (Esc / walking away)
# -------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _dialogue == null:
		return
	if not _dialogue.visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_dialogue()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _dialogue == null:
		return
	if not _dialogue.visible:
		return
	if _current_npc == null:
		return
	if _current_actor == null:
		return

	if not _is_actor_in_range():
		close_dialogue()


func _is_actor_in_range() -> bool:
	var npc_2d: Node2D = _current_npc as Node2D
	var actor_2d: Node2D = _current_actor as Node2D

	if npc_2d == null or actor_2d == null:
		return true

	var npc_radius: float = 0.0
	if _current_npc.has_method("get_interact_radius"):
		var r_v: Variant = _current_npc.call("get_interact_radius")
		if r_v is float or r_v is int:
			npc_radius = float(r_v)

	var base_radius: float = 0.0
	var isys: InteractionSystem = InteractionSys
	if isys != null:
		base_radius = isys.interact_radius

	var r: float = npc_radius
	if base_radius > r:
		r = base_radius
	if r <= 0.0:
		r = 32.0

	var dist: float = npc_2d.global_position.distance_to(actor_2d.global_position)
	var max_dist: float = r * 1.2
	return dist <= max_dist
