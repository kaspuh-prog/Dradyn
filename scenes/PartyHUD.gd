extends Control
class_name PartyHUD

@export var panel_scene: PackedScene          # assign PartyBarsPanel.tscn in Inspector
@export var x_start: int = 12
@export var y_start: int = 12
@export var x_spacing: int = 8                # pixels between panels when scaled
@export var panel_scale: float = 0.75         # overall scale applied to each panel

@onready var _row: Control = $"Row"

var _pm: PartyManager = null
var _panels: Array[Control] = []

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
	# Optional: highlight leader later if desired
	pass

func _rebuild_from(members: Array) -> void:
	_clear_row()

	var x: int = x_start
	var i: int = 0
	while i < members.size():
		var m: Node = members[i]
		var panel: Control = _spawn_panel(m)
		panel.scale = Vector2(panel_scale, panel_scale)

		panel.position = Vector2(x, y_start)
		_panels.append(panel)

		# Next x position: use panel’s unscaled width times scale, plus spacing
		var w: int = int(panel.size.x * panel.scale.x)
		x += w + x_spacing
		i += 1

func _spawn_panel(member: Node) -> Control:
	var panel: Control = panel_scene.instantiate() as Control
	_row.add_child(panel)

	# Find Bars node and hook stats
	var bars: Node = panel.get_node_or_null("Bars")
	if bars == null:
		push_warning("PartyHUD: Bars node missing on panel.")
	else:
		var stats: Node = _find_stats_on(member)
		if stats != null and "set_stats" in bars:
			bars.set_stats(stats)

	return panel

func _clear_row() -> void:
	for c in _panels:
		if is_instance_valid(c):
			c.queue_free()
	_panels.clear()

func _find_stats_on(actor: Node) -> Node:
	if actor == null:
		return null
	if actor.has_node("StatsComponent"):
		return actor.get_node("StatsComponent")
	# Shallow search fallback
	for ch in actor.get_children():
		if ch.name == "StatsComponent":
			return ch
	return null
