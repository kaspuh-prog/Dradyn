extends Node2D
# PartyRoot_Bootstrap.gd
#
# Fix: if a save payload specifies a different party roster than what's already
# under PartyRoot, rebuild the actor children to match the save roster.
#
# New-game customization integration:
# - Apply player name to the ACTOR (so PartyHUD/PartyBars show it)
# - Apply class_def to LevelComponent (so Stats tab + SkillTreeMediator see it)
# - Nudge UI/mediators by re-emitting PartyManager signals after we apply changes
#
# Appearance integration:
# - Supports optional behind layers in VisualRoot:
#     HairBehindSprite
#     CloakBehindSprite
#   When present, loads "<hair_id>_behind" into HairBehindSprite (case-insensitive file match).

@export var leader_scene: PackedScene
@export var companion_scenes: Array[PackedScene] = []

@onready var _pm: Node = get_tree().get_first_node_in_group("PartyManager")

var _has_saved_party_payload: bool = false
var _expected_scene_paths: PackedStringArray = PackedStringArray()

# one-shot guard so we don't reapply every area change
var _applied_customization: bool = false


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

	# apply customization after spawn/rebuild so it overwrites PC_Base defaults
	call_deferred("_apply_customization_from_save_if_present")

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

	# after rebuild, apply customization again (it needs to overwrite fresh instances)
	_applied_customization = false
	call_deferred("_apply_customization_from_save_if_present")

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


# ------------------------------------------------------------
# Apply player_customization onto leader (name + class + visuals)
# ------------------------------------------------------------
func _apply_customization_from_save_if_present() -> void:
	if _applied_customization:
		return

	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		return

	var payload: Dictionary = save_sys.get_last_loaded_payload()
	if payload.is_empty():
		return
	if not payload.has("player_customization"):
		return

	var pc_any: Variant = payload["player_customization"]
	if typeof(pc_any) != TYPE_DICTIONARY:
		return
	var pc: Dictionary = pc_any

	var leader: Node = _resolve_controlled_or_first_actor()
	if leader == null:
		return

	# 1) Apply the chosen name (PartyHUD/PartyBars uses actor.name)
	var did_name: bool = _apply_custom_name_to_actor(leader, payload, pc)

	# 2) Apply the chosen class onto LevelComponent (TabbedMenu + SkillTreeMediator use LevelComponent.class_def)
	var did_class: bool = _apply_custom_class_to_actor(leader, pc)

	# 3) Apply appearance visuals
	_apply_customization_to_actor_visuals(leader, pc)

	# If we changed identity/class after PartyHUD/mediators already bound, nudge them.
	if did_name or did_class:
		_notify_party_systems_identity_changed(leader)

	_applied_customization = true

func _resolve_controlled_or_first_actor() -> Node:
	if _pm != null and _pm.has_method("get_controlled"):
		var c_any: Variant = _pm.call("get_controlled")
		var c: Node = c_any as Node
		if c != null:
			return c

	for c2 in get_children():
		if c2 is CharacterBody2D:
			return c2 as Node

	return null

func _apply_custom_name_to_actor(actor: Node, payload: Dictionary, pc: Dictionary) -> bool:
	if actor == null:
		return false

	var desired: String = ""
	if payload.has("player_name"):
		desired = str(payload.get("player_name", "")).strip_edges()
	if desired == "":
		desired = str(pc.get("display_name", "")).strip_edges()

	if desired == "":
		return false

	desired = desired.replace("/", "_")
	desired = desired.replace(":", "_")
	desired = desired.replace("\\", "_")

	if actor.name == desired:
		return false

	actor.name = desired
	return true

func _apply_custom_class_to_actor(actor: Node, pc: Dictionary) -> bool:
	if actor == null:
		return false

	var class_path: String = str(pc.get("class_def_path", "")).strip_edges()
	if class_path == "":
		return false

	if not ResourceLoader.exists(class_path):
		push_warning("[PartyRoot_Bootstrap] class_def_path missing: %s" % class_path)
		return false

	var class_res: Resource = ResourceLoader.load(class_path)
	if class_res == null:
		push_warning("[PartyRoot_Bootstrap] failed to load class_def_path: %s" % class_path)
		return false

	# LevelComponent is the canonical source for class in UI + SkillTreeMediator.
	var level: Node = actor.get_node_or_null("LevelComponent")
	if level == null:
		level = actor.find_child("LevelComponent", true, false)

	# StatsComponent still gets the overlay (used by formulas/derived reads).
	var stats: Node = actor.get_node_or_null("StatsComponent")
	if stats == null:
		stats = actor.find_child("StatsComponent", true, false)

	var changed: bool = false

	if level != null:
		var already: bool = false
		if "class_def" in level:
			var cur: Variant = level.get("class_def")
			if cur == class_res:
				already = true

		if not already and "class_def" in level:
			level.set("class_def", class_res)
			changed = true

		if changed:
			if level.has_method("_apply_class_to_stats"):
				level.call("_apply_class_to_stats", true)
			if level.has_method("_force_refill_and_emit"):
				level.call("_force_refill_and_emit")
			if level.has_signal("points_changed"):
				level.emit_signal("points_changed", int(level.get("unspent_points")))
			if level.has_signal("skill_points_changed"):
				level.emit_signal("skill_points_changed", int(level.get("unspent_skill_points")), int(level.get("total_skill_points_awarded")))

	if stats != null:
		var did_stats: bool = false
		if stats.has_method("set_class_def"):
			stats.call("set_class_def", class_res)
			did_stats = true
		elif "class_def" in stats:
			stats.set("class_def", class_res)
			did_stats = true

		if did_stats:
			changed = true

	return changed

func _notify_party_systems_identity_changed(leader: Node) -> void:
	if _pm != null:
		if _pm.has_signal("party_changed") and _pm.has_method("get_members"):
			var members_any: Variant = _pm.call("get_members")
			if typeof(members_any) == TYPE_ARRAY:
				_pm.emit_signal("party_changed", members_any)

		if leader != null and _pm.has_signal("controlled_changed"):
			_pm.emit_signal("controlled_changed", leader)

func _apply_customization_to_actor_visuals(actor: Node, pc: Dictionary) -> void:
	if actor == null:
		return

	var gender_str: String = str(pc.get("gender", "male")).strip_edges().to_lower()
	var gender_folder: String = "Male"
	if gender_str == "female":
		gender_folder = "Female"

	var hair_id: String = str(pc.get("hair_id", "")).strip_edges()
	if hair_id == "":
		hair_id = "Short"

	# Resolve VisualRoot
	var vr: Node = actor.get_node_or_null("VisualRoot")
	if vr == null:
		vr = actor.find_child("VisualRoot", true, false)
	if vr == null:
		push_warning("[PartyRoot_Bootstrap] No VisualRoot found on actor: %s" % actor.name)
		return

	# Contract layer names
	var body: AnimatedSprite2D = vr.get_node_or_null("BodySprite") as AnimatedSprite2D
	var armor: AnimatedSprite2D = vr.get_node_or_null("ArmorSprite") as AnimatedSprite2D
	var hair: AnimatedSprite2D = vr.get_node_or_null("HairSprite") as AnimatedSprite2D

	# NEW: optional behind layers
	var hair_behind: AnimatedSprite2D = vr.get_node_or_null("HairBehindSprite") as AnimatedSprite2D
	var cloak_behind: AnimatedSprite2D = vr.get_node_or_null("CloakBehindSprite") as AnimatedSprite2D

	# Optional: set EquipmentVisuals.gender_folder if present so future equipment swaps use correct folder.
	var eqv: Node = actor.get_node_or_null("EquipmentVisuals")
	if eqv == null:
		eqv = actor.find_child("EquipmentVisuals", true, false)
	if eqv != null and "gender_folder" in eqv:
		if gender_folder == "Female":
			eqv.set("gender_folder", StringName("female"))
		else:
			eqv.set("gender_folder", StringName("male"))

	var root: String = "res://assets/sprites/characters/%s" % gender_folder

	# Force Body + Cloth + Hair
	if body != null:
		var body_frames: SpriteFrames = _load_frames_ci("%s/BodySprites" % root, "Body")
		if body_frames != null:
			body.sprite_frames = body_frames

	if armor != null:
		var cloth_frames: SpriteFrames = _load_frames_ci("%s/ArmorSprites" % root, "Cloth")
		if cloth_frames != null:
			armor.sprite_frames = cloth_frames

	if hair != null:
		var hair_frames: SpriteFrames = _load_frames_ci("%s/HairSprites" % root, hair_id)
		if hair_frames != null:
			hair.sprite_frames = hair_frames

	# NEW: behind hair frames: "<hair_id>_behind"
	if hair_behind != null:
		var behind_id: String = hair_id + "_behind"
		var hair_behind_frames: SpriteFrames = _load_frames_ci("%s/HairSprites" % root, behind_id)
		if hair_behind_frames != null:
			hair_behind.sprite_frames = hair_behind_frames
	# Cloak behind is left as a no-op until cloak selection is added to customization.
	# This keeps the layer ready without forcing any particular cloak frames.
	if cloak_behind != null:
		pass

func _load_frames_ci(dir_path: String, base_name: String) -> SpriteFrames:
	if dir_path.strip_edges() == "":
		return null
	if base_name.strip_edges() == "":
		return null

	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return null

	var want: String = base_name.to_lower()

	da.list_dir_begin()
	var fn: String = da.get_next()
	while fn != "":
		if not da.current_is_dir():
			var lower: String = fn.to_lower()
			var ok: bool = lower.ends_with(".res") or lower.ends_with(".tres")
			if ok:
				var base: String = fn.get_basename()
				if base.to_lower() == want:
					var full_path: String = "%s/%s" % [dir_path, fn]
					if ResourceLoader.exists(full_path):
						var r: Resource = load(full_path)
						return r as SpriteFrames
		fn = da.get_next()
	da.list_dir_end()

	return null
