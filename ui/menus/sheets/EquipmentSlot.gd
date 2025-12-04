extends Control
class_name EquipmentSlot

signal slot_selected(slot_name: String, item: ItemDef)

@export var slot_name: String
@export var frame_path: NodePath = ^"Frame"

var _inv: InventorySystem = null
var _party: Node = null
var _frame: TextureRect = null
var _icon_rect: TextureRect = null
var _hovering_valid: bool = false

# Click vs Drag state
var _pressing: bool = false
var _dragging: bool = false
var _press_pos: Vector2 = Vector2.ZERO
var _drag_threshold_px: float = 4.0

func _ready() -> void:
	# Resolve singletons
	_inv = get_node_or_null("/root/InventorySystem") as InventorySystem
	if _inv == null:
		_inv = get_node_or_null("/root/InventorySys") as InventorySystem

	# Preferred Party autoload; fallback to PartyManager
	_party = get_node_or_null("/root/Party")
	if _party == null:
		_party = get_tree().get_first_node_in_group("PartyManager")
	if _party == null:
		_party = get_node_or_null("/root/PartyManager")

	# Nodes
	_frame = get_node_or_null(frame_path) as TextureRect
	mouse_filter = Control.MOUSE_FILTER_PASS

	# Overlay TextureRect to render the equipped icon ABOVE the frame.
	_icon_rect = TextureRect.new()
	_icon_rect.name = "Icon"
	_icon_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_icon_rect)
	move_child(_icon_rect, get_child_count() - 1)
	_update_icon_rect_size()

	# Listen for changes
	if _inv != null:
		if _inv.has_signal("actor_equipped_changed"):
			_inv.actor_equipped_changed.connect(_on_actor_equipped_changed)
		if _inv.has_signal("inventory_changed"):
			_inv.inventory_changed.connect(_on_inventory_changed)

	if _party != null:
		if _party.has_signal("controlled_changed"):
			_party.controlled_changed.connect(_on_controlled_changed)

	_refresh_icon()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_icon_rect_size()
	if what == NOTIFICATION_DRAG_END:
		_dragging = false
		_pressing = false

func _update_icon_rect_size() -> void:
	if _icon_rect == null:
		return
	_icon_rect.position = Vector2.ZERO
	_icon_rect.size = size

func _get_controlled_actor() -> Node:
	if _party != null and _party.has_method("get_controlled"):
		var v: Variant = _party.call("get_controlled")
		if v is Node:
			return v as Node
	return null

func _bag_for_controlled(create_if_missing: bool) -> InventoryModel:
	if _inv == null:
		return null
	var user: Node = _get_controlled_actor()
	if user == null:
		return null
	if create_if_missing:
		return _inv.ensure_inventory_model_for(user)
	return _inv.get_inventory_model_for(user)

func _on_controlled_changed(_current: Node) -> void:
	_refresh_icon()

func _on_inventory_changed() -> void:
	_refresh_icon()

func _on_actor_equipped_changed(actor: Node, slot: String, _prev_item: ItemDef, _new_item: ItemDef) -> void:
	if String(slot) != String(slot_name):
		return
	var controlled: Node = _get_controlled_actor()
	if controlled == null:
		return
	if actor != controlled:
		return
	_refresh_icon()

func _current_equipped_item() -> ItemDef:
	if _inv == null:
		return null
	var controlled: Node = _get_controlled_actor()
	if controlled == null:
		return null
	var em_v: Variant = _inv.call("ensure_equipment_model_for", controlled)
	if typeof(em_v) != TYPE_OBJECT:
		return null
	var em: EquipmentModel = em_v
	if not em.has_method("get_equipped"):
		return null
	return em.get_equipped(String(slot_name))

func _refresh_icon() -> void:
	var itm: ItemDef = _current_equipped_item()
	if _icon_rect != null:
		if itm != null:
			_icon_rect.texture = itm.icon
		else:
			_icon_rect.texture = null

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if _pressing and not _dragging:
			var dist: float = mm.position.distance_to(_press_pos)
			if dist >= _drag_threshold_px:
				_dragging = true

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressing = true
				_dragging = false
				_press_pos = mb.position
			else:
				# Click without drag: select to show description (no movement)
				if _pressing and not _dragging:
					var itm: ItemDef = _current_equipped_item()
					slot_selected.emit(slot_name, itm)
				_pressing = false
				_dragging = false

# Accept equipping by dropping an inventory item onto this slot
func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	_hovering_valid = false
	_update_frame(false)

	if typeof(data) != TYPE_DICTIONARY:
		return false

	var d: Dictionary = data
	if not d.has("type"):
		return false
	if String(d["type"]) != "inv_item":
		return false
	if not d.has("index"):
		return false

	# NEW: read the item from the controlled actor’s bag (per-actor inventory)
	var bag: InventoryModel = _bag_for_controlled(false)
	if bag == null:
		return false

	var idx: int = int(d["index"])
	var st_v: Variant = bag.get_slot_stack(idx)
	if typeof(st_v) != TYPE_OBJECT:
		return false

	var st: ItemStack = st_v
	if st == null or st.item == null:
		return false

	var item: ItemDef = st.item
	var is_equipment: bool = String(item.item_type) == "equipment"
	var slot_matches: bool = String(item.equip_slot) == String(slot_name)

	var ok: bool = false
	if is_equipment and slot_matches:
		ok = true

	_hovering_valid = ok
	_update_frame(ok)
	return ok

func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_update_frame(false)
	if not _hovering_valid:
		return
	if typeof(data) != TYPE_DICTIONARY:
		return
	if _inv == null or not _inv.has_method("try_equip_from_inventory"):
		return

	var idx: int = int((data as Dictionary).get("index", -1))
	if idx < 0:
		return

	var user: Node = _get_controlled_actor()
	if user == null:
		return

	var res_v: Variant = _inv.call("try_equip_from_inventory", user, idx)
	var equipped_ok: bool = false
	if typeof(res_v) == TYPE_BOOL:
		equipped_ok = bool(res_v)
	if equipped_ok:
		_refresh_icon()
		# InventorySys will also emit inventory_changed / actor_equipped_changed

# Drag source: allow dragging equipped item back to the inventory grid
func _get_drag_data(_at_position: Vector2) -> Variant:
	var itm: ItemDef = _current_equipped_item()
	if itm == null:
		return null

	_dragging = true
	var payload: Dictionary = {}
	payload["type"] = "equipped_item"
	payload["slot"] = String(slot_name)

	if itm.icon != null:
		var preview := TextureRect.new()
		preview.texture = itm.icon
		preview.stretch_mode = TextureRect.STRETCH_KEEP
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		set_drag_preview(preview)

	return payload

func _update_frame(active: bool) -> void:
	if _frame == null:
		return
	if active:
		_frame.modulate = Color(1.0, 1.0, 1.0, 1.0)
	else:
		_frame.modulate = Color(1.0, 1.0, 1.0, 0.85)
