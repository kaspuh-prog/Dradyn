extends Control
class_name Hotbar
# Godot 4.5 — fully typed, no ternaries.

signal slot_assigned(slot_index: int, entry_type: String, entry_id: String)
signal slot_cleared(slot_index: int)
signal slot_triggered(slot_index: int, entry_type: String, entry_id: String) # emitted on E/R/F/C (and Shift+)

@export var background: Texture2D
@export var slot_size: Vector2i = Vector2i(16, 16)

# Important: editor overrides can zero this; we will harden in _ensure_slots_defined()
var slot_positions: PackedVector2Array = PackedVector2Array([
	Vector2(0, 0), Vector2(16, 0), Vector2(32, 0), Vector2(48, 0),
	Vector2(0, 16), Vector2(16, 16), Vector2(32, 16), Vector2(48, 16)
])

@export var icon_placeholder: Texture2D
@export var hotkey_labels: PackedStringArray = []

@export var hover_color: Color = Color(1, 1, 1, 0.35)
@export var hover_border: int = 1

@export var debug_logs: bool = true

class Entry:
	var entry_type: String = ""
	var entry_id: String = ""

var _slots: Array[Control] = []
var _data: Array[Entry] = []

var _hover_index: int = -1

func _dbg(msg: String) -> void:
	if debug_logs:
		print("[Hotbar] ", msg)

func _ready() -> void:
	# Visual on top and receives DnD.
	z_as_relative = false
	z_index = 100

	_ensure_slots_defined()
	_build_bg()
	_build_slots()
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	set_process_unhandled_input(true)

	_dbg("ready; slots=" + str(slot_positions.size()))

func _ensure_slots_defined() -> void:
	# If the scene accidentally overrides slot_positions to empty, synthesize a 2x4 grid.
	if slot_positions.size() > 0:
		return
	var cols: int = 4
	var rows: int = 2
	var y: int = 0
	var out := PackedVector2Array()
	while y < rows:
		var x: int = 0
		while x < cols:
			out.append(Vector2(float(x * slot_size.x), float(y * slot_size.y)))
			x += 1
		y += 1
	slot_positions = out
	_dbg("slot_positions was empty; synthesized " + str(slot_positions.size()) + " coords")

func _process(_dt: float) -> void:
	pass

func _build_bg() -> void:
	var bg: TextureRect
	if has_node("BG"):
		bg = $BG as TextureRect
	else:
		bg = TextureRect.new()
		bg.name = "BG"
		add_child(bg)

	bg.texture = background
	bg.stretch_mode = TextureRect.STRETCH_KEEP

	var tex_size: Vector2 = Vector2(64, 32)
	if background != null:
		var s: Vector2i = background.get_size()
		tex_size = Vector2(float(s.x), float(s.y))

	bg.size = tex_size
	bg.position = Vector2.ZERO
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	custom_minimum_size = tex_size
	size = tex_size

func _build_slots() -> void:
	_clear_runtime_slots()
	var i: int = 0
	while i < slot_positions.size():
		var slot := Control.new()
		slot.name = "Slot%d" % (i + 1)
		slot.size = Vector2(float(slot_size.x), float(slot_size.y))
		slot.position = slot_positions[i]
		slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(slot)

		var icon := TextureRect.new()
		icon.name = "Icon"
		icon.texture = icon_placeholder
		icon.size = Vector2(float(slot_size.x), float(slot_size.y))
		icon.stretch_mode = TextureRect.STRETCH_KEEP
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon)

		if i < hotkey_labels.size():
			var key := Label.new()
			key.name = "Key"
			key.text = hotkey_labels[i]
			key.size = Vector2(float(slot_size.x), float(slot_size.y))
			key.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			key.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			key.add_theme_font_size_override("font_size", 8)
			key.mouse_filter = Control.MOUSE_FILTER_IGNORE
			slot.add_child(key)

		_slots.append(slot)
		var e := Entry.new()
		_data.append(e)
		i += 1
	_dbg("_build_slots complete; total=" + str(_slots.size()))

func _clear_runtime_slots() -> void:
	var s: int = 0
	while s < _slots.size():
		if is_instance_valid(_slots[s]):
			_slots[s].queue_free()
		s += 1
	_slots.clear()
	_data.clear()

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		var local_pos: Vector2 = get_local_mouse_position()
		var idx: int = _slot_at(local_pos)
		if idx >= 0:
			_dbg("RMB clear slot=" + str(idx))
			_clear(idx)
			accept_event()

# -----------------------------
# Drag & Drop (Godot 4 style)
# -----------------------------
func can_drop_data(pos: Vector2, data: Variant) -> bool:
	var idx: int = _slot_at(pos)
	_dbg("can_drop_data: pos=" + str(pos) + " idx=" + str(idx) + " data_type=" + str(typeof(data)))
	if idx < 0:
		_hover_index = -1
		queue_redraw()
		return false

	var parsed: Dictionary = _parse_payload(data)
	var ok: bool = parsed.get("ok", false)
	_dbg("can_drop_data: parsed ok=" + str(ok) + " kind=" + String(parsed.get("kind", "")) + " id=" + String(parsed.get("id", "")))
	if ok:
		_hover_index = idx
		queue_redraw()
		return true

	_hover_index = -1
	queue_redraw()
	return false

func drop_data(pos: Vector2, data: Variant) -> void:
	var idx: int = _slot_at(pos)
	_dbg("drop_data: pos=" + str(pos) + " idx=" + str(idx) + " data_type=" + str(typeof(data)))
	if idx < 0:
		_dbg("drop_data: no slot under pointer")
		_clear_hover()
		return

	var parsed: Dictionary = _parse_payload(data)
	var ok: bool = parsed.get("ok", false)
	var kind: String = String(parsed.get("kind", ""))
	var id: String = String(parsed.get("id", ""))

	_dbg("drop_data: parsed ok=" + str(ok) + " kind=" + kind + " id=" + id)
	if not ok:
		_clear_hover()
		return

	_assign(idx, kind, id)
	_clear_hover()

# Unified payload parser – returns {"ok": bool, "kind": String, "id": String}
func _parse_payload(data: Variant) -> Dictionary:
	var result := {
		"ok": false,
		"kind": "",
		"id": ""
	}

	if typeof(data) != TYPE_DICTIONARY:
		_dbg("parse: not a dictionary; type=" + str(typeof(data)))
		return result

	var d: Dictionary = data
	_dbg("parse: keys=" + str(d.keys()))

	# Normalize possible wrappers first
	var core: Dictionary = d
	if d.has("data") and typeof(d["data"]) == TYPE_DICTIONARY:
		core = d["data"]
		_dbg("parse: using d['data'] wrapper; keys=" + str(core.keys()))
	elif d.has("payload") and typeof(d["payload"]) == TYPE_DICTIONARY:
		core = d["payload"]
		_dbg("parse: using d['payload'] wrapper; keys=" + str(core.keys()))

	# Accept a few shapes:
	# 1) {"drag_type":"ability","ability_id":"..."}
	if core.has("drag_type") and String(core["drag_type"]) == "ability" and core.has("ability_id"):
		result["ok"] = String(core["ability_id"]) != ""
		result["kind"] = "ability"
		result["id"] = String(core["ability_id"])
		return result

	# 2) {"type":"ability","id":"..."}
	if core.has("type") and String(core["type"]) == "ability" and core.has("id"):
		result["ok"] = String(core["id"]) != ""
		result["kind"] = "ability"
		result["id"] = String(core["id"])
		return result

	# 3) {"ability_id":"..."} plain
	if core.has("ability_id"):
		result["ok"] = String(core["ability_id"]) != ""
		result["kind"] = "ability"
		result["id"] = String(core["ability_id"])
		return result

	# 4) {"ability":"..."} fallback
	if core.has("ability"):
		result["ok"] = String(core["ability"]) != ""
		result["kind"] = "ability"
		result["id"] = String(core["ability"])
		return result

	_dbg("parse: no recognized keys")
	return result

func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_dbg("NOTIFICATION_DRAG_END")
		_clear_hover()

func _clear_hover() -> void:
	if _hover_index != -1:
		_hover_index = -1
		queue_redraw()

func _assign(idx: int, kind: String, id: String) -> void:
	if idx < 0 or idx >= _data.size():
		return
	if id == "":
		_dbg("assign: blocked empty id")
		return
	_dbg("assign: idx=" + str(idx) + " kind=" + kind + " id=" + id)
	_data[idx].entry_type = kind
	_data[idx].entry_id = id
	_refresh_icon(idx)
	slot_assigned.emit(idx, kind, id)

func _clear(idx: int) -> void:
	if idx < 0 or idx >= _data.size():
		return
	_dbg("clear: idx=" + str(idx))
	_data[idx] = Entry.new()
	_refresh_icon(idx)
	slot_cleared.emit(idx)

func _refresh_icon(idx: int) -> void:
	if idx < 0 or idx >= _slots.size():
		return
	var s: Control = _slots[idx]
	var icon := s.get_node("Icon") as TextureRect
	var e := _data[idx]
	var tex: Texture2D = icon_placeholder
	if e.entry_type == "ability":
		var ability_sys := get_node_or_null("/root/AbilitySys")
		if ability_sys != null and ability_sys.has_method("get_ability_icon"):
			var t_any: Variant = ability_sys.call("get_ability_icon", e.entry_id)
			if t_any is Texture2D:
				tex = t_any as Texture2D
	icon.texture = tex

func _draw() -> void:
	if _hover_index < 0:
		return
	if _hover_index >= _slots.size():
		return
	var s: Control = _slots[_hover_index]
	var rect := Rect2(s.position, s.size)
	var i: int = 0
	while i < hover_border:
		draw_rect(Rect2(rect.position - Vector2(float(i), float(i)), rect.size + Vector2(float(i * 2), float(i * 2))), hover_color, false, 1.0)
		i += 1

func _slot_at(local_pos: Vector2) -> int:
	# local_pos is Hotbar-local.
	var i: int = 0
	while i < _slots.size():
		var s: Control = _slots[i]
		var r := Rect2(s.position, s.size)
		if r.has_point(local_pos):
			if debug_logs:
				_dbg("slot_at: hit slot " + str(i) + " rect=" + str(r) + " local_pos=" + str(local_pos))
			return i
		i += 1
	if debug_logs:
		_dbg("slot_at: miss local_pos=" + str(local_pos))
	return -1

func try_assign_drag(data: Dictionary) -> void:
	_dbg("try_assign_drag (fallback) data_keys=" + (str(data.keys()) if typeof(data) == TYPE_DICTIONARY else "<non-dict>"))
	if typeof(data) != TYPE_DICTIONARY:
		return

	var parsed: Dictionary = _parse_payload(data)
	var ok: bool = parsed.get("ok", false)
	var id: String = String(parsed.get("id", ""))
	if not ok or id == "":
		return

	# Slot to first empty slot
	var idx: int = 0
	while idx < _data.size():
		if _data[idx].entry_type == "" or _data[idx].entry_id == "":
			_assign(idx, "ability", id)
			return
		idx += 1

	# Or replace slot 0 if full
	_assign(0, "ability", id)

# -------------------------------------------------------------------
# Screen-space wrappers for HotbarDropCatcher
# -------------------------------------------------------------------
func can_drop_payload_at_screen_pos(screen_pos: Vector2, data: Variant) -> bool:
	var inv: Transform2D = get_global_transform_with_canvas().affine_inverse()
	var local_pos: Vector2 = inv * screen_pos
	_dbg("catcher->hotbar can_drop: screen_pos=" + str(screen_pos) + " -> local_pos=" + str(local_pos))
	return can_drop_data(local_pos, data)

func try_assign_at_screen_pos(screen_pos: Vector2, data: Variant) -> void:
	var inv: Transform2D = get_global_transform_with_canvas().affine_inverse()
	var local_pos: Vector2 = inv * screen_pos
	_dbg("catcher->hotbar drop: screen_pos=" + str(screen_pos) + " -> local_pos=" + str(local_pos))
	if can_drop_data(local_pos, data):
		drop_data(local_pos, data)
	else:
		if typeof(data) == TYPE_DICTIONARY:
			try_assign_drag(data)

# -------------------------------------------------------------------
# Hotkey & RMB (unhandled safety net)
# -------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	# 1) Right-click clear as a fallback if something ate the GUI event upstream
	var mb := event as InputEventMouseButton
	if mb != null:
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var inv: Transform2D = get_global_transform_with_canvas().affine_inverse()
			var local_pos: Vector2 = inv * mb.position
			var idx_mouse: int = _slot_at(local_pos)
			if idx_mouse >= 0:
				_dbg("RMB(unhandled) clear slot=" + str(idx_mouse))
				_clear(idx_mouse)
				accept_event()
				return

	# 2) Keyboard hotkeys (E/R/F/C & Shift variants)
	var key := event as InputEventKey
	if key == null:
		return
	if not key.pressed:
		return
	if key.echo:
		return

	var index: int = -1
	if key.keycode == KEY_E:
		index = 0
	elif key.keycode == KEY_R:
		index = 1
	elif key.keycode == KEY_F:
		index = 2
	elif key.keycode == KEY_C:
		index = 3

	if index == -1:
		return

	if key.shift_pressed:
		index += 4

	_activate_slot(index)

func _activate_slot(index: int) -> void:
	if index < 0 or index >= _data.size():
		return
	var e := _data[index]
	if e.entry_type == "" or e.entry_id == "":
		return

	slot_triggered.emit(index, e.entry_type, e.entry_id)

	if e.entry_type == "ability":
		var ability_sys := get_node_or_null("/root/AbilitySys")
		if ability_sys != null:
			if ability_sys.has_method("activate_from_hotbar"):
				ability_sys.call("activate_from_hotbar", e.entry_id)
			elif ability_sys.has_method("try_cast_for_controlled"):
				ability_sys.call("try_cast_for_controlled", e.entry_id)
			elif ability_sys.has_method("activate"):
				ability_sys.call("activate", e.entry_id)
