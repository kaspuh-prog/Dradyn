extends Node
class_name InteractionSystem
## Autoload name: InteractionSys
##
## Service-only: no input handling here. Player calls:
##   - find_best_target(actor, facing_dir)
##   - try_interact_from(actor, facing_dir)

signal interaction_started(actor: Node, target: Node)
signal interaction_failed(actor: Node)

@export var interact_radius: float = 32.0
@export var max_facing_angle_deg: float = 90.0
@export var facing_weight: float = 0.35

@export var highlight_enabled: bool = true
@export var highlight_refresh_hz: float = 8.0  # 0 = off

# NEW: safety net + diagnostics
@export var fallback_probe_scale: float = 2.0    # extra reach if first pass finds nothing
@export var debug_prints: bool = false           # enable while testing

const GROUP_INTERACTABLE: StringName = &"interactable"
const HIGHLIGHT_METHOD: StringName = &"set_interact_highlight"

var _highlight_timer: Timer = null

func _ready() -> void:
	if highlight_enabled and highlight_refresh_hz > 0.0:
		_highlight_timer = Timer.new()
		_highlight_timer.one_shot = false
		_highlight_timer.wait_time = 1.0 / highlight_refresh_hz
		add_child(_highlight_timer)
		_highlight_timer.timeout.connect(_on_highlight_tick)
		_highlight_timer.start()

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------
func try_interact_from(actor: Node, facing_dir: Vector2 = Vector2.ZERO) -> bool:
	if actor == null:
		return false
	var target: Node = find_best_target(actor, facing_dir)
	if target == null:
		emit_signal("interaction_failed", actor)
		return false

	_set_highlight(target, false)
	emit_signal("interaction_started", actor, target)

	if target.has_method("interact"):
		target.call("interact", actor)
	return true

func find_best_target(actor: Node, facing_dir: Vector2 = Vector2.ZERO) -> Node:
	var origin: Vector2 = _global_pos(actor)
	var want_dir: Vector2 = facing_dir
	if want_dir.length() > 0.0001:
		want_dir = want_dir.normalized()
	var max_angle_rad: float = deg_to_rad(max_facing_angle_deg)

	var nodes: Array = get_tree().get_nodes_in_group(GROUP_INTERACTABLE)
	if debug_prints:
		print("[InteractionSys] interactables: ", nodes.size())

	var best: Node = null
	var best_score: float = -1.0

	# ---------- Pass 1: pure distance+optional facing ----------
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		if not _is_valid_interactable(n):
			i += 1
			continue

		var p: Vector2 = _global_pos(n)
		var to_vec: Vector2 = p - origin
		var dist: float = to_vec.length()

		var r: float = _candidate_radius(n)
		if debug_prints:
			print("  • ", n.name, " dist=", dist, " r=", r)

		if dist <= 0.0001 or dist > r:
			i += 1
			continue

		var align_score: float = 1.0
		if want_dir.length() > 0.5:
			var dir: Vector2 = to_vec / dist
			var dot: float = dir.dot(want_dir)
			if dot < -1.0:
				dot = -1.0
			if dot > 1.0:
				dot = 1.0
			var ang: float = acos(dot)
			if ang > max_angle_rad:
				i += 1
				continue
			if max_angle_rad > 0.0001:
				align_score = 1.0 - (ang / max_angle_rad)

		var dist_score: float = 1.0 - (dist / max(0.0001, r))
		var comb: float = (1.0 - facing_weight) * dist_score + facing_weight * align_score

		if comb > best_score:
			best_score = comb
			best = n

		i += 1

	# ---------- Pass 2: physics probe fallback (wider circle) ----------
	if best == null and fallback_probe_scale > 1.0:
		var probe_r: float = interact_radius * fallback_probe_scale
		var prox: Array = _physics_probe_interactables(origin, probe_r)
		if debug_prints:
			print("[InteractionSys] fallback probe hits=", prox.size(), " @r=", probe_r)
		var j: int = 0
		while j < prox.size():
			var k: Node = prox[j]
			if _is_valid_interactable(k):
				best = k
				break
			j += 1

	# Update highlight
	if highlight_enabled:
		_update_highlights(best)

	return best

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------
func _candidate_radius(n: Node) -> float:
	# Per-node override path:
	# 1) method get_interact_radius() -> float
	# 2) meta "interact_radius" -> float
	# 3) exported property "interact_radius_override" -> float
	# 4) global default interact_radius
	if n.has_method("get_interact_radius"):
		var v: Variant = n.call("get_interact_radius")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			var f: float = float(v)
			if f > 0.0:
				return f
	if n.has_meta("interact_radius"):
		var m: Variant = n.get_meta("interact_radius")
		if typeof(m) == TYPE_FLOAT or typeof(m) == TYPE_INT:
			var mf: float = float(m)
			if mf > 0.0:
				return mf
	if "interact_radius_override" in n:
		var o: Variant = n.get("interact_radius_override")
		if typeof(o) == TYPE_FLOAT or typeof(o) == TYPE_INT:
			var of: float = float(o)
			if of > 0.0:
				return of
	return interact_radius

func _physics_probe_interactables(center: Vector2, radius: float) -> Array:
	var vp: Viewport = get_viewport()
	if vp == null:
		return []
	var world: World2D = vp.get_world_2d()
	if world == null:
		return []
	var space: PhysicsDirectSpaceState2D = world.direct_space_state
	if space == null:
		return []

	var shape: CircleShape2D = CircleShape2D.new()
	shape.radius = radius

	var xform: Transform2D = Transform2D.IDENTITY
	xform.origin = center

	var params: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = xform
	params.collide_with_areas = true
	params.collide_with_bodies = true
	params.collision_mask = 0xFFFFFFFF

	var results: Array = space.intersect_shape(params, 32)
	var out: Array = []

	var i: int = 0
	while i < results.size():
		var d: Dictionary = results[i]
		if d.has("collider"):
			var o: Object = d["collider"]
			var n: Node = o as Node
			if n != null:
				if n.is_in_group(GROUP_INTERACTABLE):
					out.append(n)
		i += 1

	return out


func _on_highlight_tick() -> void:
	var pm: PartyManager = get_tree().get_first_node_in_group("PartyManager") as PartyManager
	if pm == null:
		return
	var actor: Node = pm.get_controlled()
	if actor == null:
		return
	find_best_target(actor, Vector2.ZERO) # distance-only during highlight refresh

func _is_valid_interactable(node: Node) -> bool:
	if node == null:
		return false
	if not node.is_inside_tree():
		return false
	if not node.is_in_group(GROUP_INTERACTABLE):
		return false
	if not node.has_method("interact"):
		return false
	return true

func _global_pos(node: Node) -> Vector2:
	# Preferred explicit anchor
	var anchor: Node2D = node.get_node_or_null("InteractAnchor") as Node2D
	if anchor != null:
		return anchor.global_position

	# Common: CollisionShape2D
	var cs: CollisionShape2D = node.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs != null:
		return cs.global_position

	# Node itself or any child Node2D
	if node is Node2D:
		return (node as Node2D).global_position
	var i: int = 0
	while i < node.get_child_count():
		var c: Node = node.get_child(i)
		if c is Node2D:
			return (c as Node2D).global_position
		i += 1
	return Vector2.ZERO

func _update_highlights(best: Node) -> void:
	if not highlight_enabled:
		return
	var nodes: Array = get_tree().get_nodes_in_group(GROUP_INTERACTABLE)
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i]
		var on: bool = (n == best)
		_set_highlight(n, on)
		i += 1

func _set_highlight(node: Node, on: bool) -> void:
	if node == null:
		return
	if node.has_method(HIGHLIGHT_METHOD):
		node.call(HIGHLIGHT_METHOD, on)
