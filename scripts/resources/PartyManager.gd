@icon("res://icon.svg")
extends Node
class_name PartyManager

signal controlled_changed(current: Node)
signal party_changed(members: Array)

var _members: Array[Node] = []
var _controlled_idx: int = -1

# --- Public API ----------------------------------------------------

func add_member(member: Node, make_controlled: bool = false) -> void:
	if member in _members:
		return
	_members.append(member)
	emit_signal("party_changed", _members.duplicate())
	if make_controlled or _controlled_idx == -1:
		_set_controlled_by_index(_members.size() - 1)

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
	# If we removed the controlled character, clamp to a valid one.
	if idx == _controlled_idx:
		_set_controlled_by_index(min(idx, _members.size() - 1))
	else:
		# Adjust index if we removed one before the controlled index.
		if idx < _controlled_idx:
			_controlled_idx -= 1
		emit_signal("party_changed", _members.duplicate())

func get_members() -> Array[Node]:
	return _members

func get_controlled() -> Node:
	if _controlled_idx < 0 or _controlled_idx >= _members.size():
		return null
	return _members[_controlled_idx]

func next() -> void:
	if _members.size() <= 1:
		return
	var nxt := (_controlled_idx + 1) % _members.size()
	_set_controlled_by_index(nxt)

func prev() -> void:
	if _members.size() <= 1:
		return
	var prv := (_controlled_idx - 1 + _members.size()) % _members.size()
	_set_controlled_by_index(prv)

func set_controlled(target: Node) -> void:
	var idx := _members.find(target)
	if idx >= 0:
		_set_controlled_by_index(idx)

# --- Internal ------------------------------------------------------

func _set_controlled_by_index(new_idx: int) -> void:
	if new_idx == _controlled_idx:
		return
	_controlled_idx = clampi(new_idx, 0, max(0, _members.size() - 1))
	emit_signal("controlled_changed", get_controlled())
	emit_signal("party_changed", _members.duplicate())
