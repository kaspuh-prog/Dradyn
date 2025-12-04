extends Control
class_name BagTabsRow

signal bag_changed(bag_index: int)     # 0..4 for Bag1..Bag5, 5 for Key Items
signal tab_pressed_locked(index: int)  # fired if a locked tab is clicked

@export var locked_mask: PackedInt32Array = [0, 1, 1, 1, 1, 0]
# index 0..5: 1 means locked, 0 means unlocked. Default: Bag1 unlocked, Bag2..5 locked, Key unlocked.

@export var start_index: int = 0       # 0..5; which tab is active at open

var _buttons: Array[TextureButton] = []
var _active: int = -1

func _ready() -> void:
	_collect_buttons()
	_apply_locked_visuals()
	_connect_buttons()
	_set_active(clampi(start_index, 0, 5))

func get_active() -> int:
	return _active

func set_locked(index: int, locked: bool) -> void:
	if index < 0 or index >= 6:
		return
	if index >= locked_mask.size():
		# grow mask if needed
		var grow: int = index - locked_mask.size() + 1
		var i: int = 0
		while i < grow:
			locked_mask.append(0)
			i += 1
	locked_mask[index] = 1 if locked else 0
	_apply_locked_visuals()

func _collect_buttons() -> void:
	_buttons.clear()
	var order: Array[String] = ["Tab_Bag1", "Tab_Bag2", "Tab_Bag3", "Tab_Bag4", "Tab_Bag5", "Tab_Key"]
	var i: int = 0
	while i < order.size():
		var n: String = order[i]
		var b: TextureButton = get_node_or_null(n) as TextureButton
		if b != null:
			_buttons.append(b)
		else:
			push_warning("BagTabsRow: Missing child TextureButton: " + n)
		i += 1

func _apply_locked_visuals() -> void:
	var i: int = 0
	while i < _buttons.size():
		var b: TextureButton = _buttons[i]
		var locked: bool = false
		if i < locked_mask.size():
			locked = locked_mask[i] != 0
		# Use disabled to show your locked art and ignore input
		b.disabled = locked
		# ensure toggle mode for pressed state visuals
		b.toggle_mode = true
		i += 1

func _connect_buttons() -> void:
	var i: int = 0
	while i < _buttons.size():
		var b: TextureButton = _buttons[i]
		if not b.pressed.is_connected(_on_button_pressed.bind(i)):
			b.pressed.connect(_on_button_pressed.bind(i))
		i += 1

func _on_button_pressed(index: int) -> void:
	# If locked, bounce and signal it
	var locked: bool = false
	if index < locked_mask.size():
		locked = locked_mask[index] != 0
	if locked:
		tab_pressed_locked.emit(index)
		# restore previous visual pressed state
		_update_pressed_visuals()
		return

	_set_active(index)

func _set_active(index: int) -> void:
	if index < 0 or index >= _buttons.size():
		return
	_active = index
	_update_pressed_visuals()
	bag_changed.emit(_active)

func _update_pressed_visuals() -> void:
	var i: int = 0
	while i < _buttons.size():
		var b: TextureButton = _buttons[i]
		b.button_pressed = (i == _active)
		i += 1
