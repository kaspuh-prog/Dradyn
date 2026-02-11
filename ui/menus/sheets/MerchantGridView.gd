extends Control
class_name MerchantGridView

signal selection_changed(index: int)
signal activated(index: int)
signal hovered(index: int)
signal sell_payload_dropped(data: Dictionary)

@export var cols: int = 6:
	set(value):
		if value < 1:
			value = 1
		cols = value
		_resize_items()
		queue_redraw()

@export var rows: int = 10:
	set(value):
		if value < 1:
			value = 1
		rows = value
		_resize_items()
		queue_redraw()

@export var cell_size: int = 16:
	set(value):
		if value < 1:
			value = 1
		cell_size = value
		queue_redraw()

@export var tex_slot_empty: Texture2D
@export var tex_hover_overlay: Texture2D
@export var tex_selected_overlay: Texture2D

@export_group("Selection Outline")
@export var selected_outline_enabled: bool = true
@export var selected_outline_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var selected_outline_width: float = 1.0

var _hover_index: int = -1
var _selected_index: int = -1

## Merchant stock entries by index (0..cols*rows-1).
## If null at an index, we draw an empty slot with no icon.
var _items: Array[ItemDef] = []

## When true, this grid accepts InventoryGridView drag payloads for selling.
var _sell_drop_enabled: bool = false


func _ready() -> void:
	_resize_items()
	queue_redraw()


func _resize_items() -> void:
	var total: int = cols * rows
	if _items.size() != total:
		_items.resize(total)


# -------------------------------------------------
# Public API
# -------------------------------------------------

func set_stock(items: Array[ItemDef]) -> void:
	var total: int = cols * rows
	_items.resize(total)

	var i: int = 0
	while i < total:
		var def: ItemDef = null
		if i < items.size():
			var it_v: Variant = items[i]
			if it_v is ItemDef:
				def = it_v
		_items[i] = def
		i += 1

	queue_redraw()

func clear_stock() -> void:
	var total: int = cols * rows
	_items.resize(total)

	var i: int = 0
	while i < total:
		_items[i] = null
		i += 1

	set_selected_index(-1)
	queue_redraw()

func get_item_at(index: int) -> ItemDef:
	if index < 0:
		return null
	var total: int = cols * rows
	if index >= total:
		return null
	if index >= _items.size():
		return null

	var it_v: Variant = _items[index]
	if it_v is ItemDef:
		return it_v
	return null

func is_slot_locked(index: int) -> bool:
	var total: int = cols * rows
	if index < 0:
		return true
	if index >= total:
		return true
	return false

func set_selected_index(index: int) -> void:
	var total: int = cols * rows
	var clamped: int = index

	if clamped < -1:
		clamped = -1
	if clamped >= total:
		clamped = total - 1

	if clamped == _selected_index:
		return

	_selected_index = clamped
	selection_changed.emit(_selected_index)
	queue_redraw()

func get_selected_index() -> int:
	return _selected_index

func set_sell_drop_enabled(enabled: bool) -> void:
	_sell_drop_enabled = enabled


# -------------------------------------------------
# Drag & drop (SELL)
# -------------------------------------------------

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not _sell_drop_enabled:
		return false
	if typeof(data) != TYPE_DICTIONARY:
		return false

	var d: Dictionary = data
	var t: String = String(d.get("type", ""))
	# Accept inventory items only (not hotbar, equipped, etc.).
	return t == "inv_item"

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not _sell_drop_enabled:
		return
	if typeof(data) != TYPE_DICTIONARY:
		return

	var d: Dictionary = data
	sell_payload_dropped.emit(d)


# -------------------------------------------------
# Input
# -------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		var idx: int = _index_at_local(motion.position)
		if idx != _hover_index:
			_hover_index = idx
			hovered.emit(_hover_index)
			queue_redraw()

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var idx_press: int = _index_at_local(mb.position)
				if idx_press >= 0:
					set_selected_index(idx_press)
			else:
				var idx_release: int = _index_at_local(mb.position)
				if idx_release >= 0 and idx_release == _selected_index:
					activated.emit(idx_release)


# -------------------------------------------------
# Layout helpers
# -------------------------------------------------

func _index_at_local(pos: Vector2) -> int:
	if pos.x < 0.0 or pos.y < 0.0:
		return -1

	var total_width: float = float(cols * cell_size)
	var total_height: float = float(rows * cell_size)

	if pos.x >= total_width or pos.y >= total_height:
		return -1

	var cx: int = int(pos.x) / cell_size
	var cy: int = int(pos.y) / cell_size
	var idx: int = cy * cols + cx
	return idx


# -------------------------------------------------
# Drawing
# -------------------------------------------------

func _draw() -> void:
	var total: int = cols * rows
	var i: int = 0

	while i < total:
		var cx: int = i % cols
		var cy: int = i / cols
		var pos: Vector2 = Vector2(float(cx * cell_size), float(cy * cell_size))
		var slot_rect: Rect2 = Rect2(pos, Vector2(float(cell_size), float(cell_size)))

		if tex_slot_empty != null:
			# Scale the empty slot art to exactly the cell rect.
			draw_texture_rect(tex_slot_empty, slot_rect, false)

		i += 1

	_draw_item_icons()
	_draw_overlays()

func _draw_item_icons() -> void:
	var total: int = cols * rows
	var i: int = 0

	# Draw each icon slightly inset so it never crowds the slot border.
	var inset: float = 1.0
	var icon_size: float = float(cell_size) - inset * 2.0
	if icon_size < 1.0:
		icon_size = float(cell_size)

	while i < total:
		if i < _items.size():
			var it_v: Variant = _items[i]
			if it_v is ItemDef:
				var def: ItemDef = it_v
				if def.icon != null:
					var cx: int = i % cols
					var cy: int = i / cols
					var base_pos: Vector2 = Vector2(float(cx * cell_size), float(cy * cell_size))
					var icon_pos: Vector2 = base_pos + Vector2(inset, inset)
					var rect: Rect2 = Rect2(icon_pos, Vector2(icon_size, icon_size))
					draw_texture_rect(def.icon, rect, false)
		i += 1

func _draw_overlays() -> void:
	var total: int = cols * rows

	if _hover_index >= 0 and _hover_index < total and tex_hover_overlay != null:
		var hx: int = _hover_index % cols
		var hy: int = _hover_index / cols
		var hpos: Vector2 = Vector2(float(hx * cell_size), float(hy * cell_size))
		var hrect: Rect2 = Rect2(hpos, Vector2(float(cell_size), float(cell_size)))
		draw_texture_rect(tex_hover_overlay, hrect, false)

	if _selected_index >= 0 and _selected_index < total and tex_selected_overlay != null:
		var sx: int = _selected_index % cols
		var sy: int = _selected_index / cols
		var spos: Vector2 = Vector2(float(sx * cell_size), float(sy * cell_size))
		var srect: Rect2 = Rect2(spos, Vector2(float(cell_size), float(cell_size)))
		draw_texture_rect(tex_selected_overlay, srect, false)

	if _selected_index >= 0 and _selected_index < total and selected_outline_enabled:
		var sx2: int = _selected_index % cols
		var sy2: int = _selected_index / cols
		var spos2: Vector2 = Vector2(float(sx2 * cell_size), float(sy2 * cell_size))
		var srect2: Rect2 = Rect2(spos2, Vector2(float(cell_size), float(cell_size)))

		var w: float = selected_outline_width
		if w <= 0.0:
			w = 1.0

		# Inset by half the line width so the stroke doesn’t clip outside the cell.
		var inset2: float = w * 0.5
		var orect: Rect2 = srect2.grow(-inset2)
		draw_rect(orect, selected_outline_color, false, w)
