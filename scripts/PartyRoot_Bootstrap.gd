extends Node2D
# PartyRoot_Bootstrap.gd

@export var leader_scene: PackedScene
@export var companion_scenes: Array[PackedScene] = []

@onready var _pm: Node = get_tree().get_first_node_in_group("PartyManager")

func _ready() -> void:
	# Spawn if no CharacterBody2D children yet (ignores stray placeholders)
	if _count_actor_bodies() == 0:
		_spawn_party()

	# Hook SceneManager whether it's an autoload or a node in GameRoot
	var sm := get_tree().root.find_child("SceneManager", true, false)
	if sm and not sm.is_connected("area_changed", Callable(self, "_on_area_changed")):
		sm.connect("area_changed", Callable(self, "_on_area_changed"))
		# Fallback: if an area is already mounted, try to locate an entry and place now.
		var entry := _find_entry_marker()
		if entry:
			_on_area_changed(sm, entry)

func _spawn_party() -> void:
	if leader_scene:
		var leader := leader_scene.instantiate()
		add_child(leader)
		if _pm and _pm.has_method("add_member"):
			_pm.add_member(leader, true)  # make leader controlled
	for ps in companion_scenes:
		if ps == null: continue
		var c := ps.instantiate()
		add_child(c)
		if _pm and _pm.has_method("add_member"):
			_pm.add_member(c, false)
	# If PartyManager lacked add_member(), do your own grouping/registration here

func _on_area_changed(_area: Node, entry_marker: Node2D) -> void:
	if entry_marker:
		_teleport_party(entry_marker.global_position)

func _teleport_party(pos: Vector2) -> void:
	var i := 0
	for child in get_children():
		if child is Node2D:
			(child as Node2D).global_position = pos + Vector2(-12 * i, 8 * i)
			i += 1

func _count_actor_bodies() -> int:
	var n := 0
	for c in get_children():
		if c is CharacterBody2D:
			n += 1
	return n

func _find_entry_marker() -> Node2D:
	# Look for EntryPoints/default in the mounted area under WorldRoot
	var world_root := get_tree().root.find_child("WorldRoot", true, false)
	if not world_root or world_root.get_child_count() == 0:
		return null
	var area := world_root.get_child(0)
	var eps := area.find_child("EntryPoints", true, false)
	if eps:
		var def := eps.find_child("default", false, false)
		if def is Node2D:
			return def
		# any Marker2D under EntryPoints as fallback
		for ch in eps.get_children():
			if ch is Node2D:
				return ch
	# ultimate fallback: first Marker2D in area
	return area.find_child("", true, false) as Node2D
