extends Node
class_name GiveXpOnDeath
## Attach this to ENEMY scenes only.
## On the owner's StatsComponent.died, divide xp_reward equally among
## the current leader AND all unique party members. Fallback: leader only.

@export var xp_reward: int = 25
@export var enabled: bool = true
@export var party_group_name: String = "PartyManager"
@export var level_component_name: String = "LevelComponent"  # node name to try first
@export var debug_prints: bool = false

var _awarded: bool = false

func _ready() -> void:
	var enemy_root: Node = _get_enemy_root()
	var stats: Node = _find_stats_component(enemy_root)
	if stats != null and stats.has_signal("died"):
		if not stats.died.is_connected(_on_owner_died):
			stats.died.connect(_on_owner_died)
		if debug_prints:
			print("[GiveXpOnDeath] Connected to died on: ", stats)
	else:
		if debug_prints:
			print("[GiveXpOnDeath] WARNING: could not find StatsComponent to connect died.")

func _on_owner_died() -> void:
	if _awarded:
		return
	if not enabled:
		return
	if xp_reward <= 0:
		return
	_awarded = true

	var recipients: Array = _collect_party_recipients_living_only()
	if debug_prints:
		print("[GiveXpOnDeath] awarding ", xp_reward, " XP to ", recipients.size(), " recipients (living only)")
	_split_and_award(recipients, xp_reward)

# -----------------------------
# Recipient collection / splitting
# -----------------------------
func _collect_party_recipients_living_only() -> Array:
	var out: Array = []
	var uniq: Dictionary = {}  # Node -> true

	var party: Node = get_tree().get_first_node_in_group(party_group_name)

	var leader: Node = null
	if party != null and party.has_method("get_controlled"):
		leader = party.get_controlled()

	var members: Array = []
	if party != null and party.has_method("get_members"):
		members = party.get_members()

	# Unique set of actors (leader + members)
	if leader != null:
		uniq[leader] = true
	for m in members:
		if m != null:
			uniq[m] = true

	# Find LevelComponent (or any node with add_xp) on each actor,
	# but include only if the actor is currently alive (not dead).
	for actor in uniq.keys():
		if actor == null:
			continue
		if _is_actor_dead(actor):
			if debug_prints:
				print("[GiveXpOnDeath] skipping dead actor: ", actor)
			continue
		var lvl: Node = _find_level_component(actor)
		if lvl != null and lvl.has_method("add_xp"):
			out.append(lvl)

	# Fallback to leader only (but still only if alive)
	if out.size() == 0 and leader != null and _is_actor_dead(leader) == false:
		var l2: Node = _find_level_component(leader)
		if l2 != null and l2.has_method("add_xp"):
			out.append(l2)

	return out

func _split_and_award(targets: Array, total_xp: int) -> void:
	var n: int = targets.size()
	if n <= 0:
		return
	if total_xp <= 0:
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
			if debug_prints:
				print("[GiveXpOnDeath] -> ", lvl_node, " +", amt, " XP")
			lvl_node.add_xp(amt)
		i = i + 1

# -----------------------------
# Helpers
# -----------------------------
func _get_enemy_root() -> Node:
	# Prefer nearest ancestor in "Enemies" group
	var n: Node = self
	while n != null:
		if n.is_in_group("Enemies"):
			return n
		n = n.get_parent()
	# Fallback: parent (typical enemy root), then self
	if get_parent() != null:
		return get_parent()
	return self

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	# Direct child first
	var s: Node = root.get_node_or_null("StatsComponent")
	if s != null:
		return s
	# Anywhere under the same enemy root
	return root.find_child("StatsComponent", true, false)

func _find_level_component(root: Node) -> Node:
	if root == null:
		return null
	# Try an immediate child with the expected name
	var n: Node = root.get_node_or_null(level_component_name)
	if n != null:
		return n
	# Try by name/class anywhere below
	var found: Node = root.find_child("LevelComponent", true, false)
	if found != null:
		return found
	# Last resort: BFS for any node offering add_xp()
	var q: Array = [root]
	while q.size() > 0:
		var node: Node = q.pop_back()
		if node != root and node != null and node.has_method("add_xp"):
			return node
		if node != null:
			for c in node.get_children():
				q.append(c)
	return null

func _is_actor_dead(actor: Node) -> bool:
	var s: Node = _find_status_node(actor)
	if s == null:
		return false
	if s.has_method("is_dead"):
		var v: Variant = s.call("is_dead")
		if typeof(v) == TYPE_BOOL:
			return bool(v)
	return false

func _find_status_node(actor: Node) -> Node:
	if actor == null:
		return null
	# First try a direct child named "StatusConditions"
	var direct: Node = actor.get_node_or_null("StatusConditions")
	if direct != null:
		return direct
	# Otherwise search under the actor for any "StatusConditions"
	return actor.find_child("StatusConditions", true, false)
