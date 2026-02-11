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
# Best: fill these in the inspector with the exact nodes for each equipment slot control/button.
@export var equipment_slot_paths: Array[NodePath] = []
# If you prefer groups: put your slot nodes in this group.
@export var equipment_slot_group_name: String = "equipment_slot"
@export var search_slots_by_group: bool = true
# Heuristic fallback (safe-ish): searches children for names containing "slot" or "equip".
@export var search_slots_by_heuristic: bool = true

@export_group("Selection Outline")
@export var selected_outline_enabled: bool = true
@export var selected_outline_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var selected_outline_width: int = 1

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

# Slots we found + selection state
var _equip_slots: Array[Control] = []
var _selected_slot: Control = null

# Audio autoload cache
var _audio_obj: Object = null
var _audio_checked_once: bool = false


func _ready() -> void:
	# Basic safety: ensure the portrait TextureRect exists
	if _portrait == null:
		push_warning("PortraitCluster: Portrait TextureRect not found. Please set `portrait_node`.")
		return

	# Try to resolve PartyManager (explicit path first, then group)
	_resolve_party_manager()

	# Initialize from current controlled, if available
	if _party_manager != null and _party_manager.has_method("get_controlled"):
		var leader: Node = _party_manager.call("get_controlled") as Node
		_update_portrait_from_leader(leader)

	# Resolve audio
	_resolve_audio_sys()

	# Wire equipment slots
	_collect_and_wire_equipment_slots()


func _exit_tree() -> void:
	_disconnect_party_manager()
	_unwire_equipment_slots()


# -------------------------------------------------------------------
# PartyManager hookup (unchanged behavior)
# -------------------------------------------------------------------
func _resolve_party_manager() -> void:
	_disconnect_party_manager()

	var candidate: Node = null

	# 1) Explicit NodePath if provided
	if party_manager_path != NodePath(""):
		var node_candidate: Node = get_node_or_null(party_manager_path)
		if node_candidate != null:
			candidate = node_candidate

	# 2) Fallback: search by group if allowed
	if candidate == null and search_party_manager_by_group:
		var list: Array[Node] = get_tree().get_nodes_in_group(party_manager_group_name)
		if list.size() > 0:
			candidate = list[0]

	_party_manager = candidate

	# Connect to controlled_changed if present
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
	if leader == null:
		_set_portrait_texture(null)
		return

	# 1) Preferred: character provides a dedicated portrait texture
	if leader.has_method("get_portrait_texture"):
		var tex: Texture2D = leader.call("get_portrait_texture") as Texture2D
		if tex != null:
			_set_portrait_texture(tex)
			return

	# 2) Try AnimatedSprite2D → SpriteFrames → "idle_down" frame 0
	var anim_sprite: AnimatedSprite2D = _find_first_animated_sprite2d(leader)
	if anim_sprite != null:
		var frames: SpriteFrames = anim_sprite.sprite_frames
		if frames != null:
			if frames.has_animation("idle_down"):
				if frames.get_frame_count("idle_down") > 0:
					var frame_tex: Texture2D = frames.get_frame_texture("idle_down", 0)
					if frame_tex != null:
						_set_portrait_texture(frame_tex)
						return

	# 3) Fallback: any Sprite2D texture
	var sprite2d: Sprite2D = _find_first_sprite2d(leader)
	if sprite2d != null:
		var spr_tex: Texture2D = sprite2d.texture
		if spr_tex != null:
			_set_portrait_texture(spr_tex)
			return

	_set_portrait_texture(null)


func _set_portrait_texture(tex: Texture2D) -> void:
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	_portrait.texture = tex


# -------------------------------------------------------------------
# Equipment Slots: selection outline + UI_click
# -------------------------------------------------------------------
func _collect_and_wire_equipment_slots() -> void:
	_equip_slots.clear()

	# 1) Explicit paths (best)
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

	# 2) Group lookup
	if _equip_slots.is_empty() and search_slots_by_group and equipment_slot_group_name != "":
		var group_nodes: Array[Node] = get_tree().get_nodes_in_group(equipment_slot_group_name)
		var j: int = 0
		while j < group_nodes.size():
			var c2: Control = group_nodes[j] as Control
			if c2 != null and _is_descendant_of_self(c2):
				_equip_slots.append(c2)
			j += 1

	# 3) Heuristic fallback under this cluster
	if _equip_slots.is_empty() and search_slots_by_heuristic:
		var found: Array[Control] = _find_slots_by_heuristic(self)
		var k: int = 0
		while k < found.size():
			_equip_slots.append(found[k])
			k += 1

	# Wire events + ensure overlay node exists
	var s: int = 0
	while s < _equip_slots.size():
		var slot: Control = _equip_slots[s]
		_ensure_selection_overlay(slot)
		_wire_slot_input(slot)
		s += 1

	if debug_log:
		print("[PortraitCluster] Found equipment slots: ", str(_equip_slots.size()))
		var t: int = 0
		while t < _equip_slots.size():
			print("  - slot[", t, "] = ", str(_equip_slots[t].get_path()))
			t += 1


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

	# Prefer pressed() if it's a button
	var btn: BaseButton = slot as BaseButton
	if btn != null:
		if btn.pressed.is_connected(Callable(self, "_on_equipment_slot_pressed")):
			btn.pressed.disconnect(Callable(self, "_on_equipment_slot_pressed"))
		btn.pressed.connect(Callable(self, "_on_equipment_slot_pressed").bind(slot))
		return

	# Otherwise, listen for gui_input clicks
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


func _select_equipment_slot(slot: Control, reason: String) -> void:
	if slot == null:
		return

	_selected_slot = slot
	_play_ui_sound(ui_click_event, ui_click_volume_db)

	# Update overlays
	var i: int = 0
	while i < _equip_slots.size():
		var s: Control = _equip_slots[i]
		_set_overlay_visible(s, s == _selected_slot)
		i += 1

	if debug_log:
		print("[PortraitCluster] Selected slot: ", str(slot.get_path()), " via ", reason)


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
		# Put on top of slot contents
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

	# Re-apply style in case outline settings changed in inspector at runtime.
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
				# Prefer things that can be clicked
				var btn: BaseButton = c as BaseButton
				if btn != null:
					out.append(c)
				else:
					# Allow non-buttons too; we'll use gui_input on them
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
		var nm: String = audio_autoload_names[i]
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_audio_obj = obj
				if debug_log:
					print("[PortraitCluster] Resolved audio autoload: ", path)
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

	# Fallback (older AudioSystem)
	if _audio_obj.has_method("play_sfx_event"):
		_audio_obj.call("play_sfx_event", event_name, Vector2.INF, volume_db)
		return


# --------- Helpers ---------
func _find_first_animated_sprite2d(root: Node) -> AnimatedSprite2D:
	var q: Array[Node] = []
	q.append(root)
	while q.size() > 0:
		var n: Node = q.pop_front()
		var aspr: AnimatedSprite2D = n as AnimatedSprite2D
		if aspr != null:
			return aspr
		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1
	return null


func _find_first_sprite2d(root: Node) -> Sprite2D:
	var q: Array[Node] = []
	q.append(root)
	while q.size() > 0:
		var n: Node = q.pop_front()
		var spr: Sprite2D = n as Sprite2D
		if spr != null and spr.texture != null:
			return spr
		var i: int = 0
		while i < n.get_child_count():
			q.append(n.get_child(i))
			i += 1
	return null
