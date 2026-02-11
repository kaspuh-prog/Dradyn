extends Resource
class_name AlchemyUnlockDef

## Defines a single “turn in reagents to unlock potion” recipe
## for the Alchemy (SPECIAL) merchant tab.

@export var id: StringName
## Potion that will be unlocked for purchase on the BUY tab.
@export var potion: ItemDef

## Reagents that must be turned in to unlock this potion.
## cost_items[i] pairs with cost_counts[i].
@export var cost_items: Array[ItemDef] = []
@export var cost_counts: Array[int] = []

## Optional flavour / extra description for the unlock itself.
## (Potion’s own description still comes from potion.description.)
@export var unlock_description: String = ""

## If true, this recipe should only be used once per party.
## Future visits to the Alchemy merchant would treat it as already unlocked.
@export var once_per_party: bool = true


func is_valid() -> bool:
	## Basic sanity check so we can skip half-configured recipes.
	if potion == null:
		return false
	if id == StringName():
		return false
	
	if cost_items.is_empty():
		return false

	var pair_count: int = min(cost_items.size(), cost_counts.size())
	if pair_count <= 0:
		return false

	return true


func get_cost_summary() -> String:
	## Builds a human-readable summary like:
	## "Requires: 3× Rat Ear, 2× Slime Core"
	var parts: Array[String] = []

	var pair_count: int = min(cost_items.size(), cost_counts.size())
	var i: int = 0
	while i < pair_count:
		var reagent: ItemDef = cost_items[i]
		var needed: int = cost_counts[i]

		if reagent != null and needed > 0:
			var name_text: String = ""
			if reagent.display_name != "":
				name_text = reagent.display_name
			else:
				name_text = String(reagent.id)

			var count_text: String = str(needed)
			var piece: String = count_text + "× " + name_text
			parts.append(piece)
		i += 1

	if parts.is_empty():
		return ""

	var result: String = "Requires: "
	var j: int = 0
	while j < parts.size():
		result += parts[j]
		if j < parts.size() - 1:
			result += ", "
		j += 1

	return result
