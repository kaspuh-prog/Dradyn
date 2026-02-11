extends Node
class_name RenderLayerProbe
# Godot 4.5 — fully typed, no ternaries.
#
# Purpose:
# Quickly identify WHICH TileMapLayer (or other CanvasItem) is responsible for a weird
# “rectangle goes dark / unlit” rendering artifact.
#
# Controls (while running):
#   [   previous layer
#   ]   next layer
#   V   toggle visible on selected layer
#   P   print details of selected layer
#
# Usage:
# 1) Add a Node named "RenderProbe" somewhere in the running Area scene.
# 2) Attach this script to it.
# 3) Play, walk to the glitch rectangle, then toggle layers until the artifact disappears.
# 4) Tell me which layer index/name/path causes it.

@export var debug_logging: bool = true
@export var include_non_tilemap_canvas_items: bool = false
@export var max_non_tilemap_items: int = 64

var _items: Array[CanvasItem] = []
var _labels: Array[String] = []
var _index: int = 0

func _ready() -> void:
	_rebuild_list()
	if _items.is_empty():
		push_warning("[RenderLayerProbe] No layers found.")
		return
	_print_current("ready")

func _unhandled_input(event: InputEvent) -> void:
	var ek: InputEventKey = event as InputEventKey
	if ek == null:
		return
	if not ek.pressed:
		return
	if ek.echo:
		return

	if ek.keycode == KEY_BRACKETLEFT:
		_prev()
	elif ek.keycode == KEY_BRACKETRIGHT:
		_next()
	elif ek.keycode == KEY_V:
		_toggle_visible()
	elif ek.keycode == KEY_P:
		_print_current("print")

func _rebuild_list() -> void:
	_items.clear()
	_labels.clear()
	_index = 0

	var root: Node = get_tree().current_scene
	if root == null:
		return

	var all: Array[Node] = []
	_collect_nodes(root, all)

	# Prioritize TileMapLayer first.
	for n in all:
		var tml: TileMapLayer = n as TileMapLayer
		if tml != null:
			var ci: CanvasItem = tml as CanvasItem
			_items.append(ci)
			_labels.append(_label_for_node(n))

	# Optionally include other CanvasItems (limited).
	if include_non_tilemap_canvas_items:
		var added_non: int = 0
		for n2 in all:
			if added_non >= max_non_tilemap_items:
				break

			var tml2: TileMapLayer = n2 as TileMapLayer
			if tml2 != null:
				continue

			var ci2: CanvasItem = n2 as CanvasItem
			if ci2 == null:
				continue

			_items.append(ci2)
			_labels.append(_label_for_node(n2))
			added_non += 1

	if debug_logging:
		print("[RenderLayerProbe] Found CanvasItems=", _items.size(), " (TileMapLayer-only=", not include_non_tilemap_canvas_items, ")")

func _collect_nodes(node: Node, out: Array[Node]) -> void:
	out.append(node)
	var i: int = 0
	while i < node.get_child_count():
		var c: Node = node.get_child(i)
		_collect_nodes(c, out)
		i += 1

func _label_for_node(n: Node) -> String:
	return n.name + " @ " + String(n.get_path())

func _prev() -> void:
	if _items.is_empty():
		return
	_index -= 1
	if _index < 0:
		_index = _items.size() - 1
	_print_current("prev")

func _next() -> void:
	if _items.is_empty():
		return
	_index += 1
	if _index >= _items.size():
		_index = 0
	_print_current("next")

func _toggle_visible() -> void:
	var ci: CanvasItem = _current_item()
	if ci == null:
		return
	ci.visible = not ci.visible
	_print_current("toggle_visible")

func _current_item() -> CanvasItem:
	if _items.is_empty():
		return null
	if _index < 0 or _index >= _items.size():
		return null
	var ci: CanvasItem = _items[_index]
	if ci == null:
		return null
	if not is_instance_valid(ci):
		return null
	return ci

func _print_current(context: String) -> void:
	if not debug_logging:
		return
	var ci: CanvasItem = _current_item()
	if ci == null:
		print("[RenderLayerProbe] (", context, ") no current item")
		return

	var n: Node = ci as Node
	var label: String = ""
	if _index >= 0 and _index < _labels.size():
		label = _labels[_index]
	else:
		label = _label_for_node(n)

	var mat_name: String = "null"
	if ci.material != null:
		mat_name = ci.material.get_class()

	print("[RenderLayerProbe] (", context, ") idx=", _index, "/", _items.size() - 1,
		" visible=", ci.visible,
		" light_mask=", ci.light_mask,
		" visibility_layer=", ci.visibility_layer,
		" modulate=", ci.modulate,
		" material=", mat_name,
		" :: ", label
	)
