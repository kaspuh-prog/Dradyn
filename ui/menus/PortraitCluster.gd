extends Control
class_name PortraitCluster

## Signals in your project:
## - PartyManager emits: controlled_changed(new_leader: Node)
## - PartyManager has: get_controlled() -> Node

@export var portrait_node: NodePath = ^"Portrait"  # TextureRect inside PortraitCluster
@export var party_manager_path: NodePath           # Optional: set to /root/PartyManager if you prefer
@export var search_party_manager_by_group: bool = true
@export var party_manager_group_name: String = "PartyManager"

# ----------------------------
# Equipment slot selection
# ----------------------------
@export_group("Equipment Slots")
@export var equipment_slot_paths: Array[NodePath] = []
@export var equipment_slot_group_name: String = "equipment_slot"
@export var search_slots_by_group: bool = true
@export var search_slots_by_heuristic: bool = true

@export_group("Selection Outline")
@export var selected_outline_enabled: bool = true
@export var selected_outline_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var selected_outline_width: int = 1

# ----------------------------
# Portrait render (VisualRoot via SubViewport)
# ----------------------------
@export_group("Portrait Render")
@export var visual_root_name: String = "VisualRoot"
@export var viewport_size_px: Vector2i = Vector2i(96, 96)
@export var portrait_zoom: float = 2.0
@export var portrait_offset_px: Vector2 = Vector2(0.0, 10.0)
@export var hide_weapon_nodes_in_portrait: bool = true
@export var weapon_node_names_to_hide: PackedStringArray = PackedStringArray(["WeaponRoot", "Mainhand", "Offhand", "WeaponTrail"])

@export var prefer_idle_down_animation: bool = true
@export var idle_down_name: String = "idle_down"

@export_group("Portrait Refresh")
@export var watch_equip_slots_for_portrait_refresh: PackedStringArray = PackedStringArray(["back"])
@export var inventory_autoload_names: PackedStringArray = PackedStringArray(["InventorySys", "InventorySystem"])

# ----------------------------
# UI SFX
# ----------------------------
@export_group("UI SFX")
@export var ui_click_event: StringName = &"UI_click.mp3"
@export var ui_click_volume_db: float = 0.0
@export var audio_autoload_names: PackedStringArray = PackedStringArray(["AudioSys", "AudioSystem"])

@export var debug_log: bool = false

@onready var _portrait: TextureRect = get_node(portrait_node) as TextureRect

var _party_manager: Node = null
var _current_leader: Node = null

var _equip_slots: Array[Control] = []
var _selected_slot: Control = null

var _audio_obj: Object = null
var _audio_checked_once: bool = false

var _inventory_obj: Object = null

var _sv: SubViewport = null
var _sv_root: Node2D = null
var _sv_clone: Node = null


func _ready() -> void:
	if _portrait == null:
		push_warning("PortraitCluster: Portrait TextureRect not found. Please set `portrait_node`.")
		return

	_ensure_portrait_viewport()

	_resolve_party_manager()

	_resolve_inventory_sys()
	_connect_inventory_signals()

	if _party_manager != null and _party_manager.has_method("get_controlled"):
		var leader: Node = _party_manager.call("get_controlled") as Node
		_update_portrait_from_leader(leader)

	_resolve_audio_sys()
	_collect_and_wire_equipment_slots()


func _exit_tree() -> void:
	_disconnect_party_manager()
	_disconnect_inventory_signals()
	_unwire_equipment_slots()
	_clear_portrait_clone()


# -------------------------------------------------------------------
# PartyManager hookup
# -------------------------------------------------------------------
func _resolve_party_manager() -> void:
	_disconnect_party_manager()

	var candidate: Node = null

	if party_manager_path != NodePath(""):
		var node_candidate: Node = get_node_or_null(party_manager_path)
		if node_candidate != null:
			candidate = node_candidate

	if candidate == null and search_party_manager_by_group:
		var list: Array[Node] = get_tree().get_nodes_in_group(party_manager_group_name)
		if list.size() > 0:
			candidate = list[0]

	_party_manager = candidate

	if _party_manager != null:
		if _party_manager.has_signal("controlled_changed"):
			_party_manager.connect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
		else:
			push_warning("PortraitCluster: PartyManager found but does not have `controlled_changed` signal.")


func _disconnect_party_manager() -> void:
	if _party_manager != null:
		if _party_manager.is_connected("controlled_changed", Callable(self, "_on_party_controlled_changed")):
			_party_manager.disconnect("controlled_changed", Callable(self, "_on_party_controlled_changed"))
	_party_manager = null


func _on_party_controlled_changed(new_leader: Node) -> void:
	_update_portrait_from_leader(new_leader)


func _update_portrait_from_leader(leader: Node) -> void:
	_current_leader = leader

	if leader == null:
		_set_portrait_texture(null)
		_clear_portrait_clone()
		return

	if leader.has_method("get_portrait_texture"):
		var tex: Texture2D = leader.call("get_portrait_texture") as Texture2D
		if tex != null:
			_set_portrait_texture(tex)
			_clear_portrait_clone()
			return

	var ok: bool = _build_visual_root_portrait(leader)
	if ok:
		var sv_tex: Texture2D = _sv.get_texture()
		_set_portrait_texture(sv_tex)
		return

	_set_portrait_texture(null)
	_clear_portrait_clone()


func _set_portrait_texture(tex: Texture2D) -> void:
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_portrait.texture = tex


# -------------------------------------------------------------------
# Inventory hook
# -------------------------------------------------------------------
func _resolve_inventory_sys() -> void:
	_inventory_obj = null

	var root: Node = get_tree().get_root()
	var i: int = 0
	while i < inventory_autoload_names.size():
		var nm: String = String(inventory_autoload_names[i])
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_inventory_obj = obj
				if debug_log:
					print("[PortraitCluster] Resolved inventory autoload: ", path)
				return
		i += 1


func _connect_inventory_signals() -> void:
	if _inventory_obj == null:
		return
	if not is_instance_valid(_inventory_obj):
		return

	if _inventory_obj.has_signal("actor_equipped_changed"):
		if not _inventory_obj.is_connected("actor_equipped_changed", Callable(self, "_on_actor_equipped_changed")):
			_inventory_obj.connect("actor_equipped_changed", Callable(self, "_on_actor_equipped_changed"))


func _disconnect_inventory_signals() -> void:
	if _inventory_obj == null:
		return
	if not is_instance_valid(_inventory_obj):
		return

	if _inventory_obj.has_signal("actor_equipped_changed"):
		if _inventory_obj.is_connected("actor_equipped_changed", Callable(self, "_on_actor_equipped_changed")):
			_inventory_obj.disconnect("actor_equipped_changed", Callable(self, "_on_actor_equipped_changed"))


func _on_actor_equipped_changed(actor: Node, slot: String, _prev_item: Resource, _new_item: Resource) -> void:
	if actor == null or _current_leader == null:
		return
	if actor != _current_leader:
		return

	var slot_norm: String = slot.strip_edges().to_lower()
	if slot_norm == "":
		return

	if not _is_watched_equip_slot(slot_norm):
		return

	if debug_log:
		print("[PortraitCluster] Equip changed on leader slot=", slot, " -> refreshing portrait.")
	_update_portrait_from_leader(_current_leader)


func _is_watched_equip_slot(slot_norm: String) -> bool:
	var i: int = 0
	while i < watch_equip_slots_for_portrait_refresh.size():
		var s: String = String(watch_equip_slots_for_portrait_refresh[i]).strip_edges().to_lower()
		if s != "" and s == slot_norm:
			return true
		i += 1
	return false


# -------------------------------------------------------------------
# Portrait viewport pipeline
# -------------------------------------------------------------------
func _ensure_portrait_viewport() -> void:
	if _sv != null and is_instance_valid(_sv):
		return

	_sv = SubViewport.new()
	_sv.name = "PortraitViewport"
	_sv.transparent_bg = true
	_sv.disable_3d = true
	_sv.size = viewport_size_px
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	add_child(_sv)

	_sv_root = Node2D.new()
	_sv_root.name = "PortraitRoot2D"
	_sv.add_child(_sv_root)


func _clear_portrait_clone() -> void:
	if _sv_clone != null and is_instance_valid(_sv_clone):
		_sv_clone.queue_free()
	_sv_clone = null


func _build_visual_root_portrait(leader: Node) -> bool:
	_ensure_portrait_viewport()

	if _sv == null or _sv_root == null:
		return false

	var vr: Node = _find_visual_root(leader)
	if vr == null:
		return false

	_clear_portrait_clone()

	var clone: Node = vr.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
	if clone == null:
		return false

	_sv_clone = clone
	_sv_root.add_child(_sv_clone)

	_disable_processing_recursive(_sv_clone)

	if hide_weapon_nodes_in_portrait:
		_hide_named_nodes_recursive(_sv_clone, weapon_node_names_to_hide)

	if prefer_idle_down_animation:
		_force_animation_on_all_animated_sprites(_sv_clone, idle_down_name)

	var center: Vector2 = Vector2(float(_sv.size.x) * 0.5, float(_sv.size.y) * 0.5)
	var n2d: Node2D = _sv_clone as Node2D
	if n2d != null:
		n2d.position = center + portrait_offset_px
		n2d.scale = Vector2(portrait_zoom, portrait_zoom)

	var motion_player: AnimationPlayer = _sv_clone.get_node_or_null("MotionPlayer") as AnimationPlayer
	if motion_player != null:
		motion_player.stop()

	return true


func _find_visual_root(leader: Node) -> Node:
	if leader == null:
		return null

	var direct: Node = leader.get_node_or_null(NodePath(visual_root_name))
	if direct != null:
		return direct

	return leader.find_child(visual_root_name, true, false)


func _disable_processing_recursive(root: Node) -> void:
	if root == null:
		return

	root.process_mode = Node.PROCESS_MODE_DISABLED

	var i: int = 0
	while i < root.get_child_count():
		var c: Node = root.get_child(i)
		if c != null:
			_disable_processing_recursive(c)
		i += 1


func _hide_named_nodes_recursive(root: Node, names_to_hide: PackedStringArray) -> void:
	if root == null:
		return

	var nm: String = root.name
	var i: int = 0
	while i < names_to_hide.size():
		var target: String = String(names_to_hide[i])
		if target != "" and nm == target:
			var canvas: CanvasItem = root as CanvasItem
			if canvas != null:
				canvas.visible = false
			break
		i += 1

	var j: int = 0
	while j < root.get_child_count():
		var c: Node = root.get_child(j)
		if c != null:
			_hide_named_nodes_recursive(c, names_to_hide)
		j += 1


func _force_animation_on_all_animated_sprites(root: Node, desired_anim_name: String) -> void:
	if root == null:
		return

	var desired_norm: String = desired_anim_name.strip_edges().to_lower()
	if desired_norm == "":
		return

	var q: Array[Node] = []
	q.append(root)

	while q.size() > 0:
		var n: Node = q.pop_front()
		var aspr: AnimatedSprite2D = n as AnimatedSprite2D
		if aspr != null:
			var frames: SpriteFrames = aspr.sprite_frames
			if frames != null:
				var chosen: String = _find_animation_name_case_insensitive(frames, desired_norm)
				if chosen != "":
					aspr.animation = chosen
					aspr.frame = 0
					aspr.play()

		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1


func _find_animation_name_case_insensitive(frames: SpriteFrames, desired_norm: String) -> String:
	if frames == null:
		return ""

	var names: PackedStringArray = frames.get_animation_names()
	var i: int = 0
	while i < names.size():
		var nm: String = String(names[i]).strip_edges()
		if nm.to_lower() == desired_norm:
			return nm
		i += 1

	return ""


# -------------------------------------------------------------------
# Equipment Slots: selection outline + UI_click
# -------------------------------------------------------------------
func _collect_and_wire_equipment_slots() -> void:
	_equip_slots.clear()

	if equipment_slot_paths.size() > 0:
		var i: int = 0
		while i < equipment_slot_paths.size():
			var p: NodePath = equipment_slot_paths[i]
			if p != NodePath(""):
				var n: Node = get_node_or_null(p)
				var c: Control = n as Control
				if c != null:
					_equip_slots.append(c)
			i += 1

	if _equip_slots.is_empty() and search_slots_by_group and equipment_slot_group_name != "":
		var group_nodes: Array[Node] = get_tree().get_nodes_in_group(equipment_slot_group_name)
		var j: int = 0
		while j < group_nodes.size():
			var c2: Control = group_nodes[j] as Control
			if c2 != null and _is_descendant_of_self(c2):
				_equip_slots.append(c2)
			j += 1

	if _equip_slots.is_empty() and search_slots_by_heuristic:
		var found: Array[Control] = _find_slots_by_heuristic(self)
		var k: int = 0
		while k < found.size():
			_equip_slots.append(found[k])
			k += 1

	var s: int = 0
	while s < _equip_slots.size():
		var slot: Control = _equip_slots[s]
		_ensure_selection_overlay(slot)
		_wire_slot_input(slot)
		s += 1


func _unwire_equipment_slots() -> void:
	var i: int = 0
	while i < _equip_slots.size():
		var slot: Control = _equip_slots[i]
		if slot != null and is_instance_valid(slot):
			var btn: BaseButton = slot as BaseButton
			if btn != null:
				if btn.pressed.is_connected(Callable(self, "_on_equipment_slot_pressed")):
					btn.pressed.disconnect(Callable(self, "_on_equipment_slot_pressed"))
			else:
				if slot.gui_input.is_connected(Callable(self, "_on_equipment_slot_gui_input")):
					slot.gui_input.disconnect(Callable(self, "_on_equipment_slot_gui_input"))
		i += 1

	_equip_slots.clear()
	_selected_slot = null


func _wire_slot_input(slot: Control) -> void:
	if slot == null:
		return

	var btn: BaseButton = slot as BaseButton
	if btn != null:
		if btn.pressed.is_connected(Callable(self, "_on_equipment_slot_pressed")):
			btn.pressed.disconnect(Callable(self, "_on_equipment_slot_pressed"))
		btn.pressed.connect(Callable(self, "_on_equipment_slot_pressed").bind(slot))
		return

	if slot.gui_input.is_connected(Callable(self, "_on_equipment_slot_gui_input")):
		slot.gui_input.disconnect(Callable(self, "_on_equipment_slot_gui_input"))
	slot.gui_input.connect(Callable(self, "_on_equipment_slot_gui_input").bind(slot))


func _on_equipment_slot_pressed(slot: Control) -> void:
	_select_equipment_slot(slot, "pressed")


func _on_equipment_slot_gui_input(event: InputEvent, slot: Control) -> void:
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_select_equipment_slot(slot, "gui_input")


func _select_equipment_slot(slot: Control, _reason: String) -> void:
	if slot == null:
		return

	_selected_slot = slot
	_play_ui_sound(ui_click_event, ui_click_volume_db)

	var i: int = 0
	while i < _equip_slots.size():
		var s: Control = _equip_slots[i]
		_set_overlay_visible(s, s == _selected_slot)
		i += 1


func _ensure_selection_overlay(slot: Control) -> void:
	if slot == null:
		return

	var existing: Node = slot.get_node_or_null("SelectionOutline")
	var panel: Panel = existing as Panel
	if panel == null:
		panel = Panel.new()
		panel.name = "SelectionOutline"
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		panel.anchor_left = 0.0
		panel.anchor_top = 0.0
		panel.anchor_right = 1.0
		panel.anchor_bottom = 1.0
		panel.offset_left = 0.0
		panel.offset_top = 0.0
		panel.offset_right = 0.0
		panel.offset_bottom = 0.0
		slot.add_child(panel)
		slot.move_child(panel, slot.get_child_count() - 1)

	_apply_outline_style(panel)
	panel.visible = false


func _apply_outline_style(panel: Panel) -> void:
	if panel == null:
		return

	if not selected_outline_enabled:
		panel.visible = false
		return

	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.border_color = selected_outline_color

	var w: int = selected_outline_width
	if w <= 0:
		w = 1

	sb.border_width_left = w
	sb.border_width_right = w
	sb.border_width_top = w
	sb.border_width_bottom = w

	panel.add_theme_stylebox_override(&"panel", sb)


func _set_overlay_visible(slot: Control, is_on: bool) -> void:
	if slot == null or not is_instance_valid(slot):
		return
	var panel: Panel = slot.get_node_or_null("SelectionOutline") as Panel
	if panel == null:
		return

	_apply_outline_style(panel)

	if selected_outline_enabled:
		panel.visible = is_on
	else:
		panel.visible = false


func _is_descendant_of_self(n: Node) -> bool:
	if n == null:
		return false
	var cur: Node = n
	var depth: int = 0
	while cur != null and depth < 64:
		if cur == self:
			return true
		cur = cur.get_parent()
		depth += 1
	return false


func _find_slots_by_heuristic(root_node: Node) -> Array[Control]:
	var out: Array[Control] = []
	if root_node == null:
		return out

	var q: Array[Node] = []
	q.append(root_node)

	while q.size() > 0:
		var n: Node = q.pop_front()
		var c: Control = n as Control
		if c != null:
			var nm: String = c.name.to_lower()
			var looks_like_slot: bool = (nm.find("slot") >= 0) or (nm.find("equip") >= 0)
			if looks_like_slot:
				var btn: BaseButton = c as BaseButton
				if btn != null:
					out.append(c)
				else:
					out.append(c)

		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1

	return out


# -------------------------------------------------------------------
# Audio (UI click)
# -------------------------------------------------------------------
func _resolve_audio_sys() -> void:
	if _audio_checked_once and _audio_obj != null and is_instance_valid(_audio_obj):
		return
	if _audio_checked_once and _audio_obj == null:
		return

	_audio_checked_once = true
	_audio_obj = null

	var root: Node = get_tree().get_root()
	var i: int = 0
	while i < audio_autoload_names.size():
		var nm: String = String(audio_autoload_names[i])
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_audio_obj = obj
				return
		i += 1


func _play_ui_sound(event_name: StringName, volume_db: float) -> void:
	if event_name == StringName(""):
		return

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		_audio_checked_once = false
		_resolve_audio_sys()

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		return

	if _audio_obj.has_method("play_ui_sfx"):
		_audio_obj.call("play_ui_sfx", event_name, volume_db)
		return

	if _audio_obj.has_method("play_sfx_event"):
		_audio_obj.call("play_sfx_event", event_name, Vector2.INF, volume_db)
		return
