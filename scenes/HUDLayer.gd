extends CanvasLayer
class_name HUDLayer

@export var party_hud_scene: PackedScene
@export var hud_offset: Vector2i = Vector2i(16, 16)  # screen-space offset from top-left
@export var ui_layer: int = 10
@export var item_obtained_popup_scene: PackedScene

var _party_hud: Node = null
var _item_popup: ItemObtainedPopup = null
var _inventory_sys: InventorySystem = null

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
		print("HUDLayer: Connected to InventorySys.item_obtained for item popup.")

func _on_item_obtained(item: ItemDef, added: int, leftover: int) -> void:
	if added <= 0:
		return
	if _item_popup == null:
		return
	_item_popup.enqueue_item(item, added)

func is_ui_blocking_input() -> bool:
	# Inventory/menus visible?
	var inv: Node = get_node_or_null("InventorySheet")
	if inv != null and inv is Control and (inv as Control).visible:
		return true

	var tabs: Node = get_node_or_null("TabbedMenu")
	if tabs != null and tabs is Control and (tabs as Control).visible:
		return true

	# Ready bar editing focus?
	var ready: Node = get_node_or_null("ConsumableReadyBar")
	if ready != null and ready is Control and (ready as Control).has_focus():
		return true

	# Any focused Control with mouse captured?
	var f: Control = get_viewport().gui_get_focus_owner()
	if f != null:
		if f.get_viewport() != null:
			# When a drag is active, the focused control typically remains, and we should stand down.
			# We also treat any focused control in HUD as "UI owns input".
			return true

	return false
