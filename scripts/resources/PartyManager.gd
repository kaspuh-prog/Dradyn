@icon("res://icon.svg")
extends Node
class_name PartyManager

signal controlled_changed(current: Node)
signal party_changed(members: Array)

@onready var _cam: LeaderCamera = get_tree().get_first_node_in_group("LeaderCamera") as LeaderCamera

var _members: Array[Node] = []
var _controlled_idx: int = -1

const ACTION_PARTY_NEXT := "party_next"

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------
func _ready() -> void:
	# Defer so DamageNumberLayer is ready first
	call_deferred("_register_emitters_late")

	if _members.is_empty():
		print("[Party] _ready: no members yet (actors will register themselves)")
		return

	if _controlled_idx < 0 or _controlled_idx >= _members.size():
		_controlled_idx = 0
	_set_controlled_by_index(_controlled_idx)
	call_deferred("_update_camera_target_deferred")

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------
func add_member(member: Node, make_controlled: bool = false) -> void:
	if member in _members:
		return
	_members.append(member)
	emit_signal("party_changed", _members.duplicate())
	print("[Party] add_member: ", member.name, " leader=", make_controlled, " size=", _members.size()+1)

	# Register this actor's stats with the DamageNumberLayer
	_register_member_emitter(member)

	if make_controlled or _controlled_idx == -1:
		_set_controlled_by_index(_members.size() - 1)
	else:
		_refresh_followers()

func remove_member(member: Node) -> void:
	var idx := _members.find(member)
	if idx == -1:
		return
	_members.remove_at(idx)

	if _members.is_empty():
		_controlled_idx = -1
		emit_signal("party_changed", _members.duplicate())
		emit_signal("controlled_changed", null)
		return

	if idx == _controlled_idx:
		_set_controlled_by_index(min(idx, _members.size() - 1))
	else:
		emit_signal("party_changed", _members.duplicate())
		_refresh_followers()

func get_members() -> Array:
	return _members.duplicate()

func get_controlled() -> Node:
	if _controlled_idx >= 0 and _controlled_idx < _members.size():
		return _members[_controlled_idx]
	return null

# -------------------------------------------------------------------
# Control logic
# -------------------------------------------------------------------
func _set_controlled_by_index(idx: int) -> void:
	if _members.is_empty():
		return
	idx = clamp(idx, 0, _members.size() - 1)

	var prev := get_controlled()
	_controlled_idx = idx
	var cur := get_controlled()

	if prev != null and prev.has_method("set_controlled"):
		prev.set_controlled(false)
	if cur != null and cur.has_method("set_controlled"):
		cur.set_controlled(true)

	if cur != null:
		print("[Party] leader -> ", cur.name)
	else:
		print("[Party] leader -> null")

	emit_signal("controlled_changed", cur)
	_refresh_followers()
	_update_camera_target(cur)

func next_controlled() -> void:
	if _members.is_empty():
		return
	_set_controlled_by_index((_controlled_idx + 1) % _members.size())

func next() -> void:
	next_controlled()

func _refresh_followers() -> void:
	var leader := get_controlled()
	if leader == null:
		return
	for m in _members:
		if m == leader:
			continue
		if m.has_method("set_follow_target"):
			m.set_follow_target(leader)
			continue
		var cf := m.find_child("CompanionFollow", true, false)
		if cf != null and cf.has_method("set_follow_target"):
			cf.set_follow_target(leader)

# -------------------------------------------------------------------
# Input
# -------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_PARTY_NEXT):
		next_controlled()

func set_controlled(member: Node) -> void:
	var idx := _members.find(member)
	if idx != -1:
		_set_controlled_by_index(idx)

# -------------------------------------------------------------------
# DamageNumber hookup
# -------------------------------------------------------------------
func _register_emitters_late() -> void:
	for m in _members:
		_register_member_emitter(m)

func _register_member_emitter(member: Node) -> void:
	var stats := _find_stats_component(member)
	if stats == null:
		print("[Party] WARN: no StatsComponent found under ", member.name)
		return
	var anchor := _guess_anchor_from_stats(stats)
	get_tree().call_group("DamageNumberSpawners", "register_emitter", stats, anchor)
	print("[Party] registered emitter: member=", member.name, " stats=", stats, " anchor=", anchor)

# Find by name, then by type, then by signals (robust in any scene)
func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	# 1) common node names
	var by_name := root.find_child("StatsComponent", true, false)
	if by_name: return by_name
	by_name = root.find_child("Stats", true, false)
	if by_name: return by_name
	# 2) typed class (requires class_name StatsComponent in the script)
	if root is StatsComponent:
		return root
	for c in root.get_children():
		var found := _find_stats_component(c)
		if found != null:
			return found
	# 3) last resort: look for hp_changed + current_hp API
	if root.has_signal("hp_changed") and root.has_method("current_hp"):
		return root
	return null

func _guess_anchor_from_stats(stats_node: Node) -> Node2D:
	var n: Node = stats_node
	while n != null:
		if n is Node2D:
			return n as Node2D
		n = n.get_parent()
	return null

# -------------------------------------------------------------------
# Camera helpers (safe no-op if no LeaderCamera)
# -------------------------------------------------------------------
func _ensure_camera() -> void:
	if _cam == null:
		_cam = get_tree().get_first_node_in_group("LeaderCamera") as LeaderCamera

func _update_camera_target(n: Node) -> void:
	_ensure_camera()
	if _cam == null:
		return
	var n2d := n as Node2D
	if n2d != null:
		_cam.set_target(n2d)
		_cam.make_current()

func _update_camera_target_deferred() -> void:
	_update_camera_target(get_controlled())
