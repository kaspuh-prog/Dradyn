@icon("res://icon.svg")
extends Node
class_name PartyManager

signal controlled_changed(current: Node)
signal party_changed(members: Array)

var _members: Array[Node] = []
var _controlled_idx: int = -1

# --- Public API ----------------------------------------------------

func add_member(member: Node, make_controlled: bool = false) -> void:
    if member == null: return
    if _members.has(member): return
    _members.append(member)
    emit_signal("party_changed", _members.duplicate())
    if make_controlled:
        set_controlled(_members.size() - 1)

func remove_member(member: Node) -> void:
    var i := _members.find(member)
    if i == -1: return
    var was_controlled := (i == _controlled_idx)
    _members.remove_at(i)
    if was_controlled:
        _controlled_idx = -1
        _apply_control(null)
    # Re-normalize controlled index (keep same index if possible)
    if _members.size() > 0 and _controlled_idx == -1:
        set_controlled(min(i, _members.size() - 1))
    emit_signal("party_changed", _members.duplicate())

func get_members() -> Array[Node]:
    return _members.duplicate()

func get_controlled() -> Node:
    if _controlled_idx >= 0 and _controlled_idx < _members.size():
        return _members[_controlled_idx]
    return null

func set_controlled(member_or_index: Variant) -> void:
    var idx := -1
    if typeof(member_or_index) == TYPE_INT:
        idx = int(member_or_index)
    else:
        idx = _members.find(member_or_index)
    if idx < 0 or idx >= _members.size():
        return
    if idx == _controlled_idx:
        return
    _controlled_idx = idx
    _apply_control(get_controlled())

func cycle_control(direction: int = 1) -> void:
    if _members.is_empty(): return
    if _controlled_idx == -1:
        set_controlled(0)
        return
    var n := _members.size()
    var step := (1 if direction >= 0 else -1)
    var next := (_controlled_idx + step) % n
    if next < 0:
        next += n
    set_controlled(next)

func _unhandled_input(event: InputEvent) -> void:
    # Optional guard so swap doesn't fire while typing in a LineEdit
    var f := get_viewport().gui_get_focus_owner()
    if f and f is LineEdit and f.editable:
        return

    if Input.is_action_just_pressed("party_next"):
        cycle_control(1)
        get_viewport().set_input_as_handled()
 

  
# --- Helpers -------------------------------------------------------

func _apply_control(now: Node) -> void:
    # Update each member's control state, groups, and motion ownership
    for n in _members:
        var is_leader := (n == now)

        # Group flag for convenience (Player.gd reads this in _ready)
        if is_leader and not n.is_in_group("player_controlled"):
            n.add_to_group("player_controlled")
        elif (not is_leader) and n.is_in_group("player_controlled"):
            n.remove_from_group("player_controlled")

        # Player script lives on the same root as the body
        if n.has_method("on_control_gain") and is_leader:
            n.on_control_gain()
        elif n.has_method("on_control_loss") and not is_leader:
            n.on_control_loss()

        # Follower node is a child named "CompanionFollow" (class CompanionFollow)
        var follow := n.get_node_or_null("CompanionFollow")
        if follow:
            if follow.has_method("enable_follow"):
                follow.enable_follow(not is_leader)
            if follow.has_method("set_motion_ownership"):
                follow.set_motion_ownership(not is_leader)

    emit_signal("controlled_changed", now)

func _emit_control_change(now: Node) -> void:
    emit_signal("controlled_changed", now)

func to_dict() -> Dictionary:
    return {
        "controlled_index": _controlled_idx,
        "member_paths": _members.map(func(m): return m.get_path() if m and m.is_inside_tree() else "")
    }

func from_dict(d: Dictionary) -> void:
    var idx := int(d.get("controlled_index", -1))
    if idx >= 0 and idx < _members.size():
        set_controlled(idx)
