extends Control
class_name DialogueBox

signal choice_selected(index: int, id: StringName)
signal dialogue_closed()

@export var wrap_width: int = 320
@export var show_speaker_name: bool = true

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
	if _body_label != null:
		_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		_body_label.fit_content = true
		_body_label.custom_minimum_size = Vector2(float(wrap_width), 0.0)

	if _speaker_label != null:
		_speaker_label.visible = show_speaker_name


# -------------------------------------------------
# Public API
# -------------------------------------------------

## Show a dialogue line with optional speaker and choices.
## choices: button labels (e.g., ["Yes", "No"])
## choice_ids: optional stable ids (e.g., ["yes", "no"]) for logic; if empty, labels are reused as ids.
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

	# Choices
	_build_choice_buttons(choices, choice_ids)

	visible = true
	_request_size_update()


## Hide the dialogue box without emitting choice_selected.
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

		# Make the button "text only" so it sits nicely on the NinePatch.
		btn.flat = true

		# Keep the buttons from stretching to huge gray slabs.
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		btn.custom_minimum_size = Vector2(0.0, 14.0)

		# Match the dialogue body font + size + color so it feels integrated.
		if _body_label != null:
			var body_font: Font = _body_label.get_theme_font("normal_font")
			if body_font != null:
				btn.add_theme_font_override("font", body_font)

			var body_font_size: int = _body_label.get_theme_font_size("normal_font_size")
			if body_font_size > 0:
				btn.add_theme_font_size_override("font_size", body_font_size)

			# Grab the font color from the body label.
			var body_font_color: Color = _body_label.get_theme_color("font_color")
			btn.add_theme_color_override("font_color", body_font_color)

		# Tighter margins so the button doesn't look chunky.
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
	# Defer so layout / font metrics can update before we query sizes.
	call_deferred("_update_size_to_content")

func _update_size_to_content() -> void:
	if _bg == null:
		return

	if _body_label != null:
		var min_label: Vector2 = _body_label.get_minimum_size()
		if min_label.x < float(wrap_width):
			min_label.x = float(wrap_width)
		_body_label.custom_minimum_size = min_label

	# Let the BG decide its minimum size from children.
	var min_size: Vector2 = _bg.get_combined_minimum_size()

	if min_size.x < float(wrap_width):
		min_size.x = float(wrap_width)

	_bg.custom_minimum_size = min_size
	custom_minimum_size = min_size
