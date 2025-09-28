extends Node
class_name GiveXpOnDeath
## Attach this to ENEMY scenes only (or any unit that should award XP).
## On the owner's StatsComponent.died, divide xp_reward equally among
## the current leader AND all party members (unique). Fallback: leader only.

@export var xp_reward: int = 25
@export var enabled: bool = true
@export var party_group_name: String = "PartyManager"
@export var level_component_name: String = "LevelComponent"  # change if your node is named differently

var _awarded: bool = false

func _ready() -> void:
	var stats: Node = _find_stats_component(owner)
	if stats != null and stats.has_signal("died"):
		if not stats.died.is_connected(_on_owner_died):
			stats.died.connect(_on_owner_died)

func _on_owner_died() -> void:
	if _awarded:
		return
	_awarded = true
	if not enabled:
		return
	if xp_reward <= 0:
		return

	var recipients: Array = _collect_party_recipients()
	_split_and_award(recipients, xp_reward)

# -----------------------------
# Recipient collection / splitting
# -----------------------------
func _collect_party_recipients() -> Array:
	var out: Array = []
	var uniq: Dictionary = {}  # Node -> true

	var party: Node = get_tree().get_first_node_in_group(party_group_name)

	var leader: Node = null
	if party != null and party.has_method("get_controlled"):
		leader = party.get_controlled()

	var members: Array = []
	if party != null and party.has_method("get_members"):
		members = party.get_members()

	# Unique set of actors
	if leader != null:
		uniq[leader] = true
	for m in members:
		if m != null:
			uniq[m] = true

	# Find LevelComponent (or any node with add_xp) on each actor
	var keys: Array = uniq.keys()
	for actor in keys:
		var actor_node: Node = actor
		var lvl: Node = _find_level_component(actor_node)
		if lvl != null and lvl.has_method("add_xp"):
			out.append(lvl)

	# Fallback to leader only
	if out.size() == 0 and leader != null:
		var l2: Node = _find_level_component(leader)
		if l2 != null and l2.has_method("add_xp"):
			out.append(l2)

	return out

func _split_and_award(targets: Array, total_xp: int) -> void:
	var n: int = targets.size()
	if n <= 0 or total_xp <= 0:
		return

	var base_share: int = total_xp / n
	var remainder: int = total_xp - base_share * n

	var i: int = 0
	for t in targets:
		var lvl_node: Node = t
		var amt: int = base_share
		if i < remainder:
			amt = amt + 1
		if lvl_node != null and lvl_node.has_method("add_xp"):
			lvl_node.add_xp(amt)
		i = i + 1

# -----------------------------
# Helpers
# -----------------------------
func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var s: Node = root.get_node_or_null("StatsComponent")
	if s != null:
		return s
	return root.find_child("StatsComponent", true, false)

func _find_level_component(root: Node) -> Node:
	if root == null:
		return null
	# Try a direct child with the expected name
	var n: Node = root.get_node_or_null(level_component_name)
	if n != null:
		return n
	# Try by class/name anywhere below
	var found: Node = root.find_child("LevelComponent", true, false)
	if found != null:
		return found
	# Last resort: BFS for any node offering add_xp()
	var q: Array = []
	q.append(root)
	while q.size() > 0:
		var node: Node = q.pop_back()
		if node != root and node != null and node.has_method("add_xp"):
			return node
		if node != null:
			var children: Array = node.get_children()
			for c in children:
				var child_node: Node = c
				q.append(child_node)
	return null
