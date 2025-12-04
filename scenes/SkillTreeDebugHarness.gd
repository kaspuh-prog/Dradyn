# File: SkillTreeSheetDebugHarness.gd
# Attach to: SkillTreeSheet/SkillTreeDebug  (a child Node)
extends Node
class_name SkillTreeSheetDebugHarness

@export var auto_demo_on_ready: bool = true
@export var panel0_count: int = 40
@export var panel1_count: int = 25
@export var panel2_count: int = 0
@export var panel3_count: int = 0

# Optional: set a specific sheet path if this node is not a direct child
@export var sheet_path: NodePath = NodePath("..")

# Configurable hotkeys (defaults avoid F11 & F12)
@export var key_fill_p0: Key = KEY_F4
@export var key_fill_p1: Key = KEY_F5
@export var key_fill_p2: Key = KEY_F6
@export var key_fill_p3: Key = KEY_F7
@export var key_fill_all: Key = KEY_F8
@export var key_clear_all: Key = KEY_F9

const ACT_P0: StringName = &"SKILLTREE_DEMO_P0"
const ACT_P1: StringName = &"SKILLTREE_DEMO_P1"
const ACT_P2: StringName = &"SKILLTREE_DEMO_P2"
const ACT_P3: StringName = &"SKILLTREE_DEMO_P3"
const ACT_ALL: StringName = &"SKILLTREE_DEMO_ALL"
const ACT_CLEAR: StringName = &"SKILLTREE_DEMO_CLEAR"

var _sheet: Node

func _enter_tree() -> void:
	_sheet = get_node_or_null(sheet_path)
	_setup_actions()

func _ready() -> void:
	if auto_demo_on_ready:
		_populate_all()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACT_P0):
		_populate_one(0, panel0_count)
	elif event.is_action_pressed(ACT_P1):
		_populate_one(1, panel1_count)
	elif event.is_action_pressed(ACT_P2):
		_populate_one(2, panel2_count)
	elif event.is_action_pressed(ACT_P3):
		_populate_one(3, panel3_count)
	elif event.is_action_pressed(ACT_ALL):
		_populate_all()
	elif event.is_action_pressed(ACT_CLEAR):
		_clear_all()

func _setup_actions() -> void:
	_bind_action_key(ACT_P0, key_fill_p0)
	_bind_action_key(ACT_P1, key_fill_p1)
	_bind_action_key(ACT_P2, key_fill_p2)
	_bind_action_key(ACT_P3, key_fill_p3)
	_bind_action_key(ACT_ALL, key_fill_all)
	_bind_action_key(ACT_CLEAR, key_clear_all)

func _bind_action_key(act: StringName, keycode: Key) -> void:
	if not InputMap.has_action(act):
		InputMap.add_action(act)
	# Avoid adding duplicate key events if already present
	if not _action_has_key(act, keycode):
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.pressed = false
		InputMap.action_add_event(act, ev)

func _action_has_key(act: StringName, keycode: Key) -> bool:
	var events := InputMap.action_get_events(act)
	for e in events:
		var kev := e as InputEventKey
		if kev != null:
			if kev.keycode == keycode:
				return true
	return false

# ---- Helpers (call into SkillTreeSheet’s API) ----
func _populate_one(index: int, count: int) -> void:
	if _sheet == null:
		return
	if _sheet.has_method("populate_test_scroll"):
		_sheet.call("populate_test_scroll", index, count)

func _populate_all() -> void:
	_populate_one(0, panel0_count)
	_populate_one(1, panel1_count)
	_populate_one(2, panel2_count)
	_populate_one(3, panel3_count)

func _clear_all() -> void:
	if _sheet == null:
		return
	for i in 4:
		if _sheet.has_method("clear_panel"):
			_sheet.call("clear_panel", i)
