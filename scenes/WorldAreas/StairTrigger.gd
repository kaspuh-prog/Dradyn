extends Area2D
class_name StairTrigger

@export var use_same_area_offset: bool = false
@export var local_offset: Vector2 = Vector2(0.0, -24.0)

@export var same_area_entry_tag: String = ""

@export var target_area_path: String = ""  # e.g., "res://scenes/WorldAreas/OrphanageCellar.tscn"
@export var entry_tag: String = "default"

@export var require_leader: bool = true
@export var debug_prints: bool = true

const GROUP_LEADER := "PartyLeader"
const GROUP_STAIR := "StairTriggerNodes"

func _enter_tree() -> void:
	if not is_in_group(GROUP_STAIR):
		add_to_group(GROUP_STAIR)

func _ready() -> void:
	# Defer these to avoid “Function blocked during in/out signal” errors
	set_deferred("monitoring", true)
	set_deferred("monitorable", true)

	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))
	if not is_connected("area_entered", Callable(self, "_on_area_entered")):
		connect("area_entered", Callable(self, "_on_area_entered"))

	_bind_party_manager_for_mask_sync()
	call_deferred("_sync_mask_to_leader")

	if debug_prints:
		print("[StairTrigger] READY @", get_path(),
			" pos=", global_position,
			" layer=", collision_layer,
			" mask=", collision_mask,
			" target_area_path=", target_area_path,
			" entry_tag=", entry_tag)

func _bind_party_manager_for_mask_sync() -> void:
	var pm: PartyManager = get_tree().get_first_node_in_group("PartyManager") as PartyManager
	if pm == null:
		if debug_prints:
			print("[StairTrigger] WARN: PartyManager not found.")
		return
	if not pm.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
		pm.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
	_sync_mask_to_leader()

func _on_controlled_changed(_current: Node) -> void:
	_sync_mask_to_leader()

func _sync_mask_to_leader() -> void:
	var pm: PartyManager = get_tree().get_first_node_in_group("PartyManager") as PartyManager
	if pm == null:
		return
	var co: CollisionObject2D = pm.get_controlled() as CollisionObject2D
	if co == null:
		return
	var player_layer: int = co.collision_layer
	if player_layer != 0:
		var before: int = collision_mask
		collision_mask = collision_mask | player_layer
		if debug_prints and before != collision_mask:
			print("[StairTrigger] Mask sync: leader_layer=", player_layer, " mask=", collision_mask)

func _on_body_entered(body: Node) -> void:
	if debug_prints:
		print("[StairTrigger] body_entered by=", body)
	_process_body(body)

func _on_area_entered(area: Area2D) -> void:
	if debug_prints:
		print("[StairTrigger] area_entered by=", area)
	_process_body(area)

func _process_body(body: Node) -> void:
	if body == null:
		return
	if require_leader:
		if not body.is_in_group(GROUP_LEADER):
			if debug_prints:
				print("[StairTrigger] Ignored: not leader.")
			return
	else:
		var pm: PartyManager = get_tree().get_first_node_in_group("PartyManager") as PartyManager
		if pm != null:
			var members: Array = pm.get_members()
			if members.find(body) == -1:
				if debug_prints:
					print("[StairTrigger] Ignored: not party member.")
				return
	_trigger_transition()

func _trigger_transition() -> void:
	if target_area_path != "":
		# Defer the call to SceneMgr to avoid physics flush errors.
		call_deferred("_deferred_go_cross_area")
		return
	if same_area_entry_tag != "":
		call_deferred("_move_party_to_same_area_entry", same_area_entry_tag)
		return
	if use_same_area_offset:
		call_deferred("_nudge_party_by_offset", local_offset)
		return
	if debug_prints:
		print("[StairTrigger] No action configured.")

func _deferred_go_cross_area() -> void:
	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm == null:
		if debug_prints:
			print("[StairTrigger] ERROR: /root/SceneMgr not found.")
		return
	if not sm.has_method("change_area"):
		if debug_prints:
			print("[StairTrigger] ERROR: SceneMgr.change_area not found.")
		return
	if debug_prints:
		print("[StairTrigger] Changing area to: ", target_area_path, " entry_tag=", entry_tag)
	# SceneMgr itself defers the actual swap internally now.
	sm.call("change_area", target_area_path, entry_tag)

func _move_party_to_same_area_entry(tag: String) -> void:
	var pm: PartyManager = get_tree().get_first_node_in_group("PartyManager") as PartyManager
	if pm == null:
		if debug_prints:
			print("[StairTrigger] ERROR: PartyManager not found.")
		return
	var scene_mgr: SceneManager = get_node_or_null("/root/SceneMgr") as SceneManager
	if scene_mgr == null:
		if debug_prints:
			print("[StairTrigger] ERROR: SceneMgr not found.")
		return
	var area: Node = scene_mgr.get_current_area()
	if area == null:
		if debug_prints:
			print("[StairTrigger] ERROR: current area is null.")
		return
	var entry_points: Node = area.get_node_or_null("EntryPoints")
	if entry_points == null:
		if debug_prints:
			print("[StairTrigger] ERROR: EntryPoints missing.")
		return
	var n: Node = entry_points.get_node_or_null(tag)
	if not (n is Node2D):
		if debug_prints:
			print("[StairTrigger] ERROR: Entry '", tag, "' missing or not Node2D.")
		return
	var entry: Node2D = n as Node2D
	var base_pos: Vector2 = entry.global_position
	_teleport_party(pm, base_pos)

func _nudge_party_by_offset(offset: Vector2) -> void:
	var pm: PartyManager = get_tree().get_first_node_in_group("PartyManager") as PartyManager
	if pm == null:
		if debug_prints:
			print("[StairTrigger] ERROR: PartyManager not found.")
		return
	var leader2d: Node2D = pm.get_controlled() as Node2D
	if leader2d == null:
		if debug_prints:
			print("[StairTrigger] ERROR: Leader is not Node2D.")
		return
	var base_pos: Vector2 = leader2d.global_position + offset
	_teleport_party(pm, base_pos)

func _teleport_party(pm: PartyManager, base_pos: Vector2) -> void:
	var step: Vector2 = Vector2(12.0, 0.0)
	var members: Array = pm.get_members()
	var i: int = 0
	while i < members.size():
		var m: Node = members[i]
		if m is Node2D:
			var p: Vector2 = base_pos + step * float(i)
			if m.has_method("teleport_to"):
				m.call("teleport_to", p)
			else:
				var m2d: Node2D = m as Node2D
				m2d.global_position = p
		i += 1
	if debug_prints:
		print("[StairTrigger] Teleported party to base=", base_pos, " members=", members.size())
