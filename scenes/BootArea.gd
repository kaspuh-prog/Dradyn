extends Node
class_name BootArea

@export_file("*.tscn") var start_area: String = "res://scenes/WorldAreas/OrphanageCommonRoom.tscn"
@export var start_entry_tag: String = "default"
@export var auto_start: bool = true

func _ready() -> void:
	if not auto_start:
		return
	
	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm == null:
		push_error("[BootArea] SceneMgr autoload not found. Add it in Project Settings → Autoload.")
		return
	
	var target_area: String = start_area
	var target_entry_tag: String = start_entry_tag
	
	# If we have a SaveSys autoload and a last_loaded_payload, prefer that.
	var save_sys: Node = get_node_or_null("/root/SaveSys")
	if save_sys != null and save_sys.has_method("get_last_loaded_payload"):
		var payload_any: Variant = save_sys.call("get_last_loaded_payload")
		if typeof(payload_any) == TYPE_DICTIONARY:
			var payload: Dictionary = payload_any

			# --- DEBUG: inspect the loaded payload and story_state ---
			print("[BootArea] Loaded payload: ", payload)
			if payload.has("story_state"):
				print("[BootArea] story_state: ", payload["story_state"])
			else:
				print("[BootArea] No story_state in payload.")

			if payload.has("area_path"):
				target_area = str(payload["area_path"])
			if payload.has("entry_tag"):
				target_entry_tag = str(payload["entry_tag"])
			
			# --- Apply story state from the save, if present ---
			if payload.has("story_state"):
				var story_state_any: Variant = payload["story_state"]
				if typeof(story_state_any) == TYPE_DICTIONARY:
					var story_state: Dictionary = story_state_any
					var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
					if story != null:
						story.apply_save_state(story_state)
	
	if sm.has_method("change_area"):
		# This is safe: SceneManager defers the actual swap internally.
		sm.call("change_area", target_area, target_entry_tag)
