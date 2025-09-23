@icon("res://icon.svg")
extends Node
class_name PartyManager

signal controlled_changed(current: Node)
signal party_changed(members: Array)

var _members: Array[Node] = []
var _controlled_idx: int = -1

const ACTION_PARTY_NEXT := "party_next"

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------
func _ready() -> void:
	# It's OK if members are added later; add_member() will set the first leader.
    if _members.is_empty():
        print("[Party] _ready: no members yet (actors will register themselves)")
        return

    if _controlled_idx < 0 or _controlled_idx >= _members.size():
        _controlled_idx = 0
    _set_controlled_by_index(_controlled_idx)

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------
func add_member(member: Node, make_controlled: bool = false) -> void:
    if member in _members:
        return
    _members.append(member)
    emit_signal("party_changed", _members.duplicate())
    print("[Party] add_member: ", member.name, " leader=", make_controlled, " size=", _members.size()+1)

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

func next_controlled() -> void:
    if _members.is_empty():
        return
    _set_controlled_by_index((_controlled_idx + 1) % _members.size())

# Alias for any older code that might call Party.next()
func next() -> void:
    next_controlled()

func _refresh_followers() -> void:
    var leader := get_controlled()
    if leader == null:
        return

    for m in _members:
        if m == leader:
            continue

        # Preferred API on actor:
        if m.has_method("set_follow_target"):
            m.set_follow_target(leader)
            continue

        # Fallback: find a CompanionFollow child anywhere under the actor
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
