extends CanvasLayer
class_name TransitionLayer

@export var fade_color: Color = Color(0, 0, 0, 1)
@export var fade_out_time: float = 0.45
@export var fade_in_time: float = 0.35
@export var block_input_during_fade: bool = true

var _rect: ColorRect
var _tween: Tween
var _is_busy: bool = false

func _ready() -> void:
	layer = 100

	_rect = get_node_or_null("FadeRect") as ColorRect
	if _rect == null:
		_rect = ColorRect.new()
		_rect.name = "FadeRect"
		add_child(_rect)

	# Fullscreen anchors
	_rect.anchor_left = 0.0
	_rect.anchor_top = 0.0
	_rect.anchor_right = 1.0
	_rect.anchor_bottom = 1.0
	_rect.offset_left = 0.0
	_rect.offset_top = 0.0
	_rect.offset_right = 0.0
	_rect.offset_bottom = 0.0

	# Start fully clear and NON-blocking
	_rect.color = Color(fade_color.r, fade_color.g, fade_color.b, 0.0)
	_rect.visible = false
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

func is_fading() -> bool:
	return _is_busy

func fade_to_black() -> void:
	if _is_busy:
		await _wait_until_idle()
	_is_busy = true
	_begin_blocking_if_configured()

	_kill_tween()
	_rect.visible = true

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(
		_rect, "color",
		Color(fade_color.r, fade_color.g, fade_color.b, 1.0),
		max(0.0, fade_out_time)
	)
	await _tween.finished
	_is_busy = false

func fade_from_black() -> void:
	if _is_busy:
		await _wait_until_idle()
	_is_busy = true
	_begin_blocking_if_configured()

	_kill_tween()
	_rect.visible = true

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE)
	_tween.set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(
		_rect, "color",
		Color(fade_color.r, fade_color.g, fade_color.b, 0.0),
		max(0.0, fade_in_time)
	)
	await _tween.finished
	_is_busy = false

	# After fully clear, stop blocking and hide to restore UI input
	_end_blocking_and_hide()

func instant_black() -> void:
	_kill_tween()
	_is_busy = false
	_rect.visible = true
	_rect.color = Color(fade_color.r, fade_color.g, fade_color.b, 1.0)
	_begin_blocking_if_configured()

func instant_clear() -> void:
	_kill_tween()
	_is_busy = false
	_rect.color = Color(fade_color.r, fade_color.g, fade_color.b, 0.0)
	_end_blocking_and_hide()

func _begin_blocking_if_configured() -> void:
	if block_input_during_fade:
		_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _end_blocking_and_hide() -> void:
	_rect.visible = false
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _kill_tween() -> void:
	if _tween != null:
		if _tween.is_valid():
			_tween.kill()
	_tween = null

func _wait_until_idle() -> void:
	while _is_busy:
		await get_tree().process_frame
