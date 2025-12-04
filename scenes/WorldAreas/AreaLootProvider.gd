extends Node
class_name AreaLootProvider

@export var chest_scene: PackedScene
@export_range(0.0, 1.0, 0.001) var chest_spawn_chance: float = 0.15
@export var loot_table: LootTable
@export var verbose_debug: bool = false

# NEW: only spawn a chest if at least one drop is produced
@export var only_spawn_with_loot: bool = true

var _rng: RandomNumberGenerator

func _ready() -> void:
	if not is_in_group("AreaLootProvider"):
		add_to_group("AreaLootProvider")
	_rng = RandomNumberGenerator.new()
	_rng.randomize()

func should_spawn_chest() -> bool:
	if chest_spawn_chance <= 0.0:
		return false
	if chest_spawn_chance >= 1.0:
		return true
	var roll: float = _rng.randf()
	if roll <= chest_spawn_chance:
		return true
	return false

func _roll_loot() -> Array[Dictionary]:
	if loot_table == null:
		return []
	return loot_table.pick(_rng)

## parent: where to instance
## position: world space
## destroy_after_open: despawn chest once opened
## source_id: optional debug/analytics tag
func spawn_chest_at(parent: Node, position: Vector2, destroy_after_open: bool, source_id: String) -> Node:
	if chest_scene == null:
		if verbose_debug:
			print_debug("[AreaLootProvider] No chest_scene set.")
		return null

	# Roll loot FIRST; optionally skip spawn if empty
	var drops: Array[Dictionary] = _roll_loot()
	if only_spawn_with_loot and drops.is_empty():
		if verbose_debug:
			print_debug("[AreaLootProvider] Skipping chest (empty drops). pos=", str(position))
		return null

	var inst: Node = chest_scene.instantiate()
	parent.call_deferred("add_child", inst)

	var n2d: Node2D = inst as Node2D
	if n2d != null:
	# Safe: still not in the tree yet, so no physics bodies have been registered.
		n2d.global_position = position


	# Preferred typed path
	var chest: InteractableChest = inst as InteractableChest
	if chest != null:
		chest.set_generated_loot(drops)
		chest.set_destroy_after_open(destroy_after_open)
		chest.set_source(source_id)
		if verbose_debug:
			print_debug("[AreaLootProvider] Spawned InteractableChest at ", str(position), " destroy_after_open=", str(destroy_after_open), " drops=", str(drops.size()))
		return inst

	# Generic fallback (scene with different script name)
	if inst.has_method("set_generated_loot"):
		inst.call("set_generated_loot", drops)
	if inst.has_method("set_destroy_after_open"):
		inst.call("set_destroy_after_open", destroy_after_open)
	if inst.has_method("set_source"):
		inst.call("set_source", source_id)

	if verbose_debug:
		print_debug("[AreaLootProvider] Spawned chest (generic) at ", str(position), " destroy_after_open=", str(destroy_after_open), " drops=", str(drops.size()))
	return inst
