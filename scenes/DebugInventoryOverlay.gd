extends Control
class_name DebugInventoryOverlay
# Godot 4.5 — fully typed, no ternaries.
# Verifies per-actor inventory wiring against your PartyManager (autoload "Party", group "PartyManager").
# - Lists party members using PartyManager.get_members()
# - Shows the controlled actor using PartyManager.get_controlled()
# - Uses InventorySystem per-actor bag APIs (ensure_inventory_model_for / get_inventory_model_for)
# - Hotkey F10 toggles visibility

@export_group("Test Setup")
@export var test_item_path: String = ""          # e.g. "res://data/items/LeatherVest.tres"
@export var transfer_slot_index: int = 0         # source slot in controlled actor's bag

@export_group("UI")
@export var start_visible: bool = true
@export var anchor_top_left: Vector2 = Vector2(16, 16)

var _panel: Panel = Panel.new()
var _vbox: VBoxContainer = VBoxContainer.new()
var _info_label: Label = Label.new()
var _btn_row: HBoxContainer = HBoxContainer.new()
var _btn_add: Button = Button.new()
var _btn_transfer: Button = Button.new()
var _btn_refresh: Button = Button.new()

func _ready() -> void:
	name = "DebugInventoryOverlay"
	mouse_filter = Control.MOUSE_FILTER_PASS
	visible = start_visible
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = anchor_top_left

	_panel.name = "Panel"
	_panel.custom_minimum_size = Vector2(380, 0)
	add_child(_panel)

	_vbox.name = "VBox"
	_vbox.anchor_left = 0.0
	_vbox.anchor_top = 0.0
	_vbox.anchor_right = 1.0
	_vbox.anchor_bottom = 1.0
	_vbox.offset_left = 8
	_vbox.offset_top = 8
	_vbox.offset_right = -8
	_vbox.offset_bottom = -8
	_panel.add_child(_vbox)

	var title: Label = Label.new()
	title.text = "Inventory Debug"
	title.add_theme_font_size_override("font_size", 18)
	_vbox.add_child(title)

	_info_label.name = "Info"
	_info_label.text = "(initializing…)"
	_vbox.add_child(_info_label)

	_btn_row.name = "Buttons"
	_vbox.add_child(_btn_row)

	_btn_add.text = "Add Test Item → Controlled"
	_btn_transfer.text = "Transfer Slot → Next Member"
	_btn_refresh.text = "Refresh"
	_btn_row.add_child(_btn_add)
	_btn_row.add_child(_btn_transfer)
	_btn_row.add_child(_btn_refresh)

	_btn_add.pressed.connect(_on_pressed_add)
	_btn_transfer.pressed.connect(_on_pressed_transfer)
	_btn_refresh.pressed.connect(_on_pressed_refresh)

	set_process_input(true)

	# Defer hookup so autoloads/groups are present
	call_deferred("_late_bind")

func _late_bind() -> void:
	_bind_party_signals()
	_refresh_info()

func _bind_party_signals() -> void:
	var party: Node = _get_party()
	if party != null:
		if not party.is_connected("party_changed", Callable(self, "_on_party_changed")):
			party.connect("party_changed", Callable(self, "_on_party_changed"))
		if not party.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
			party.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
	else:
		# Fallback: poll once on the next frame if autoload not ready
		await get_tree().process_frame
		party = _get_party()
		if party != null:
			_bind_party_signals()

func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k: InputEventKey = event as InputEventKey
		if k.pressed and k.physical_keycode == KEY_F10:
			visible = not visible

# -----------------------------
# Party resolution (matches Dradyn)
# -----------------------------
func _get_party() -> Node:
	# Primary: autoload named "Party" (editor shows > Party="*res://AutoLoads/PartyManager.gd")
	var party: Node = get_node_or_null("/root/Party")
	if party != null:
		return party
	# Fallback: first node in group "PartyManager"
	var pm: Node = get_tree().get_first_node_in_group("PartyManager")
	return pm

func _get_members() -> Array:
	var out: Array = []
	var party: Node = _get_party()
	if party == null:
		return out
	if party.has_method("get_members"):
		var any_v: Variant = party.call("get_members")
		if typeof(any_v) == TYPE_ARRAY:
			out = any_v
	return out

func _get_controlled() -> Node:
	var party: Node = _get_party()
	if party == null:
		return null
	if party.has_method("get_controlled"):
		var v: Variant = party.call("get_controlled")
		return v as Node
	return null

# -----------------------------
# Inventory access
# -----------------------------
func _inv() -> InventorySystem:
	var n: Node = get_node_or_null("/root/InventorySystem")
	if n == null:
		n = get_node_or_null("/root/InventorySys")
	return n as InventorySystem

func _ensure_bag(actor: Node) -> InventoryModel:
	var inv: InventorySystem = _inv()
	if inv == null or actor == null:
		return null
	return inv.ensure_inventory_model_for(actor)

func _bag(actor: Node) -> InventoryModel:
	var inv: InventorySystem = _inv()
	if inv == null or actor == null:
		return null
	return inv.get_inventory_model_for(actor)

# -----------------------------
# UI helpers
# -----------------------------
func _name_of(actor: Node) -> String:
	if actor == null:
		return "(none)"
	if actor.has_method("get_display_name"):
		var v: Variant = actor.call("get_display_name")
		return String(v)
	return String(actor.name)

func _count_non_empty_slots_for(actor: Node) -> int:
	var bag: InventoryModel = _bag(actor)
	if bag == null:
		return 0
	var inv: InventorySystem = _inv()
	if inv == null:
		return 0
	var count: int = 0
	var i: int = 0
	while i < inv.initial_slots:
		var st: Variant = bag.get_slot_stack(i)
		if st != null:
			count += 1
		i += 1
	return count

func _refresh_info() -> void:
	var inv: InventorySystem = _inv()
	var controlled: Node = _get_controlled()
	var members: Array = _get_members()

	# Ensure bags exist (so counts show up)
	var i: int = 0
	while i < members.size():
		_ensure_bag(members[i])
		i += 1

	var lines: Array[String] = []
	lines.append("Party size: " + str(members.size()))
	if controlled != null:
		lines.append("Controlled: " + _name_of(controlled))
	else:
		lines.append("Controlled: (none)")

	# Bag mode sanity
	var bag_mode: String = "Per-Actor"
	if inv == null:
		bag_mode = "InventorySystem not found"
	elif controlled == null or inv.get_inventory_model_for(controlled) == null:
		bag_mode = "No bag yet → will init on first add"

	lines.append("Bag Mode: " + bag_mode)
	lines.append("Transfer slot index: " + str(transfer_slot_index))
	lines.append("Members:")

	i = 0
	while i < members.size():
		var m: Node = members[i]
		var entry: String = "  " + str(i) + ": " + _name_of(m) + " — stacks " + str(_count_non_empty_slots_for(m))
		lines.append(entry)
		i += 1

	_info_label.text = "\n".join(lines)

# -----------------------------
# Buttons
# -----------------------------
func _on_pressed_refresh() -> void:
	_refresh_info()

func _on_pressed_add() -> void:
	var inv: InventorySystem = _inv()
	if inv == null:
		return
	var controlled: Node = _get_controlled()
	if controlled == null:
		return
	if test_item_path == "":
		return
	var res: Resource = ResourceLoader.load(test_item_path)
	var def: ItemDef = res as ItemDef
	if def == null:
		return
	inv.add_item_for(controlled, def, 1)
	_refresh_info()

func _on_pressed_transfer() -> void:
	var inv: InventorySystem = _inv()
	if inv == null:
		return
	var members: Array = _get_members()
	var controlled: Node = _get_controlled()
	if controlled == null:
		return
	# Choose next member after controlled
	var controlled_index: int = members.find(controlled)
	if controlled_index == -1:
		return
	var target_index: int = controlled_index + 1
	if target_index >= members.size():
		target_index = 0
	if members.size() < 2:
		return
	var target: Node = members[target_index]

	inv.transfer_stack_between_actors(controlled, transfer_slot_index, target)
	_refresh_info()

# -----------------------------
# Party signal handlers
# -----------------------------
func _on_party_changed(_members: Array) -> void:
	_refresh_info()

func _on_controlled_changed(_actor: Node) -> void:
	_refresh_info()
