extends Control
class_name PartyBarsPanel

@export var texture_frame: Texture2D
@export var texture_under: Texture2D          # BarNoFill.png (256×32)
@export var texture_hp_fill: Texture2D        # FilledHP.png  (256×32)
@export var texture_mp_fill: Texture2D        # FilledMP.png  (256×32)
@export var texture_end_fill: Texture2D       # FilledEND.png (256×32)

const PANEL_SIZE: Vector2i = Vector2i(256, 128)

# Transparent window tops inside frame (from your 3bars.png):
const HOLE_TOP_HP: int = 24
const HOLE_TOP_MP: int = 56
const HOLE_TOP_END: int = 88

# Drawn portion inside each 32px bar starts at row 8 (rows 8..26 are non-transparent)
const BAR_DRAW_TOP_IN_SPRITE: int = 8

# Computed placement: bar sprite top = hole_top - drawn_top
const HP_Y: int = HOLE_TOP_HP - BAR_DRAW_TOP_IN_SPRITE    # 16
const MP_Y: int = HOLE_TOP_MP - BAR_DRAW_TOP_IN_SPRITE    # 48
const END_Y: int = HOLE_TOP_END - BAR_DRAW_TOP_IN_SPRITE  # 80

@onready var _bars_root: Control = $"Bars"
@onready var _hp: TextureProgressBar = $"Bars/HpBar"
@onready var _mp: TextureProgressBar = $"Bars/MpBar"
@onready var _end: TextureProgressBar = $"Bars/EndBar"
@onready var _frame: TextureRect = $"Frame"

func _ready() -> void:
	_setup_root()
	_setup_frame()
	_setup_bars_container()
	_setup_bar_exact(_hp, HP_Y, texture_hp_fill)
	_setup_bar_exact(_mp, MP_Y, texture_mp_fill)
	_setup_bar_exact(_end, END_Y, texture_end_fill)

func _setup_root() -> void:
	anchors_preset = Control.PRESET_TOP_LEFT
	set_deferred("custom_minimum_size", Vector2(PANEL_SIZE))
	size = Vector2(PANEL_SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_as_relative = false
	z_index = 0

func _setup_frame() -> void:
	_frame.texture = texture_frame
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.anchors_preset = Control.PRESET_TOP_LEFT
	_frame.position = Vector2(0, 0)
	_frame.size = Vector2(PANEL_SIZE)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.z_as_relative = false
	_frame.z_index = 10  # frame on top

func _setup_bars_container() -> void:
	_bars_root.anchors_preset = Control.PRESET_TOP_LEFT
	_bars_root.position = Vector2(0, 0)
	_bars_root.size = Vector2(PANEL_SIZE)
	_bars_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars_root.z_as_relative = false
	_bars_root.z_index = 0

func _setup_bar_exact(bar: TextureProgressBar, top_y: int, fill_tex: Texture2D) -> void:
	if bar == null:
		return
	# Exact sprite size: 256×32; no scaling, no 9-patch.
	var sprite_w: int = 256
	var sprite_h: int = 32
	if texture_under != null:
		sprite_w = texture_under.get_width()
		sprite_h = texture_under.get_height()

	bar.anchors_preset = Control.PRESET_TOP_LEFT
	bar.position = Vector2(0, top_y)       # x=0 so it spans the panel width exactly
	bar.size = Vector2(sprite_w, sprite_h) # exact size; no stretch

	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 100.0
	bar.step = 1.0
	bar.fill_mode = TextureProgressBar.FILL_LEFT_TO_RIGHT

	bar.texture_under = texture_under
	bar.texture_progress = fill_tex

	bar.nine_patch_stretch = false         # important: keep pixels 1:1
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.z_as_relative = false
	bar.z_index = 0
