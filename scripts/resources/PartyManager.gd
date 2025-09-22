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

func set_controlled(idx: int) -> void:
    if _members.is_empty(): 
        return
    idx = clamp(idx, 0, _members.size() - 1)
    if idx == _controlled_idx:
        return

    var prev := get_controlled()
    _controlled_idx = idx
    var cur := get_controlled()

    # Optional: toggle a 'controlled' flag if your actors expose it
    if is_instance_valid(prev) and prev.has_method("set_controlled"):
        prev.set_controlled(false)
    if is_instance_valid(cur) and cur.has_method("set_controlled"):
        cur.set_controlled(true)

    emit_signal("controlled_changed", cur)
    _refresh_followers()  # <-- make everyone else follow the new leader

func next_controlled() -> void:
    if _members.is_empty():
        return
    var next_idx := (_controlled_idx + 1) % _members.size()
    set_controlled(next_idx)

func _refresh_followers() -> void:
    var leader := get_controlled()
    if leader == null:
        return
    for m in _members:
        if m == leader:
            continue
        # Preferred: actor exposes set_follow_target(leader)
        if m.has_method("set_follow_target"):
            m.set_follow_target(leader)
        # Fallback: there is a CompanionFollow node on the actor
        elif m.has_node("CompanionFollow"):
            m.get_node("CompanionFollow").call("set_follow_target", leader)
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

# --- Internal ------------------------------------------------------

func _set_controlled_by_index(new_idx: int) -> void:
    if new_idx == _controlled_idx:
        return
    _controlled_idx = clampi(new_idx, 0, max(0, _members.size() - 1))
    emit_signal("controlled_changed", get_controlled())
    emit_signal("party_changed", _members.duplicate())
    
func _unhandled_input(event: InputEvent) -> void:
    if event.is_action_pressed("party_next"):
        print("[PartyManager] party_next pressed")
        next_controlled()
