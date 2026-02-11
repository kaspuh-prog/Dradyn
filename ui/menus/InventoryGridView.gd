extends Control
class_name InventoryGridView

signal selection_changed(index: int)
signal activated(index: int)
signal hovered(index: int)

@export var cols: int = 12
@export var rows: int = 4
@export var cell_size: int = 16

@export var unlocked_capacity: int = 0:
	set(value):
		var max_slots: int = cols * rows
		var v: int = value
		if v < 0:
			v = 0
		if v > max_slots:
			v = max_slots
		unlocked_capacity = v
		queue_redraw()

@export var tex_slot_open: Texture2D
@export var tex_slot_locked: Texture2D
@export var tex_hover_overlay: Texture2D
@export var tex_selected_overlay: Texture2D

@export_group("Selection Outline")
@export var selected_outline_enabled: bool = true
@export var selected_outline_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var selected_outline_width: float = 1.0

# ---------------- UI SFX ----------------
@export_group("UI SFX")
@export var ui_click_event: StringName = &"UI_click"
@export var ui_click_volume_db: float = 0.0
@export var audio_autoload_names: PackedStringArray = PackedStringArray(["AudioSys", "AudioSystem"])
@export var debug_log: bool = false

var _hover_index: int = -1
var _selected_index: int = -1
var _total_capacity: int = 0

var _inv: InventorySystem = null
var _party: Node = null

# Audio autoload cache
var _audio_obj: Object = null
var _audio_checked_once: bool = false

# Click vs Drag state
var _pressing: bool = false
var _dragging: bool = false
var _press_index: int = -1
var _press_pos: Vector2 = Vector2.ZERO
var _drag_threshold_px: float = 4.0

func _ready() -> void:
	custom_minimum_size = Vector2(cols * cell_size, rows * cell_size)
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_ALL
	_total_capacity = cols * rows

	_resolve_audio_sys()

	_resolve_inventory()
	_resolve_party()
	_bind_party_signals()
	queue_redraw()

# -----------------------------
# Autoloads / signals
# -----------------------------
func _resolve_inventory() -> void:
	var n: Node = get_node_or_null("/root/InventorySystem")
	if n == null:
		n = get_node_or_null("/root/InventorySys")
	_inv = n as InventorySystem
	if _inv != null:
		if _inv.has_signal("inventory_changed"):
			if not _inv.is_connected("inventory_changed", Callable(self, "_on_inventory_changed")):
				_inv.inventory_changed.connect(_on_inventory_changed)

func _resolve_party() -> void:
	# Primary autoload name in this project is "Party"
	_party = get_node_or_null("/root/Party")
	if _party == null:
		_party = get_tree().get_first_node_in_group("PartyManager")
	if _party == null:
		_party = get_node_or_null("/root/PartyManager")

func _bind_party_signals() -> void:
	if _party == null:
		return
	if _party.has_signal("controlled_changed"):
		if not _party.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
			_party.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
	if _party.has_signal("party_changed"):
		if not _party.is_connected("party_changed", Callable(self, "_on_party_changed")):
			_party.connect("party_changed", Callable(self, "_on_party_changed"))

func _on_inventory_changed() -> void:
	queue_redraw()

func _on_controlled_changed(_actor: Node) -> void:
	queue_redraw()

func _on_party_changed(_members: Array) -> void:
	queue_redraw()

# -----------------------------
# Actor / bag helpers
# -----------------------------
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

func _stack_for_controlled(slot_index: int) -> Variant:
	var user: Node = _get_controlled_actor()
	if user == null or _inv == null:
		return null
	# STRICT per-actor read
	return _inv.get_stack_at_for(user, slot_index)

# -----------------------------
# Capacity / selection
# -----------------------------
func set_capacity(unlocked: int, total: int) -> void:
	var grid_total: int = cols * rows
	var clamped_unlocked: int = unlocked
	if clamped_unlocked < 0:
		clamped_unlocked = 0
	if clamped_unlocked > grid_total:
		clamped_unlocked = grid_total
	unlocked_capacity = clamped_unlocked

	var clamped_total: int = total
	if clamped_total < 0:
		clamped_total = 0
	if clamped_total > grid_total:
		clamped_total = grid_total
	_total_capacity = clamped_total

func get_unlocked_capacity() -> int:
	return unlocked_capacity

func get_total_capacity() -> int:
	return _total_capacity

func is_slot_locked(index: int) -> bool:
	if index < 0:
		return true
	var max_slots: int = cols * rows
	if index >= max_slots:
		return true
	if index >= unlocked_capacity:
		return true
	return false

func set_selected_index(index: int) -> void:
	var total: int = cols * rows
	if index < 0:
		_selected_index = -1
	elif index >= total:
		_selected_index = total - 1
	else:
		_selected_index = index
	selection_changed.emit(_selected_index)
	queue_redraw()

func get_selected_index() -> int:
	return _selected_index

# -----------------------------
# Input
# -----------------------------
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		var idx: int = _index_at_local(motion.position)
		if idx != _hover_index:
			_hover_index = idx
			hovered.emit(_hover_index)
			queue_redraw()
		if _pressing and not _dragging:
			var dist: float = motion.position.distance_to(_press_pos)
			if dist >= _drag_threshold_px:
				_dragging = true

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressing = true
				_dragging = false
				_press_pos = mb.position
				_press_index = _index_at_local(mb.position)
				if _press_index >= 0:
					_play_ui_click()
					set_selected_index(_press_index)
			else:
				if _pressing and not _dragging and _press_index >= 0:
					activated.emit(_press_index)
				_pressing = false
				_dragging = false
				_press_index = -1

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_dragging = false
		_pressing = false
		_press_index = -1

func _unhandled_key_input(event: InputEvent) -> void:
	if not has_focus():
		return
	if event.is_action_pressed("ui_left"):
		_move_selection(-1)
	elif event.is_action_pressed("ui_right"):
		_move_selection(1)
	elif event.is_action_pressed("ui_up"):
		_move_selection(-cols)
	elif event.is_action_pressed("ui_down"):
		_move_selection(cols)
	elif event.is_action_pressed("ui_accept"):
		if _selected_index >= 0:
			_play_ui_click()
			activated.emit(_selected_index)

func _move_selection(delta: int) -> void:
	var total: int = cols * rows
	var next: int = _selected_index
	if next < 0:
		next = 0
	else:
		next = next + delta
		if next < 0:
			next = 0
		if next >= total:
			next = total - 1
	set_selected_index(next)

# -----------------------------
# Layout / drawing
# -----------------------------
func _index_at_local(p: Vector2) -> int:
	if p.x < 0.0 or p.y < 0.0:
		return -1
	var cx: int = int(p.x) / cell_size
	var cy: int = int(p.y) / cell_size
	if cx < 0 or cx >= cols:
		return -1
	if cy < 0 or cy >= rows:
		return -1
	return cy * cols + cx

func _draw() -> void:
	var total: int = cols * rows
	var i: int = 0
	while i < total:
		var cx: int = i % cols
		var cy: int = i / cols
		var pos: Vector2 = Vector2(cx * cell_size, cy * cell_size)
		var base_tex: Texture2D = tex_slot_locked
		if i < unlocked_capacity:
			base_tex = tex_slot_open
		if base_tex != null:
			draw_texture(base_tex, pos)
		i += 1
	_draw_item_icons()
	_draw_overlays()

func _draw_item_icons() -> void:
	if _inv == null:
		return
	# Ensure the controlled actor has a bag (so drag works even with empty bags)
	var bag: InventoryModel = _bag_for_controlled(true)
	if bag == null:
		return

	var total: int = cols * rows
	var i: int = 0
	while i < total:
		if i < unlocked_capacity:
			# STRICT per-actor: read from the actor's bag only.
			var st_v: Variant = bag.get_slot_stack(i)
			if typeof(st_v) == TYPE_OBJECT:
				var st: ItemStack = st_v
				if st != null and st.item != null and st.item.icon != null:
					var cx: int = i % cols
					var cy: int = i / cols
					var pos: Vector2 = Vector2(cx * cell_size, cy * cell_size)
					var rect: Rect2 = Rect2(pos, Vector2(cell_size, cell_size))
					draw_texture_rect(st.item.icon, rect, false)
		i += 1

func _draw_overlays() -> void:
	var total: int = cols * rows
	if _hover_index >= 0 and _hover_index < total and tex_hover_overlay != null:
		var hx: int = _hover_index % cols
		var hy: int = _hover_index / cols
		draw_texture(tex_hover_overlay, Vector2(hx * cell_size, hy * cell_size))
	if _selected_index >= 0 and _selected_index < total and tex_selected_overlay != null:
		var sx: int = _selected_index % cols
		var sy: int = _selected_index / cols
		draw_texture(tex_selected_overlay, Vector2(sx * cell_size, sy * cell_size))

	# NEW: 1px outline for the selected cell (readability)
	if selected_outline_enabled and _selected_index >= 0 and _selected_index < total:
		var sx2: int = _selected_index % cols
		var sy2: int = _selected_index / cols
		var srect: Rect2 = Rect2(Vector2(sx2 * cell_size, sy2 * cell_size), Vector2(cell_size, cell_size))

		var w: float = selected_outline_width
		if w <= 0.0:
			w = 1.0

		var inset: float = w * 0.5
		var orect: Rect2 = srect.grow(-inset)
		draw_rect(orect, selected_outline_color, false, w)

# -----------------------------
# Drag & drop (STRICT per-actor)
# -----------------------------
func _get_drag_data(at_position: Vector2) -> Variant:
	_dragging = true
	var idx: int = _index_at_local(at_position)
	if idx < 0 or idx >= unlocked_capacity:
		return null
	if _inv == null:
		return null

	var bag: InventoryModel = _bag_for_controlled(false)
	if bag == null:
		return null

	var st_v: Variant = bag.get_slot_stack(idx)
	if typeof(st_v) != TYPE_OBJECT:
		return null
	var st: ItemStack = st_v
	if st == null or st.item == null:
		return null

	var payload: Dictionary = {}
	payload["type"] = "inv_item"
	payload["index"] = idx

	var icon: Texture2D = st.item.icon
	if icon != null:
		var preview: TextureRect = TextureRect.new()
		preview.texture = icon
		preview.stretch_mode = TextureRect.STRETCH_KEEP
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		set_drag_preview(preview)
	return payload

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var to_index: int = _index_at_local(at_position)
	if to_index < 0 or to_index >= unlocked_capacity:
		return false

	var t: String = String((data as Dictionary).get("type", ""))
	return t == "inv_item" or t == "equipped_item"

func _drop_data(at_position: Vector2, data: Variant) -> void:
	if typeof(data) != TYPE_DICTIONARY:
		return
	var to_index: int = _index_at_local(at_position)
	if to_index < 0 or to_index >= unlocked_capacity:
		return
	if _inv == null:
		return

	var d: Dictionary = data
	var t: String = String(d.get("type", ""))

	if t == "inv_item":
		if not d.has("index"):
			return
		var from_index: int = int(d["index"])
		if from_index == to_index:
			return

		var bag: InventoryModel = _bag_for_controlled(true)
		if bag == null:
			return

		# Prefer model-level move_or_merge; else do a safe local move/swap/merge.
		if bag.has_method("move_or_merge"):
			bag.move_or_merge(from_index, to_index)
		else:
			var from_st: ItemStack = bag.get_slot_stack(from_index)
			var to_st: ItemStack = bag.get_slot_stack(to_index)

			if from_st == null:
				return

			# Empty → move
			if to_st == null:
				bag.set_stack(to_index, from_st)
				bag.set_stack(from_index, null)
			else:
				# Same item → merge within stack_max
				if to_st.item != null and from_st.item != null and to_st.item.id == from_st.item.id:
					var can_take: int = to_st.item.stack_max - to_st.count
					if can_take > 0:
						var moved: int = min(can_take, from_st.count)
						to_st.count += moved
						from_st.count -= moved
						if from_st.count <= 0:
							bag.set_stack(from_index, null)
						if bag.has_signal("inventory_changed"):
							bag.emit_signal("inventory_changed")
				else:
					# Different item → swap
					bag.set_stack(from_index, to_st)
					bag.set_stack(to_index, from_st)
		return

	# ---------- Equipped → Inventory (centralized via InventorySystem) ----------
	if t == "equipped_item":
		var slot_name: String = String(d.get("slot", ""))
		if slot_name.is_empty():
			return

		var user: Node = _get_controlled_actor()
		if user == null:
			return

		# First, try precise placement at the hovered cell
		if _inv.has_method("try_unequip_to_inventory_at"):
			var ok_at: Variant = _inv.call("try_unequip_to_inventory_at", user, slot_name, to_index)
			if typeof(ok_at) == TYPE_BOOL and bool(ok_at):
				queue_redraw()
				return

		# Fallback: let InventorySystem choose the first available slot
		if _inv.has_method("try_unequip_to_inventory"):
			var ok_any: Variant = _inv.call("try_unequip_to_inventory", user, slot_name)
			if typeof(ok_any) == TYPE_BOOL and bool(ok_any):
				queue_redraw()
				return

		# If neither API exists or both fail, do nothing here (avoid duplicating logic).

# -----------------------------
# Audio helpers
# -----------------------------
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
					print("[InventoryGridView] Resolved audio autoload: ", path)
				return
		i += 1

func _play_ui_click() -> void:
	if ui_click_event == StringName(""):
		return

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		_audio_checked_once = false
		_resolve_audio_sys()

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		return

	if _audio_obj.has_method("play_ui_sfx"):
		_audio_obj.call("play_ui_sfx", ui_click_event, ui_click_volume_db)
		return

	# Fallback (older AudioSystem only exposes play_sfx_event)
	if _audio_obj.has_method("play_sfx_event"):
		_audio_obj.call("play_sfx_event", ui_click_event, Vector2.INF, ui_click_volume_db)
		return
