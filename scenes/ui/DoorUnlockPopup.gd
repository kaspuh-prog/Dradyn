extends NinePatchRect
class_name DoorUnlockPopup
# Godot 4.5 — fully typed, no ternaries.
# IMPORTANT: This is NOT full-screen. It's only the 96x96 panel so it won't block TabbedMenu.

signal closed
signal unlocked(door: InteractableDoor, actor: Node, method: String)

@export var panel_texture: Texture2D = preload("res://ui/styles/chatbox.png")
@export var slot_texture: Texture2D = preload("res://ui/styles/KeyholeSlot.png")

@export var title_text: String = "Locked"
@export var message_text: String = "(drag a key)"

# NEW: Lockpick mini-game UI scene
@export var lockpick_minigame_scene: PackedScene = preload("res://scenes/ui/LockpickMinigameUI.tscn")

# Mirrors DialogueBox.tscn (InnController)
const DIALOGUE_FONT_PATH: String = "res://assets/fonts/Raleway-SemiBold.ttf"
const DIALOGUE_FONT_SIZE: int = 6
const DIALOGUE_FONT_COLOR: Color = Color(0.2509804, 0.13333334, 0.10980392, 1.0)

const BUTTON_HEIGHT: float = 14.0
const BTN_MARGIN_LR: int = 4
const BTN_MARGIN_TB: int = 1

# Runtime
var _door: InteractableDoor = null
var _actor: Node = null

var _vbox: VBoxContainer = null
var _title_label: Label = null
var _body_rich: RichTextLabel = null
var _keyhole: DoorKeyholeSlot = null
var _pick_button: Button = null
var _close_button: Button = null

var _font: Font = null

# minigame runtime
var _lockpick_ui: LockpickMinigame = null
var _suppress_closed_emit: bool = false


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE

	_font = load(DIALOGUE_FONT_PATH) as Font

	# NinePatch look (DialogueBox chatbox)
	texture = panel_texture
	patch_margin_left = 48
	patch_margin_top = 48
	patch_margin_right = 48
	patch_margin_bottom = 48
	axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE_FIT

	# LEFT + vertically centered, 96x96 (same size as ItemObtainedPopup panel)
	anchor_left = 0.0
	anchor_top = 0.5
	anchor_right = 0.0
	anchor_bottom = 0.5
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_BOTH
	offset_left = 0.0
	offset_right = 96.0
	offset_top = -48.0
	offset_bottom = 48.0

	_build_ui()


func show_for(door: InteractableDoor, actor: Node) -> void:
	_cleanup_lockpick_ui()

	_door = door
	_actor = actor

	var safe_title: String = "Locked"
	var safe_msg: String = "(drag a key)"

	if title_text != null:
		var t: String = String(title_text)
		if t.strip_edges() != "":
			safe_title = t

	if message_text != null:
		var m: String = String(message_text)
		if m.strip_edges() != "":
			safe_msg = m

	if _title_label != null:
		_title_label.text = safe_title

	if _body_rich != null:
		_body_rich.clear()
		_body_rich.append_text(safe_msg)

	if _keyhole != null:
		_keyhole.configure(_door, _actor)

	_refresh_pick_button()
	visible = true


func hide_popup() -> void:
	visible = false

	if _suppress_closed_emit:
		_suppress_closed_emit = false
		return

	_cleanup_lockpick_ui()

	_door = null
	_actor = null
	emit_signal("closed")


func _hide_popup_keep_context() -> void:
	# Hide the popup when we swap to minigame, but keep _door/_actor intact.
	_suppress_closed_emit = true
	visible = false


# -------------------------------------------------
# UI
# -------------------------------------------------
func _build_ui() -> void:
	_vbox = VBoxContainer.new()
	_vbox.name = "VBox"
	_vbox.anchor_left = 0.0
	_vbox.anchor_top = 0.0
	_vbox.anchor_right = 1.0
	_vbox.anchor_bottom = 1.0
	_vbox.offset_left = 16.0
	_vbox.offset_top = 16.0
	_vbox.offset_right = -16.0
	_vbox.offset_bottom = -16.0
	add_child(_vbox)

	_title_label = Label.new()
	_title_label.name = "TitleLabel"
	_title_label.text = "Locked"
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_apply_dialogue_label_style(_title_label)
	_vbox.add_child(_title_label)

	_body_rich = RichTextLabel.new()
	_body_rich.name = "Body"
	_body_rich.fit_content = true
	_body_rich.bbcode_enabled = false
	_body_rich.scroll_active = false
	_body_rich.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_dialogue_body_style(_body_rich)
	_body_rich.append_text("(drag a key)")
	_vbox.add_child(_body_rich)

	var row: HBoxContainer = HBoxContainer.new()
	row.name = "KeyRow"
	row.add_theme_constant_override("separation", 6)
	_vbox.add_child(row)

	_keyhole = DoorKeyholeSlot.new()
	_keyhole.name = "Keyhole"
	_keyhole.slot_texture = slot_texture
	_keyhole.custom_minimum_size = Vector2(16.0, 16.0)
	_keyhole.key_attempt_result.connect(_on_key_attempt_result)
	row.add_child(_keyhole)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.add_theme_constant_override("separation", 6)
	_vbox.add_child(buttons)

	_pick_button = Button.new()
	_pick_button.name = "PickButton"
	_pick_button.text = "Pick lock"
	_style_like_dialogue_choice_button(_pick_button)
	_pick_button.pressed.connect(_on_pick_pressed)
	buttons.add_child(_pick_button)

	_close_button = Button.new()
	_close_button.name = "CloseButton"
	_close_button.text = "Close"
	_style_like_dialogue_choice_button(_close_button)
	_close_button.pressed.connect(_on_close_pressed)
	buttons.add_child(_close_button)


func _apply_dialogue_label_style(lbl: Label) -> void:
	if _font != null:
		lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", DIALOGUE_FONT_SIZE)
	lbl.add_theme_color_override("font_color", DIALOGUE_FONT_COLOR)


func _apply_dialogue_body_style(rtl: RichTextLabel) -> void:
	rtl.add_theme_color_override("default_color", DIALOGUE_FONT_COLOR)
	if _font != null:
		rtl.add_theme_font_override("normal_font", _font)
		rtl.add_theme_font_override("bold_font", _font)
	rtl.add_theme_font_size_override("normal_font_size", DIALOGUE_FONT_SIZE)
	rtl.add_theme_font_size_override("bold_font_size", DIALOGUE_FONT_SIZE)
	rtl.add_theme_font_size_override("italics_font_size", DIALOGUE_FONT_SIZE)
	rtl.add_theme_font_size_override("bold_italics_font_size", DIALOGUE_FONT_SIZE)
	rtl.add_theme_font_size_override("mono_font_size", DIALOGUE_FONT_SIZE)


func _style_like_dialogue_choice_button(btn: Button) -> void:
	btn.focus_mode = Control.FOCUS_ALL
	btn.flat = true
	btn.mouse_filter = Control.MOUSE_FILTER_STOP

	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.custom_minimum_size = Vector2(0.0, BUTTON_HEIGHT)

	if _font != null:
		btn.add_theme_font_override("font", _font)
	btn.add_theme_font_size_override("font_size", DIALOGUE_FONT_SIZE)
	btn.add_theme_color_override("font_color", DIALOGUE_FONT_COLOR)

	btn.add_theme_constant_override("content_margin_left", BTN_MARGIN_LR)
	btn.add_theme_constant_override("content_margin_right", BTN_MARGIN_LR)
	btn.add_theme_constant_override("content_margin_top", BTN_MARGIN_TB)
	btn.add_theme_constant_override("content_margin_bottom", BTN_MARGIN_TB)


func _set_button_enabled(btn: Button, enabled: bool) -> void:
	btn.disabled = not enabled
	if enabled:
		btn.modulate = Color(1.0, 1.0, 1.0, 1.0)
	else:
		btn.modulate = Color(1.0, 1.0, 1.0, 0.40)


func _refresh_pick_button() -> void:
	if _pick_button == null:
		return

	_pick_button.text = "Pick lock"

	if _door == null or _actor == null:
		_set_button_enabled(_pick_button, false)
		return

	if not _door.allow_lockpick:
		_set_button_enabled(_pick_button, false)
		return

	var ok_gate: bool = _actor_can_attempt_lockpick(_actor, _door)
	if not ok_gate:
		_set_button_enabled(_pick_button, false)
		return

	var req: int = _door.lockpick_required_dex
	if req < 0:
		req = 0
	var dex_val: float = _get_actor_dex(_actor)
	var ok_dex: bool = dex_val + 0.000001 >= float(req)

	_set_button_enabled(_pick_button, ok_dex)


# -------------------------------------------------
# Actions
# -------------------------------------------------
func _on_key_attempt_result(success: bool, message: String) -> void:
	if success:
		if _door != null:
			_door.is_locked = false
		if _door != null and _actor != null:
			emit_signal("unlocked", _door, _actor, "key")

		if _door != null and _actor != null and _door.target_scene_path != "":
			hide_popup()
			_door.interact(_actor)
			return

		hide_popup()
		return

	if _body_rich != null:
		_body_rich.clear()
		var msg: String = message
		if msg.strip_edges() == "":
			msg = "This isn't the key."
		_body_rich.append_text(msg)


func _on_pick_pressed() -> void:
	if _pick_button != null and _pick_button.disabled:
		return
	if _door == null or _actor == null:
		return
	if lockpick_minigame_scene == null:
		return

	_start_lockpick_minigame()


func _start_lockpick_minigame() -> void:
	_cleanup_lockpick_ui()

	var inst: Node = lockpick_minigame_scene.instantiate()
	if inst == null:
		return

	var lp: LockpickMinigame = inst as LockpickMinigame
	if lp == null:
		push_warning("[DoorUnlockPopup] LockpickMinigameUI.tscn root is not LockpickMinigame.")
		inst.queue_free()
		return

	_lockpick_ui = lp

	# Put it next to this popup (same parent, normally HUDLayer).
	var parent: Node = get_parent()
	if parent == null:
		parent = get_tree().root
	parent.add_child(_lockpick_ui)

	# --- IMPORTANT FIX ---
	# Keep z_as_relative TRUE so children inherit this z_index (otherwise they stay at 0 and can hide).
	_lockpick_ui.z_as_relative = true
	_lockpick_ui.z_index = 200

	# Also force it to be last among same-z siblings.
	parent.move_child(_lockpick_ui, parent.get_child_count() - 1)

	_lockpick_ui.succeeded.connect(_on_lockpick_succeeded)
	_lockpick_ui.cancelled.connect(_on_lockpick_cancelled)

	_hide_popup_keep_context()


func _on_lockpick_succeeded() -> void:
	var door_local: InteractableDoor = _door
	var actor_local: Node = _actor

	_cleanup_lockpick_ui()

	if door_local != null:
		door_local.is_locked = false

	if door_local != null and actor_local != null:
		emit_signal("unlocked", door_local, actor_local, "lockpick")

	if door_local != null and actor_local != null and door_local.target_scene_path != "":
		hide_popup()
		door_local.interact(actor_local)
		return

	hide_popup()


func _on_lockpick_cancelled() -> void:
	_cleanup_lockpick_ui()

	if _door != null and _actor != null:
		visible = true
		if _keyhole != null:
			_keyhole.configure(_door, _actor)
		_refresh_pick_button()
		return

	hide_popup()


func _cleanup_lockpick_ui() -> void:
	if _lockpick_ui == null:
		return
	if is_instance_valid(_lockpick_ui):
		_lockpick_ui.queue_free()
	_lockpick_ui = null


func _on_close_pressed() -> void:
	hide_popup()


# -------------------------------------------------
# Eligibility helpers
# -------------------------------------------------
func _actor_can_attempt_lockpick(actor: Node, door: InteractableDoor) -> bool:
	if actor == null or door == null:
		return false

	if String(door.lockpick_required_class_title) != "":
		var class_title: String = _get_actor_class_title(actor)
		if class_title.strip_edges().to_lower() != String(door.lockpick_required_class_title).strip_edges().to_lower():
			return false

	if door.lockpick_requires_ability_id != "":
		if not _actor_has_known_ability(actor, door.lockpick_requires_ability_id):
			return false

	return true


func _get_actor_dex(actor: Node) -> float:
	var stats: StatsComponent = _find_stats_component(actor)
	if stats == null:
		return 0.0
	return stats.get_final_stat("DEX")


func _get_actor_class_title(actor: Node) -> String:
	var stats: StatsComponent = _find_stats_component(actor)
	if stats == null:
		return ""
	var cd_res: Resource = stats.get_class_def()
	if cd_res == null:
		return ""
	var cd: ClassDefinition = cd_res as ClassDefinition
	if cd == null:
		return ""
	return cd.class_title


func _find_stats_component(root: Node) -> StatsComponent:
	if root == null:
		return null

	var direct: Node = root.find_child("StatsComponent", true, false)
	if direct != null and direct is StatsComponent:
		return direct as StatsComponent

	var queue: Array[Node] = []
	queue.append(root)
	while not queue.is_empty():
		var cur: Node = queue.pop_front()
		if cur is StatsComponent:
			return cur as StatsComponent
		for ch in cur.get_children():
			var n: Node = ch as Node
			if n != null:
				queue.append(n)
	return null


func _actor_has_known_ability(root: Node, ability_id: String) -> bool:
	if root == null:
		return false
	if ability_id == "":
		return false

	var queue: Array[Node] = []
	queue.append(root)
	while not queue.is_empty():
		var cur: Node = queue.pop_front()
		if cur is KnownAbilitiesComponent:
			var kac: KnownAbilitiesComponent = cur as KnownAbilitiesComponent
			return kac.has_ability(ability_id)
		for ch in cur.get_children():
			var n: Node = ch as Node
			if n != null:
				queue.append(n)
	return false


# =================================================
# Keyhole slot control (16x16)
# =================================================
class DoorKeyholeSlot:
	extends Control

	signal key_attempt_result(success: bool, message: String)

	var slot_texture: Texture2D = null

	var _door: InteractableDoor = null
	var _actor: Node = null
	var _icon_rect: TextureRect = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		focus_mode = Control.FOCUS_NONE
		custom_minimum_size = Vector2(16.0, 16.0)

		_icon_rect = TextureRect.new()
		_icon_rect.name = "Icon"
		_icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP
		_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon_rect.anchor_left = 0.0
		_icon_rect.anchor_top = 0.0
		_icon_rect.anchor_right = 1.0
		_icon_rect.anchor_bottom = 1.0
		add_child(_icon_rect)

	func configure(door: InteractableDoor, actor: Node) -> void:
		_door = door
		_actor = actor
		if _icon_rect != null:
			_icon_rect.texture = null
		queue_redraw()

	func _draw() -> void:
		if slot_texture != null:
			draw_texture(slot_texture, Vector2.ZERO)

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		if _door == null:
			return false
		if _actor == null:
			return false
		if typeof(data) != TYPE_DICTIONARY:
			return false
		var d: Dictionary = data as Dictionary
		var t: String = String(d.get("type", ""))
		if t != "inv_item":
			return false
		if not d.has("index"):
			return false
		return true

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if _door == null or _actor == null:
			return
		if typeof(data) != TYPE_DICTIONARY:
			return

		var d: Dictionary = data as Dictionary
		var idx: int = int(d.get("index", -1))
		if idx < 0:
			emit_signal("key_attempt_result", false, "This isn't the key.")
			return

		if String(_door.key_item_id) == "":
			emit_signal("key_attempt_result", false, "This lock needs a key.")
			return

		var inv: Node = get_node_or_null("/root/InventorySys")
		if inv == null:
			emit_signal("key_attempt_result", false, "No inventory.")
			return

		var inv_sys: InventorySystem = inv as InventorySystem
		if inv_sys == null:
			emit_signal("key_attempt_result", false, "No inventory.")
			return

		var st_v: Variant = inv_sys.get_stack_at_for(_actor, idx)
		if typeof(st_v) != TYPE_OBJECT:
			emit_signal("key_attempt_result", false, "This isn't the key.")
			return

		var st: ItemStack = st_v as ItemStack
		if st == null or st.item == null or st.count <= 0:
			emit_signal("key_attempt_result", false, "This isn't the key.")
			return

		if st.item.id != _door.key_item_id:
			emit_signal("key_attempt_result", false, "This isn't the key.")
			return

		if _door.consume_key_on_unlock:
			var bag: InventoryModel = inv_sys.get_inventory_model_for(_actor)
			if bag != null:
				bag.remove_amount(idx, 1)

		if _icon_rect != null:
			_icon_rect.texture = st.item.icon

		emit_signal("key_attempt_result", true, "Unlocked.")
