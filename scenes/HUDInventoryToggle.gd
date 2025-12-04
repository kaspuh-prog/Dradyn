extends Node
class_name HUDInventoryToggle

@export var tabbed_menu_path: NodePath  # optional; leave empty to auto-find
@export var debug_logs: bool = true

var _tabbed_menu: Node = null

func _enter_tree() -> void:
	# We want global hotkey without stealing player controls.
	set_process_unhandled_input(true)

func _ready() -> void:
	_resolve_tabbed_menu()

func _resolve_tabbed_menu() -> void:
	if _tabbed_menu != null:
		return
	if tabbed_menu_path != NodePath():
		_tabbed_menu = get_node_or_null(tabbed_menu_path)
	if _tabbed_menu == null:
		# Try to find a child named "TabbedMenu" anywhere under HUDRoot
		_tabbed_menu = get_tree().get_root().find_child("TabbedMenu", true, false)
	if debug_logs and _tabbed_menu == null:
		print("[HUDInventoryToggle] TabbedMenu not found. Add it under HUDRoot (name it 'TabbedMenu').")

func _toggle_tabbed_menu() -> void:
	_resolve_tabbed_menu()
	if _tabbed_menu == null:
		return
	# Prefer the helper if present
	if "set_open" in _tabbed_menu:
		_tabbed_menu.set_open(!_tabbed_menu.visible)
	else:
		_tabbed_menu.visible = !_tabbed_menu.visible

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_inventory"):
		_toggle_tabbed_menu()
		get_viewport().set_input_as_handled()
