extends Node
class_name GiveGoldOnDeath
## Attach to ENEMY scenes only.
## On the owner's StatsComponent.died, award 'gold_reward' to party currency via your Inventory autoload.

@export var gold_reward: int = 10
@export var enabled: bool = true
@export var debug_prints: bool = false

# Enemy + owner component discovery
@export var enemies_group_name: String = "Enemies"
@export var stats_component_name: String = "StatsComponent"

# --- IMPORTANT: your autoload name(s). First match that exists under /root will be used.
@export var inventory_autoload_names: PackedStringArray = PackedStringArray(["InventorySys", "InventorySystem"])

var _awarded: bool = false
var _inv_obj: Object = null          # cached autoload object
var _inv_checked_once: bool = false  # don’t re-resolve every time

func _ready() -> void:
	var enemy_root: Node = _get_enemy_root()
	var stats: Node = _find_stats_component(enemy_root)
	if stats != null and stats.has_signal("died"):
		if not stats.died.is_connected(_on_owner_died):
			stats.died.connect(_on_owner_died)
		if debug_prints:
			print("[GiveGoldOnDeath] Connected to died on: ", stats)
	else:
		if debug_prints:
			print("[GiveGoldOnDeath] WARNING: StatsComponent not found; cannot connect 'died'.")

func _on_owner_died() -> void:
	if _awarded:
		return
	if not enabled:
		return
	if gold_reward <= 0:
		return

	_awarded = true
	_award_to_party_currency(gold_reward)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
func _get_enemy_root() -> Node:
	var n: Node = self
	while n != null:
		if n.is_in_group(enemies_group_name):
			return n
		n = n.get_parent()
	var p: Node = get_parent()
	if p != null:
		return p
	return self

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var s_direct: Node = root.get_node_or_null(stats_component_name)
	if s_direct != null:
		return s_direct
	var s_deep: Node = root.find_child(stats_component_name, true, false)
	if s_deep != null:
		return s_deep
	return null

# --- Inventory autoload resolution (works for project autoloads) ---------------
func _resolve_inventory_sys() -> Object:
	if _inv_checked_once and _inv_obj != null and is_instance_valid(_inv_obj):
		return _inv_obj
	if _inv_checked_once and _inv_obj == null:
		return null

	_inv_checked_once = true
	_inv_obj = null

	var root: Node = get_tree().get_root()
	var i: int = 0
	while i < inventory_autoload_names.size():
		var nm: String = inventory_autoload_names[i]
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_inv_obj = obj
				if debug_prints:
					print("[GiveGoldOnDeath] Resolved inventory autoload: ", path)
				return _inv_obj
		i += 1

	if debug_prints:
		print("[GiveGoldOnDeath] WARNING: could not resolve inventory autoload under /root. Tried: ", inventory_autoload_names)
	return null

func _award_to_party_currency(amount: int) -> void:
	if amount <= 0:
		return

	var inv: Object = _resolve_inventory_sys()
	if inv == null:
		if debug_prints:
			print("[GiveGoldOnDeath] WARNING: Inventory autoload not found; award skipped (amount=", amount, ").")
		return

	# Preferred: add_currency(int) -> int
	if inv.has_method("add_currency"):
		inv.call("add_currency", amount)
		if debug_prints:
			print("[GiveGoldOnDeath] +", amount, " gold via add_currency()")
		return

	# Alternate: give_currency(int) -> int
	if inv.has_method("give_currency"):
		inv.call("give_currency", amount)
		if debug_prints:
			print("[GiveGoldOnDeath] +", amount, " gold via give_currency()")
		return

	# Fallback: get_currency() + set_currency(int)
	var total: int = 0
	if inv.has_method("get_currency"):
		total = int(inv.call("get_currency"))
	var new_total: int = total + amount
	if inv.has_method("set_currency"):
		inv.call("set_currency", new_total)
		if debug_prints:
			print("[GiveGoldOnDeath] +", amount, " gold via get/set (", total, "→", new_total, ")")
	else:
		if debug_prints:
			print("[GiveGoldOnDeath] WARNING: inventory autoload lacks currency mutators; award skipped (amount=", amount, ").")
