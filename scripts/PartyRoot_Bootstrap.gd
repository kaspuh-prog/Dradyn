extends Node2D
# PartyRoot_Bootstrap.gd
#
# Fix: if a save payload specifies a different party roster than what's already
# under PartyRoot, rebuild the actor children to match the save roster.

@export var leader_scene: PackedScene
@export var companion_scenes: Array[PackedScene] = []

@onready var _pm: Node = get_tree().get_first_node_in_group("PartyManager")

var _has_saved_party_payload: bool = false
var _expected_scene_paths: PackedStringArray = PackedStringArray()

func _ready() -> void:
	# If a save payload was loaded (TitleScreen -> Continue), prefer party composition from that payload.
	_apply_party_composition_from_last_loaded_payload()

	# If actors already exist (e.g., Main.tscn has placeholders), but the save roster differs,
	# rebuild PartyRoot children to match the save roster.
	if _has_saved_party_payload:
		_rebuild_party_if_needed()

	# Spawn if no CharacterBody2D children yet (ignores stray placeholders)
	if _count_actor_bodies() == 0:
		_spawn_party()

	# Hook SceneManager whether it's an autoload or a node in GameRoot
	var sm: Node = get_tree().root.find_child("SceneManager", true, false)
	if sm != null:
		if not sm.is_connected("area_changed", Callable(self, "_on_area_changed")):
			sm.connect("area_changed", Callable(self, "_on_area_changed"))

		# Fallback: if an area is already mounted, try to locate an entry and place now.
		var entry: Node2D = _find_entry_marker()
		if entry != null:
			_on_area_changed(sm, entry)

func _apply_party_composition_from_last_loaded_payload() -> void:
	_has_saved_party_payload = false
	_expected_scene_paths = PackedStringArray()

	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		return

	var payload: Dictionary = save_sys.get_last_loaded_payload()
	if payload.is_empty():
		return

	if not payload.has("party"):
		return

	var party_any: Variant = payload["party"]
	if typeof(party_any) != TYPE_DICTIONARY:
		return
	var party: Dictionary = party_any

	if not party.has("members"):
		return

	var members_any: Variant = party["members"]
	if typeof(members_any) != TYPE_ARRAY:
		return
	var members: Array = members_any

	if members.is_empty():
		return

	var controlled_index: int = 0
	if party.has("controlled_index"):
		var ci_any: Variant = party["controlled_index"]
		if typeof(ci_any) == TYPE_INT:
			controlled_index = int(ci_any)

	if controlled_index < 0:
		controlled_index = 0
	if controlled_index >= members.size():
		controlled_index = 0

	# Resolve leader from controlled_index and companions from the remaining entries (in order).
	var leader_ps: PackedScene = _packed_scene_from_member(members, controlled_index)
	if leader_ps == null:
		return

	var companions_out: Array[PackedScene] = []

	var i: int = 0
	while i < members.size():
		if i != controlled_index:
			var ps: PackedScene = _packed_scene_from_member(members, i)
			if ps != null:
				companions_out.append(ps)
		i += 1

	# Apply
	leader_scene = leader_ps
	companion_scenes = companions_out

	# Track expected roster so we can rebuild if PartyRoot already has the wrong actors.
	_has_saved_party_payload = true
	_expected_scene_paths = _build_expected_scene_paths()

func _packed_scene_from_member(members: Array, index: int) -> PackedScene:
	if index < 0 or index >= members.size():
		return null

	var m_any: Variant = members[index]
	if typeof(m_any) != TYPE_DICTIONARY:
		return null
	var md: Dictionary = m_any

	if not md.has("scene_path"):
		return null

	var sp_any: Variant = md["scene_path"]
	if typeof(sp_any) != TYPE_STRING:
		return null

	var scene_path: String = String(sp_any).strip_edges()
	if scene_path == "":
		return null

	if not ResourceLoader.exists(scene_path):
		push_warning("[PartyRoot_Bootstrap] Missing saved party scene: %s" % scene_path)
		return null

	var res: Resource = ResourceLoader.load(scene_path)
	var ps: PackedScene = res as PackedScene
	if ps == null:
		push_warning("[PartyRoot_Bootstrap] Saved party scene is not a PackedScene: %s" % scene_path)
		return null

	return ps

func _build_expected_scene_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()

	if leader_scene != null:
		var lp: String = leader_scene.resource_path
		if lp != "":
			out.append(lp)

	for ps in companion_scenes:
		if ps == null:
			continue
		var p: String = ps.resource_path
		if p != "":
			out.append(p)

	return out

func _rebuild_party_if_needed() -> void:
	# If there are no actor bodies yet, just let _spawn_party() handle it.
	var existing_actor_count: int = _count_actor_bodies()
	if existing_actor_count == 0:
		return

	# If we somehow have no expected roster, do nothing.
	if _expected_scene_paths.is_empty():
		return

	var current_paths: PackedStringArray = _collect_current_actor_scene_paths()

	# If mismatch in size or any path differs, rebuild.
	if current_paths.size() != _expected_scene_paths.size():
		_rebuild_party_now()
		return

	var i: int = 0
	while i < current_paths.size():
		if current_paths[i] != _expected_scene_paths[i]:
			_rebuild_party_now()
			return
		i += 1

func _collect_current_actor_scene_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()

	for c in get_children():
		if not (c is CharacterBody2D):
			continue

		var n: Node = c as Node
		var p: String = ""

		# Prefer meta-tag (we set this on spawn).
		if n.has_meta("spawn_scene_path"):
			var any: Variant = n.get_meta("spawn_scene_path")
			if typeof(any) == TYPE_STRING:
				p = String(any)

		# Fallback to scene_file_path if present.
		if p == "":
			var nd: Node = c as Node
			p = nd.scene_file_path

		out.append(p)

	return out

func _rebuild_party_now() -> void:
	# 1) Gather existing actor nodes under PartyRoot
	var to_remove: Array[Node] = []
	for c in get_children():
		if c is CharacterBody2D:
			to_remove.append(c as Node)

	# 2) Unregister from PartyManager (if supported) and remove immediately from tree
	for n in to_remove:
		if _pm != null and _pm.has_method("remove_member"):
			_pm.remove_member(n)

		if n.get_parent() == self:
			remove_child(n)

		n.queue_free()

	# 3) Spawn the correct roster from the save-selected PackedScenes
	_spawn_party()

func _spawn_party() -> void:
	if leader_scene != null:
		var leader: Node = leader_scene.instantiate()
		add_child(leader)
		_tag_actor_scene_path(leader, leader_scene)

		if _pm != null and _pm.has_method("add_member"):
			_pm.add_member(leader, true) # make leader controlled

	for ps in companion_scenes:
		if ps == null:
			continue
		var c: Node = ps.instantiate()
		add_child(c)
		_tag_actor_scene_path(c, ps)

		if _pm != null and _pm.has_method("add_member"):
			_pm.add_member(c, false)

	# If PartyManager lacked add_member(), do your own grouping/registration here

func _tag_actor_scene_path(actor: Node, ps: PackedScene) -> void:
	if actor == null:
		return
	if ps == null:
		return

	# Store the originating scene path for SaveSystem to use even if actor.scene_file_path is empty.
	var p: String = ps.resource_path
	if p == "":
		return

	actor.set_meta("spawn_scene_path", p)

func _on_area_changed(_area: Node, entry_marker: Node2D) -> void:
	if entry_marker != null:
		_teleport_party(entry_marker.global_position)

func _teleport_party(pos: Vector2) -> void:
	var i: int = 0
	for child in get_children():
		if child is Node2D:
			(child as Node2D).global_position = pos + Vector2(-12.0 * float(i), 8.0 * float(i))
			i += 1

func _count_actor_bodies() -> int:
	var n: int = 0
	for c in get_children():
		if c is CharacterBody2D:
			n += 1
	return n

func _find_entry_marker() -> Node2D:
	# Look for EntryPoints/default in the mounted area under WorldRoot
	var world_root: Node = get_tree().root.find_child("WorldRoot", true, false)
	if world_root == null or world_root.get_child_count() == 0:
		return null

	var area: Node = world_root.get_child(0)
	var eps: Node = area.find_child("EntryPoints", true, false)
	if eps != null:
		var def: Node = eps.find_child("default", false, false)
		if def is Node2D:
			return def as Node2D

		# any Marker2D under EntryPoints as fallback
		for ch in eps.get_children():
			if ch is Node2D:
				return ch as Node2D

	# ultimate fallback: first Marker2D in area
	return area.find_child("", true, false) as Node2D
