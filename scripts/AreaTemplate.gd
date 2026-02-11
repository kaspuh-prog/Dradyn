extends Node2D
class_name AreaTemplate

@export var tileset: TileSet

@export_group("Audio / BGM")
# If set, this area will register bgm_stream under bgm_event and play it on _ready().
@export var bgm_event: StringName = StringName("")
@export var bgm_stream: AudioStream
@export var bgm_volume_db: float = -6.0
@export var bgm_fade_in_sec: float = 1.0
@export var bgm_stop_on_exit: bool = true
@export var bgm_fade_out_sec: float = 1.0

@onready var _l0_ground: TileMapLayer = $L0_Ground
@onready var _l1_details: TileMapLayer = $L1_Details
@onready var _l2_colliders: TileMapLayer = $L2_Colliders
@onready var _l3_overhangs: TileMapLayer = $L3_Overhangs

const Z_GROUND: int = -10
const Z_DETAILS: int = -3
const Z_COLLIDERS_ABSOLUTE: int = -4
const Z_OVERHANGS: int = 10

func _ready() -> void:
	_apply_tileset_to_layers()
	_apply_z_order_defaults()
	_apply_audio_bindings()
	_apply_bgm_on_ready()

func _exit_tree() -> void:
	_apply_bgm_on_exit()

func _apply_tileset_to_layers() -> void:
	if tileset == null:
		return

	_l0_ground.tile_set = tileset
	_l1_details.tile_set = tileset
	_l2_colliders.tile_set = tileset
	_l3_overhangs.tile_set = tileset

func _apply_z_order_defaults() -> void:
	# Ground and Details use normal relative z.
	_l0_ground.z_as_relative = true
	_l0_ground.z_index = Z_GROUND

	_l1_details.z_as_relative = true
	_l1_details.z_index = Z_DETAILS

	# Colliders become an absolute back-plane: ignore any per-tile z,
	# and use a very low absolute z so actors (0/1) always render above.
	_l2_colliders.z_as_relative = false
	_l2_colliders.z_index = Z_COLLIDERS_ABSOLUTE

	# Overhangs on top (relative is fine here).
	_l3_overhangs.z_as_relative = true
	_l3_overhangs.z_index = Z_OVERHANGS

func _apply_audio_bindings() -> void:
	# Tell the AudioSys autoload which layer is the ground layer for footsteps.
	if _l0_ground == null:
		return

	# Autoload singleton is named "AudioSys".
	var audio_sys: AudioSystem = AudioSys
	if audio_sys == null:
		return

	audio_sys.register_footstep_layer(_l0_ground)

func _apply_bgm_on_ready() -> void:
	if bgm_event == StringName(""):
		return

	var audio_sys: AudioSystem = AudioSys
	if audio_sys == null:
		return

	# If a stream was provided in the inspector, register it explicitly.
	# (If bgm_stream is null, AudioSys will still try to auto-discover by event name.)
	if bgm_stream != null:
		audio_sys.register_music_event(bgm_event, bgm_stream)

	audio_sys.play_music(bgm_event, bgm_fade_in_sec, bgm_volume_db)

func _apply_bgm_on_exit() -> void:
	if not bgm_stop_on_exit:
		return
	if bgm_event == StringName(""):
		return

	var audio_sys: AudioSystem = AudioSys
	if audio_sys == null:
		return

	audio_sys.stop_music(bgm_fade_out_sec)
