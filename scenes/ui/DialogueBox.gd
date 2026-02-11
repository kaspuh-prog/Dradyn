extends Control
class_name DialogueBox

signal choice_selected(index: int, id: StringName)
signal dialogue_closed()

@export var wrap_width: int = 320
@export var show_speaker_name: bool = true

# Keep the box from exceeding the viewport width.
@export var clamp_to_viewport: bool = true
@export var viewport_margin_px: int = 16

# NEW: safety padding so the RichTextLabel never “hangs” past the NinePatch edge.
# This accounts for BG theme/panel padding + RichTextLabel internal margins.
@export var inner_padding_px: int = 24

@onready var _bg: Control = $BG
@onready var _speaker_label: Label = $BG/Header/SpeakerLabel
@onready var _body_label: RichTextLabel = $BG/Body
@onready var _choices_row: HBoxContainer = $BG/ChoicesRow

var _choice_ids: Array[StringName] = []


func _ready() -> void:
	_setup_labels()
	_clear_choices()
	visible = false


func _setup_labels() -> void:
	# Clip children at BOTH levels (some themes / parents can still draw outside).
	clip_contents = true
	if _bg != null:
		_bg.clip_contents = true

	if _body_label != null:
		_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		_body_label.fit_content = true
		_body_label.scroll_active = false
		_body_label.scroll_following = false
		_body_label.clip_contents = true

		var w: int = _body_text_width()
		_body_label.custom_minimum_size = Vector2(float(w), 0.0)

	if _speaker_label != null:
		_speaker_label.visible = show_speaker_name


# -------------------------------------------------
# Public API
# -------------------------------------------------

func show_message(
	text: String,
	speaker: String = "",
	choices: Array[String] = [],
	choice_ids: Array[StringName] = []
) -> void:
	# Speaker
	if _speaker_label != null:
		if show_speaker_name and speaker != "":
			_speaker_label.text = speaker
			_speaker_label.visible = true
		else:
			_speaker_label.text = ""
			_speaker_label.visible = false

	# Body text
	if _body_label != null:
		_body_label.text = text
		var w: int = _body_text_width()
		_body_label.custom_minimum_size = Vector2(float(w), 0.0)

	# Choices
	_build_choice_buttons(choices, choice_ids)

	visible = true
	_request_size_update()


func close_dialogue() -> void:
	visible = false
	dialogue_closed.emit()


# -------------------------------------------------
# Internal: choices
# -------------------------------------------------

func _build_choice_buttons(
	choices: Array[String],
	choice_ids: Array[StringName]
) -> void:
	_clear_choices()
	_choice_ids.clear()

	if _choices_row == null:
		return

	var count: int = choices.size()
	if count <= 0:
		_choices_row.visible = false
		return

	_choices_row.visible = true

	var use_custom_ids: bool = choice_ids.size() == count

	var i: int = 0
	while i < count:
		var label: String = choices[i]
		var id_value: StringName = StringName(label)
		if use_custom_ids:
			id_value = choice_ids[i]

		_choice_ids.append(id_value)

		var btn: Button = Button.new()
		btn.text = label
		btn.focus_mode = Control.FOCUS_ALL
		btn.flat = true

		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.custom_minimum_size = Vector2(0.0, 14.0)

		if _body_label != null:
			var body_font: Font = _body_label.get_theme_font("normal_font")
			if body_font != null:
				btn.add_theme_font_override("font", body_font)

			var body_font_size: int = _body_label.get_theme_font_size("normal_font_size")
			if body_font_size > 0:
				btn.add_theme_font_size_override("font_size", body_font_size)

			var body_font_color: Color = _body_label.get_theme_color("font_color")
			btn.add_theme_color_override("font_color", body_font_color)

		btn.add_theme_constant_override("content_margin_left", 4)
		btn.add_theme_constant_override("content_margin_right", 4)
		btn.add_theme_constant_override("content_margin_top", 1)
		btn.add_theme_constant_override("content_margin_bottom", 1)

		btn.pressed.connect(_on_choice_pressed.bind(i))
		_choices_row.add_child(btn)
		i += 1


func _clear_choices() -> void:
	if _choices_row == null:
		return

	var children: Array[Node] = _choices_row.get_children()
	var i: int = 0
	while i < children.size():
		children[i].queue_free()
		i += 1
	_choices_row.visible = false


func _on_choice_pressed(index: int) -> void:
	var id_value: StringName = StringName("")
	if index >= 0 and index < _choice_ids.size():
		id_value = _choice_ids[index]
	choice_selected.emit(index, id_value)


# -------------------------------------------------
# Internal: sizing
# -------------------------------------------------

func _request_size_update() -> void:
	call_deferred("_update_size_to_content")


func _update_size_to_content() -> void:
	if _bg == null:
		return

	# Re-apply wrap widths every update (viewport can change, fonts can change).
	var wrap_w: int = _effective_wrap_width()
	var body_w: int = _body_text_width()

	if _body_label != null:
		_body_label.custom_minimum_size = Vector2(float(body_w), 0.0)

		# Force the label's actual width too (prevents “hang” even if min-size math is off).
		var s: Vector2 = _body_label.size
		s.x = float(body_w)
		_body_label.size = s

	# Let BG decide its minimum size from children.
	var min_size: Vector2 = _bg.get_combined_minimum_size()

	# Force the BG/control width to the wrap width (not the body width).
	if min_size.x < float(wrap_w):
		min_size.x = float(wrap_w)

	_bg.custom_minimum_size = min_size
	custom_minimum_size = min_size

	# IMPORTANT: Explicitly set sizes so non-container parents still resize correctly.
	_bg.size = min_size
	size = min_size


func _effective_wrap_width() -> int:
	var w: int = wrap_width
	if w <= 0:
		w = 320

	if not clamp_to_viewport:
		return w

	var vp: Viewport = get_viewport()
	if vp == null:
		return w

	var vp_w: int = int(vp.get_visible_rect().size.x)
	if vp_w <= 0:
		return w

	var max_w: int = vp_w - viewport_margin_px
	if max_w < 64:
		max_w = 64

	if w > max_w:
		w = max_w

	return w


func _body_text_width() -> int:
	var w: int = _effective_wrap_width() - inner_padding_px
	if w < 64:
		w = 64
	return w
