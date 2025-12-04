extends Control
class_name IconOverlay

@export var grid_path: NodePath = ^".."
@export var show_debug_outlines: bool = false

var _grid: InventoryGridView = null
var _inv: Node = null

var _cols: int = 0
var _rows: int = 0
var _cell: int = 16
var _cap_unlocked: int = 0
var _total_cells: int = 0

func _ready() -> void:
	_resolve_refs()
	_configure_layer()
	_bind_signals()
	_sync_from_grid()
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED or what == NOTIFICATION_THEME_CHANGED or what == NOTIFICATION_POST_ENTER_TREE:
		_sync_from_grid()
		queue_redraw()

func _resolve_refs() -> void:
	_grid = get_node_or_null(grid_path) as InventoryGridView
	if _grid == null:
		push_warning("[IconOverlay] InventoryGridView not found at: " + str(grid_path))
	var n: Node = get_node_or_null("/root/InventorySys")
	if n == null:
		n = get_node_or_null("/root/InventorySystem")
	_inv = n

func _configure_layer() -> void:
	# Always above siblings; let anchors control size (avoid writing size).
	z_as_relative = false
	z_index = 4096
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(PRESET_FULL_RECT)

func _bind_signals() -> void:
	if _grid != null:
		if not _grid.resized.is_connected(_on_grid_resized):
			_grid.resized.connect(_on_grid_resized)
		if not _grid.tree_entered.is_connected(_on_grid_tree_event):
			_grid.tree_entered.connect(_on_grid_tree_event)
		if not _grid.tree_exited.is_connected(_on_grid_tree_event):
			_grid.tree_exited.connect(_on_grid_tree_event)
	if _inv != null and _inv.has_signal("inventory_changed"):
		(_inv as Node).connect("inventory_changed", Callable(self, "_on_inventory_changed"))

func _on_grid_resized() -> void:
	_sync_from_grid()
	queue_redraw()

func _on_grid_tree_event() -> void:
	_sync_from_grid()
	queue_redraw()

func _on_inventory_changed() -> void:
	queue_redraw()

func _sync_from_grid() -> void:
	if _grid == null:
		return
	_cols = _grid.cols
	_rows = _grid.rows
	_cell = _grid.cell_size
	_cap_unlocked = _grid.get_unlocked_capacity()
	_total_cells = _cols * _rows
	if _cap_unlocked > _total_cells:
		_cap_unlocked = _total_cells

func _font() -> Font:
	var f: Font = get_theme_default_font()
	if f == null:
		f = ThemeDB.fallback_font
		
	return f
func _font_size() -> int:
	var s: int = get_theme_default_font_size()
	if s <= 0:
		s = 1  # safe fallback so TextServer always has a positive size
	return s

func _draw() -> void:
	if _grid == null:
		return
	if _inv == null:
		return
	if _cols <= 0 or _rows <= 0 or _cell <= 0:
		return
	if not _inv.has_method("get_item_summary_for_slot"):
		return

	var font: Font = _font()
	var limit: int = _cap_unlocked

	var i: int = 0
	while i < limit:
		var cx: int = i % _cols
		var cy: int = i / _cols
		var pos: Vector2 = Vector2(cx * _cell, cy * _cell)
		var rect := Rect2(pos, Vector2(float(_cell), float(_cell)))

		# Pull summary (expects: has_item, icon, qty)
		var d_v: Variant = _inv.call("get_item_summary_for_slot", i)
		if typeof(d_v) == TYPE_DICTIONARY:
			var d: Dictionary = d_v
			var has_item: bool = bool(d.get("has_item", false))
			if has_item:
				var icon: Texture2D = d.get("icon", null) as Texture2D
				var qty: int = int(d.get("qty", 0))

				if icon != null:
					draw_texture_rect(icon, rect, false)
				# qty overlay for stacks
				if qty > 1:
					var qty_pos := rect.position + Vector2(0.0, rect.size.y - 8.0)
					draw_string(font, qty_pos, str(qty), HORIZONTAL_ALIGNMENT_LEFT, 5.0, _font_size(), Color.WHITE)


		if show_debug_outlines:
			draw_rect(rect, Color(1.0, 1.0, 1.0, 0.06), true)
			draw_rect(rect, Color(0.2, 0.9, 0.9, 0.6), false, 1.0)

		i += 1
