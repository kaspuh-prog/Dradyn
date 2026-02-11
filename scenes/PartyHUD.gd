extends Control
class_name PartyHUD

@export var panel_scene: PackedScene          # assign PartyBarsPanel.tscn in Inspector
@export var x_start: int = 12
@export var y_start: int = 12
@export var x_spacing: int = 8                # pixels between panels when scaled
@export var panel_scale: float = 0.75         # overall scale applied to each panel

@onready var _row: Control = $"Row"

var _pm: PartyManager = null
var _panels: Array[PartyBarsPanel] = []
var _members: Array[Node] = []

func _ready() -> void:
	_pm = get_tree().get_first_node_in_group("PartyManager") as PartyManager
	if _pm == null:
		push_warning("PartyHUD: PartyManager not found.")
		return

	if not _pm.is_connected("party_changed", Callable(self, "_on_party_changed")):
		_pm.connect("party_changed", Callable(self, "_on_party_changed"))
	if not _pm.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
		_pm.connect("controlled_changed", Callable(self, "_on_controlled_changed"))

	# Initial build (in case members already exist)
	_rebuild_from(_pm.get_members())

func _on_party_changed(members: Array) -> void:
	_rebuild_from(members)

func _on_controlled_changed(current: Node) -> void:
	_refresh_highlight(current)

func _rebuild_from(members: Array) -> void:
	_clear_row()

	_members.clear()
	var x: int = x_start
	var i: int = 0
	while i < members.size():
		var m: Node = members[i]
		_members.append(m)

		var panel: PartyBarsPanel = _spawn_panel(m)
		panel.scale = Vector2(panel_scale, panel_scale)
		panel.position = Vector2(x, y_start)
		_panels.append(panel)

		var w: int = int(panel.size.x * panel.scale.x)
		x += w + x_spacing
		i += 1

	if _pm != null:
		_refresh_highlight(_pm.get_controlled())

func _spawn_panel(member: Node) -> PartyBarsPanel:
	var panel: PartyBarsPanel = panel_scene.instantiate() as PartyBarsPanel
	_row.add_child(panel)

	var stats: Node = _find_stats_on(member)

	# Hook stats into panel's Bars node (existing behavior)
	var bars: Node = panel.get_node_or_null("Bars")
	if bars == null:
		push_warning("PartyHUD: Bars node missing on panel.")
	else:
		if stats != null and "set_stats" in bars:
			bars.set_stats(stats)

	# NEW: let the panel track buffs from the same StatsComponent
	if stats != null and panel != null:
		if panel.has_method("set_stats_component"):
			panel.set_stats_component(stats)

	# Set display name using same rule as StatsHeaderBinder
	var display_name: String = _derive_actor_name(member)
	panel.set_display_name(display_name)

	panel.set_highlighted(false)

	return panel

func _clear_row() -> void:
	for c in _panels:
		if is_instance_valid(c):
			c.queue_free()
	_panels.clear()
	_members.clear()

func _find_stats_on(actor: Node) -> Node:
	if actor == null:
		return null
	if actor.has_node("StatsComponent"):
		return actor.get_node("StatsComponent")
	for ch in actor.get_children():
		if ch.name == "StatsComponent":
			return ch
	return null

func _derive_actor_name(actor: Node) -> String:
	if actor == null:
		return "Unknown"
	if actor.has_method("get_name"):
		return str(actor.get_name())
	return str(actor.name)

func _refresh_highlight(current: Node) -> void:
	var i: int = 0
	while i < _panels.size():
		var panel: PartyBarsPanel = _panels[i]
		if not is_instance_valid(panel):
			i += 1
			continue

		var member: Node = null
		if i < _members.size():
			member = _members[i]

		var is_highlighted: bool = false
		if member != null and current != null:
			if member == current:
				is_highlighted = true

		panel.set_highlighted(is_highlighted)
		i += 1
