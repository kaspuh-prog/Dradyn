extends CanvasLayer
class_name HUDLayer

@export var party_hud_scene: PackedScene
@export var hud_offset: Vector2i = Vector2i(16, 16)  # screen-space offset from top-left
@export var ui_layer: int = 10
@export var item_obtained_popup_scene: PackedScene

@export_group("Quest Rewards Popup")
@export var quest_reward_popup_duration: float = 2.0
@export var quest_reward_popup_offset_y_from_center: float = 64.0

@export_group("Door Unlock Popup")
@export var door_popup_script_path: String = "res://scenes/ui/DoorUnlockPopup.gd"
@export var debug_door_popup: bool = true

var _party_hud: Node = null
var _item_popup: ItemObtainedPopup = null
var _inventory_sys: InventorySystem = null

# Door unlock popup runtime
var _door_popup: Control = null

# Quest reward popup runtime
var _quest_sys: QuestSystem = null
var _quest_panel: NinePatchRect = null
var _quest_title_label: Label = null
var _quest_body_label: Label = null
var _quest_timer: Timer = null
var _quest_queue: Array[Dictionary] = []
var _quest_is_showing: bool = false


func _ready() -> void:
	# A CanvasLayer is already screen-space by default. We disable follow so it
	# does NOT move with the camera.
	layer = ui_layer
	follow_viewport_enabled = false
	offset = Vector2.ZERO
	transform = Transform2D.IDENTITY

	if party_hud_scene == null:
		push_error("HUDLayer: 'party_hud_scene' is not assigned.")
		return

	_party_hud = party_hud_scene.instantiate()
	if _party_hud == null:
		push_error("HUDLayer: instancing 'party_hud_scene' returned null.")
		return

	add_child(_party_hud)

	# If PartyHUD.tscn is itself a CanvasLayer, force it to be screen-fixed too.
	var as_layer: CanvasLayer = _party_hud as CanvasLayer
	if as_layer != null:
		as_layer.follow_viewport_enabled = false
		as_layer.layer = ui_layer
		as_layer.offset = Vector2.ZERO
		as_layer.transform = Transform2D.IDENTITY

	_place_party_hud()

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)

	_setup_item_obtained_popup()
	_connect_inventory_item_obtained()

	_setup_quest_reward_popup()
	_connect_quest_rewards()

	_setup_door_unlock_popup()

	# Bind after everything is actually in-tree (doors add to group in their _ready).
	call_deferred("_bind_existing_doors")

	# Catch future spawns (areas swapping, runtime instancing, etc.)
	_bind_door_spawns()
	_bind_scene_mgr_area_changed()


func _place_party_hud() -> void:
	# Prefer a Control named "Root" inside the PartyHUD for placement.
	var ctl: Control = _party_hud.get_node_or_null("Root") as Control
	if ctl == null:
		# If the root is a Control, use it; otherwise find the first Control.
		ctl = _party_hud as Control
		if ctl == null:
			ctl = _find_first_control_dfs(_party_hud)

	if ctl == null:
		push_warning("HUDLayer: No Control found to position; skipping placement.")
		return

	ctl.anchors_preset = Control.PRESET_TOP_LEFT
	ctl.anchor_left = 0.0
	ctl.anchor_top = 0.0
	ctl.anchor_right = 0.0
	ctl.anchor_bottom = 0.0
	ctl.position = Vector2(hud_offset)


func _find_first_control_dfs(n: Node) -> Control:
	var c: Control = n as Control
	if c != null:
		return c
	for ch in n.get_children():
		var found: Control = _find_first_control_dfs(ch)
		if found != null:
			return found
	return null


func _on_viewport_resized() -> void:
	_place_party_hud()


func _setup_item_obtained_popup() -> void:
	if item_obtained_popup_scene == null:
		push_warning("HUDLayer: 'item_obtained_popup_scene' is not assigned.")
		return

	var popup_instance: Node = item_obtained_popup_scene.instantiate()
	if popup_instance == null:
		push_warning("HUDLayer: Failed to instance 'item_obtained_popup_scene'.")
		return

	_item_popup = popup_instance as ItemObtainedPopup
	if _item_popup == null:
		push_warning("HUDLayer: Instanced popup is not an ItemObtainedPopup.")
	add_child(popup_instance)


func _connect_inventory_item_obtained() -> void:
	# Autoload name in project.godot is "InventorySys"
	var inv_node: Node = get_node_or_null("/root/InventorySys")
	if inv_node == null:
		push_warning("HUDLayer: InventorySys autoload not found; item obtained popup will not be shown.")
		return

	_inventory_sys = inv_node as InventorySystem
	if _inventory_sys == null:
		push_warning("HUDLayer: InventorySys is not an InventorySystem instance.")
		return

	if not _inventory_sys.item_obtained.is_connected(_on_item_obtained):
		_inventory_sys.item_obtained.connect(_on_item_obtained)
		if debug_door_popup:
			print("HUDLayer: Connected to InventorySys.item_obtained for item popup.")


func _on_item_obtained(item: ItemDef, added: int, leftover: int) -> void:
	if added <= 0:
		return
	if _item_popup == null:
		return
	_item_popup.enqueue_item(item, added)


# -------------------------------------------------
# Door unlock popup (load-by-path, bind-by-signal)
# -------------------------------------------------
func _setup_door_unlock_popup() -> void:
	_door_popup = null

	if door_popup_script_path.strip_edges() == "":
		push_warning("HUDLayer: door_popup_script_path is empty; door popup disabled.")
		return

	var s: Script = load(door_popup_script_path) as Script
	if s == null:
		push_error("HUDLayer: Failed to load door popup script at: " + door_popup_script_path)
		return

	var inst: Variant = s.new()
	if typeof(inst) != TYPE_OBJECT:
		push_error("HUDLayer: Door popup script did not instance as an Object: " + door_popup_script_path)
		return

	var n: Node = inst as Node
	if n == null:
		push_error("HUDLayer: Door popup instance is not a Node: " + door_popup_script_path)
		return

	var c: Control = n as Control
	if c == null:
		push_error("HUDLayer: Door popup instance is not a Control: " + door_popup_script_path)
		return

	_door_popup = c
	_door_popup.name = "DoorUnlockPopup"
	add_child(_door_popup)

	if debug_door_popup:
		print("HUDLayer: DoorUnlockPopup loaded OK from ", door_popup_script_path)


func _bind_existing_doors() -> void:
	var nodes: Array[Node] = get_tree().get_nodes_in_group("interactable")
	var i: int = 0
	while i < nodes.size():
		var d: InteractableDoor = nodes[i] as InteractableDoor
		if d != null:
			_bind_one_door(d)
		i += 1

	if debug_door_popup:
		print("HUDLayer: Bound existing interactables scan. Count=", nodes.size())


func _bind_door_spawns() -> void:
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)
		if debug_door_popup:
			print("HUDLayer: Connected SceneTree.node_added for door binding.")


func _on_tree_node_added(n: Node) -> void:
	var d: InteractableDoor = n as InteractableDoor
	if d != null:
		_bind_one_door(d)


func _bind_scene_mgr_area_changed() -> void:
	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm == null:
		if debug_door_popup:
			print("HUDLayer: SceneMgr not found; skipping area_changed binding.")
		return

	if sm.has_signal("area_changed"):
		if not sm.is_connected("area_changed", Callable(self, "_on_area_changed")):
			sm.connect("area_changed", Callable(self, "_on_area_changed"))
			if debug_door_popup:
				print("HUDLayer: Connected to SceneMgr.area_changed; will rebind doors after swaps.")
	else:
		if debug_door_popup:
			print("HUDLayer: SceneMgr has no signal area_changed; skipping.")


func _on_area_changed(_area: Node, _entry_tag: String) -> void:
	call_deferred("_bind_existing_doors")



func _bind_one_door(d: InteractableDoor) -> void:
	if d == null:
		return

	if not d.has_signal("unlock_ui_requested"):
		if debug_door_popup:
			print("HUDLayer: Door has no unlock_ui_requested signal: ", d.name)
		return

	if not d.unlock_ui_requested.is_connected(_on_door_unlock_ui_requested):
		d.unlock_ui_requested.connect(_on_door_unlock_ui_requested)
		if debug_door_popup:
			print("HUDLayer: Connected unlock_ui_requested for door: ", d.name)


func _on_door_unlock_ui_requested(door: InteractableDoor, actor: Node) -> void:
	if debug_door_popup:
		print("HUDLayer: unlock_ui_requested received. door=", door.name, " actor=", actor)

	if _door_popup == null:
		push_warning("HUDLayer: Door popup is null (failed to load).")
		return

	if _door_popup.has_method("show_for"):
		_door_popup.call("show_for", door, actor)
	else:
		push_error("HUDLayer: Door popup has no method show_for(door, actor).")


# -------------------------------------------------
# Quest rewards popup (small chatbox-style panel)
# -------------------------------------------------
func _setup_quest_reward_popup() -> void:
	# Build a lightweight panel in code so no new scene is required.
	var panel: NinePatchRect = NinePatchRect.new()
	panel.name = "QuestRewardPopup"
	panel.visible = false

	# Match ItemObtainedPopup look
	panel.texture = load("res://ui/styles/chatbox.png") as Texture2D
	panel.patch_margin_left = 48
	panel.patch_margin_top = 48
	panel.patch_margin_right = 48
	panel.patch_margin_bottom = 48
	panel.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE
	panel.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_TILE_FIT

	# Anchor on the right, centered vertically, then offset downward a bit so it doesn't overlap the item popup.
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	panel.offset_left = -140.0
	panel.offset_right = 0.0
	panel.offset_top = quest_reward_popup_offset_y_from_center
	panel.offset_bottom = quest_reward_popup_offset_y_from_center + 72.0

	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.name = "VBox"
	vbox.anchor_left = 0.0
	vbox.anchor_top = 0.0
	vbox.anchor_right = 1.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 12.0
	vbox.offset_top = 10.0
	vbox.offset_right = -12.0
	vbox.offset_bottom = -10.0
	panel.add_child(vbox)

	_quest_title_label = Label.new()
	_quest_title_label.name = "TitleLabel"
	_quest_title_label.text = "Quest rewards"
	_quest_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_quest_title_label)

	_quest_body_label = Label.new()
	_quest_body_label.name = "BodyLabel"
	_quest_body_label.text = ""
	_quest_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_quest_body_label)

	# Apply the same font used by ItemObtainedPopup if available
	var f: Font = load("res://assets/fonts/Raleway-SemiBold.ttf") as Font
	if f != null:
		_quest_title_label.add_theme_font_override("font", f)
		_quest_body_label.add_theme_font_override("font", f)
		_quest_title_label.add_theme_font_size_override("font_size", 6)
		_quest_body_label.add_theme_font_size_override("font_size", 6)

	# Text color similar to ItemObtainedPopup
	_quest_title_label.add_theme_color_override("font_color", Color(0.2509804, 0.13333334, 0.10980392, 1.0))
	_quest_body_label.add_theme_color_override("font_color", Color(0.2509804, 0.13333334, 0.10980392, 1.0))

	add_child(panel)
	_quest_panel = panel

	_quest_timer = Timer.new()
	_quest_timer.name = "QuestRewardTimer"
	_quest_timer.one_shot = true
	add_child(_quest_timer)

	if not _quest_timer.timeout.is_connected(_on_quest_timer_timeout):
		_quest_timer.timeout.connect(_on_quest_timer_timeout)


func _connect_quest_rewards() -> void:
	var qs_node: Node = get_node_or_null("/root/QuestSys")
	if qs_node == null:
		# QuestSys may not exist in some test scenes; fail quietly.
		return

	_quest_sys = qs_node as QuestSystem
	if _quest_sys == null:
		push_warning("HUDLayer: QuestSys is not a QuestSystem instance.")
		return

	if not _quest_sys.quest_rewards_granted.is_connected(_on_quest_rewards_granted):
		_quest_sys.quest_rewards_granted.connect(_on_quest_rewards_granted)


func _on_quest_rewards_granted(def: QuestDef, rewards: Dictionary) -> void:
	if def == null:
		return

	var quest_name: String = def.display_name
	if quest_name == "":
		quest_name = String(def.quest_id)

	var xp: int = 0
	if rewards.has("xp"):
		var v: Variant = rewards["xp"]
		if typeof(v) == TYPE_INT:
			xp = int(v)

	var gold: int = 0
	if rewards.has("gold"):
		var vg: Variant = rewards["gold"]
		if typeof(vg) == TYPE_INT:
			gold = int(vg)

	var body: String = quest_name
	if xp > 0:
		body += "\n+" + str(xp) + " XP"
	if gold > 0:
		body += "\n+" + str(gold) + " gold"

	_enqueue_quest_reward("Quest completed!", body)


func _enqueue_quest_reward(title: String, body: String) -> void:
	if _quest_panel == null or _quest_timer == null:
		return

	var entry: Dictionary = {
		"title": title,
		"body": body
	}
	_quest_queue.append(entry)

	if not _quest_is_showing:
		_dequeue_and_show_next_quest_reward()


func _dequeue_and_show_next_quest_reward() -> void:
	if _quest_panel == null or _quest_timer == null:
		return

	if _quest_queue.is_empty():
		_quest_is_showing = false
		_quest_panel.visible = false
		return

	_quest_is_showing = true
	var entry: Dictionary = _quest_queue.pop_front()

	if _quest_title_label != null:
		_quest_title_label.text = String(entry.get("title", "Quest completed!"))
	if _quest_body_label != null:
		_quest_body_label.text = String(entry.get("body", ""))

	_quest_panel.visible = true
	_quest_timer.start(quest_reward_popup_duration)


func _on_quest_timer_timeout() -> void:
	_dequeue_and_show_next_quest_reward()


# -------------------------------------------------
# Existing helper
# -------------------------------------------------
func is_ui_blocking_input() -> bool:
	# Inventory/menus visible?
	var inv: Node = get_node_or_null("InventorySheet")
	if inv != null and inv is Control and (inv as Control).visible:
		return true

	var tabs: Node = get_node_or_null("TabbedMenu")
	if tabs != null and tabs is Control and (tabs as Control).visible:
		return true

	# Door popup visible?
	if _door_popup != null and _door_popup.visible:
		return true

	# Ready bar editing focus?
	var ready: Node = get_node_or_null("ConsumableReadyBar")
	if ready != null and ready is Control and (ready as Control).has_focus():
		return true

	# Any focused Control with mouse captured?
	var f: Control = get_viewport().gui_get_focus_owner()
	if f != null:
		if f.get_viewport() != null:
			return true

	return false
