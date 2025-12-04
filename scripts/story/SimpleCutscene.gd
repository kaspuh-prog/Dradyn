extends Control
class_name SimpleCutscene

@export_group("Setup")
@export var dialogue_box_scene: PackedScene
@export var story_gate_path: NodePath

@export_group("Dialogue")
@export var speaker_name: String = ""
@export_multiline var line_text: String = ""

# If you want a custom button label instead of "▶"
@export var proceed_button_label: String = "▶"

var _dialogue: DialogueBox = null
var _gate: StoryGate = null
var _is_running: bool = false


func _ready() -> void:
	# Optionally keep this UI on a special layer under HUDRoot later.
	visible = false

	if story_gate_path != NodePath():
		_gate = get_node_or_null(story_gate_path) as StoryGate

	_instantiate_dialogue_box()


func _instantiate_dialogue_box() -> void:
	if _dialogue != null:
		return

	if dialogue_box_scene == null:
		push_error("[SimpleCutscene] dialogue_box_scene is not assigned.")
		return

	var inst: Node = dialogue_box_scene.instantiate()
	var as_dialogue: DialogueBox = inst as DialogueBox
	if as_dialogue == null:
		push_error("[SimpleCutscene] dialogue_box_scene does not instantiate a DialogueBox.")
		add_child(inst)
		return

	_dialogue = as_dialogue
	add_child(_dialogue)
	_dialogue.visible = false

	_dialogue.dialogue_closed.connect(_on_dialogue_closed)


func can_play() -> bool:
	if _gate == null:
		# If there is no gate, we assume this cutscene is always allowed.
		return true

	return _gate.is_passing()


func play() -> void:
	if _is_running:
		return

	if not can_play():
		return

	if _dialogue == null:
		_instantiate_dialogue_box()
		if _dialogue == null:
			return

	_is_running = true
	visible = true

	# TODO: This is where we will:
	#  - Disable player input
	#  - Lock InteractionSys / combat
	# For now this just plays dialogue.

	_show_line()


func _show_line() -> void:
	if _dialogue == null:
		return

	var choices: Array[String] = []
	choices.append(proceed_button_label)

	var ids: Array[StringName] = []
	ids.append(StringName("ok"))

	_dialogue.show_message(line_text, speaker_name, choices, ids)


func _on_dialogue_closed() -> void:
	# Dialogue finished; apply story changes via the gate, if any.
	if _gate != null:
		_gate.apply_after_effects()

	_finish_cutscene()


func _finish_cutscene() -> void:
	# TODO: Re-enable player input and other systems here when we wire them up.
	_is_running = false
	visible = false
