extends Control
class_name ConsumableReadyBar

signal consumable_used(slot_index: int, from_slot_index: int)
signal slot_assigned(slot_index: int, from_slot_index: int)
signal slot_cleared(slot_index: int)

@export var background: Texture2D
@export var slot_size: Vector2i = Vector2i(16, 16)
@export var slot_positions: PackedVector2Array = PackedVector2Array([Vector2(0, 0), Vector2(16, 16)])

@export var icon_placeholder: Texture2D
@export var action_use_1: StringName = &"ui_use_consume_1"
@export var action_use_2: StringName = &"ui_use_consume_2"

# Quantity label knobs (per-slot nudges)
@export var qty_offset_x: int = 0
@export var qty_offset_y: int = 0
@export var qty_offset_x2: int = 0
@export var qty_offset_y2: int = 0
@export var qty_font: Font
@export var qty_font_size: int = 8
@export var qty_color: Color = Color(1, 1, 1, 1)

@export var drag_threshold_px: float = 6.0
@export var debug_trace: bool = false

# Active actor’s 2-slot mapping (inventory indices)
var _from_slot_index: Array[int] = [-1, -1]

# Built slot nodes
var _slots: Array[Control] = []
var _press_pos: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _pressed: Array[bool] = [false, false]
var _dragging: Array[bool] = [false, false]

# While any drag is active, let drags pass through to other UI (Hotbar, etc.)
var _drag_passthrough_active: bool = false

# Per-actor mapping: instance_id() -> [slot0_index, slot1_index]
var _assigned_by_actor: Dictionary = {}

# Cached autoloads
var _inv_sys: InventorySystem = null
var _party: Node = null

# ---------- Slot class (drop target) ----------
class SlotNode:
	extends Control
	var bar: ConsumableReadyBar
	var idx: int = -1

	func _init(p_bar: ConsumableReadyBar, p_idx: int) -> void:
		bar = p_bar
		idx = p_idx

	func _can_drop_data(_pos: Vector2, data: Variant) -> bool:
		return bar._payload_is_consumable_for_controlled(data)

	func _drop_data(_pos: Vector2, data: Variant) -> void:
		if not bar._payload_is_consumable_for_controlled(data):
			return
		var d: Dictionary = data
		var inv_slot: int = int(d["index"])
		bar._assign_slot_for_current_actor(idx, inv_slot)
		bar._refresh_visual(idx)
		bar.slot_assigned.emit(idx, inv_slot)

	func _gui_input(event: InputEvent) -> void:
		bar._on_slot_gui_input(event, idx)

# ---------- Lifecycle ----------
func _ready() -> void:
	_resolve_autoloads()
	_bind_signals()
	_build_bg()
	_build_slots()
	set_process_unhandled_input(true)
	_set_drag_passthrough(false) # idle

	# Load current actor’s mapping and paint
	_load_assignments_for_current_actor()
	_refresh_visual(0)
	_refresh_visual(1)

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_BEGIN:
		_set_drag_passthrough(true)
	elif what == NOTIFICATION_DRAG_END:
		_set_drag_passthrough(false)

# ---------- Autoloads / Signals ----------
func _resolve_autoloads() -> void:
	var n: Node = get_node_or_null("/root/InventorySystem")
	if n == null:
		n = get_node_or_null("/root/InventorySys")
	_inv_sys = n as InventorySystem

	_party = get_node_or_null("/root/Party")
	if _party == null:
		_party = get_tree().get_first_node_in_group("PartyManager")
	if _party == null:
		_party = get_node_or_null("/root/PartyManager")

func _bind_signals() -> void:
	if _inv_sys != null and _inv_sys.has_signal("inventory_changed"):
		if not _inv_sys.is_connected("inventory_changed", Callable(self, "_on_inventory_changed")):
			_inv_sys.inventory_changed.connect(_on_inventory_changed)
	if _party != null:
		if _party.has_signal("controlled_changed"):
			if not _party.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
				_party.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
		if _party.has_signal("party_changed"):
			if not _party.is_connected("party_changed", Callable(self, "_on_party_changed")):
				_party.connect("party_changed", Callable(self, "_on_party_changed"))

func _on_inventory_changed() -> void:
	_refresh_visual(0)
	_refresh_visual(1)

func _on_controlled_changed(_actor: Node) -> void:
	_save_assignments_for_current_actor()
	_load_assignments_for_current_actor()
	_refresh_visual(0)
	_refresh_visual(1)

func _on_party_changed(_members: Array) -> void:
	_refresh_visual(0)
	_refresh_visual(1)

# ---------- Actor / Bag helpers ----------
func _controlled() -> Node:
	if _party != null and _party.has_method("get_controlled"):
		var v: Variant = _party.call("get_controlled")
		if v is Node:
			return v as Node
	return null

func _bag_for_controlled(create_if_missing: bool) -> InventoryModel:
	if _inv_sys == null:
		return null
	var user: Node = _controlled()
	if user == null:
		return null
	if create_if_missing:
		return _inv_sys.ensure_inventory_model_for(user)
	return _inv_sys.get_inventory_model_for(user)

# ---------- Per-actor assignments ----------
func _actor_key(a: Node) -> int:
	if a == null:
		return 0
	return a.get_instance_id()

func _save_assignments_for_current_actor() -> void:
	var user: Node = _controlled()
	if user == null:
		return
	var key: int = _actor_key(user)
	_assigned_by_actor[key] = [int(_from_slot_index[0]), int(_from_slot_index[1])]

func _load_assignments_for_current_actor() -> void:
	_from_slot_index = [-1, -1]
	var user: Node = _controlled()
	if user == null:
		return
	var key: int = _actor_key(user)
	if _assigned_by_actor.has(key):
		var arr_v: Variant = _assigned_by_actor[key]
		if typeof(arr_v) == TYPE_ARRAY:
			var arr: Array = arr_v
			if arr.size() >= 2:
				_from_slot_index[0] = int(arr[0])
				_from_slot_index[1] = int(arr[1])

func _assign_slot_for_current_actor(idx: int, inv_slot: int) -> void:
	if idx < 0 or idx >= _from_slot_index.size():
		return
	_from_slot_index[idx] = inv_slot
	_save_assignments_for_current_actor()

# ---------- Root-level DnD fallback (optional; Slots handle most drops) ----------
func _can_drop_data(pos: Vector2, data: Variant) -> bool:
	if not _payload_is_consumable_for_controlled(data):
		return false
	var idx: int = _slot_at(pos)
	return idx >= 0

func _drop_data(pos: Vector2, data: Variant) -> void:
	if not _payload_is_consumable_for_controlled(data):
		return
	var idx: int = _slot_at(pos)
	if idx < 0:
		return
	var d: Dictionary = data
	var inv_slot: int = int(d["index"])
	_assign_slot_for_current_actor(idx, inv_slot)
	_refresh_visual(idx)
	slot_assigned.emit(idx, inv_slot)

# ---------- Build ----------
func _build_bg() -> void:
	var bg: TextureRect = $BG as TextureRect
	if bg == null:
		bg = TextureRect.new()
		bg.name = "BG"
		add_child(bg)

	bg.texture = background
	bg.stretch_mode = TextureRect.STRETCH_KEEP
	var tex_size: Vector2 = Vector2(32, 32)
	if background != null:
		var s: Vector2i = background.get_size()
		tex_size = Vector2(float(s.x), float(s.y))
	bg.size = tex_size
	bg.position = Vector2.ZERO
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.z_index = 0

	custom_minimum_size = tex_size
	size = tex_size
	mouse_filter = Control.MOUSE_FILTER_PASS

func _build_slots() -> void:
	if slot_positions.size() < 2:
		slot_positions = PackedVector2Array([Vector2(0, 0), Vector2(16, 16)])

	_slots.clear()
	var i: int = 0
	while i < 2:
		var slot_name: String = "Slot" + str(i + 1)
		var slot: Control = get_node_or_null(slot_name) as Control
		if slot == null or not (slot is SlotNode):
			if slot != null:
				slot.queue_free()
			var sn := SlotNode.new(self, i)
			sn.name = slot_name
			add_child(sn)
			slot = sn

		slot.size = Vector2(float(slot_size.x), float(slot_size.y))
		if i < slot_positions.size():
			slot.position = slot_positions[i]
		else:
			slot.position = Vector2.ZERO

		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.z_index = 10

		var icon := slot.get_node_or_null("Icon") as TextureRect
		if icon == null:
			icon = TextureRect.new()
			icon.name = "Icon"
			slot.add_child(icon)
		icon.texture = icon_placeholder
		icon.size = Vector2(float(slot_size.x), float(slot_size.y))
		icon.stretch_mode = TextureRect.STRETCH_KEEP
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.z_index = 11
		_cleanup_extras(slot, "Icon", icon)

		var qty := slot.get_node_or_null("Qty") as Label
		if qty == null:
			qty = Label.new()
			qty.name = "Qty"
			slot.add_child(qty)
		qty.text = "0"
		qty.size = Vector2(float(slot_size.x), float(slot_size.y))
		qty.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		_apply_qty_style(qty, i)
		qty.mouse_filter = Control.MOUSE_FILTER_IGNORE
		qty.z_index = 12
		_cleanup_extras(slot, "Qty", qty)

		var cd := slot.get_node_or_null("Cooldown") as ColorRect
		if cd == null:
			cd = ColorRect.new()
			cd.name = "Cooldown"
			slot.add_child(cd)
		cd.size = Vector2(float(slot_size.x), 0.0)
		cd.position = Vector2(0, 0)
		cd.color = Color(0, 0, 0, 0.55)
		cd.visible = false
		cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cd.z_index = 12
		_cleanup_extras(slot, "Cooldown", cd)

		_slots.append(slot)
		i += 1

	_from_slot_index = [-1, -1]
	_press_pos = [Vector2.ZERO, Vector2.ZERO]
	_pressed = [false, false]
	_dragging = [false, false]
	_apply_current_passthrough_to_slots()

func _cleanup_extras(parent_node: Node, wanted_name: String, keep_ref: Node) -> void:
	var to_delete: Array[Node] = []
	var i: int = 0
	while i < parent_node.get_child_count():
		var c: Node = parent_node.get_child(i)
		if c.name == wanted_name and c != keep_ref:
			to_delete.append(c)
		i += 1
	for n in to_delete:
		n.queue_free()

# ---------- Input ----------
func _unhandled_input(_event: InputEvent) -> void:
	if Input.is_action_just_pressed(action_use_1):
		_use_slot(0)
	if Input.is_action_just_pressed(action_use_2):
		_use_slot(1)

func _on_slot_gui_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_use_slot(idx)
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_clear_slot(idx)

# ---------- Use / Clear / Visuals ----------
func _use_slot(idx: int) -> void:
	if idx < 0 or idx >= _from_slot_index.size():
		return
	var inv_slot: int = _from_slot_index[idx]
	if inv_slot < 0:
		return

	var user: Node = _controlled()
	if user == null:
		return

	var bag: InventoryModel = _bag_for_controlled(true)
	if bag == null:
		return
	if not bag.has_method("use_item"):
		return

	bag.call("use_item", inv_slot, user)

	_refresh_visual(idx)
	consumable_used.emit(idx, inv_slot)

func _clear_slot(idx: int) -> void:
	if idx < 0 or idx >= _from_slot_index.size():
		return
	_from_slot_index[idx] = -1
	_save_assignments_for_current_actor()
	if idx < _slots.size():
		var s: Control = _slots[idx]
		var icon: TextureRect = s.get_node("Icon") as TextureRect
		var qty: Label = s.get_node("Qty") as Label
		var cr: ColorRect = s.get_node("Cooldown") as ColorRect
		icon.texture = icon_placeholder
		qty.text = "0"
		_apply_qty_style(qty, idx)
		cr.visible = false
	slot_cleared.emit(idx)

func _refresh_visual(idx: int) -> void:
	var inv_slot: int = _from_slot_index[idx]
	var s: Control = _slots[idx]
	var icon_node: TextureRect = s.get_node("Icon") as TextureRect
	var qty: Label = s.get_node("Qty") as Label

	if inv_slot < 0:
		icon_node.texture = icon_placeholder
		qty.text = "0"
		_apply_qty_style(qty, idx)
		return

	var bag: InventoryModel = _bag_for_controlled(false)
	if bag == null:
		icon_node.texture = icon_placeholder
		qty.text = "0"
		_apply_qty_style(qty, idx)
		return

	var st_v: Variant = bag.get_slot_stack(inv_slot)
	var icon: Texture2D = icon_placeholder
	var count: int = 0

	if st_v is ItemStack:
		var st: ItemStack = st_v
		if st.item != null:
			icon = st.item.icon
		count = st.count
	elif (st_v as Object) != null:
		var obj: Object = st_v
		if obj.has_method("get_item"):
			var it_any: Variant = obj.call("get_item")
			if it_any is ItemDef:
				icon = (it_any as ItemDef).icon
		if obj.has_method("get_count"):
			var c_any: Variant = obj.call("get_count")
			if typeof(c_any) == TYPE_INT:
				count = int(c_any)

	icon_node.texture = icon
	qty.text = str(count)
	_apply_qty_style(qty, idx)

	if count <= 0:
		_clear_slot(idx)

# ---------- Quantity label styling ----------
func _apply_qty_style(qty_label: Label, idx: int) -> void:
	var x: int = qty_offset_x
	var y: int = qty_offset_y
	if idx == 1:
		x = qty_offset_x2
		y = qty_offset_y2
	qty_label.position = Vector2(float(x), float(y))
	if qty_font != null:
		qty_label.add_theme_font_override("font", qty_font)
	qty_label.add_theme_font_size_override("font_size", qty_font_size)
	qty_label.add_theme_color_override("font_color", qty_color)

# ---------- Drag hit-test helpers ----------
func _slot_at(local_pos: Vector2) -> int:
	var i: int = 0
	while i < _slots.size():
		var s: Control = _slots[i]
		var r: Rect2 = Rect2(s.position, s.size)
		if r.has_point(local_pos):
			return i
		i += 1
	return -1

# ---------- Validation ----------
func _payload_is_consumable_for_controlled(data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var d: Dictionary = data
	if not d.has("type") or String(d["type"]) != "inv_item":
		return false
	if not d.has("index"):
		return false

	var bag: InventoryModel = _bag_for_controlled(false)
	if bag == null:
		return false

	var st_v: Variant = bag.get_slot_stack(int(d["index"]))
	if st_v == null:
		return false

	var item: ItemDef = null
	if st_v is ItemStack:
		item = (st_v as ItemStack).item
	elif (st_v as Object) != null and (st_v as Object).has_method("get_item"):
		var it_any: Variant = (st_v as Object).call("get_item")
		if it_any is ItemDef:
			item = it_any as ItemDef

	if item == null:
		return false
	return String(item.item_type) == "consumable"

# ---------- Drag passthrough ----------
func _set_drag_passthrough(active: bool) -> void:
	if _drag_passthrough_active == active:
		return
	_drag_passthrough_active = active
	_apply_current_passthrough_to_slots()
	if debug_trace:
		print("[ConsumableReadyBar] drag_passthrough=", str(active))

func _apply_current_passthrough_to_slots() -> void:
	var i: int = 0
	while i < _slots.size():
		var slot: Control = _slots[i]
		if _drag_passthrough_active:
			slot.mouse_filter = Control.MOUSE_FILTER_PASS
		else:
			slot.mouse_filter = Control.MOUSE_FILTER_STOP
		i += 1
