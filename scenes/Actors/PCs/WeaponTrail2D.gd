extends Line2D
class_name WeaponTrail2D
# Godot 4.5 — fully typed, no ternaries.

@export_node_path("Node2D") var anchor_path: NodePath = NodePath("../TrailAnchor")

@export var is_active: bool = false
@export_range(0.0, 60.0, 0.1) var sample_hz: float = 60.0
@export_range(0.0, 64.0, 0.1) var min_point_distance_px: float = 1.0
@export_range(2, 256, 1) var max_points: int = 24

@export_range(0.0, 2.0, 0.01) var fade_out_seconds: float = 0.12
@export var clear_on_start: bool = true
@export var visible_only_while_active: bool = false

var _anchor: Node2D = null
var _accum: float = 0.0
var _fade_accum: float = 0.0

func _ready() -> void:
	_anchor = get_node_or_null(anchor_path) as Node2D
	if visible_only_while_active:
		visible = is_active

	if clear_on_start and is_active:
		clear_points()

func _process(delta: float) -> void:
	if _anchor == null:
		_anchor = get_node_or_null(anchor_path) as Node2D
		if _anchor == null:
			return

	if is_active:
		_fade_accum = 0.0
		_accum += delta

		var step: float = 0.0
		if sample_hz > 0.0:
			step = 1.0 / sample_hz

		if step <= 0.0:
			_sample_now()
			return

		while _accum >= step:
			_accum -= step
			_sample_now()
	else:
		_accum = 0.0
		_fade_out(delta)

func start_trail() -> void:
	is_active = true
	_accum = 0.0
	_fade_accum = 0.0
	if clear_on_start:
		clear_points()
	if visible_only_while_active:
		visible = true

func stop_trail() -> void:
	is_active = false
	_accum = 0.0
	if visible_only_while_active:
		# Keep visible during fade-out if there are points; hide when cleared.
		if points.size() == 0:
			visible = false

func clear_trail() -> void:
	clear_points()
	_fade_accum = 0.0
	if visible_only_while_active:
		visible = false

func _sample_now() -> void:
	if _anchor == null:
		return

	var p_global: Vector2 = _anchor.global_position
	var p_local: Vector2 = to_local(p_global)

	if points.size() > 0:
		var last: Vector2 = points[points.size() - 1]
		if last.distance_to(p_local) < min_point_distance_px:
			return

	add_point(p_local)

	while points.size() > max_points:
		remove_point(0)

func _fade_out(delta: float) -> void:
	if points.size() == 0:
		if visible_only_while_active:
			visible = false
		return

	if fade_out_seconds <= 0.0:
		clear_points()
		if visible_only_while_active:
			visible = false
		return

	_fade_accum += delta

	var remove_interval: float = fade_out_seconds / float(max_points)
	if remove_interval <= 0.0:
		remove_interval = 0.01

	while _fade_accum >= remove_interval and points.size() > 0:
		_fade_accum -= remove_interval
		remove_point(0)

	if points.size() == 0 and visible_only_while_active:
		visible = false
