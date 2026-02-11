extends Resource
class_name QuestDef

# Godot 4.5 — typed, no ternaries.
# Generic quest definition resource intended for plug-and-play authoring (CSV -> .tres).
# QuestSys will evaluate availability + handle completion based on these fields.

@export_group("Identity")
@export var quest_id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""

@export_group("Giver / Routing")
# Optional: if set, QuestSys can use it for validation/routing. Otherwise QuestSys can rely on NPC.quest_giver_id.
@export var giver_id: StringName = &""

@export_group("Availability: Story Position")
@export var require_story_position: bool = false
@export var require_act_id: int = 1
@export var require_step_id: int = 1
@export var require_part_id: int = 1

@export_group("Availability: Flags")
# All of these flags must be true for the quest to be available.
@export var require_flags_all: Array[StringName] = []
# None of these flags may be true for the quest to be available.
@export var require_flags_none: Array[StringName] = []

@export_group("Availability: Previous Quests")
# QuestSys will typically map completion to flags like "quest_<id>_complete" (implementation detail),
# but this lets your data express chaining without hardcoding.
@export var require_quests_complete: Array[StringName] = []
@export var forbid_quests_complete: Array[StringName] = []

@export_group("Availability: Inventory")
# "Any-of" bucket: player can bring any mix of these items that sum to total >= require_items_any_total.
@export var require_items_any: Array[StringName] = []
@export var require_items_any_total: int = 0

@export_group("Completion: Item Consumption")
# If true, QuestSys consumes items on completion.
@export var consume_items_on_complete: bool = true
# If -1, QuestSys should default to require_items_any_total.
@export var consume_items_any_total: int = -1

@export_group("Rewards")
@export var reward_xp: int = 0
@export var reward_gold: int = 0
@export var set_flags_on_complete: Array[StringName] = []
@export var clear_flags_on_complete: Array[StringName] = []

@export_group("Rewards: Items Received")
# Parallel arrays (CSV-friendly):
# - reward_item_ids[i] is granted in quantity reward_item_counts[i]
# - QuestSys should treat missing/out-of-range counts as 1, and ignore <= 0 counts.
@export var reward_item_ids: Array[StringName] = []
@export var reward_item_counts: Array[int] = []

@export_group("Rewards: Story Advance")
# Optional: for story-critical quests that should advance the story position.
@export var advance_story_position_on_complete: bool = false
@export var advance_act_id: int = 1
@export var advance_step_id: int = 1
@export var advance_part_id: int = 1

@export_group("Dialogue")
# These are optional. QuestSys should fall back to generic text if these are empty.
# Suggested tokens for QuestSys to substitute later (implementation detail):
#   {quest_name}, {have}, {need}, {xp}, {gold}
@export_multiline var dialogue_offer: String = ""
@export_multiline var dialogue_not_ready: String = ""
@export_multiline var dialogue_ready_to_turn_in: String = ""
@export_multiline var dialogue_completed: String = ""


func effective_consume_any_total() -> int:
	if consume_items_any_total >= 0:
		return consume_items_any_total
	return require_items_any_total


func get_reward_items_map() -> Dictionary:
	# Returns Dictionary[StringName, int]
	var out: Dictionary = {}

	var i: int = 0
	while i < reward_item_ids.size():
		var item_id: StringName = reward_item_ids[i]
		if item_id != &"":
			var count: int = 1
			if i < reward_item_counts.size():
				count = reward_item_counts[i]
			if count > 0:
				if out.has(item_id):
					out[item_id] = int(out[item_id]) + count
				else:
					out[item_id] = count
		i += 1

	return out
