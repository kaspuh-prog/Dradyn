extends Area2D
class_name InteractableDoor

signal unlock_ui_requested(door: InteractableDoor, actor: Node)

@export var target_scene_path: String = ""
@export var entry_tag: String = "default"
@export var require_press: bool = true

# NEW: let the door be easier to grab without changing global radius
@export var interact_radius_override: float = 48.0
func get_interact_radius() -> float:
	return interact_radius_override

# NEW: animation wiring
@export var animated_sprite_path: NodePath
@export var open_animation: StringName = &"open"
@export var closed_animation: StringName = &"closed"

@export_group("Night Animations")
@export var use_night_animations: bool = true
@export var night_open_animation: StringName = &"open_night"
@export var night_closed_animation: StringName = &"closed_night"

@export_group("Locking")
@export var is_locked: bool = false
@export var locked_prompt_text: String = "Locked"

# If true, this door is locked ONLY during NIGHT (independent from is_locked).
@export var lock_only_at_night: bool = false

# Key path (drag-drop UI uses this)
@export var key_item_id: StringName = &""
@export var consume_key_on_unlock: bool = false

# Lockpick path (UI button uses this)
@export var allow_lockpick: bool = true
@export var lockpick_required_class_title: StringName = &"Rogue"
@export var lockpick_required_dex: int = 0
@export var lockpick_requires_ability_id: String = ""

@export_group("Debug")
@export var debug_lock_ui: bool = false
@export var debug_night_anims: bool = false

const GROUP_LEADER: String = "PartyLeader"
const DAYNIGHT_AUTOLOAD_PATH: NodePath = NodePath("/root/DayandNight")

var _sprite: AnimatedSprite2D = null
var _daynight: DayNight = null
var _is_night: bool = false


func get_interact_prompt() -> String:
	if target_scene_path == "":
		return ""
	if _is_effectively_locked():
		return locked_prompt_text
	return "Open"


func can_interact(actor: Node) -> bool:
	if target_scene_path == "":
		return false
	if actor == null:
		return false
	return true


func interact(actor: Node) -> void:
	if debug_lock_ui:
		print("[InteractableDoor] interact() door=", name, " locked=", _is_effectively_locked(), " actor=", actor, " target=", target_scene_path)

	if not can_interact(actor):
		if debug_lock_ui:
			print("[InteractableDoor] can_interact=false door=", name)
		return

	if _is_effectively_locked():
		if debug_lock_ui:
			print("[InteractableDoor] EMIT unlock_ui_requested door=", name)
		emit_signal("unlock_ui_requested", self, actor)
		_play_closed_visual()
		return

	_play_open_visual()

	var sm: Node = get_node_or_null("/root/SceneMgr")
	if sm == null:
		if debug_lock_ui:
			print("[InteractableDoor] SceneMgr not found, abort.")
		return
	if sm.has_method("change_area"):
		sm.call("change_area", target_scene_path, entry_tag)


func _on_body_entered(body: Node) -> void:
	if not require_press:
		if _is_effectively_locked():
			return
		if body != null:
			if body.is_in_group(GROUP_LEADER):
				interact(body)


func _ready() -> void:
	if not is_in_group("interactable"):
		add_to_group("interactable")
	if not is_connected("body_entered", Callable(self, "_on_body_entered")):
		connect("body_entered", Callable(self, "_on_body_entered"))

	if debug_lock_ui:
		print("[InteractableDoor] ready() door=", name, " is_locked=", is_locked, " lock_only_at_night=", lock_only_at_night, " in_group(interactable)=", is_in_group("interactable"))

	_resolve_sprite()
	_wire_daynight()
	_sync_is_night_from_daynight()
	_play_closed_visual()


# -------------------------------------------------
# Effective lock policy
# -------------------------------------------------
func _is_effectively_locked() -> bool:
	if is_locked:
		return true

	if lock_only_at_night:
		if _is_night:
			return true

	return false


# -------------------------------------------------
# Day/Night helpers (DayandNight autoload)
# DayNight.gd (pasted) provides:
# - signal phase_changed(is_day: bool)
# - func is_day() -> bool
# -------------------------------------------------
func _wire_daynight() -> void:
	_daynight = null

	var n: Node = get_node_or_null(DAYNIGHT_AUTOLOAD_PATH)
	if n == null:
		if debug_night_anims:
			print("[InteractableDoor] DayandNight autoload not found at ", String(DAYNIGHT_AUTOLOAD_PATH))
		return

	if n is DayNight:
		_daynight = n as DayNight
	else:
		if debug_night_anims:
			print("[InteractableDoor] Node at ", String(DAYNIGHT_AUTOLOAD_PATH), " is not DayNight: ", n)
		return

	if not _daynight.is_connected("phase_changed", Callable(self, "_on_daynight_phase_changed")):
		_daynight.connect("phase_changed", Callable(self, "_on_daynight_phase_changed"))


func _sync_is_night_from_daynight() -> void:
	if _daynight == null:
		_is_night = false
		return

	var is_day_now: bool = _daynight.is_day()
	_is_night = not is_day_now


func _on_daynight_phase_changed(is_day_now: bool) -> void:
	var old_is_night: bool = _is_night
	_is_night = not is_day_now

	if debug_night_anims and old_is_night != _is_night:
		print("[InteractableDoor] phase_changed door=", name, " is_day=", is_day_now, " is_night=", _is_night)

	_play_closed_visual()


func _choose_animation(day_anim: StringName, night_anim: StringName) -> StringName:
	if not use_night_animations:
		return day_anim
	if not _is_night:
		return day_anim

	var night_str: String = String(night_anim)
	if night_str == "":
		return day_anim
	return night_anim


# -------------------------------------------------
# Visual helpers
# -------------------------------------------------
func _resolve_sprite() -> void:
	_sprite = null

	if animated_sprite_path != NodePath(""):
		var node: Node = get_node_or_null(animated_sprite_path)
		if node != null and node is AnimatedSprite2D:
			_sprite = node as AnimatedSprite2D
	else:
		var direct: Node = get_node_or_null("AnimatedSprite2D")
		if direct != null and direct is AnimatedSprite2D:
			_sprite = direct as AnimatedSprite2D


func _can_play_anim(anim_name: String) -> bool:
	if _sprite == null:
		return false
	if anim_name == "":
		return false
	if _sprite.sprite_frames == null:
		return false
	if not _sprite.sprite_frames.has_animation(anim_name):
		if debug_night_anims:
			print("[InteractableDoor] Missing anim '", anim_name, "' on door=", name, " sprite=", _sprite)
		return false
	return true


func _play_closed_visual() -> void:
	if _sprite == null:
		return

	var picked: StringName = _choose_animation(closed_animation, night_closed_animation)
	var anim_name: String = String(picked)
	if not _can_play_anim(anim_name):
		return

	_sprite.play(anim_name)


func _play_open_visual() -> void:
	if _sprite == null:
		return

	var picked: StringName = _choose_animation(open_animation, night_open_animation)
	var anim_name: String = String(picked)
	if not _can_play_anim(anim_name):
		return

	_sprite.play(anim_name)
