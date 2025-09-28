@icon("res://icon.svg")
extends Node
class_name PartyManager

signal controlled_changed(current: Node)
signal party_changed(members: Array)

const ACTION_PARTY_NEXT := "party_next"
const GROUP_LEADER := "PartyLeader"

@onready var _cam: LeaderCamera = get_tree().get_first_node_in_group("LeaderCamera") as LeaderCamera

var _members: Array[Node] = []
var _controlled_idx: int = -1

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------
func _ready() -> void:
	# Discoverable by followers
	if not is_in_group("PartyManager"):
		add_to_group("PartyManager")

	# Damage numbers might not be ready on first frame
	call_deferred("_register_emitters_late")

	# Retarget after area swaps (autoload or child of GameRoot)
	var sm := get_tree().root.find_child("SceneManager", true, false)
	if sm and not sm.is_connected("area_changed", Callable(self, "_on_area_changed")):
		sm.connect("area_changed", Callable(self, "_on_area_changed"))

	# Initialize leader/camera if we already have members
	if not _members.is_empty():
		if _controlled_idx < 0 or _controlled_idx >= _members.size():
			_controlled_idx = 0
		_set_controlled_by_index(_controlled_idx)
		call_deferred("_update_camera_target_deferred")
		_emphasize_controlled_z()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------
func add_member(member: Node, make_controlled: bool = false) -> void:
	if member == null:
		return
	if member in _members:
		return
	_members.append(member)
	emit_signal("party_changed", _members.duplicate())
	_register_member_emitter(member)

	if make_controlled:
		_set_controlled_by_index(_members.size() - 1)
	else:
		if _controlled_idx == -1:
			_set_controlled_by_index(_members.size() - 1)
		else:
			_refresh_followers()
			_emphasize_controlled_z()

func register_member(member: Node, make_controlled: bool = false) -> void:
	add_member(member, make_controlled)

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
		var next_idx := idx
		if next_idx >= _members.size():
			next_idx = _members.size() - 1
		_set_controlled_by_index(next_idx)
	else:
		emit_signal("party_changed", _members.duplicate())
		_refresh_followers()
		_emphasize_controlled_z()

func get_members() -> Array:
	return _members.duplicate()

func get_controlled() -> Node:
	if _controlled_idx >= 0 and _controlled_idx < _members.size():
		return _members[_controlled_idx]
	return null

func set_controlled(member: Node) -> void:
	var idx := _members.find(member)
	if idx != -1:
		_set_controlled_by_index(idx)

# -------------------------------------------------------------------
# Control logic
# -------------------------------------------------------------------
func _set_controlled_by_index(idx: int) -> void:
	if _members.is_empty():
		return
	if idx < 0:
		idx = 0
	if idx >= _members.size():
		idx = _members.size() - 1

	var prev := get_controlled()
	_controlled_idx = idx
	var cur := get_controlled()

	if prev != null:
		if prev.has_method("set_controlled"):
			prev.set_controlled(false)
	if cur != null:
		if cur.has_method("set_controlled"):
			cur.set_controlled(true)

	_update_leader_group_flags()

	emit_signal("controlled_changed", cur)
	_refresh_followers()
	_update_camera_target(cur)
	_emphasize_controlled_z()

func next_controlled() -> void:
	if _members.is_empty():
		return
	var next_idx := _controlled_idx + 1
	if next_idx >= _members.size():
		next_idx = 0
	_set_controlled_by_index(next_idx)

func next() -> void:
	next_controlled()

# Followers: leader has no target; others chain up
func _refresh_followers() -> void:
	var count := _members.size()
	var leader := get_controlled()
	if leader == null:
		return

	_clear_follow_for_member(leader)
	_set_companion_active(leader, false)

	if count <= 1:
		return

	var prev := leader
	var i := 1
	while i < count:
		var idx := _controlled_idx + i
		if idx >= count:
			idx -= count
		var m := _members[idx]
		if m != leader:
			_set_follow_for_member(m, prev)
			_set_companion_active(m, true)
			prev = m
		i += 1

func _set_follow_for_member(m: Node, target: Node) -> void:
	if m == null:
		return
	if m.has_method("set_follow_target"):
		m.set_follow_target(target)
		return
	var cf := m.find_child("CompanionFollow", true, false)
	if cf != null:
		if cf.has_method("set_follow_target"):
			cf.set_follow_target(target)

func _clear_follow_for_member(m: Node) -> void:
	if m == null:
		return
	if m.has_method("set_follow_target"):
		m.set_follow_target(null)
		return
	var cf := m.find_child("CompanionFollow", true, false)
	if cf != null:
		if cf.has_method("set_follow_target"):
			cf.set_follow_target(null)

func _set_companion_active(m: Node, active: bool) -> void:
	if m == null:
		return
	if m.has_method("set_active"):
		m.call("set_active", active)
		return
	var cf := m.find_child("CompanionFollow", true, false)
	if cf != null:
		if cf.has_method("set_active"):
			cf.call("set_active", active)
		else:
			if cf.has_variable("_active"):
				cf.set("_active", active)
			else:
				if cf.has_variable("active"):
					cf.set("active", active)

func _update_leader_group_flags() -> void:
	var i := 0
	while i < _members.size():
		var m := _members[i]
		if m != null:
			if i == _controlled_idx:
				if not m.is_in_group(GROUP_LEADER):
					m.add_to_group(GROUP_LEADER)
			else:
				if m.is_in_group(GROUP_LEADER):
					m.remove_from_group(GROUP_LEADER)
		i += 1

# -------------------------------------------------------------------
# Input
# -------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_PARTY_NEXT):
		next_controlled()

# -------------------------------------------------------------------
# DamageNumber hookup
# -------------------------------------------------------------------
func _register_emitters_late() -> void:
	for m in _members:
		_register_member_emitter(m)

func _register_member_emitter(member: Node) -> void:
	var stats := _find_stats_component(member)
	if stats == null:
		return
	var anchor := _guess_anchor_from_stats(stats)
	get_tree().call_group("DamageNumberSpawners", "register_emitter", stats, anchor)

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var by_name := root.find_child("StatsComponent", true, false)
	if by_name:
		return by_name
	by_name = root.find_child("Stats", true, false)
	if by_name:
		return by_name
	if root is StatsComponent:
		return root
	for c in root.get_children():
		var found := _find_stats_component(c)
		if found != null:
			return found
	if root.has_signal("hp_changed"):
		if root.has_method("current_hp"):
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
# Camera helpers
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

# -------------------------------------------------------------------
# Visual Z helpers
# -------------------------------------------------------------------
func _set_visual_z_recursive(node: Node, z: int, relative: bool) -> void:
	if node is CanvasItem:
		var c := node as CanvasItem
		c.z_index = z
		c.z_as_relative = relative
	for ch in node.get_children():
		_set_visual_z_recursive(ch, z, relative)

func _emphasize_controlled_z() -> void:
	var leader := get_controlled()
	for m in _members:
		if m != null:
			var z := 0
			if m == leader:
				z = 1
			_set_visual_z_recursive(m, z, true)

# -------------------------------------------------------------------
# Scene change hook
# -------------------------------------------------------------------
func _on_area_changed(_area: Node, _entry: Node2D) -> void:
	_refresh_followers()
	_update_camera_target_deferred()
	_emphasize_controlled_z()
