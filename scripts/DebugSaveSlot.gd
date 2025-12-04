extends Node
class_name DebugSaveSlot

@export var slot_index: int = 1
@export var input_action: StringName = &"debug_save_slot_1"
@export var use_boot_area_if_no_area_found: bool = true

func _ready() -> void:
	set_process_unhandled_input(true)

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(input_action):
		return
	_perform_debug_save()

func _perform_debug_save() -> void:
	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		push_warning("[DebugSaveSlot] SaveSys autoload not found; cannot save.")
		return
	
	var area_path: String = ""
	var entry_tag: String = "default"
	
	var area_node: Node = _find_current_area()
	if area_node != null:
		# In Godot 4, instanced scenes expose their source path here.
		area_path = area_node.scene_file_path
	
	if area_path == "" and use_boot_area_if_no_area_found:
		# Fallback to the BootArea start config so Continue has something sane.
		var boot: BootArea = get_tree().root.find_child("BootArea", true, false) as BootArea
		if boot != null:
			area_path = boot.start_area
			entry_tag = boot.start_entry_tag
	
	if area_path == "":
		push_warning("[DebugSaveSlot] Could not determine area_path; aborting save.")
		return
	
	var payload: Dictionary = {}
	payload["player_name"] = "DebugHero"
	payload["area_path"] = area_path
	payload["entry_tag"] = entry_tag
	# We will hook this up to real tracking later.
	payload["play_time_sec"] = 0
	
	# --- NEW: include story state so cutscenes and quests persist ---
	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story != null:
		var story_state: Dictionary = story.get_save_state()
		payload["story_state"] = story_state
	
	save_sys.save_to_slot(slot_index, payload)
	print("[DebugSaveSlot] Saved slot %d at area '%s' (entry_tag='%s')." % [slot_index, area_path, entry_tag])

func _find_current_area() -> Node:
	# Try to ask SceneMgr first, if it exposes a helper later.
	var sm_node: SceneManager = get_node_or_null("/root/SceneMgr") as SceneManager
	if sm_node != null:
		# If we later add a public API like get_current_area(), we can use it here.
		if sm_node.has_method("get_current_area"):
			var any_area: Variant = sm_node.call("get_current_area")
			var area_from_sm: Node = any_area as Node
			if area_from_sm != null:
				return area_from_sm
		
		# Otherwise we fall back to inspecting the world_root and its children.
		var world_root: Node = sm_node.world_root
		if world_root == null:
			world_root = get_tree().root.find_child("WorldRoot", true, false)
		
		if world_root == null:
			return null
		
		for child in world_root.get_children():
			var node_child: Node = child
			# Our area scenes use AreaTemplate as their root script.
			if node_child is AreaTemplate:
				return node_child
	
	# If we somehow have no SceneMgr, we cannot reliably find an area.
	return null
