extends Control
class_name ItemObtainedPopup

@export var show_duration: float = 2.0

var _queue: Array[Dictionary] = []
var _is_showing: bool = false

var _title_label: Label = null
var _item_label: Label = null
var _icon_rect: TextureRect = null
var _timer: Timer = null

func _ready() -> void:
	_title_label = get_node_or_null("Panel/VBox/TitleLabel") as Label
	_item_label = get_node_or_null("Panel/VBox/ContentRow/ItemLabel") as Label
	_icon_rect = get_node_or_null("Panel/VBox/ContentRow/Icon") as TextureRect
	_timer = get_node_or_null("Panel/Timer") as Timer

	if _timer == null:
		_timer = Timer.new()
		_timer.name = "Timer"
		add_child(_timer)

	_timer.one_shot = true
	if not _timer.timeout.is_connected(_on_timer_timeout):
		_timer.timeout.connect(_on_timer_timeout)

	# Default text
	if _title_label != null:
		_title_label.text = "You obtained a new item!"

	hide()

func enqueue_item(item: ItemDef, count: int) -> void:
	if item == null:
		return
	if count <= 0:
		return

	var entry: Dictionary = {
		"item": item,
		"count": count
	}
	_queue.append(entry)

	if not _is_showing:
		_dequeue_and_show_next()

func _dequeue_and_show_next() -> void:
	if _queue.is_empty():
		_is_showing = false
		hide()
		return

	_is_showing = true
	var entry: Dictionary = _queue.pop_front()
	_apply_entry(entry)

	show()
	if _timer != null:
		_timer.start(show_duration)

func _apply_entry(entry: Dictionary) -> void:
	var item: ItemDef = entry.get("item", null)
	var count: int = int(entry.get("count", 0))

	if item == null:
		return

	# Title label stays "You received"
	if _item_label != null:
		var display: String = item.display_name
		if count > 1:
			display = display + " x" + str(count)
		_item_label.text = display

	if _icon_rect != null:
		_icon_rect.texture = item.icon

func _on_timer_timeout() -> void:
	_dequeue_and_show_next()
