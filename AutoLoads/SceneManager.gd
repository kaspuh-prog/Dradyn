# res://autoloads/SceneManager.gd (Godot 4.5)
extends Node
class_name SceneManager

@onready var world_root: Node = null
var _current_area: Node = null

func _ready() -> void:
	# Find WorldRoot in the running GameRoot
	world_root = get_tree().root.find_child("WorldRoot", true, false)

func change_area(area_scene_path: String, entry_tag: String = "default") -> void:
	# Optional: fade out here
	_unload_current_area()
	var packed: PackedScene = load(area_scene_path)
	_current_area = packed.instantiate()
	world_root.add_child(_current_area)

	# Position the party at the entry point
	var spawn := _find_entry_point(_current_area, entry_tag)
	if spawn and Party:  # Party is an autoload singleton
		Party.place_at(spawn.global_position, spawn.get("facing") if spawn.has_method("get") else null)

	# Optional: retarget camera to PartyManager's leader here
	# Optional: fade in here

func _unload_current_area() -> void:
	if _current_area and is_instance_valid(_current_area):
		_current_area.queue_free()
		_current_area = null

func _find_entry_point(area: Node, tag: String) -> Node2D:
	# Convention: entry markers live under "EntryPoints" and are named/tagged
	var entry_points := area.find_child("EntryPoints", true, false)
	if entry_points:
		for child in entry_points.get_children():
			if child is Node2D and (child.name == tag or (child.has_meta("tag") and child.get_meta("tag") == tag)):
				return child
	# Fallback: any node named "Spawn" or first Marker2D we find
	var spawn := area.find_child("Spawn", true, false)
	if spawn is Node2D:
		return spawn
	for n in area.get_children():
		if n is Marker2D:
			return n
	return null
	
	
