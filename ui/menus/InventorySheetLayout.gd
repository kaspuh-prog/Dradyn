extends Control
class_name InventorySheetLayout

# --- Core layout constants ---
@export var left_inset_px: int = 32
@export var right_inset_px: int = 32

@export var grid_cols: int = 12
@export var grid_rows: int = 4
@export var cell_px: int = 16

@export var tab_width_px: int = 32
@export var tab_height_px: int = 16
@export var bottom_gap_to_bg_px: int = 16      # distance ABOVE BG outer bottom for the grid bottom (your rule)

@export var portrait_top_px: int = 32          # distance BELOW page top for the portrait cluster
@export var cluster_gap_right_px: int = 16     # overlay gap from BG OUTER right edge
@export var desc_gap_px: int = 8

# --- Fine-tune nudges (positive/down-right, negative/up-left) ---
@export var tabs_nudge_y_px: int = -16         # move bag tabs row up/down
@export var grid_bottom_nudge_px: int = 0      # move grid bottom up/down relative to BG.bottom-16
@export var portrait_nudge_x_px: int = -16     # move portrait cluster left/right
@export var portrait_nudge_y_px: int = -4      # move portrait cluster up/down

# --- Currency counter (8x32 box) ---
@export var currency_box_path: NodePath = NodePath("")     # e.g., ^"CurrencyBox" (Control/NinePatchRect sized by code)
@export var currency_value_label_path: NodePath = NodePath("")  # optional Label inside the box to show the number
@export var currency_box_width_px: int = 8
@export var currency_box_height_px: int = 32
@export var currency_nudge_x_px: int = 0        # small horizontal tweak relative to centered-on-Tab_Bag4
@export var currency_nudge_y_px: int = 0        # small vertical tweak (down is positive)

# --- Nodes (assign in Inspector) ---
@export var bg_path_from_tabbedmenu: NodePath = ^"BG"      # NinePatchRect in TabbedMenu
@export var bag_tabs_row_path: NodePath = ^"BagTabsRow"
@export var grid_path: NodePath = ^"Grid"
@export var portrait_cluster_path: NodePath = ^"PortraitCluster"
@export var description_pane_path: NodePath = ^"DescriptionPane"

# --- Z overlay (keep above BG) ---
@export var z_overlay_min: int = 20

# --- Debug overlay ---
@export var debug_draw_layout: bool = false
@export var debug_color_bg_edges: Color = Color(0.9, 0.3, 0.3, 0.8)
@export var debug_color_grid: Color = Color(0.3, 0.9, 0.3, 0.8)
@export var debug_color_tabs: Color = Color(0.3, 0.6, 0.9, 0.8)
@export var debug_color_cluster: Color = Color(0.9, 0.8, 0.3, 0.8)
@export var debug_color_desc: Color = Color(0.8, 0.3, 0.9, 0.8)
@export var debug_color_currency: Color = Color(0.95, 0.95, 0.2, 0.9)

var _bg: Control
var _content: Control
var _tabs: Control
var _grid: Control
var _cluster: Control
var _desc: Control

var _currency_box: Control
var _currency_label: Label

# Cached rects for debug
var _debug_bg_bottom: float = 0.0
var _debug_bg_right: float = 0.0
var _debug_grid_rect: Rect2 = Rect2()
var _debug_tabs_rect: Rect2 = Rect2()
var _debug_cluster_rect: Rect2 = Rect2()
var _debug_desc_rect: Rect2 = Rect2()
var _debug_currency_rect: Rect2 = Rect2()

func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

	_content = get_parent() as Control
	var tabbed: Control = null
	if _content != null:
		tabbed = _content.get_parent() as Control
	if tabbed != null and bg_path_from_tabbedmenu != NodePath(""):
		_bg = tabbed.get_node_or_null(bg_path_from_tabbedmenu) as Control

	_tabs = get_node_or_null(bag_tabs_row_path) as Control
	_grid = get_node_or_null(grid_path) as Control
	_cluster = get_node_or_null(portrait_cluster_path) as Control
	_desc = get_node_or_null(description_pane_path) as Control

	_currency_box = get_node_or_null(currency_box_path) as Control
	_currency_label = get_node_or_null(currency_value_label_path) as Label

	# Listen to currency updates if label provided
	if _currency_label != null:
		if Engine.has_singleton("InventorySys"):
			# In Godot, autoload is a global; access directly.
			# Connect signal safely if it exists.
			if "currency_changed" in InventorySys:
				InventorySys.currency_changed.connect(_on_currency_changed)
		# Initialize from current total if API is present
		_update_currency_display(_get_current_currency())

	_apply_layout()
	if _content != null:
		_content.resized.connect(_on_any_resized)
	resized.connect(_on_any_resized)

func _on_any_resized() -> void:
	_apply_layout()
	queue_redraw()

func _apply_layout() -> void:
	if _content == null:
		return

	var sheet_w: float = size.x
	var sheet_h: float = size.y

	# Grid dimensions (12×4 @ 16)
	var grid_w: float = float(grid_cols * cell_px)  # 192
	var grid_h: float = float(grid_rows * cell_px)  # 64

	# Z above BG
	var overlay_z: int = z_overlay_min
	if _bg != null and _bg.z_index >= overlay_z:
		overlay_z = _bg.z_index + 1

	# BG outer edges in InventorySheet local
	var bg_bottom_local: float = sheet_h
	var bg_right_local: float = sheet_w - float(right_inset_px)
	if _bg != null:
		var bg_global: Rect2 = _bg.get_global_rect()
		var content_top_left: Vector2 = _content.global_position
		bg_bottom_local = (bg_global.position.y + bg_global.size.y) - content_top_left.y
		bg_right_local = (bg_global.position.x + bg_global.size.x) - content_top_left.x

	_debug_bg_bottom = bg_bottom_local
	_debug_bg_right = bg_right_local

	# ---------- Bottom section (tabs above grid; grid bottom = BG.bottom - 16 + nudge) ----------
	var grid_bottom_local: float = bg_bottom_local - float(bottom_gap_to_bg_px) + float(grid_bottom_nudge_px)

	if _tabs != null:
		var tabs_x: float = float(left_inset_px)
		var tabs_y: float = grid_bottom_local - (grid_h + float(tab_height_px)) + float(tabs_nudge_y_px)
		_tabs.position = Vector2(tabs_x, tabs_y)
		_tabs.size = Vector2(grid_w, float(tab_height_px))
		_tabs.z_index = overlay_z
		_layout_tab_buttons(_tabs)
		_debug_tabs_rect = Rect2(_tabs.position, _tabs.size)

	if _grid != null:
		var grid_x: float = float(left_inset_px)
		var grid_y: float
		if _tabs != null:
			grid_y = _tabs.position.y + _tabs.size.y
		else:
			grid_y = grid_bottom_local - grid_h
		_grid.position = Vector2(grid_x, grid_y)
		_grid.size = Vector2(grid_w, grid_h)
		_grid.z_index = overlay_z
		_grid.visible = true
		_debug_grid_rect = Rect2(_grid.position, _grid.size)

	# ---------- Currency box above 4th bag tab ----------
	_position_currency_box(overlay_z)

	# ---------- Top-right cluster (overlay on BG border) ----------
	if _cluster != null:
		var cw: float = maxf(_cluster.size.x, 96.0)     # 16 + 64 + 16
		var ch: float = maxf(_cluster.size.y, 80.0)     # 64 + 16
		var right_edge_local: float = bg_right_local    # use BG OUTER right
		var cluster_left: float = right_edge_local - float(cluster_gap_right_px) - cw + float(portrait_nudge_x_px)
		var cluster_top: float = float(portrait_top_px) + float(portrait_nudge_y_px)

		_cluster.position = Vector2(cluster_left, cluster_top)
		_cluster.size = Vector2(cw, ch)
		_cluster.z_index = overlay_z
		_cluster.visible = true
		_debug_cluster_rect = Rect2(_cluster.position, _cluster.size)

	# ---------- Description (left of cluster) ----------
	if _desc != null and _cluster != null:
		var desc_left: float = float(left_inset_px)
		var desc_right: float = maxf(_cluster.position.x - float(desc_gap_px), desc_left + 16.0)
		var desc_top: float = _cluster.position.y
		var desc_bottom: float = _cluster.position.y + _cluster.size.y

		_desc.position = Vector2(desc_left, desc_top)
		_desc.size = Vector2(desc_right - desc_left, desc_bottom - desc_top)
		_desc.z_index = overlay_z
		_desc.visible = true
		_debug_desc_rect = Rect2(_desc.position, _desc.size)

func _position_currency_box(overlay_z: int) -> void:
	if _currency_box == null or _tabs == null:
		_debug_currency_rect = Rect2()
		return

	# Box dimensions
	var bw: float = float(currency_box_width_px)
	var bh: float = float(currency_box_height_px)
	_currency_box.size = Vector2(bw, bh)

	# Locate Tab_Bag4 within tabs row
	var tab_4: TextureButton = _tabs.get_node_or_null("Tab_Bag4") as TextureButton
	if tab_4 == null:
		_debug_currency_rect = Rect2()
		return

	# Compute position in this layout's local space:
	# Start from tabs-row origin, add tab_4.x, center horizontally, place directly above (touching)
	var centered_x_on_tab: float = _tabs.position.x + tab_4.position.x + (tab_4.size.x - bw) * 0.5
	var top_y_above_tab: float = _tabs.position.y - bh

	var final_x: float = centered_x_on_tab + float(currency_nudge_x_px)
	var final_y: float = top_y_above_tab + float(currency_nudge_y_px)

	_currency_box.position = Vector2(final_x, final_y)
	_currency_box.z_index = overlay_z
	_currency_box.visible = true

	_debug_currency_rect = Rect2(_currency_box.position, _currency_box.size)

	# If a value label is used, keep it centered inside
	if _currency_label != null:
		_currency_label.position = Vector2(0.0, 0.0)
		_currency_label.size = _currency_box.size
		_currency_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_currency_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_currency_label.visible = true

func _get_current_currency() -> int:
	# Safe access into InventorySys if APIs exist
	if Engine.has_singleton("InventorySys"):
		if "get_currency" in InventorySys:
			var total: int = InventorySys.get_currency()
			return total
	return 0

func _on_currency_changed(total: int, delta: int) -> void:
	_update_currency_display(total)

func _update_currency_display(total: int) -> void:
	if _currency_label == null:
		return
	# Format with thousands separators
	var text_val: String = str(total)
	# Simple formatting: insert commas manually
	var s: PackedStringArray = []
	var i: int = text_val.length() - 1
	var group: int = 0
	while i >= 0:
		var c: String = text_val[i]
		s.append(c)
		group += 1
		if group == 3 and i > 0:
			s.append(",")
			group = 0
		i -= 1
	s.reverse()
	_currency_label.text = "".join(s)

func _layout_tab_buttons(tabs_row: Control) -> void:
	var order: Array[String] = ["Tab_Bag1","Tab_Bag2","Tab_Bag3","Tab_Bag4","Tab_Bag5","Tab_Key"]
	var x: float = 0.0
	var w: float = float(tab_width_px)
	var h: float = float(tab_height_px)

	var i: int = 0
	while i < order.size():
		var name: String = order[i]
		var tb: TextureButton = tabs_row.get_node_or_null(name) as TextureButton
		if tb != null:
			tb.position = Vector2(x, 0.0)
			tb.custom_minimum_size = Vector2(w, h)
			tb.size = Vector2(w, h)
			tb.focus_mode = Control.FOCUS_ALL
			tb.toggle_mode = true
			tb.z_index = tabs_row.z_index
			tb.visible = true
		x += w
		i += 1

func _draw() -> void:
	if not debug_draw_layout:
		return

	# BG outer reference lines
	draw_line(Vector2(0.0, _debug_bg_bottom), Vector2(size.x, _debug_bg_bottom), debug_color_bg_edges, 1.0)
	draw_line(Vector2(_debug_bg_right, 0.0), Vector2(_debug_bg_right, size.y), debug_color_bg_edges, 1.0)

	# Rects
	_draw_rect_outline(_debug_tabs_rect, debug_color_tabs)
	_draw_rect_outline(_debug_grid_rect, debug_color_grid)
	_draw_rect_outline(_debug_cluster_rect, debug_color_cluster)
	_draw_rect_outline(_debug_desc_rect, debug_color_desc)
	_draw_rect_outline(_debug_currency_rect, debug_color_currency)

func _draw_rect_outline(r: Rect2, c: Color) -> void:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var a: Vector2 = r.position
	var b: Vector2 = r.position + Vector2(r.size.x, 0.0)
	var d: Vector2 = r.position + Vector2(0.0, r.size.y)
	var e: Vector2 = r.position + r.size
	draw_line(a, b, c, 1.0)
	draw_line(b, e, c, 1.0)
	draw_line(e, d, c, 1.0)
	draw_line(d, a, c, 1.0)

# In InventorySheet's script
func _on_bag_tabs_row_bag_changed(bag_index: int) -> void:
	# TODO: update the grid for the selected bag
	# Example placeholder:
	print("Bag changed to index: ", bag_index)
