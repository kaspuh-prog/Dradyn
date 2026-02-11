extends Control
class_name PetModeBar
# Godot 4.5 — fully typed, no ternaries.

@export var debug_logs: bool = false

# Art
@export var bar_texture: Texture2D
@export var icon_aggressive: Texture2D
@export var icon_defensive: Texture2D
@export var icon_passive: Texture2D
@export var icon_support: Texture2D

# Layout (base art sizes before scale)
@export var base_bar_size: Vector2 = Vector2(64.0, 16.0)
@export var icon_size: Vector2 = Vector2(16.0, 16.0)
@export var icon_inset_px: float = 0.0  # set if your bar art has padding

# We scale the whole bar to 50% so icons become 8x8 and bar becomes 32x8.
@export var hud_scale: Vector2 = Vector2(0.5, 0.5)

# Optional: auto-align this bar above the main Hotbar control (sibling under HUDLayer).
@export var auto_align_to_hotbar: bool = true
@export var hotbar_path: NodePath = NodePath("../Hotbar")
@export var align_gap_px: float = 2.0

# Hotkeys
@export var require_shift_for_hotkeys: bool = true

# Visual
@export var unselected_alpha: float = 0.55
@export var selected_alpha: float = 1.0

# Internal nodes
var _bg: TextureRect
var _btns: Array[TextureButton] = []

# Cached target
var _summoner: Node
var _pets_comp: SummonedPetsComponent

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	_build_ui()
	scale = hud_scale

	_wire_party_signals()
	_refresh_binding()
	_refresh_visuals()

	if auto_align_to_hotbar:
		call_deferred("_align_to_hotbar")

func _unhandled_input(event: InputEvent) -> void:
	var evk: InputEventKey = event as InputEventKey
	if evk == null:
		return
	if not evk.pressed:
		return
	if evk.echo:
		return

	if require_shift_for_hotkeys and not evk.shift_pressed:
		return

	# Shift+1..4 selects modes
	if evk.keycode == KEY_1:
		_try_set_mode(SummonedPetsComponent.PetMode.AGGRESSIVE)
		get_viewport().set_input_as_handled()
	elif evk.keycode == KEY_2:
		_try_set_mode(SummonedPetsComponent.PetMode.DEFENSIVE)
		get_viewport().set_input_as_handled()
	elif evk.keycode == KEY_3:
		_try_set_mode(SummonedPetsComponent.PetMode.PASSIVE)
		get_viewport().set_input_as_handled()
	elif evk.keycode == KEY_4:
		_try_set_mode(SummonedPetsComponent.PetMode.SUPPORT)
		get_viewport().set_input_as_handled()

func _build_ui() -> void:
	# Background
	_bg = TextureRect.new()
	_bg.name = "BG"
	_bg.texture = bar_texture
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	custom_minimum_size = base_bar_size
	size = base_bar_size
	_bg.size = base_bar_size

	# 4 buttons, each 16x16 in the unscaled space.
	_btns.clear()
	_btns.append(_make_btn("AggressiveBtn", icon_aggressive, SummonedPetsComponent.PetMode.AGGRESSIVE))
	_btns.append(_make_btn("DefensiveBtn", icon_defensive, SummonedPetsComponent.PetMode.DEFENSIVE))
	_btns.append(_make_btn("PassiveBtn", icon_passive, SummonedPetsComponent.PetMode.PASSIVE))
	_btns.append(_make_btn("SupportBtn", icon_support, SummonedPetsComponent.PetMode.SUPPORT))

	_layout_buttons()

func _make_btn(node_name: String, icon: Texture2D, mode: int) -> TextureButton:
	var b: TextureButton = TextureButton.new()
	b.name = node_name
	b.texture_normal = icon
	b.texture_pressed = icon
	b.texture_hover = icon
	b.texture_disabled = icon
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.ignore_texture_size = true
	b.custom_minimum_size = icon_size
	b.size = icon_size
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(_on_mode_pressed.bind(mode))
	add_child(b)
	return b

func _layout_buttons() -> void:
	# Place buttons in a 4-wide row.
	# Unscaled: bar is 64 wide, icons are 16 wide. Perfect fit.
	var x: float = icon_inset_px
	var y: float = 0.0

	for i in range(_btns.size()):
		var b: TextureButton = _btns[i]
		b.position = Vector2(x, y)
		b.size = icon_size
		x += icon_size.x

func _wire_party_signals() -> void:
	# Party is the autoload PartyManager.
	if Party == null:
		return

	if Party.has_signal("controlled_changed"):
		if not Party.controlled_changed.is_connected(_on_party_controlled_changed):
			Party.controlled_changed.connect(_on_party_controlled_changed)

	if Party.has_signal("party_changed"):
		if not Party.party_changed.is_connected(_on_party_party_changed):
			Party.party_changed.connect(_on_party_party_changed)

func _on_party_controlled_changed(_controlled: Node) -> void:
	_refresh_binding()

func _on_party_party_changed() -> void:
	_refresh_binding()

func _refresh_binding() -> void:
	# Find the currently controlled actor (summoner candidate)
	_summoner = null
	_pets_comp = null

	if Party != null:
		if Party.has_method("get_controlled"):
			_summoner = Party.call("get_controlled")

	if _summoner == null:
		_set_visible_for_summoner(false)
		return

	_pets_comp = _find_pets_component(_summoner)
	if _pets_comp == null:
		_set_visible_for_summoner(false)
		return

	_set_visible_for_summoner(true)

	# Listen for mode changes to update highlights
	if not _pets_comp.pet_mode_changed.is_connected(_on_pet_mode_changed):
		_pets_comp.pet_mode_changed.connect(_on_pet_mode_changed)

	_refresh_visuals()

func _on_pet_mode_changed(_mode: int) -> void:
	_refresh_visuals()

func _set_visible_for_summoner(on: bool) -> void:
	visible = on
	set_process_unhandled_input(on)

func _refresh_visuals() -> void:
	if _pets_comp == null:
		_set_all_btn_alpha(unselected_alpha)
		return

	var mode: int = _pets_comp.get_pet_mode()
	for i in range(_btns.size()):
		var b: TextureButton = _btns[i]
		var b_mode: int = _mode_for_index(i)
		if b_mode == mode:
			b.modulate.a = selected_alpha
		else:
			b.modulate.a = unselected_alpha

func _set_all_btn_alpha(a: float) -> void:
	for b in _btns:
		b.modulate.a = a

func _mode_for_index(i: int) -> int:
	if i == 0:
		return SummonedPetsComponent.PetMode.AGGRESSIVE
	if i == 1:
		return SummonedPetsComponent.PetMode.DEFENSIVE
	if i == 2:
		return SummonedPetsComponent.PetMode.PASSIVE
	return SummonedPetsComponent.PetMode.SUPPORT

func _on_mode_pressed(mode: int) -> void:
	_try_set_mode(mode)

func _try_set_mode(mode: int) -> void:
	if _pets_comp == null:
		if debug_logs:
			print("[PetModeBar] No SummonedPetsComponent bound; ignoring mode set.")
		return

	_pets_comp.set_pet_mode(mode)
	_refresh_visuals()

func _find_pets_component(root: Node) -> SummonedPetsComponent:
	# Preferred: node named "SummonedPetsComponent"
	var direct: Node = root.get_node_or_null("SummonedPetsComponent")
	var direct_comp: SummonedPetsComponent = direct as SummonedPetsComponent
	if direct_comp != null:
		return direct_comp

	# Fallback: BFS search for SummonedPetsComponent class
	var q: Array[Node] = [root]
	while q.size() > 0:
		var cur: Node = q.pop_front()
		var as_comp: SummonedPetsComponent = cur as SummonedPetsComponent
		if as_comp != null:
			return as_comp
		for c in cur.get_children():
			q.push_back(c)

	return null

func _align_to_hotbar() -> void:
	var hb: Control = get_node_or_null(hotbar_path) as Control
	if hb == null:
		if debug_logs:
			print("[PetModeBar] Hotbar not found at path: ", hotbar_path)
		return

	# We assume both are anchored top-left style (like your Hotbar in Main.tscn).
	# Position this bar centered above the hotbar.
	var bar_w: float = base_bar_size.x * hud_scale.x
	var bar_h: float = base_bar_size.y * hud_scale.y

	var x: float = hb.position.x + (hb.size.x - bar_w) * 0.5
	var y: float = hb.position.y - bar_h - align_gap_px

	position = Vector2(x, y)
