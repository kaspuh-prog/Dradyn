extends Node2D
class_name TileOccluders2D
# Spawns LightOccluder2D edge strips for marked tiles.
# Use TileSet Custom Data:
#   occlude: bool        -> mark tiles that should occlude (beds/walls/props)
#   occlude_edges: String (optional) -> comma or | separated mask: "top,bottom,left,right"
# If occlude_edges is absent/empty, we default to neighbor-based exposure (edges with empty neighbor).

@export var target_layer_path: NodePath
@export var custom_data_key: String = "occlude"     # bool on tiles that should cast
@export var custom_edges_key: String = "occlude_edges"  # optional string "top,right"
@export var source_ids: Array[int] = []             # fallback A: mark by source id
@export var atlas_coords: Array[Vector2i] = []      # fallback B: mark by atlas coords

# Edge strip settings
@export var edge_thickness_pixels: float = 3.0
@export var push_out_pixels: float = 0.5
@export var trim_corners_pixels: float = 0.0

# Fallback cell size (only if TileSet.tile_size is unavailable)
@export var fallback_cell_size: Vector2 = Vector2(16.0, 16.0)

var _layer: TileMapLayer = null
var _spawned: Array[LightOccluder2D] = []
var _cell_size: Vector2 = Vector2(16.0, 16.0)

func _ready() -> void:
	_layer = get_node_or_null(target_layer_path) as TileMapLayer
	if _layer == null:
		push_error("[TileOccluders2D] target_layer_path is not set or not a TileMapLayer.")
		return

	_cell_size = _read_cell_size()
	_rebuild()

	if _layer.has_signal("changed"):
		_layer.connect("changed", Callable(self, "_on_layer_changed"))

func _on_layer_changed() -> void:
	_rebuild()

func _read_cell_size() -> Vector2:
	var ts: TileSet = _layer.tile_set
	if ts != null:
		var tsize: Vector2i = ts.tile_size
		if tsize.x > 0 and tsize.y > 0:
			return Vector2(float(tsize.x), float(tsize.y))
	return fallback_cell_size

func _rebuild() -> void:
	_clear_all()

	var used: Array[Vector2i] = _layer.get_used_cells()
	var i: int = 0
	while i < used.size():
		var cell: Vector2i = used[i]
		var td: TileData = _layer.get_cell_tile_data(cell)
		if td != null and _tile_is_marked(cell, td):
			var edges: PackedStringArray = _read_edges_mask(td)
			if edges.size() > 0:
				_spawn_edges_by_mask(cell, edges)
			else:
				_spawn_edges_by_exposure(cell)
		i += 1

func _tile_is_marked(cell: Vector2i, td: TileData) -> bool:
	# Preferred: boolean custom data (e.g., occlude = true)
	if td.has_custom_data(custom_data_key):
		var v: Variant = td.get_custom_data(custom_data_key)
		var b: bool = false
		if typeof(v) == TYPE_BOOL:
			b = bool(v)
		elif typeof(v) == TYPE_INT:
			b = int(v) != 0
		elif typeof(v) == TYPE_STRING:
			b = String(v).to_lower() == "true"
		if b:
			return true

	# Fallback A: by source id
	var sid: int = _layer.get_cell_source_id(cell)
	var j: int = 0
	while j < source_ids.size():
		if sid == source_ids[j]:
			return true
		j += 1

	# Fallback B: by atlas coords
	var coord: Vector2i = _layer.get_cell_atlas_coords(cell)
	j = 0
	while j < atlas_coords.size():
		if coord == atlas_coords[j]:
			return true
		j += 1

	return false

func _read_edges_mask(td: TileData) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if td.has_custom_data(custom_edges_key):
		var v: Variant = td.get_custom_data(custom_edges_key)
		if typeof(v) == TYPE_STRING:
			var s: String = String(v)
			s = s.replace("|", ",")
			var parts: PackedStringArray = s.split(",", false)
			var i: int = 0
			while i < parts.size():
				var p: String = parts[i].strip_edges().to_lower()
				if p == "top" or p == "bottom" or p == "left" or p == "right":
					result.append(p)
				i += 1
	return result

func _spawn_edges_by_mask(cell: Vector2i, edges: PackedStringArray) -> void:
	var half: Vector2 = _cell_size * 0.5
	var center: Vector2 = _layer.map_to_local(cell) + Vector2(half.x, half.y)

	var i: int = 0
	while i < edges.size():
		var e: String = edges[i]
		if e == "left":
			_spawn_edge_strip(center, Vector2(-1.0, 0.0), half, edge_thickness_pixels, push_out_pixels)
		elif e == "right":
			_spawn_edge_strip(center, Vector2(1.0, 0.0), half, edge_thickness_pixels, push_out_pixels)
		elif e == "top":
			_spawn_edge_strip(center, Vector2(0.0, -1.0), half, edge_thickness_pixels, push_out_pixels)
		elif e == "bottom":
			_spawn_edge_strip(center, Vector2(0.0, 1.0), half, edge_thickness_pixels, push_out_pixels)
		i += 1

func _spawn_edges_by_exposure(cell: Vector2i) -> void:
	# For convenience: if no explicit mask, create edges where neighbor is NOT marked wall/prop.
	var half: Vector2 = _cell_size * 0.5
	var center: Vector2 = _layer.map_to_local(cell) + Vector2(half.x, half.y)

	var left_cell: Vector2i = Vector2i(cell.x - 1, cell.y)
	var right_cell: Vector2i = Vector2i(cell.x + 1, cell.y)
	var up_cell: Vector2i = Vector2i(cell.x, cell.y - 1)
	var down_cell: Vector2i = Vector2i(cell.x, cell.y + 1)

	if not _neighbor_is_marked(left_cell):
		_spawn_edge_strip(center, Vector2(-1.0, 0.0), half, edge_thickness_pixels, push_out_pixels)
	if not _neighbor_is_marked(right_cell):
		_spawn_edge_strip(center, Vector2(1.0, 0.0), half, edge_thickness_pixels, push_out_pixels)
	if not _neighbor_is_marked(up_cell):
		_spawn_edge_strip(center, Vector2(0.0, -1.0), half, edge_thickness_pixels, push_out_pixels)
	if not _neighbor_is_marked(down_cell):
		_spawn_edge_strip(center, Vector2(0.0, 1.0), half, edge_thickness_pixels, push_out_pixels)

func _neighbor_is_marked(cell: Vector2i) -> bool:
	var td: TileData = _layer.get_cell_tile_data(cell)
	if td == null:
		return false
	return _tile_is_marked(cell, td)

func _spawn_edge_strip(center: Vector2, normal_dir: Vector2, half: Vector2, thickness: float, push: float) -> void:
	var occl: LightOccluder2D = LightOccluder2D.new()
	var poly: OccluderPolygon2D = OccluderPolygon2D.new()
	occl.occluder = poly

	var hx: float = half.x
	var hy: float = half.y
	var t: float = max(0.1, thickness)
	var p: float = push
	var trim: float = max(0.0, trim_corners_pixels)

	var pts: PackedVector2Array = PackedVector2Array()

	if normal_dir.x < 0.0:
		var x0: float = -hx - p
		var x1: float = -hx + t
		var y0: float = -hy + trim
		var y1: float = hy - trim
		pts.append(Vector2(x0, y0))
		pts.append(Vector2(x1, y0))
		pts.append(Vector2(x1, y1))
		pts.append(Vector2(x0, y1))
	elif normal_dir.x > 0.0:
		var x0r: float = hx - t
		var x1r: float = hx + p
		var yr0: float = -hy + trim
		var yr1: float = hy - trim
		pts.append(Vector2(x0r, yr0))
		pts.append(Vector2(x1r, yr0))
		pts.append(Vector2(x1r, yr1))
		pts.append(Vector2(x0r, yr1))
	elif normal_dir.y < 0.0:
		var y0t: float = -hy - p
		var y1t: float = -hy + t
		var x0t: float = -hx + trim
		var x1t: float = hx - trim
		pts.append(Vector2(x0t, y0t))
		pts.append(Vector2(x1t, y0t))
		pts.append(Vector2(x1t, y1t))
		pts.append(Vector2(x0t, y1t))
	else:
		var y0b: float = hy - t
		var y1b: float = hy + p
		var x0b: float = -hx + trim
		var x1b: float = hx - trim
		pts.append(Vector2(x0b, y0b))
		pts.append(Vector2(x1b, y0b))
		pts.append(Vector2(x1b, y1b))
		pts.append(Vector2(x0b, y1b))

	poly.polygon = pts
	poly.closed = true
	occl.position = center

	add_child(occl)
	_spawned.append(occl)

func _clear_all() -> void:
	var i: int = 0
	while i < _spawned.size():
		var n: LightOccluder2D = _spawned[i]
		if n != null and is_instance_valid(n):
			n.queue_free()
		i += 1
	_spawned.clear()
