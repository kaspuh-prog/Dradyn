extends Node
class_name StoryGate

@export_group("Required Story Position")
@export var required_act_id: int = -1        # -1 = any act
@export var required_step_id: int = -1       # -1 = any step

@export_group("Required / Forbidden Flags")
@export var required_flags: PackedStringArray = PackedStringArray()
@export var forbidden_flags: PackedStringArray = PackedStringArray()

@export_group("Story Changes After Success")
@export var set_act_id_after: int = -1       # -1 = leave as current
@export var set_step_id_after: int = -1      # -1 = leave as current

@export var flags_to_set_after: PackedStringArray = PackedStringArray()
@export var flags_to_clear_after: PackedStringArray = PackedStringArray()


func _get_story() -> StoryStateSystem:
	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story == null:
		push_warning("[StoryGate] StoryStateSys autoload not found.")
	return story


func is_passing() -> bool:
	var story: StoryStateSystem = _get_story()
	if story == null:
		# Fallback: allow things to run rather than silently killing content.
		return true

	var current_act: int = story.get_current_act_id()
	var current_step: int = story.get_current_step_id()

	# Act / step requirements
	if required_act_id > 0 and current_act != required_act_id:
		return false

	if required_step_id > 0 and current_step != required_step_id:
		return false

	# Required flags: all must be true.
	var i: int = 0
	while i < required_flags.size():
		var name_str: String = required_flags[i]
		var flag_name: StringName = StringName(name_str)
		if not story.has_flag(flag_name):
			return false
		i += 1

	# Forbidden flags: all must be false.
	i = 0
	while i < forbidden_flags.size():
		var forbid_str: String = forbidden_flags[i]
		var forbid_name: StringName = StringName(forbid_str)
		if story.has_flag(forbid_name):
			return false
		i += 1

	return true


func apply_after_effects() -> void:
	var story: StoryStateSystem = _get_story()
	if story == null:
		return

	var act: int = story.get_current_act_id()
	var step: int = story.get_current_step_id()

	# If you specify act/step, we override the corresponding piece.
	var changed: bool = false

	if set_act_id_after > 0:
		act = set_act_id_after
		changed = true

	if set_step_id_after > 0:
		step = set_step_id_after
		changed = true

	if changed:
		story.set_current_step_full(act, step)

	# Set flags
	var i: int = 0
	while i < flags_to_set_after.size():
		var name_str: String = flags_to_set_after[i]
		var flag_name: StringName = StringName(name_str)
		story.set_flag(flag_name, true)
		i += 1

	# Clear flags
	i = 0
	while i < flags_to_clear_after.size():
		var clear_str: String = flags_to_clear_after[i]
		var clear_name: StringName = StringName(clear_str)
		story.clear_flag(clear_name)
		i += 1
