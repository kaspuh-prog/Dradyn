extends Control
class_name SavePointController

@export var dialogue_box_scene: PackedScene

# NEW: Save slot picker (SaveSelectScreen.tscn)
@export var save_select_scene: PackedScene

@export_group("Close Conditions")
@export var close_on_walk_away: bool = true
@export var walk_away_multiplier: float = 1.2

const _ID_SAVE_YES: StringName = &"save_yes"
const _ID_SAVE_NO: StringName = &"save_no"

var _dialogue: DialogueBox = null
var _current_point: SavePoint = null
var _current_actor: Node = null

# NEW: overlay instance (when choosing a slot)
var _save_select: SaveSelectScreen = null

func _ready() -> void:
	add_to_group("save_ui")
	set_process(true)

	_instantiate_dialogue_box()
	_connect_existing_save_points()
	get_tree().node_added.connect(_on_node_added)

func _unhandled_input(event: InputEvent) -> void:
	# If the slot picker is open, let it handle cancel (it already closes itself in overlay_mode).
	if _save_select != null:
		return

	if _dialogue == null:
		return
	if not _dialogue.visible:
		return

	if event.is_action_pressed("ui_cancel"):
		_close_dialogue()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	# If slot picker is open, don’t auto-close the dialogue (dialogue is already closed anyway).
	if _save_select != null:
		return

	if _dialogue == null:
		return
	if not _dialogue.visible:
		return
	if not close_on_walk_away:
		return

	if _current_point == null or _current_actor == null:
		_close_dialogue()
		return

	if not _is_actor_in_range():
		_close_dialogue()

func _instantiate_dialogue_box() -> void:
	if dialogue_box_scene == null:
		push_warning("SavePointController: dialogue_box_scene is not assigned.")
		return

	var inst: Control = dialogue_box_scene.instantiate()
	_dialogue = inst as DialogueBox
	if _dialogue == null:
		push_error("SavePointController: dialogue_box_scene does not instantiate a DialogueBox.")
		add_child(inst)
		return

	add_child(_dialogue)
	_dialogue.visible = false
	_dialogue.choice_selected.connect(_on_dialog_choice_selected)
	_dialogue.dialogue_closed.connect(_on_dialogue_closed)

func _connect_existing_save_points() -> void:
	var nodes: Array[Node] = get_tree().get_nodes_in_group("interactable")
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		var sp: SavePoint = n as SavePoint
		if sp != null:
			_connect_save_point(sp)
		i += 1

func _on_node_added(node: Node) -> void:
	var sp: SavePoint = node as SavePoint
	if sp != null:
		_connect_save_point(sp)

func _connect_save_point(sp: SavePoint) -> void:
	if sp.save_requested.is_connected(_on_save_requested):
		return
	sp.save_requested.connect(_on_save_requested)

func _on_save_requested(sp: SavePoint, actor: Node) -> void:
	# If slot picker already open, ignore new requests.
	if _save_select != null:
		return

	if _dialogue == null:
		return

	_current_point = sp
	_current_actor = actor

	var speaker: String = sp.speaker_name
	if speaker == "":
		speaker = "Save Point"

	var text: String = sp.prompt_text
	if text == "":
		text = "Save your game?"

	var choices: Array[String] = []
	choices.append("Yes")
	choices.append("No")

	var ids: Array[StringName] = []
	ids.append(_ID_SAVE_YES)
	ids.append(_ID_SAVE_NO)

	_dialogue.show_message(text, speaker, choices, ids)

func _on_dialog_choice_selected(_index: int, id_value: StringName) -> void:
	if id_value == _ID_SAVE_YES:
		_close_dialogue()
		_open_save_select_overlay()
		return

	if id_value == _ID_SAVE_NO:
		_close_dialogue()
		return

	_close_dialogue()

func _on_dialogue_closed() -> void:
	_reset_state()

func _close_dialogue() -> void:
	if _dialogue != null:
		_dialogue.close_dialogue()
	_reset_state()

func _reset_state() -> void:
	_current_point = null
	_current_actor = null

func _is_actor_in_range() -> bool:
	var sp_2d: Node2D = _current_point as Node2D
	var actor_2d: Node2D = _current_actor as Node2D

	if sp_2d == null or actor_2d == null:
		return true

	var r: float = 32.0
	if _current_point != null and _current_point.has_method("get_interact_radius"):
		var rv: Variant = _current_point.call("get_interact_radius")
		if rv is float or rv is int:
			var rf: float = float(rv)
			if rf > 0.0:
				r = rf

	var mult: float = walk_away_multiplier
	if mult <= 0.0:
		mult = 1.2

	var max_dist: float = r * mult
	var dist: float = sp_2d.global_position.distance_to(actor_2d.global_position)
	return dist <= max_dist

# --------------------------------------------------------------------
# Slot picker overlay (SAVE intent)
# --------------------------------------------------------------------
func _open_save_select_overlay() -> void:
	if _save_select != null:
		return

	if save_select_scene == null:
		push_warning("[SavePointController] save_select_scene not assigned; cannot open slot picker.")
		return

	var inst: Node = save_select_scene.instantiate()
	var s: SaveSelectScreen = inst as SaveSelectScreen
	if s == null:
		push_error("[SavePointController] save_select_scene does not instantiate SaveSelectScreen.")
		add_child(inst)
		return

	# IMPORTANT: configure BEFORE add_child, so SaveSelectScreen._ready builds rows in SAVE intent.
	s.intent = SaveSelectScreen.SaveSelectIntent.SAVE
	s.overlay_mode = true
	s.close_after_action = true

	_save_select = s
	add_child(_save_select)

	if not _save_select.close_requested.is_connected(_on_save_select_closed):
		_save_select.close_requested.connect(_on_save_select_closed)

	if not _save_select.slot_action_completed.is_connected(_on_save_select_action_completed):
		_save_select.slot_action_completed.connect(_on_save_select_action_completed)

func _on_save_select_action_completed(intent_value: int, _slot_index: int) -> void:
	if intent_value == int(SaveSelectScreen.SaveSelectIntent.SAVE):
		pass

func _on_save_select_closed() -> void:
	_save_select = null

# --------------------------------------------------------------------
# Legacy direct-save code preserved (shim) — no longer used.
# --------------------------------------------------------------------
func _try_save_now() -> void:
	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		push_warning("[SavePointController] SaveSys not found; cannot save.")
		return

	var slot_index: int = save_sys.get_current_slot()
	if slot_index < 1:
		slot_index = save_sys.get_last_played_slot()
	if slot_index < 1:
		slot_index = 1

	var payload: Dictionary = _build_basic_save_payload(slot_index)
	if payload.is_empty():
		push_warning("[SavePointController] Save payload empty; skipping save.")
		return

	save_sys.save_to_slot(slot_index, payload)

func _build_basic_save_payload(slot_index: int) -> Dictionary:
	var payload: Dictionary = {}

	var area_path: String = ""
	var entry_tag: String = "default"

	var sm: SceneManager = get_node_or_null("/root/SceneMgr") as SceneManager
	if sm != null:
		var area_node: Node = sm.get_current_area()
		if area_node != null:
			area_path = area_node.scene_file_path

	if area_path == "":
		var cs: Node = get_tree().current_scene
		if cs != null:
			area_path = cs.scene_file_path

	if area_path == "":
		return {}

	payload["version"] = 1
	payload["slot_index"] = slot_index
	payload["area_path"] = area_path
	payload["entry_tag"] = entry_tag

	var pm: PartyManager = Party as PartyManager
	var player_name: String = "Unknown"
	if pm != null:
		var controlled: Node = pm.get_controlled()
		if controlled != null:
			player_name = str(controlled.name)
	payload["player_name"] = player_name

	payload["play_time_sec"] = 0

	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story != null:
		payload["story_state"] = story.get_save_state()

	return payload
