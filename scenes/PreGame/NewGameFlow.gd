extends Control
class_name NewGameFlow
# Godot 4.5 — fully typed, no ternaries.

# ------------------------------------------------------------
# Flow Nodes
# ------------------------------------------------------------
@export_group("Flow Nodes")
@export var intro_screen_path: NodePath = NodePath("NewGameIntroScreen")
@export var customization_screen_path: NodePath = NodePath("PlayerCustomizationScreen")

# ------------------------------------------------------------
# Intro UI (Manual Layout)
# ------------------------------------------------------------
@export_group("Intro UI")
@export var narration_label_path: NodePath = NodePath("NewGameIntroScreen/TextPanel/NarrationLabel")
@export var continue_button_path: NodePath = NodePath("NewGameIntroScreen/ContinueIcon")

# Optional: you said FadeOverlay is under NewGameFlow root
@export_group("Overlay")
@export var fade_overlay_path: NodePath = NodePath("FadeOverlay")

# ------------------------------------------------------------
# Typewriter
# ------------------------------------------------------------
@export_group("Typewriter")
@export_range(0.005, 0.20, 0.005) var char_interval_sec: float = 0.04
@export_range(0.0, 1.0, 0.01) var punctuation_pause_sec: float = 0.18

# If true, when the label overflows vertically we clear it and keep typing from the top.
# This version avoids splitting words across pages.
@export var wrap_pages_instead_of_scroll: bool = true

@export_group("Intro Text")
@export_multiline var intro_text: String = "I’ve told this tale before.\n\nNot as a ballad.\nNot as a sermon.\nJust as it happened.\n\nDradyn has always been a place where histories overlap.\nFamilies that swear their blood remembers distant lands.\nCities that rise, fracture, and call it destiny.\n\nMost people live their whole lives without touching the deeper story.\nAnd why would they?\nThey have work, loves, rivalries, small victories.\nOrdinary days.\n\nUntil the ordinary begins to bend.\nA pattern breaks.\nA promise stops holding.\nAnd suddenly everyone is listening for footsteps that aren’t there.\n\nI remember the moment the tale truly starts.\nI remember the feeling.\n\nI just can’t remember who I’m meant to follow.\n\nSo tell me—\n\nTell me about the hero."

# ------------------------------------------------------------
# What happens after customization confirm/cancel
# ------------------------------------------------------------
@export_group("Next Scene (Optional)")
@export var next_scene_path: String = "" # If empty, we load res://scenes/Main.tscn
@export var cancel_scene_path: String = "" # If empty, we just print and stay put.

# ------------------------------------------------------------
# NEW GAME: seed payload
# ------------------------------------------------------------
@export_group("New Game Save")
@export_range(1, 24, 1) var new_game_max_slots: int = 6
@export_file("*.tscn") var base_player_scene_path: String = "res://scenes/Actors/PCs/PC_Base.tscn"
@export_file("*.tscn") var new_game_area_path: String = "" # optional; leave empty to use BootArea defaults
@export var new_game_entry_tag: String = "default"

# ------------------------------------------------------------
# Runtime
# ------------------------------------------------------------
var _intro_screen: Control
var _custom_screen: PlayerCustomizationScreen

var _narration: RichTextLabel
var _continue_button: BaseButton
var _fade: ColorRect

var _typing: bool = false
var _reveal_index: int = 0
var _char_timer: float = 0.0
var _punct_pause_timer: float = 0.0

# buffer of what is currently on the “page”
var _page_text: String = ""


func _ready() -> void:
	_intro_screen = get_node_or_null(intro_screen_path) as Control
	_custom_screen = get_node_or_null(customization_screen_path) as PlayerCustomizationScreen

	_narration = get_node_or_null(narration_label_path) as RichTextLabel
	_continue_button = get_node_or_null(continue_button_path) as BaseButton
	_fade = get_node_or_null(fade_overlay_path) as ColorRect

	_configure_narration_label()

	_wire_intro_continue()
	_wire_customization_signals()

	_show_intro()
	_start_typewriter()


func _unhandled_input(event: InputEvent) -> void:
	# Intro phase inputs
	if _intro_screen != null and _intro_screen.visible:
		if event.is_action_pressed("ui_cancel"):
			_enter_customization()
			return

		if event.is_action_pressed("ui_accept"):
			if _typing:
				_finish_instant()
			else:
				_enter_customization()
			return

	# Customization phase inputs (Escape should cancel)
	if _custom_screen != null and _custom_screen.visible:
		if event.is_action_pressed("ui_cancel"):
			_on_customization_cancelled()
			return


func _process(delta: float) -> void:
	if not _typing:
		return

	if _punct_pause_timer > 0.0:
		_punct_pause_timer -= delta
		if _punct_pause_timer > 0.0:
			return
		_punct_pause_timer = 0.0

	_char_timer += delta

	# Reveal at most one char per frame so it never “bursts” on hitches.
	if _char_timer >= char_interval_sec and _typing:
		_char_timer -= char_interval_sec
		_reveal_next_char()


# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
func _configure_narration_label() -> void:
	if _narration == null:
		return

	_narration.scroll_active = false
	_narration.scroll_following = false
	_narration.clip_contents = true


# ------------------------------------------------------------
# Wiring
# ------------------------------------------------------------
func _wire_intro_continue() -> void:
	if _continue_button == null:
		return

	_continue_button.visible = false
	if not _continue_button.pressed.is_connected(_on_intro_continue_pressed):
		_continue_button.pressed.connect(_on_intro_continue_pressed)


func _wire_customization_signals() -> void:
	if _custom_screen == null:
		return

	if not _custom_screen.customization_confirmed.is_connected(_on_customization_confirmed):
		_custom_screen.customization_confirmed.connect(_on_customization_confirmed)

	if not _custom_screen.customization_cancelled.is_connected(_on_customization_cancelled):
		_custom_screen.customization_cancelled.connect(_on_customization_cancelled)


# ------------------------------------------------------------
# Intro
# ------------------------------------------------------------
func _show_intro() -> void:
	if _intro_screen != null:
		_intro_screen.visible = true
	if _custom_screen != null:
		_custom_screen.visible = false

	if _fade != null:
		_fade.visible = false

	if _continue_button != null:
		_continue_button.visible = false


func _start_typewriter() -> void:
	if _narration == null:
		_typing = false
		return

	_reveal_index = 0
	_char_timer = 0.0
	_punct_pause_timer = 0.0
	_typing = true

	_page_text = ""
	_narration.clear()

	if _continue_button != null:
		_continue_button.visible = false


func _finish_instant() -> void:
	if _narration == null:
		_typing = false
		return

	_typing = false
	_reveal_index = intro_text.length()

	_page_text = intro_text
	_narration.clear()
	_narration.add_text(intro_text)

	if _continue_button != null:
		_continue_button.visible = true


func _reveal_next_char() -> void:
	if _narration == null:
		_typing = false
		return

	if _reveal_index >= intro_text.length():
		_typing = false
		if _continue_button != null:
			_continue_button.visible = true
		return

	var ch: String = intro_text.substr(_reveal_index, 1)
	_reveal_index += 1

	_page_text += ch
	_narration.add_text(ch)

	if wrap_pages_instead_of_scroll:
		_apply_page_wrap_if_overflow()

	if ch == ".":
		_apply_punct_pause()
	elif ch == "!":
		_apply_punct_pause()
	elif ch == "?":
		_apply_punct_pause()
	elif ch == ",":
		_apply_punct_pause()


func _apply_punct_pause() -> void:
	if punctuation_pause_sec <= 0.0:
		return
	_punct_pause_timer = punctuation_pause_sec


func _apply_page_wrap_if_overflow() -> void:
	if _narration == null:
		return
	if _narration.size.y <= 12.0:
		return

	var content_h: float = _narration.get_content_height()
	var panel_h: float = _narration.size.y
	if content_h <= (panel_h + 1.0):
		return

	var cut_idx: int = _find_last_whitespace_index(_page_text)

	var carry: String = ""
	if cut_idx >= 0 and cut_idx < (_page_text.length() - 1):
		carry = _page_text.substr(cut_idx + 1)
	else:
		carry = _page_text

	carry = carry.lstrip(" \t\r\n")

	_page_text = carry

	_narration.clear()
	if _page_text != "":
		_narration.add_text(_page_text)


func _find_last_whitespace_index(s: String) -> int:
	var i: int = s.length() - 1
	while i >= 0:
		var ch: String = s.substr(i, 1)
		if ch == " ":
			return i
		if ch == "\n":
			return i
		if ch == "\t":
			return i
		if ch == "\r":
			return i
		i -= 1
	return -1


func _on_intro_continue_pressed() -> void:
	if _typing:
		_finish_instant()
		return
	_enter_customization()


func _enter_customization() -> void:
	_typing = false

	if _intro_screen != null:
		_intro_screen.visible = false
	if _custom_screen != null:
		_custom_screen.visible = true


# ------------------------------------------------------------
# Customization results
# ------------------------------------------------------------
func _on_customization_confirmed(customization: PlayerCustomization) -> void:
	print("NewGame customization confirmed:")
	print(customization.to_dict())

	_create_and_load_new_game_slot(customization)

	var target_scene: String = next_scene_path.strip_edges()
	if target_scene == "":
		target_scene = "res://scenes/Main.tscn"

	var err: Error = get_tree().change_scene_to_file(target_scene)
	if err != OK:
		push_warning("NewGameFlow: failed to change_scene_to_file('%s') err=%d" % [target_scene, int(err)])


func _create_and_load_new_game_slot(customization: PlayerCustomization) -> void:
	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		push_warning("NewGameFlow: SaveSys autoload not found; cannot create New Game slot.")
		return

	var max_slots: int = new_game_max_slots
	if max_slots < 1:
		max_slots = 6

	var slot: int = 1
	while slot <= max_slots:
		if not save_sys.slot_exists(slot):
			break
		slot += 1
	if slot > max_slots:
		slot = 1

	# Build MINIMAL payload: party roster uses PC_Base; identity comes from customization.
	var payload: Dictionary = {}
	var cd: Dictionary = customization.to_dict()

	payload["player_name"] = str(cd.get("display_name", "")).strip_edges()
	payload["player_customization"] = cd
	payload["new_game"] = true

	var party: Dictionary = {}
	var members: Array = []
	var member0: Dictionary = {}
	member0["scene_path"] = base_player_scene_path
	member0["node_name"] = "Player"
	members.append(member0)
	party["members"] = members
	party["controlled_index"] = 0
	payload["party"] = party

	var ap: String = new_game_area_path.strip_edges()
	if ap != "":
		payload["area_path"] = ap

	var et: String = new_game_entry_tag.strip_edges()
	if et == "":
		et = "default"
	payload["entry_tag"] = et

	# Prevent “old runtime party bleed” by disabling capture during the save call.
	var prev_auto: bool = save_sys.auto_capture_runtime_state
	save_sys.auto_capture_runtime_state = false
	save_sys.save_to_slot(slot, payload)
	save_sys.auto_capture_runtime_state = prev_auto

	# CRITICAL: make this slot the active loaded payload (BootArea reads last_loaded_payload).
	save_sys.load_from_slot(slot)

	print("NewGameFlow: saved+loaded new slot ", slot, " base_player=", base_player_scene_path)


func _on_customization_cancelled() -> void:
	_on_customization_cancelled_impl()


func _on_customization_cancelled_impl() -> void:
	print("NewGame customization cancelled.")

	if cancel_scene_path.strip_edges() == "":
		_show_intro()
		_start_typewriter()
		return

	var err: Error = get_tree().change_scene_to_file(cancel_scene_path)
	if err != OK:
		push_warning("NewGameFlow: failed to change_scene_to_file('%s') err=%d" % [cancel_scene_path, int(err)])
