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

@export var cooldown_dim_color: Color = Color(0.35, 0.35, 0.35, 1.0)
@export var cooldown_start_angle_deg: float = -90.0 # 12 o'clock
@export var cooldown_clockwise: bool = true

@export var debug_logs: bool = true

class Entry:
	var entry_type: String = ""
	var entry_id: String = ""

var _slots: Array[Control] = []
var _data: Array[Entry] = []

var _hover_index: int = -1

# slot_index -> {"ability_id": String, "duration_ms": int, "until_msec": int}
var _cooldowns_by_slot: Dictionary = {}

var _controlled_user: Node = null
var _ability_sys: Node = null
var _party: Node = null

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

	_bind_runtime_signals()

	_dbg("ready; slots=" + str(slot_positions.size()))

func _exit_tree() -> void:
	_unbind_runtime_signals()

func _bind_runtime_signals() -> void:
	_ability_sys = get_node_or_null("/root/AbilitySys")
	if _ability_sys != null and _ability_sys.has_signal("cooldown_started"):
		var cb_cd: Callable = Callable(self, "_on_ability_cooldown_started")
		if not _ability_sys.is_connected("cooldown_started", cb_cd):
			_ability_sys.connect("cooldown_started", cb_cd)

	_party = get_node_or_null("/root/Party")
	if _party != null and _party.has_signal("controlled_changed"):
		var cb_ctrl: Callable = Callable(self, "_on_party_controlled_changed")
		if not _party.is_connected("controlled_changed", cb_ctrl):
			_party.connect("controlled_changed", cb_ctrl)

	# Cache current controlled immediately.
	if _party != null and _party.has_method("get_controlled"):
		var cur: Variant = _party.call("get_controlled")
		if cur is Node:
			_controlled_user = cur as Node
		else:
			_controlled_user = null

func _unbind_runtime_signals() -> void:
	if _ability_sys != null:
		var cb_cd: Callable = Callable(self, "_on_ability_cooldown_started")
		if _ability_sys.has_signal("cooldown_started") and _ability_sys.is_connected("cooldown_started", cb_cd):
			_ability_sys.disconnect("cooldown_started", cb_cd)
	_ability_sys = null

	if _party != null:
		var cb_ctrl: Callable = Callable(self, "_on_party_controlled_changed")
		if _party.has_signal("controlled_changed") and _party.is_connected("controlled_changed", cb_ctrl):
			_party.disconnect("controlled_changed", cb_ctrl)
	_party = null

func _on_party_controlled_changed(current: Node) -> void:
	_controlled_user = current
	_clear_all_cooldown_visuals()

func _on_ability_cooldown_started(user: Node, ability_id: String, duration_ms: int, until_msec: int) -> void:
	# Only show cooldowns for the currently controlled character.
	if _controlled_user != null:
		if user != _controlled_user:
			return

	if ability_id == "":
		return

	# Apply to every slot that matches this ability_id.
	var i: int = 0
	while i < _data.size():
		var e: Entry = _data[i]
		if e.entry_type == "ability" and e.entry_id == ability_id:
			var info: Dictionary = {
				"ability_id": ability_id,
				"duration_ms": duration_ms,
				"until_msec": until_msec
			}
			_cooldowns_by_slot[i] = info
			# Immediate visual update (so you see it right as you cast).
			_update_slot_cooldown_visual(i, info)
		i += 1

func _clear_all_cooldown_visuals() -> void:
	_cooldowns_by_slot.clear()
	var i: int = 0
	while i < _slots.size():
		_reset_cooldown_visual(i)
		i += 1

func _update_slot_cooldown_visual(slot_index: int, info: Dictionary) -> void:
	var dur: int = int(info.get("duration_ms", 0))
	var until: int = int(info.get("until_msec", 0))

	if dur <= 0:
		set_slot_cooldown_ready_ratio(slot_index, 1.0)
		return

	var now: int = Time.get_ticks_msec()
	var remaining: int = until - now
	if remaining <= 0:
		set_slot_cooldown_ready_ratio(slot_index, 1.0)
		return

	var ready_ratio: float = 1.0 - (float(remaining) / float(dur))
	ready_ratio = clamp(ready_ratio, 0.0, 1.0)
	set_slot_cooldown_ready_ratio(slot_index, ready_ratio)

func _ensure_slots_defined() -> void:
	# If the scene accidentally overrides slot_positions to empty, synthesize a 2x4 grid.
	if slot_positions.size() > 0:
		return

	slot_positions = PackedVector2Array([
		Vector2(0, 0), Vector2(16, 0), Vector2(32, 0), Vector2(48, 0),
		Vector2(0, 16), Vector2(16, 16), Vector2(32, 16), Vector2(48, 16)
	])

func _process(_delta: float) -> void:
	if _cooldowns_by_slot.is_empty():
		return

	var now: int = Time.get_ticks_msec()
	var keys: Array = _cooldowns_by_slot.keys()
	var k_i: int = 0
	while k_i < keys.size():
		var slot_any: Variant = keys[k_i]
		var slot_index: int = int(slot_any)

		# Slot no longer valid.
		if slot_index < 0 or slot_index >= _data.size():
			_cooldowns_by_slot.erase(slot_any)
			k_i += 1
			continue

		# Slot content changed away from this ability.
		var info: Dictionary = _cooldowns_by_slot[slot_any]
		var expected_id: String = String(info.get("ability_id", ""))
		var e: Entry = _data[slot_index]
		if e.entry_type != "ability" or e.entry_id != expected_id:
			_reset_cooldown_visual(slot_index)
			_cooldowns_by_slot.erase(slot_any)
			k_i += 1
			continue

		var dur: int = int(info.get("duration_ms", 0))
		var until: int = int(info.get("until_msec", 0))

		if dur <= 0:
			set_slot_cooldown_ready_ratio(slot_index, 1.0)
			_cooldowns_by_slot.erase(slot_any)
			k_i += 1
			continue

		var remaining: int = until - now
		if remaining <= 0:
			set_slot_cooldown_ready_ratio(slot_index, 1.0)
			_cooldowns_by_slot.erase(slot_any)
			k_i += 1
			continue

		var ready_ratio: float = 1.0 - (float(remaining) / float(dur))
		ready_ratio = clamp(ready_ratio, 0.0, 1.0)
		set_slot_cooldown_ready_ratio(slot_index, ready_ratio)

		k_i += 1

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

		# Cooldown radial reveal overlay (hidden by default).
		var cd := TextureProgressBar.new()
		cd.name = "Cooldown"
		cd.size = Vector2(float(slot_size.x), float(slot_size.y))
		cd.position = Vector2.ZERO
		cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cd.min_value = 0.0
		cd.max_value = 100.0
		cd.value = cd.max_value
		cd.visible = false
		cd.texture_progress = icon_placeholder
		cd.texture_under = null
		cd.texture_over = null
		if cooldown_clockwise:
			cd.fill_mode = TextureProgressBar.FILL_CLOCKWISE
		else:
			cd.fill_mode = TextureProgressBar.FILL_COUNTER_CLOCKWISE
		cd.radial_initial_angle = cooldown_start_angle_deg
		cd.radial_fill_degrees = 360.0
		slot.add_child(cd)

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

func _clear_runtime_slots() -> void:
	var i: int = get_child_count() - 1
	while i >= 0:
		var c: Node = get_child(i)
		if c != null and c.name.begins_with("Slot"):
			remove_child(c)
			c.queue_free()
		i -= 1
	_slots.clear()
	_data.clear()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
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
	_dbg("drop_data: pos=" + str(pos) + " idx=" + str(idx))
	if idx < 0:
		_clear_hover()
		return

	var parsed: Dictionary = _parse_payload(data)
	var ok: bool = parsed.get("ok", false)
	if not ok:
		_dbg("drop_data: payload not ok; ignoring")
		_clear_hover()
		return

	var kind: String = String(parsed.get("kind", ""))
	var id: String = String(parsed.get("id", ""))

	if kind == "" or id == "":
		_dbg("drop_data: empty kind/id; ignoring")
		_clear_hover()
		return

	_assign(idx, kind, id)
	_clear_hover()

func _parse_payload(data: Variant) -> Dictionary:
	# Expected shapes:
	# 1) {"drag_type":"ability","ability_id":"..."}
	# 2) {"type":"ability","id":"..."}
	# 3) {"ability_id":"..."} plain
	# 4) {"ability":"..."} fallback
	var result: Dictionary = {"ok": false, "kind": "", "id": ""}

	if typeof(data) != TYPE_DICTIONARY:
		_dbg("parse: data not dict")
		return result

	var d: Dictionary = data as Dictionary

	if d.has("drag_type") and String(d.get("drag_type", "")) == "ability":
		result["ok"] = true
		result["kind"] = "ability"
		result["id"] = String(d.get("ability_id", ""))
		return result

	if d.has("type") and String(d.get("type", "")) == "ability":
		result["ok"] = true
		result["kind"] = "ability"
		result["id"] = String(d.get("id", ""))
		return result

	if d.has("ability_id"):
		result["ok"] = true
		result["kind"] = "ability"
		result["id"] = String(d.get("ability_id", ""))
		return result

	if d.has("ability"):
		result["ok"] = true
		result["kind"] = "ability"
		result["id"] = String(d.get("ability", ""))
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
	_reset_cooldown_visual(idx)
	_cooldowns_by_slot.erase(idx)
	slot_assigned.emit(idx, kind, id)

func _clear(idx: int) -> void:
	if idx < 0 or idx >= _data.size():
		return
	_dbg("clear: idx=" + str(idx))
	_data[idx] = Entry.new()
	_refresh_icon(idx)
	_reset_cooldown_visual(idx)
	_cooldowns_by_slot.erase(idx)
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

	var cd := s.get_node_or_null("Cooldown") as TextureProgressBar
	if cd != null:
		cd.texture_progress = tex

	icon.texture = tex

func _reset_cooldown_visual(idx: int) -> void:
	if idx < 0 or idx >= _slots.size():
		return
	var s: Control = _slots[idx]
	var icon := s.get_node("Icon") as TextureRect
	icon.modulate = Color(1, 1, 1, 1)
	var cd := s.get_node_or_null("Cooldown") as TextureProgressBar
	if cd != null:
		cd.visible = false
		cd.value = cd.max_value

## Public API for cooldown sweep (0.0 = just started cooldown, 1.0 = ready).
func set_slot_cooldown_ready_ratio(slot_index: int, ready_ratio: float) -> void:
	if slot_index < 0 or slot_index >= _slots.size():
		return
	var s: Control = _slots[slot_index]
	var icon := s.get_node("Icon") as TextureRect
	var cd := s.get_node_or_null("Cooldown") as TextureProgressBar
	if cd == null:
		return

	var r: float = clamp(ready_ratio, 0.0, 1.0)
	if r >= 1.0:
		_reset_cooldown_visual(slot_index)
		return

	cd.visible = true
	cd.value = r * cd.max_value
	icon.modulate = cooldown_dim_color

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
	var kind: String = String(data.get("kind", data.get("type", "")))
	var id: String = String(data.get("id", data.get("ability_id", "")))
	if kind == "" or id == "":
		return
	var idx: int = _slot_at(get_local_mouse_position())
	if idx < 0:
		return
	_assign(idx, kind, id)

func can_drop_payload_at_screen_pos(screen_pos: Vector2, payload: Variant) -> bool:
	var inv: Transform2D = get_global_transform_with_canvas().affine_inverse()
	var local_pos: Vector2 = inv * screen_pos
	return can_drop_data(local_pos, payload)

func try_assign_at_screen_pos(screen_pos: Vector2, payload: Variant) -> void:
	var inv: Transform2D = get_global_transform_with_canvas().affine_inverse()
	var local_pos: Vector2 = inv * screen_pos
	drop_data(local_pos, payload)

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
	var e: Entry = _data[index]
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
