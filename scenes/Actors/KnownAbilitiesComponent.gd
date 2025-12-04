extends Node
class_name KnownAbilitiesComponent
# Godot 4.5 — fully typed, no ternaries.

@export var known_abilities: PackedStringArray = []

# Optional: wire directly to a SkillTreeMediator in your scene.
@export var skill_tree_mediator_path: NodePath
@export var sync_on_ready: bool = true

signal abilities_changed(current: PackedStringArray)

func _ready() -> void:
	# Optionally sync from a SkillTreeMediator so we never have to seed by hand.
	if sync_on_ready:
		_try_initial_sync_from_mediator()
		_try_listen_for_future_unlocks()

# ---------------------------------------------
# Public API (unchanged)
# ---------------------------------------------
func has_ability(id: String) -> bool:
	if id == "":
		return false
	return known_abilities.has(id)

func add_ability(id: String) -> void:
	if id == "":
		return
	if not known_abilities.has(id):
		known_abilities.append(id)
		abilities_changed.emit(known_abilities)

func remove_ability(id: String) -> void:
	if id == "":
		return
	if known_abilities.has(id):
		known_abilities.erase(id)
		abilities_changed.emit(known_abilities)

func clear_all() -> void:
	if known_abilities.is_empty():
		return
	known_abilities.clear()
	abilities_changed.emit(known_abilities)

func get_all() -> PackedStringArray:
	return known_abilities.duplicate()

# ---------------------------------------------
# Mediator integration (optional / non-breaking)
# ---------------------------------------------
func _try_initial_sync_from_mediator() -> void:
	var mediator: Node = _resolve_skill_tree_mediator()
	if mediator == null:
		return

	# If the mediator provides a method to fetch all unlocked abilities for this actor,
	# use it to seed our list. This is additive; we keep anything already present.
	if mediator.has_method("get_unlocked_for"):
		var actor: Node = _resolve_actor_root()
		var v: Variant = mediator.call("get_unlocked_for", actor)
		if typeof(v) == TYPE_PACKED_STRING_ARRAY:
			var unlocked: PackedStringArray = v
			var i: int = 0
			while i < unlocked.size():
				var aid: String = unlocked[i]
				if aid != "" and not known_abilities.has(aid):
					known_abilities.append(aid)
				i += 1
			abilities_changed.emit(known_abilities)

func _try_listen_for_future_unlocks() -> void:
	var mediator: Node = _resolve_skill_tree_mediator()
	if mediator == null:
		return

	# If the mediator exposes a future-friendly signal, wire it:
	# signal ability_unlocked(actor: Node, ability_id: String)
	if mediator.has_signal("ability_unlocked"):
		if not mediator.is_connected("ability_unlocked", Callable(self, "_on_mediator_ability_unlocked")):
			mediator.connect("ability_unlocked", Callable(self, "_on_mediator_ability_unlocked"))

func _on_mediator_ability_unlocked(actor: Node, ability_id: String) -> void:
	# Only react for our owning actor
	var me: Node = _resolve_actor_root()
	if actor == me:
		add_ability(ability_id)

# ---------------------------------------------
# Helpers: locate mediator and our owning actor
# ---------------------------------------------
func _resolve_skill_tree_mediator() -> Node:
	# 1) Explicit path (preferred)
	if skill_tree_mediator_path != NodePath():
		var n: Node = get_node_or_null(skill_tree_mediator_path)
		if n != null:
			return n

	# 2) Search upward from our owner (common case: mediator lives in the same UI scene)
	var owner_root: Node = _resolve_actor_root()
	if owner_root != null:
		var top: Node = owner_root.get_tree().root
		if top != null:
			# BFS for a node named/classed like SkillTreeMediator
			var queue: Array[Node] = [top]
			while queue.size() > 0:
				var cur: Node = queue.pop_front()
				# Match by class_name or script name if available
				if cur.get_class() == "SkillTreeMediator" or cur.name.find("SkillTreeMediator") != -1:
					return cur
				for c in cur.get_children():
					queue.push_back(c)

	return null

func _resolve_actor_root() -> Node:
	# Owning actor is normally the parent of this component; fall back to owner.
	if get_parent() != null:
		return get_parent()
	return owner
