extends Node
class_name AudioSystem
# Godot 4.5 — fully typed, no ternaries.
# Central audio controller for SFX + Music + tile-based footsteps.

# --- Debug --------------------------------------------------------------------
@export var debug_log: bool = false

# --- Bus names (must match your Audio buses in Project Settings) -------------
@export var sfx_bus_name: StringName = &"SFX"
@export var music_bus_name: StringName = &"Music"
@export var ui_bus_name: StringName = &"UI"

# --- UI SFX defaults ----------------------------------------------------------
@export_group("UI SFX")
@export var ui_confirm_event: StringName = &"UI_click"
@export var ui_cancel_event: StringName = &"UI_deny"
@export var ui_confirm_volume_db: float = 0.0
@export var ui_cancel_volume_db: float = 0.0
@export var ui_preload_on_ready: bool = true

# --- Footstep configuration ---------------------------------------------------
@export_group("Footsteps")
# This is now only a spare config; we do NOT fall back to this automatically.
@export var default_footstep_event: StringName = StringName("")
@export var footstep_custom_data_key: String = "footstep"

# Base directory for footstep SFX. We will look for:
#   - "<base>/TAG/*.wav/.ogg/.mp3" if a TAG subfolder exists
#   - "<base>/TAG*.wav/.ogg/.mp3" in the base folder if no TAG subfolder
@export var base_footstep_sfx_dir: String = "res://assets/audio/sfx"

# Optional explicit overrides: tag -> event name.
# These just determine the event name; they still require audio files to exist.
@export var footstep_event_map: Dictionary = {
	"grass": StringName("footstep_grass"),
	"wood": StringName("footstep_wood"),
	"stone": StringName("footstep_stone"),
	"dirt": StringName("footstep_dirt"),
	"snow": StringName("footstep_snow"),
	"sand": StringName("footstep_sand"),
	"shallow": StringName("footstep_shallow"),
}

# --- Music auto-discovery -----------------------------------------------------
@export_group("Music")
# Base directory for BGM auto-discovery.
# We will look for:
#  - "<base>/<event>.ogg/.wav/.mp3" if event includes extension
#  - "<base>/<event>/" folder (any .ogg/.wav/.mp3 inside)
#  - "<base>/<event>*.(ogg/wav/mp3)" prefix match in base folder
@export var base_music_dir: String = "res://assets/audio/music"

var _footstep_layer: TileMapLayer = null

# --- Internal storage ---------------------------------------------------------
# Event name -> Array[AudioStream] (we randomly pick one when playing)
var _sfx_events: Dictionary = {}
# Music event name -> AudioStream
var _music_events: Dictionary = {}

# Music player (non-positional)
var _music_player: AudioStreamPlayer = null
var _current_music_event: StringName = StringName("")
var _target_music_volume_db: float = 0.0
var _music_fade_speed_db_per_sec: float = 0.0
var _music_fading: bool = false

# --- Lifecycle ----------------------------------------------------------------

func _ready() -> void:
	_init_music_player()
	_register_default_events()

func _process(delta: float) -> void:
	if _music_fading and _music_player != null:
		_update_music_fade(delta)

# --- Init helpers -------------------------------------------------------------

func _init_music_player() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "MusicPlayer"
	_music_player.bus = String(music_bus_name)
	add_child(_music_player)

func _register_default_events() -> void:
	# We keep footsteps fully on-demand.
	# UI confirm/cancel SFX can be preloaded to avoid the first-click load hitch.
	if ui_preload_on_ready:
		_preload_ui_default_events()

func _preload_ui_default_events() -> void:
	if ui_confirm_event != StringName(""):
		if not _sfx_events.has(ui_confirm_event):
			_auto_register_generic_sfx_event(ui_confirm_event)

	if ui_cancel_event != StringName(""):
		if not _sfx_events.has(ui_cancel_event):
			_auto_register_generic_sfx_event(ui_cancel_event)

	if debug_log:
		print("[AudioSys] UI defaults preload complete. confirm=", ui_confirm_event, " cancel=", ui_cancel_event)

# --- Convenience UI API -------------------------------------------------------

func play_ui_confirm(volume_db: float = 0.0) -> void:
	var v: float = volume_db
	if v == 0.0:
		v = ui_confirm_volume_db
	play_ui_sfx(ui_confirm_event, v)

func play_ui_cancel(volume_db: float = 0.0) -> void:
	var v: float = volume_db
	if v == 0.0:
		v = ui_cancel_volume_db
	play_ui_sfx(ui_cancel_event, v)

# Alias names (sometimes nicer to read at call sites)
func play_ui_accept(volume_db: float = 0.0) -> void:
	play_ui_confirm(volume_db)

func play_ui_deny(volume_db: float = 0.0) -> void:
	play_ui_cancel(volume_db)

# --- Footstep API -------------------------------------------------------------

func register_footstep_layer(layer: TileMapLayer) -> void:
	# Called by an Area to tell AudioSys which TileMapLayer is the "ground".
	_footstep_layer = layer
	if debug_log:
		if layer != null:
			print("[AudioSys] Footstep layer registered: ", layer.name)
		else:
			print("[AudioSys] Footstep layer cleared")

func get_footstep_event_for_tag(tag: String) -> StringName:
	# Convert a footstep tag (e.g. "wood") into an event name (e.g. "footstep_wood")
	# and auto-register streams for it if possible.
	if tag == "":
		return StringName("")

	var key: String = tag.to_lower()
	var event_name: StringName = StringName("")

	# First, see if we have an explicit mapping from tag -> event name.
	if footstep_event_map.has(key):
		var v: Variant = footstep_event_map.get(key, StringName(""))
		if v is StringName:
			event_name = v
		elif v is String:
			event_name = StringName(String(v))
	else:
		# No explicit mapping: build an event name like "footstep_wood".
		event_name = StringName("footstep_%s" % key)

	# If we still somehow ended up empty, bail out.
	if String(event_name) == "":
		return StringName("")

	# Ensure we have streams for this event; if we can auto-load them, register.
	if not _sfx_events.has(event_name):
		_auto_register_footstep_event(event_name, key)

	# If we successfully registered something, return the event name;
	# otherwise, no sound.
	if _sfx_events.has(event_name):
		return event_name

	return StringName("")

func get_footstep_event_at(world_position: Vector2) -> StringName:
	# Look up the tile beneath world_position on the registered ground layer
	# and map its "footstep" custom data to an SFX event. Returns empty if
	# nothing is tagged or no audio exists.
	if _footstep_layer == null:
		return StringName("")

	var local_pos: Vector2 = _footstep_layer.to_local(world_position)
	var cell: Vector2i = _footstep_layer.local_to_map(local_pos)
	var td: TileData = _footstep_layer.get_cell_tile_data(cell)
	if td == null:
		return StringName("")

	if not td.has_custom_data(footstep_custom_data_key):
		return StringName("")

	var v: Variant = td.get_custom_data(footstep_custom_data_key)
	var tag: String = ""
	var t: int = typeof(v)

	if t == TYPE_STRING:
		tag = String(v)
	elif t == TYPE_STRING_NAME:
		tag = String(StringName(v))
	elif t == TYPE_INT:
		tag = str(int(v))
	elif t == TYPE_BOOL:
		if bool(v):
			tag = "true"

	if tag == "":
		return StringName("")

	return get_footstep_event_for_tag(tag)

# --- Footstep auto-registration -----------------------------------------------

func _auto_register_footstep_event(event_name: StringName, tag_key: String) -> void:
	var streams: Array[AudioStream] = []

	if base_footstep_sfx_dir == "":
		if debug_log:
			print("[AudioSys] No base_footstep_sfx_dir set; cannot auto-register ", event_name)
		return

	var tag_folder: String = _join_path(base_footstep_sfx_dir, tag_key)

	# NOTE: res:// paths are not "absolute OS paths"; detect existence by opening.
	var tag_dir: DirAccess = DirAccess.open(tag_folder)
	if tag_dir != null:
		_collect_streams_from_dir(tag_folder, tag_key, streams, true)
	else:
		_collect_streams_from_dir(base_footstep_sfx_dir, tag_key, streams, false)

	if streams.is_empty():
		if debug_log:
			print("[AudioSys] No streams found for tag=", tag_key, " event=", event_name)
		return

	register_sfx_event(event_name, streams)

	if debug_log:
		print("[AudioSys] Auto-registered footstep event ", event_name, " with ", streams.size(), " stream(s) for tag=", tag_key)

func _collect_streams_from_dir(dir_path: String, tag_key: String, out_streams: Array[AudioStream], is_tag_folder: bool) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		if debug_log:
			print("[AudioSys] DirAccess.open failed for ", dir_path)
		return

	var lower_tag: String = tag_key.to_lower()

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break

		if name.begins_with("."):
			continue

		var is_dir: bool = dir.current_is_dir()
		if is_dir:
			continue

		var lower_name: String = name.to_lower()

		# If scanning the BASE folder, require TAG prefix (TAG*.ogg).
		# If scanning the TAG folder, accept any audio filename.
		if not is_tag_folder:
			if not lower_name.begins_with(lower_tag):
				continue

		if not (lower_name.ends_with(".wav") or lower_name.ends_with(".ogg") or lower_name.ends_with(".mp3")):
			continue

		var full_path: String = _join_path(dir_path, name)
		var stream: AudioStream = _try_load_audio_stream(full_path)
		if stream != null:
			out_streams.append(stream)

	dir.list_dir_end()

func _try_load_audio_stream(path: String) -> AudioStream:
	if path == "":
		return null

	if not ResourceLoader.exists(path):
		if debug_log:
			print("[AudioSys] Audio resource does not exist: ", path)
		return null

	var res: Resource = ResourceLoader.load(path)
	if res == null:
		if debug_log:
			print("[AudioSys] Failed to load audio resource: ", path)
		return null

	var stream: AudioStream = res as AudioStream
	if stream == null:
		if debug_log:
			print("[AudioSys] Not an AudioStream: ", path)
		return null

	return stream

# --- Public SFX API -----------------------------------------------------------

func register_sfx_event(event: StringName, streams: Array[AudioStream]) -> void:
	# Replaces any existing mapping for this event.
	_sfx_events[event] = streams.duplicate()
	if debug_log:
		print("[AudioSys] Registered SFX event: ", event, " (", streams.size(), " streams)")

func has_sfx_event(event: StringName) -> bool:
	return _sfx_events.has(event)

func unregister_sfx_event(event: StringName) -> void:
	if _sfx_events.has(event):
		_sfx_events.erase(event)
		if debug_log:
			print("[AudioSys] Unregistered SFX event: ", event)

func play_sfx_event(
	event: StringName,
	world_position: Vector2 = Vector2.INF,
	volume_db: float = -20.0
) -> void:
	if event == StringName(""):
		return

	# Auto-discover generic SFX by event name (used by AbilityDef.sfx_event).
	# Looks in res://assets/audio/sfx/ by default (base_footstep_sfx_dir).
	if not _sfx_events.has(event):
		_auto_register_generic_sfx_event(event)

	if not _sfx_events.has(event):
		if debug_log:
			print("[AudioSys] Unknown SFX event (and no files found): ", event)
		return

	var stream: AudioStream = _pick_sfx_stream(event)
	if stream == null:
		if debug_log:
			print("[AudioSys] SFX event has no usable streams: ", event)
		return

	var has_position: bool = not (world_position == Vector2.INF)
	if has_position:
		_play_sfx_at_position(stream, world_position, volume_db)
	else:
		_play_sfx_global(stream, volume_db)

func play_ui_sfx(
	event: StringName,
	volume_db: float = 0.0
) -> void:
	# UI sounds should use the UI bus.
	if event == StringName(""):
		return

	if not _sfx_events.has(event):
		_auto_register_generic_sfx_event(event)

	if not _sfx_events.has(event):
		if debug_log:
			print("[AudioSys] Unknown UI SFX event (and no files found): ", event)
		return

	var stream: AudioStream = _pick_sfx_stream(event)
	if stream == null:
		if debug_log:
			print("[AudioSys] UI SFX event has no usable streams: ", event)
		return

	_play_ui_global(stream, volume_db)

# --- SFX internals ------------------------------------------------------------

func _pick_sfx_stream(event: StringName) -> AudioStream:
	var streams_variant: Variant = _sfx_events.get(event, null)
	if streams_variant == null:
		return null

	if typeof(streams_variant) != TYPE_ARRAY:
		return null

	var streams: Array = streams_variant
	if streams.is_empty():
		return null

	if streams.size() == 1:
		var only_stream: Variant = streams[0]
		if only_stream is AudioStream:
			return only_stream
		return null

	var random_index: int = randi() % streams.size()
	var picked: Variant = streams[random_index]
	if picked is AudioStream:
		return picked

	return null

func _play_sfx_global(stream: AudioStream, volume_db: float) -> void:
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.stream = stream
	p.bus = String(sfx_bus_name)
	p.volume_db = volume_db
	p.autoplay = false
	p.finished.connect(Callable(p, "queue_free"))
	add_child(p)
	p.play()

func _play_ui_global(stream: AudioStream, volume_db: float) -> void:
	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.stream = stream
	p.bus = String(ui_bus_name)
	p.volume_db = volume_db
	p.autoplay = false
	p.finished.connect(Callable(p, "queue_free"))
	add_child(p)
	p.play()

func _play_sfx_at_position(stream: AudioStream, world_position: Vector2, volume_db: float) -> void:
	# 2D positional variant; can be used for footsteps, abilities, etc.
	var p2d: AudioStreamPlayer2D = AudioStreamPlayer2D.new()
	p2d.stream = stream
	p2d.bus = String(sfx_bus_name)
	p2d.volume_db = volume_db
	p2d.global_position = world_position
	p2d.autoplay = false
	p2d.finished.connect(Callable(p2d, "queue_free"))
	add_child(p2d)
	p2d.play()

# --- Generic SFX auto-registration (AbilityDef.sfx_event) ---------------------

func _auto_register_generic_sfx_event(event: StringName) -> void:
	# Uses the event string as a "file hint":
	#  - If it ends with .wav/.ogg/.mp3: loads that exact file in base dir
	#  - Else:
	#      1) loads all audio files in "<base>/<event>/" if that folder exists
	#      2) else loads "<base>/<event>*.(wav/ogg/mp3)" from base
	var hint: String = String(event)
	if hint == "":
		return

	if base_footstep_sfx_dir == "":
		if debug_log:
			print("[AudioSys] No base SFX dir set; cannot auto-register ", event)
		return

	var streams: Array[AudioStream] = []

	var lower_hint: String = hint.to_lower()
	var has_ext: bool = false
	if lower_hint.ends_with(".wav") or lower_hint.ends_with(".ogg") or lower_hint.ends_with(".mp3"):
		has_ext = true

	if has_ext:
		# Exact file name inside base dir
		var full_path: String = _join_path(base_footstep_sfx_dir, hint)
		var stream_one: AudioStream = _try_load_audio_stream(full_path)
		if stream_one != null:
			streams.append(stream_one)
	else:
		# 1) Prefer folder "<base>/<hint>/"
		var folder_path: String = _join_path(base_footstep_sfx_dir, hint)
		var folder_dir: DirAccess = DirAccess.open(folder_path)
		if folder_dir != null:
			_collect_any_audio_from_dir(folder_path, streams)
		else:
			# 2) Fallback to "<base>/<hint>*.(ext)" in base folder
			_collect_prefixed_audio_from_dir(base_footstep_sfx_dir, hint, streams)

	if streams.is_empty():
		return

	register_sfx_event(event, streams)

	if debug_log:
		print("[AudioSys] Auto-registered generic SFX event ", event, " with ", streams.size(), " stream(s)")

func _collect_any_audio_from_dir(dir_path: String, out_streams: Array[AudioStream]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		if debug_log:
			print("[AudioSys] DirAccess.open failed for ", dir_path)
		return

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break

		if name.begins_with("."):
			continue

		if dir.current_is_dir():
			continue

		var lower_name: String = name.to_lower()
		if not (lower_name.ends_with(".wav") or lower_name.ends_with(".ogg") or lower_name.ends_with(".mp3")):
			continue

		var full_path: String = _join_path(dir_path, name)
		var stream: AudioStream = _try_load_audio_stream(full_path)
		if stream != null:
			out_streams.append(stream)

	dir.list_dir_end()

func _collect_prefixed_audio_from_dir(dir_path: String, prefix: String, out_streams: Array[AudioStream]) -> void:
	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		if debug_log:
			print("[AudioSys] DirAccess.open failed for ", dir_path)
		return

	var lower_prefix: String = prefix.to_lower()

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break

		if name.begins_with("."):
			continue

		if dir.current_is_dir():
			continue

		var lower_name: String = name.to_lower()
		if not lower_name.begins_with(lower_prefix):
			continue

		if not (lower_name.ends_with(".wav") or lower_name.ends_with(".ogg") or lower_name.ends_with(".mp3")):
			continue

		var full_path: String = _join_path(dir_path, name)
		var stream: AudioStream = _try_load_audio_stream(full_path)
		if stream != null:
			out_streams.append(stream)

	dir.list_dir_end()

# --- Public Music API ---------------------------------------------------------

func register_music_event(event: StringName, stream: AudioStream) -> void:
	_music_events[event] = stream
	if debug_log:
		print("[AudioSys] Registered Music event: ", event)

func has_music_event(event: StringName) -> bool:
	return _music_events.has(event)

func resolve_music_stream(event: StringName) -> AudioStream:
	# Returns an AudioStream if this event is registered or discoverable from base_music_dir.
	if event == StringName(""):
		return null

	if _music_events.has(event):
		var v: Variant = _music_events.get(event, null)
		if v is AudioStream:
			return v
		return null

	var ok: bool = register_music_event_auto(event)
	if not ok:
		return null

	var v2: Variant = _music_events.get(event, null)
	if v2 is AudioStream:
		return v2

	return null

func register_music_event_auto(event: StringName) -> bool:
	# Auto-discovers and registers a music event by name in base_music_dir.
	# Behavior mirrors SFX auto-discovery, but registers ONE stream per event.
	if event == StringName(""):
		return false

	if _music_events.has(event):
		return true

	var stream: AudioStream = _auto_discover_music_stream(event)
	if stream == null:
		return false

	register_music_event(event, stream)
	return true

func play_music(
	event: StringName,
	fade_time_sec: float = 0.5,
	target_volume_db: float = 0.0
) -> void:
	if _music_player == null:
		return

	# KEY FIX:
	# If we are fading OUT the current track and we re-request the same track (re-enter area fast),
	# reverse the fade instead of returning early.
	if event == _current_music_event and _music_player.playing:
		if _music_fading:
			if _music_fade_speed_db_per_sec < 0.0:
				if fade_time_sec <= 0.0:
					_music_player.volume_db = target_volume_db
					_target_music_volume_db = target_volume_db
					_music_fading = false
				else:
					_target_music_volume_db = target_volume_db
					_music_fade_speed_db_per_sec = (target_volume_db - _music_player.volume_db) / fade_time_sec
					_music_fading = true
				return
		return

	# NEW: auto-register by event name if missing.
	if not _music_events.has(event):
		var ok: bool = register_music_event_auto(event)
		if not ok:
			if debug_log:
				print("[AudioSys] Unknown Music event (and no files found): ", event)
			return

	var new_stream_variant: Variant = _music_events.get(event, null)
	if not (new_stream_variant is AudioStream):
		if debug_log:
			print("[AudioSys] Music event stream not AudioStream: ", event)
		return

	_current_music_event = event

	if fade_time_sec <= 0.0:
		_music_player.stream = new_stream_variant
		_music_player.volume_db = target_volume_db
		_music_player.play()
		_music_fading = false
		return

	# Fade in new track from low volume.
	_music_player.stream = new_stream_variant
	_music_player.volume_db = -40.0
	_music_player.play()

	_target_music_volume_db = target_volume_db
	_music_fade_speed_db_per_sec = (target_volume_db - _music_player.volume_db) / fade_time_sec
	_music_fading = true

func stop_music(fade_time_sec: float = 0.5) -> void:
	if _music_player == null:
		return

	if not _music_player.playing:
		return

	if fade_time_sec <= 0.0:
		_music_player.stop()
		_music_fading = false
		return

	_target_music_volume_db = -40.0
	_music_fade_speed_db_per_sec = (_target_music_volume_db - _music_player.volume_db) / fade_time_sec
	_music_fading = true

# --- Music auto-discovery internals ------------------------------------------

func _auto_discover_music_stream(event: StringName) -> AudioStream:
	if base_music_dir == "":
		if debug_log:
			print("[AudioSys] No base_music_dir set; cannot auto-discover ", event)
		return null

	var hint: String = String(event)
	if hint == "":
		return null

	var lower_hint: String = hint.to_lower()
	var has_ext: bool = false
	if lower_hint.ends_with(".wav") or lower_hint.ends_with(".ogg") or lower_hint.ends_with(".mp3"):
		has_ext = true

	# Gather candidates; for music we register ONE stream (first found).
	var candidates: Array[AudioStream] = []

	if has_ext:
		var full_path: String = _join_path(base_music_dir, hint)
		var s_one: AudioStream = _try_load_audio_stream(full_path)
		if s_one != null:
			return s_one
		return null

	# 1) Prefer folder "<base>/<hint>/"
	var folder_path: String = _join_path(base_music_dir, hint)
	var folder_dir: DirAccess = DirAccess.open(folder_path)
	if folder_dir != null:
		_collect_any_audio_from_dir(folder_path, candidates)
	else:
		# 2) Fallback to "<base>/<hint>*.(ext)" in base folder
		_collect_prefixed_audio_from_dir(base_music_dir, hint, candidates)

	if candidates.is_empty():
		if debug_log:
			print("[AudioSys] No music files found for event=", event, " in ", base_music_dir)
		return null

	# If multiple candidates exist, just take the first.
	# (If you ever want random music variants per event, we can expand later.)
	return candidates[0]

# --- Music internals ----------------------------------------------------------

func _update_music_fade(delta: float) -> void:
	if _music_player == null:
		_music_fading = false
		return

	var new_volume: float = _music_player.volume_db + _music_fade_speed_db_per_sec * delta

	var done_fading: bool = false
	if _music_fade_speed_db_per_sec >= 0.0:
		if new_volume >= _target_music_volume_db:
			new_volume = _target_music_volume_db
			done_fading = true
	else:
		if new_volume <= _target_music_volume_db:
			new_volume = _target_music_volume_db
			done_fading = true

	_music_player.volume_db = new_volume

	if done_fading:
		_music_fading = false
		if _music_player.volume_db <= -39.0:
			_music_player.stop()

# --- Utility ------------------------------------------------------------------

func _join_path(a: String, b: String) -> String:
	if a.ends_with("/"):
		return a + b
	return a + "/" + b
