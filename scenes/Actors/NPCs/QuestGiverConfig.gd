extends Node
class_name QuestGiverConfig

# Godot 4.5 — typed, no ternaries.
# Pure data component: attach as a child of a NonCombatNPC to define which QuestDef(s)
# this NPC can offer/handle. QuestSys will read this at runtime.

@export_group("Quest Giver")
@export var enabled: bool = true

# Drag/drop QuestDef .tres resources here (CSV -> .tres friendly).
@export var quests: Array[QuestDef] = []


func get_quests() -> Array[QuestDef]:
	# Returned array is the authoring list; QuestSys should decide eligibility/order.
	return quests
