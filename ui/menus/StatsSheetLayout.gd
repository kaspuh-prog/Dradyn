extends Control
class_name StatsSheetLayout

# --- Tab / safe area (reference) ---
const TAB_SIZE: Vector2i = Vector2i(256, 224)
const SAFE_ORIGIN: Vector2i = Vector2i(16, 16)
const HEADER_H: int = 24

# --- Left-column rows base ---
const KEYS: Array[String] = ["STR","DEX","STA","INT","WIS","LCK"]

const ROW_Y_START_BASE: int = 62
const ROW_H: int = 16
const ROW_GAP: int = 4
const MINUS_X_BASE: int = 16
const VALUE_X_BASE: int = 36
const PLUS_X_BASE:  int = 64
const LABEL_X_BASE: int = 86

# Points label (renders "Points: N")
const POINTS_POS_BASE: Vector2i = Vector2i(24, 40)
const POINTS_SIZE: Vector2i = Vector2i(96, 16)

# --- Header base rects ---
const NAME_POS_BASE: Vector2i  = Vector2i(16, 16)
const NAME_SIZE: Vector2i      = Vector2i(96, 16)

const LEVEL_POS_BASE: Vector2i = Vector2i(120, 16)
const LEVEL_SIZE: Vector2i     = Vector2i(96, 16)  # fits "Level: 99"

const CLASS_POS_BASE: Vector2i = Vector2i(160, 16)
const CLASS_SIZE: Vector2i     = Vector2i(80, 16)

# --- Your confirmed nudges (final) ---
@export var left_nudge_x: int = 0
@export var left_nudge_y: int = -36

@export var name_nudge_x: int = 0
@export var name_nudge_y: int = -22

@export var level_nudge_x: int = -104
@export var level_nudge_y: int = -10

@export var class_nudge_x: int = -144
@export var class_nudge_y: int = -16

@export var points_nudge_x: int = 8
@export var points_nudge_y: int = -24

func _ready() -> void:
	# Header (with per-label nudges)
	_norm_and_place("NameLabel",
		Vector2i(NAME_POS_BASE.x + name_nudge_x, NAME_POS_BASE.y + name_nudge_y),
		NAME_SIZE)

	_norm_and_place("LevelLabel",
		Vector2i(LEVEL_POS_BASE.x + level_nudge_x, LEVEL_POS_BASE.y + level_nudge_y),
		LEVEL_SIZE)

	_norm_and_place("ClassLabel",
		Vector2i(CLASS_POS_BASE.x + class_nudge_x, CLASS_POS_BASE.y + class_nudge_y),
		CLASS_SIZE)

	# Points (independent)
	_norm_and_place("PointsLabel",
		Vector2i(POINTS_POS_BASE.x + points_nudge_x, POINTS_POS_BASE.y + points_nudge_y),
		POINTS_SIZE)

	# Stat rows (follow left-column nudges)
	var y: int = ROW_Y_START_BASE + left_nudge_y
	for key in KEYS:
		_norm_and_place("Minus_" + key, Vector2i(MINUS_X_BASE + left_nudge_x, y), Vector2i(16, 16))
		_norm_and_place("Value_" + key, Vector2i(VALUE_X_BASE + left_nudge_x, y), Vector2i(24, 16))
		_norm_and_place("Plus_"  + key, Vector2i(PLUS_X_BASE  + left_nudge_x, y), Vector2i(16, 16))
		_norm_and_place("Label_" + key, Vector2i(LABEL_X_BASE + left_nudge_x, y), Vector2i(34, 16))
		y += ROW_H + ROW_GAP

	# Keep the bronze background behind labels
	var bg: Control = _get_ctrl("RightPanelBg")
	if bg != null:
		bg.z_index = -10

# --- helpers ---

func _get_ctrl(name: String) -> Control:
	var n: Node = get_node_or_null(name)
	if n == null:
		return null
	if n is Control:
		return n
	return null

func _norm_and_place(name: String, pos: Vector2i, size_px: Vector2i) -> void:
	var c: Control = _get_ctrl(name)
	if c == null:
		return

	# Absolute placement (preserve your tuned pixel layout)
	c.anchor_left = 0.0
	c.anchor_top = 0.0
	c.anchor_right = 0.0
	c.anchor_bottom = 0.0
	c.size_flags_horizontal = 0
	c.size_flags_vertical = 0
	c.position = Vector2(pos.x, pos.y)
	c.custom_minimum_size = Vector2(size_px.x, size_px.y)
	c.size = c.custom_minimum_size
	c.z_index = 0

	# CRITICAL: Buttons must receive mouse; labels/decor can ignore.
	if c is BaseButton:
		var b: BaseButton = c as BaseButton
		b.mouse_filter = Control.MOUSE_FILTER_STOP
		b.focus_mode = Control.FOCUS_ALL
	else:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
