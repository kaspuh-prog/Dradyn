extends Resource
class_name AbilitySfxCue
# Godot 4.5 — fully typed, no ternaries.
# Authoring data for AbilityDef SFX timing.
#
# "event" is authored as a NAME, resolved under:
#   res://assets/audio/sfx/
# Accepted extensions: .ogg, .wav, .mp3
#
# Examples:
#   event = "quickslash"              -> res://assets/audio/sfx/quickslash.wav (or .mp3/.ogg)
#   event = "grass/grass_footstep1"   -> res://assets/audio/sfx/grass/grass_footstep1.wav
#   event = "res://assets/audio/sfx/parry1.mp3" (full path)

const SFX_BASE_DIR: String = "res://assets/audio/sfx"
const ALLOWED_EXTS: Array[String] = [".ogg", ".wav", ".mp3"]

@export var event: StringName = &""
@export var frame: int = 0
@export var volume_db: float = -20.0
@export var play_once: bool = true

var _cached_key: String = ""
var _cached_path: String = ""
var _cached_stream: AudioStream = null


func resolve_sfx_path() -> String:
	var key: String = String(event).strip_edges()
	if key.is_empty():
		return ""

	# Full resource path authored directly.
	if key.begins_with("res://"):
		if ResourceLoader.exists(key):
			return key
		return ""

	# If the author included an extension, try it directly under the base dir.
	if _has_any_allowed_ext(key):
		var direct_path: String = _join_under_base(key)
		if ResourceLoader.exists(direct_path):
			return direct_path

	# Try <name> + allowed extension(s) under base dir.
	var i: int = 0
	while i < ALLOWED_EXTS.size():
		var ext: String = ALLOWED_EXTS[i]
		var candidate: String = _join_under_base(key + ext)
		if ResourceLoader.exists(candidate):
			return candidate
		i += 1

	# Fallback: case-insensitive scan of the directory (and optional subdir).
	return _scan_case_insensitive(key)


func resolve_stream() -> AudioStream:
	var key: String = String(event).strip_edges()
	if key.is_empty():
		return null

	if key == _cached_key and _cached_stream != null:
		return _cached_stream

	var path: String = resolve_sfx_path()
	if path.is_empty():
		_cached_key = key
		_cached_path = ""
		_cached_stream = null
		return null

	var res: Resource = load(path)
	var stream: AudioStream = null
	if res is AudioStream:
		stream = res as AudioStream

	_cached_key = key
	_cached_path = path
	_cached_stream = stream
	return stream


func _join_under_base(rel: String) -> String:
	var cleaned: String = rel.strip_edges()
	if cleaned.begins_with("/"):
		cleaned = cleaned.substr(1, cleaned.length() - 1)
	if cleaned.is_empty():
		return SFX_BASE_DIR
	return SFX_BASE_DIR.path_join(cleaned)


func _has_any_allowed_ext(name_or_path: String) -> bool:
	var s: String = name_or_path.to_lower()
	var i: int = 0
	while i < ALLOWED_EXTS.size():
		var ext: String = ALLOWED_EXTS[i]
		if s.ends_with(ext):
			return true
		i += 1
	return false


func _scan_case_insensitive(name_key: String) -> String:
	# Supports scanning in a subfolder if name_key includes "subdir/name".
	var key: String = name_key.strip_edges()
	if key.is_empty():
		return ""

	var subdir: String = ""
	var base_name: String = key

	var slash_index: int = key.rfind("/")
	if slash_index >= 0:
		subdir = key.substr(0, slash_index)
		base_name = key.substr(slash_index + 1, key.length() - (slash_index + 1))

	var dir_path: String = SFX_BASE_DIR
	if not subdir.is_empty():
		dir_path = dir_path.path_join(subdir)

	var dir: DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return ""

	var want: String = base_name.to_lower()

	dir.list_dir_begin()
	var fname: String = dir.get_next()
	while not fname.is_empty():
		if dir.current_is_dir():
			fname = dir.get_next()
			continue

		var lower: String = fname.to_lower()

		# Match "<base>.<ext>" ignoring case.
		if lower == want:
			var full: String = dir_path.path_join(fname)
			if ResourceLoader.exists(full):
				dir.list_dir_end()
				return full

		# Match base name ignoring case, only if file has an allowed ext.
		if _has_any_allowed_ext(lower):
			var dot: int = lower.rfind(".")
			if dot > 0:
				var just_base: String = lower.substr(0, dot)
				if just_base == want:
					var full2: String = dir_path.path_join(fname)
					if ResourceLoader.exists(full2):
						dir.list_dir_end()
						return full2

		fname = dir.get_next()

	dir.list_dir_end()
	return ""
