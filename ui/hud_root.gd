extends Control

@export var left_margin: int = 1
@export var bottom_margin: int = 1
@export var spacing: int = 4
@export var max_members: int = 4
@export var stats_node_name_hint: String = "StatsComponent"
@export var always_show_at_least_one: bool = true
@export var debug_logs: bool = true

@onready var holder: Control = $"Panel1Holder"
@onready var template_panel: Control = $"Panel1Holder/PartyPanel"

var _unit_w: float = 0.0
var _unit_h: float = 0.0

func _ready() -> void:
    # Keep HUD on top
    z_as_relative = false
    z_index = 100
    visible = true

    if holder != null:
        holder.clip_contents = false
        holder.visible = true
        holder.z_as_relative = false
        holder.z_index = 100

    if template_panel != null:
        # Freeze the template so it NEVER stretches with parent
        _freeze_panel_layout(template_panel)

        # Capture the true unit size ONCE and reuse forever
        _unit_w = template_panel.size.x
        _unit_h = template_panel.size.y
        if _unit_w <= 0.0:
            _unit_w = 73.0  # safe fallback
        if _unit_h <= 0.0:
            _unit_h = 37.0

        if debug_logs:
            print("[HUD] unit size locked: ", Vector2(_unit_w, _unit_h))

        template_panel.visible = false
        template_panel.position = Vector2.ZERO

    _place_holder()
    get_viewport().size_changed.connect(_place_holder)

    _rebuild_party_panels()

    var pm: Node = _get_party()
    if pm != null and pm.has_signal("party_changed"):
        pm.party_changed.connect(_on_party_changed)

    # Failsafe: show template if nothing visible yet
    if not _any_panel_visible() and template_panel != null:
        template_panel.visible = true
        _place_holder()
        if debug_logs:
            print("[HUD] Failsafe: forced template visible")

func _freeze_panel_layout(p: Control) -> void:
    # Anchor to top-left, disable growing/expanding so parent size won't stretch us
    p.set_anchors_preset(Control.PRESET_TOP_LEFT)
    p.anchor_left = 0.0
    p.anchor_top = 0.0
    p.anchor_right = 0.0
    p.anchor_bottom = 0.0
    # Don’t let containers/parents resize it.
    p.size_flags_horizontal = 0
    p.size_flags_vertical = 0
    # Lock the visual size to whatever the template is in the editor
    var sz: Vector2 = p.size
    if sz.x <= 0.0 or sz.y <= 0.0:
        # If size was zero at runtime, trust custom_minimum_size or use a small fallback
        var cms: Vector2 = p.custom_minimum_size
        if cms.x > 0.0 and cms.y > 0.0:
            sz = cms
        else:
            sz = Vector2(73, 37)
    p.size = sz

func _on_party_changed(_members: Array) -> void:
    if debug_logs:
        print("[HUD] party_changed received, members.size=", _members.size())
    _rebuild_party_panels()

# ------------------------ layout ------------------------
func _place_holder() -> void:
    if holder == null or template_panel == null:
        return

    # Position bottom-left
    var vp_h: float = get_viewport_rect().size.y
    holder.position = Vector2(float(left_margin), vp_h - float(bottom_margin) - _unit_h)

    # OPTIONAL: we can size the holder to fit exactly the visible panels using the LOCKED unit width
    var count: int = _count_visible_panels()
    if count < 1:
        count = 1
    var total_w: float = (_unit_w * float(count)) + (float(spacing) * float(max(0, count - 1)))
    holder.size = Vector2(total_w, _unit_h)

func _count_visible_panels() -> int:
    if holder == null:
        return 0
    var n: int = 0
    for c in holder.get_children():
        var cc: Control = c as Control
        if cc != null and cc.visible:
            n += 1
    return n

# ------------------------ build ------------------------
func _rebuild_party_panels() -> void:
    if holder == null or template_panel == null:
        if debug_logs:
            print("[HUD] holder/template missing")
        return

    # Clear clones (keep template)
    for c in holder.get_children():
        if c != template_panel:
            (c as Node).queue_free()
    await get_tree().process_frame

    var stats_list: Array[Node] = _resolve_party_stats()
    var need: int = min(max_members, stats_list.size())
    if need == 0 and always_show_at_least_one:
        need = 1

    var panels: Array[Control] = []
    for i in range(need):
        var p: Control
        if i == 0:
            p = template_panel
        else:
            p = template_panel.duplicate() as Control
            holder.add_child(p)
            _freeze_panel_layout(p)
        p.visible = true
        # Only position horizontally using LOCKED unit width; never scale
        p.position = Vector2(float(i) * (_unit_w + float(spacing)), 0.0)
        panels.append(p)

    # Bind first N stats to N panels
    var bind_count: int = min(need, stats_list.size())
    for i in range(bind_count):
        var stats_node: Node = stats_list[i]
        var p2: Control = panels[i]
        if p2 != null and stats_node != null:
            if p2.has_method("set_stats_node"):
                p2.call("set_stats_node", stats_node)
            elif _has_property(p2, "stats_path"):
                p2.set("stats_path", stats_node.get_path())

    await get_tree().process_frame
    _place_holder()

# ------------------------ party resolution ------------------------
func _get_party() -> Node:
    return get_node_or_null("/root/Party")

func _resolve_party_stats() -> Array[Node]:
    var out: Array[Node] = []
    var pm: Node = _get_party()
    if pm == null:
        if debug_logs:
            print("[HUD] Party autoload not found at /root/Party")
        return out

    if pm.has_method("get_members"):
        var members: Array = pm.call("get_members")
        if debug_logs:
            print("[HUD] get_members -> ", members.size())
        for m in members:
            var n: Node = _coerce_to_stats_node(m)
            if n != null:
                out.append(n)
            elif debug_logs:
                var nm: String = "<non-node>"
                if m is Node:
                    nm = (m as Node).name
                print("[HUD]   could not find StatsComponent under ", nm)
    else:
        if debug_logs:
            print("[HUD] Party has no get_members()")
    return out

func _coerce_to_stats_node(item: Variant) -> Node:
    if item is Node:
        var n: Node = item
        # exact child name first (your hint)
        if stats_node_name_hint != "":
            var hinted: Node = n.get_node_or_null(stats_node_name_hint)
            if hinted != null and _is_stats_like(hinted):
                return hinted
            var deep: Node = n.find_child(stats_node_name_hint, true, false)
            if deep != null and _is_stats_like(deep):
                return deep
        # fallbacks
        var s: Node = n.get_node_or_null("StatsComponent")
        if s != null and _is_stats_like(s):
            return s
        var s2: Node = n.find_child("StatsComponent", true, false)
        if s2 != null and _is_stats_like(s2):
            return s2
        var s3: Node = n.get_node_or_null("Stats")
        if s3 != null and _is_stats_like(s3):
            return s3
        var s4: Node = n.find_child("Stats", true, false)
        if s4 != null and _is_stats_like(s4):
            return s4
    return null

func _is_stats_like(n: Node) -> bool:
    if n == null:
        return false
    if n.has_signal("hp_changed") and n.has_signal("mp_changed") and n.has_signal("end_changed"):
        return true
    if n.has_method("max_hp") and n.has_method("max_mp") and n.has_method("max_end"):
        return true
    var props: Array[Dictionary] = n.get_property_list()
    for p in props:
        var nm: String = String(p.get("name"))
        if nm == "current_hp" or nm == "current_mp" or nm == "current_end":
            return true
    return false

# ------------------------ utils ------------------------
func _has_property(obj: Object, prop_name: String) -> bool:
    if obj == null:
        return false
    var props: Array[Dictionary] = obj.get_property_list()
    for p in props:
        if String(p.get("name")) == prop_name:
            return true
    return false

func _any_panel_visible() -> bool:
    if holder == null:
        return false
    for c in holder.get_children():
        var cc: Control = c as Control
        if cc != null and cc.visible:
            return true
    return false
