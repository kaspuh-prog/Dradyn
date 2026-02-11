extends Control
class_name TitleScreen

@export_file("*.tscn") var game_scene_path: String = "res://scenes/Main.tscn"
@export_file("*.tscn") var character_create_scene_path: String = ""

# NEW: Continue will go here first (slot select), then that screen will load & start the game.
@export_file("*.tscn") var save_select_scene_path: String = "res://scenes/PreGame/SaveSelectScreen.tscn"

@export var new_game_button_path: NodePath
@export var continue_button_path: NodePath
@export var quit_button_path: NodePath

@onready var _new_game_button: Button = _get_button(new_game_button_path)
@onready var _continue_button: Button = _get_button(continue_button_path)
@onready var _quit_button: Button = _get_button(quit_button_path)

func _ready() -> void:
	_refresh_continue_state()
	_wire_buttons()

func _get_button(path: NodePath) -> Button:
	if path.is_empty():
		return null
	var node: Node = get_node_or_null(path)
	if node == null:
		return null
	var button: Button = node as Button
	return button

func _get_save_sys() -> Node:
	# Autoload name must be "SaveSys" in Project Settings.
	var node: Node = get_node_or_null("/root/SaveSys")
	return node

func _refresh_continue_state() -> void:
	var save_sys: Node = _get_save_sys()
	var can_continue: bool = false
	if save_sys != null and save_sys.has_method("has_any_save"):
		var value_any: Variant = save_sys.call("has_any_save")
		if typeof(value_any) == TYPE_BOOL:
			can_continue = bool(value_any)

	if _continue_button != null:
		_continue_button.disabled = not can_continue

func _wire_buttons() -> void:
	if _new_game_button != null and not _new_game_button.pressed.is_connected(_on_new_game_pressed):
		_new_game_button.pressed.connect(_on_new_game_pressed)
	if _continue_button != null and not _continue_button.pressed.is_connected(_on_continue_pressed):
		_continue_button.pressed.connect(_on_continue_pressed)
	if _quit_button != null and not _quit_button.pressed.is_connected(_on_quit_pressed):
		_quit_button.pressed.connect(_on_quit_pressed)

func _on_new_game_pressed() -> void:
	# Later: route to CharacterCreate scene if defined.
	if character_create_scene_path != "":
		var err_cc: int = get_tree().change_scene_to_file(character_create_scene_path)
		if err_cc != OK:
			push_error("[TitleScreen] Failed to change to character_create_scene_path: %s" % character_create_scene_path)
		return

	_start_game_without_character_create()

func _start_game_without_character_create() -> void:
	if game_scene_path == "":
		push_error("[TitleScreen] game_scene_path is empty.")
		return

	var err: int = get_tree().change_scene_to_file(game_scene_path)
	if err != OK:
		push_error("[TitleScreen] Failed to change scene to: %s" % game_scene_path)

func _on_continue_pressed() -> void:
	# NEW: If SaveSelect exists, go there first.
	if save_select_scene_path != "":
		if ResourceLoader.exists(save_select_scene_path):
			var err_select: int = get_tree().change_scene_to_file(save_select_scene_path)
			if err_select != OK:
				push_error("[TitleScreen] Failed to change to save_select_scene_path: %s" % save_select_scene_path)
			return
		else:
			push_warning("[TitleScreen] save_select_scene_path does not exist: %s (falling back)" % save_select_scene_path)

	# Fallback to previous behavior (load last slot and go straight into game).
	var save_sys: Node = _get_save_sys()
	if save_sys == null:
		push_warning("[TitleScreen] Continue pressed but SaveSys not found.")
		return

	if not save_sys.has_method("get_last_played_slot"):
		push_warning("[TitleScreen] SaveSys missing get_last_played_slot.")
		return

	var last_slot_any: Variant = save_sys.call("get_last_played_slot")
	if typeof(last_slot_any) != TYPE_INT:
		push_warning("[TitleScreen] get_last_played_slot did not return int.")
		return

	var slot: int = int(last_slot_any)
	if slot <= 0:
		push_warning("[TitleScreen] No valid last played slot; falling back to New Game.")
		_start_game_without_character_create()
		return

	if not save_sys.has_method("load_from_slot"):
		push_warning("[TitleScreen] SaveSys has no load_from_slot; starting game anyway.")
		_start_game_without_character_create()
		return

	var payload_any: Variant = save_sys.call("load_from_slot", slot)
	if typeof(payload_any) != TYPE_DICTIONARY:
		push_warning("[TitleScreen] load_from_slot did not return Dictionary; starting game anyway.")
		_start_game_without_character_create()
		return

	if save_sys.has_method("set_current_slot"):
		save_sys.call("set_current_slot", slot)

	_start_game_without_character_create()

func _on_quit_pressed() -> void:
	get_tree().quit()
