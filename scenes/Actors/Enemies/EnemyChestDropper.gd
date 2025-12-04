extends Node
class_name EnemyChestDropper
## Listens for the owner's "died" signal and asks the current AreaLootProvider
## to spawn an InteractableChest with generated loot. Chests despawn after opening.

@export var enabled: bool = true
@export var source_tag: String = ""                    # Optional analytics tag ("rat", "wurm", etc.)
@export var spawn_offset: Vector2 = Vector2.ZERO       # Nudge to avoid overlap with corpse

# Optional: multiplier to bias spawn chance per-enemy type.
# 1.0 = use area chance as-is; 0.0 disables; 2.0 doubles (clamped to 1.0 after multiply).
@export_range(0.0, 10.0, 0.01) var chance_multiplier: float = 1.0

func _ready() -> void:
	if not enabled:
		return
	# Expect owner (enemy) to emit `died(self)`
	if owner != null and owner.has_signal("died"):
		if not owner.is_connected("died", Callable(self, "_on_owner_died")):
			owner.connect("died", Callable(self, "_on_owner_died"))

func _on_owner_died(enemy: Node) -> void:
	if not enabled:
		return

	# Find loot provider for this area
	var provider: AreaLootProvider = _find_area_loot_provider()
	if provider == null:
		return

	# Respect area chance with optional per-enemy multiplier
	if not _should_spawn(provider):
		return

	# --- Resolve a reliable "enemy" node ------------------------------------
	var real_enemy: Node = enemy
	if real_enemy == null or not is_instance_valid(real_enemy):
		# Fallback: assume this script is a direct child of the enemy node
		real_enemy = get_parent()

	if real_enemy == null or not is_instance_valid(real_enemy):
		return

	# --- Decide where in the tree to put the chest --------------------------
	# 1) Prefer the provider's parent (usually the current area node)
	var parent_for_chest: Node = provider.get_parent()
	# 2) Fallback to the enemy's parent (Spawner/Marker/etc.)
	if parent_for_chest == null:
		parent_for_chest = real_enemy.get_parent()
	# 3) Fallback to the current scene
	if parent_for_chest == null:
		parent_for_chest = get_tree().get_current_scene()
	# 4) Last resort: root
	if parent_for_chest == null:
		parent_for_chest = get_tree().root

	# --- Compute spawn position in world space ------------------------------
	var pos: Vector2 = _resolve_spawn_position(real_enemy) + spawn_offset

	# --- Source tag for analytics / debugging -------------------------------
	var src: String = source_tag
	if src == "":
		src = str(real_enemy.name)

	# Spawn and pre-configure chest to despawn after open
	var chest: Node = provider.spawn_chest_at(parent_for_chest, pos, true, src)

	# If for some reason the provider did not create a chest, bail gracefully
	if chest == null:
		print("[CHEST DROP] spawn_chest_at returned null for enemy=", str(real_enemy))
		return

	# Extra debug: where did it actually land?
	var chest2d: Node2D = chest as Node2D
	if chest2d != null:
		var parent_node: Node = chest2d.get_parent()
		var parent_path: String = ""
		if parent_node != null:
			parent_path = str(parent_node.get_path())
		print(
			"[CHEST DROP] enemy=", str(real_enemy),
			" root_pos=", str(_resolve_spawn_position(real_enemy)),
			" spawn_pos=", str(pos),
			" chest_local=", str(chest2d.position),
			" chest_parent=", parent_path,
			" src=", src
		)
	else:
		print("[CHEST DROP] spawn_chest_at -> chest (non-Node2D) = ", str(chest))


func _find_area_loot_provider() -> AreaLootProvider:
	# Fast path: group lookup (we'll add the provider to this group)
	var by_group: Node = get_tree().get_first_node_in_group("AreaLootProvider")
	if by_group != null and by_group is AreaLootProvider:
		return by_group as AreaLootProvider

	# Fallback: walk upwards to find a provider in ancestors or siblings
	var p: Node = owner
	if p == null:
		p = get_parent()
	while p != null:
		var prov: AreaLootProvider = p.get_node_or_null("AreaLootProvider") as AreaLootProvider
		if prov != null:
			return prov
		# Directly check p itself
		if p is AreaLootProvider:
			return p as AreaLootProvider
		p = p.get_parent()
	return null

func _should_spawn(provider: AreaLootProvider) -> bool:
	if chance_multiplier <= 0.0:
		return false
	if chance_multiplier == 1.0:
		return provider.should_spawn_chest()
	# Multiply and clamp
	var base: float = provider.chest_spawn_chance
	var eff: float = base * chance_multiplier
	if eff > 1.0:
		eff = 1.0
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var roll: float = rng.randf()
	print("[CHEST DROP] base_chance=", str(base), " mult=", str(chance_multiplier), " eff=", str(eff), " roll=", str(roll))
	if roll <= eff:
		return true
	return false

func _resolve_spawn_position(enemy: Node) -> Vector2:
	var root: Node = enemy
	if root == null:
		root = owner

	# Prefer the visible sprite/anim anchor on the enemy root.
	if root is Node2D:
		var root2d: Node2D = root as Node2D

		if root2d.has_node("Anim"):
			var anim_node: Node2D = root2d.get_node("Anim") as Node2D
			if anim_node != null:
				print("[CHEST DROP] Using Anim anchor for position: ", str(anim_node.global_position))
				return anim_node.global_position

		if root2d.has_node("Sprite"):
			var sprite_node: Node2D = root2d.get_node("Sprite") as Node2D
			if sprite_node != null:
				print("[CHEST DROP] Using Sprite anchor for position: ", str(sprite_node.global_position))
				return sprite_node.global_position

		# Fallback: use the root node’s position.
		print("[CHEST DROP] Using root Node2D position: ", str(root2d.global_position))
		return root2d.global_position

	# Last-chance fallback: use our own parent if it’s a Node2D.
	var parent_2d: Node2D = get_parent() as Node2D
	if parent_2d != null:
		print("[CHEST DROP] Using parent Node2D position: ", str(parent_2d.global_position))
		return parent_2d.global_position

	print("[CHEST DROP] No suitable anchor; defaulting to (0,0)")
	return Vector2.ZERO
