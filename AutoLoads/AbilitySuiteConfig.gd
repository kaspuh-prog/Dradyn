extends Node
class_name SuiteConfig

signal suite_enabled_changed(enabled: bool)

var _enabled_runtime: bool = true

func _ready() -> void:
	_enabled_runtime = _read_ps_bool("dradyn/suite/enabled", true)
	print("[Suite] enabled=", _enabled_runtime)

func is_suite_enabled() -> bool:
	return _enabled_runtime

func set_suite_enabled(v: bool) -> void:
	if _enabled_runtime == v:
		return
	_enabled_runtime = v
	emit_signal("suite_enabled_changed", v)
	print("[Suite] runtime toggle -> ", v)

# Call this only when NOT playing in-editor if you want to persist.
func persist_suite_enabled_to_project() -> void:
	if _is_playing_in_editor():
		push_warning("[Suite] Refusing to save ProjectSettings while playing. Stop the game first.")
		return
	ProjectSettings.set_setting("dradyn/suite/enabled", _enabled_runtime)
	ProjectSettings.save()
	print("[Suite] saved dradyn/suite/enabled = ", _enabled_runtime)

func _read_ps_bool(key: String, def: bool) -> bool:
	if ProjectSettings.has_setting(key):
		var v: Variant = ProjectSettings.get_setting(key)
		if typeof(v) == TYPE_BOOL:
			return bool(v)
		if typeof(v) == TYPE_INT:
			return int(v) != 0
	return def

func _is_playing_in_editor() -> bool:
	return Engine.is_editor_hint()
