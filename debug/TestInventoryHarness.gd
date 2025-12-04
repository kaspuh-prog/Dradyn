extends Node
class_name TestInventoryHarness

## Verifies inventory add/stack, then equips/uses when PartyManager exposes a leader.
## Requires Autoload named "InventorySys" pointing at res://AutoLoads/InventorySystem.gd
## Godot 4.5 style, fully typed, no ternaries.

var _potion_id: StringName = &"potion_s"
var _sword_id: StringName = &"wooden_sword"

var _pm: Node = null
var _ran_actor_tests: bool = false

# polling watcher
var _leader_watch_active: bool = false
var _leader_watch_elapsed_step: float = 0.0
var _leader_watch_interval: float = 0.25
var _leader_watch_total: float = 0.0
var _leader_watch_timeout: float = 10.0

func _ready() -> void:
	print("[TestInventoryHarness] Starting…")
	if not has_node("/root/InventorySys"):
		push_error("[TestInventoryHarness] Autoload 'InventorySys' not found. Set node name to InventorySys.")
		return

	var conn_err: int = InventorySys.connect("inventory_changed", Callable(self, "_on_inventory_changed"))
	if conn_err == OK:
		print("[TestInventoryHarness] Connected to InventorySys.inventory_changed")

	# Find PartyManager by GROUP ("PartyManager") per your script.
	_pm = _find_party_manager()
	if _pm != null:
		_connect_party_signals(_pm)
	else:
		print("[TestInventoryHarness] PartyManager not found yet; watcher will poll for it.")

	# --- Step 1: Create and add consumables (potions) ---
	var potion: ItemDef = ItemDef.new()
	potion.id = _potion_id
	potion.display_name = "Potion (S)"
	potion.item_type = "consumable"
	potion.stack_max = 20
	potion.restore_hp = 15

	var leftover_potions: int = InventorySys.inventory_model.add_item(potion, 3)
	print("[Test] Added 3 potions. Leftover: ", leftover_potions)
	_print_compact_inventory()

	# --- Step 2: Create and add an equipment item (weapon) ---
	var sword: ItemDef = ItemDef.new()
	sword.id = _sword_id
	sword.display_name = "Wooden Sword"
	sword.item_type = "equipment"
	sword.equip_slot = "weapon"

	var leftover_sword: int = InventorySys.inventory_model.add_item(sword, 1)
	print("[Test] Added 1 weapon. Leftover: ", leftover_sword)
	_print_compact_inventory()

	# Try immediately, then start polling for leader if needed.
	_try_run_actor_tests_now()
	_begin_leader_watch()
	print("[TestInventoryHarness] Ready. Waiting for PartyManager/leader via polling (0.25s steps, up to 10s)…")

func _process(delta: float) -> void:
	if not _leader_watch_active:
		return

	_leader_watch_total += delta
	_leader_watch_elapsed_step += delta

	# On each step, try to resolve PartyManager (in case it just spawned)
	if _pm == null:
		_pm = _find_party_manager()
		if _pm != null:
			_connect_party_signals(_pm)

	if _leader_watch_elapsed_step >= _leader_watch_interval:
		_leader_watch_elapsed_step = 0.0
		_try_run_actor_tests_now()
		if _ran_actor_tests:
			_leader_watch_active = false
			return

	if _leader_watch_total >= _leader_watch_timeout:
		_leader_watch_active = false
		push_warning("[TestInventoryHarness] Leader not found within timeout; actor-dependent tests skipped.")

func _begin_leader_watch() -> void:
	_leader_watch_active = true
	_leader_watch_elapsed_step = 0.0
	_leader_watch_total = 0.0

# --------------------
# PartyManager discovery & hooks
# --------------------

func _find_party_manager() -> Node:
	# Primary: by group "PartyManager" (your script adds itself in _ready()).
	var by_group: Node = get_tree().get_first_node_in_group("PartyManager")
	if by_group != null:
		return by_group

	# Fallback scan: look for a node literally named "PartyManager".
	var root: Node = get_tree().root
	if root == null:
		return null
	var found: Node = root.find_child("PartyManager", true, false)
	if found != null:
		return found

	return null

func _connect_party_signals(pm: Node) -> void:
	if pm == null:
		return
	if pm.has_signal("controlled_changed"):
		if not pm.is_connected("controlled_changed", Callable(self, "_on_controlled_changed")):
			pm.connect("controlled_changed", Callable(self, "_on_controlled_changed"))
		print("[TestInventoryHarness] Connected to PartyManager.controlled_changed")

func _on_controlled_changed(current: Node) -> void:
	if current != null:
		print("[TestInventoryHarness] controlled_changed → ", current.name)
		_try_run_actor_tests_now()

func _get_leader_now() -> Node:
	if _pm == null:
		return null
	if not _pm.has_method("get_controlled"):
		return null
	var controlled: Node = _pm.call("get_controlled") as Node
	return controlled

# --------------------
# Test runner (actor-dependent)
# --------------------

func _try_run_actor_tests_now() -> void:
	if _ran_actor_tests:
		return

	var leader: Node = _get_leader_now()
	if leader == null:
		return

	_ran_actor_tests = true
	print("[TestInventoryHarness] Leader resolved: ", leader.name)

	# Step 3: Equip weapon from inventory
	var sword_index: int = _find_index_by_item_id(_sword_id)
	if sword_index >= 0:
		var eq_ok: bool = InventorySys.try_equip_from_inventory(leader, sword_index)
		print("[Test] Equip weapon from slot ", sword_index, " → ", eq_ok)
		_print_compact_inventory()
	else:
		print("[Test] No weapon stack found to equip.")

	# Step 4: Use a potion on the leader
	var pot_index: int = _find_index_by_item_id(_potion_id)
	if pot_index >= 0:
		var hp_before: int = _get_hp(leader)
		InventorySys.inventory_model.use_item(pot_index, leader)
		var hp_after: int = _get_hp(leader)
		print("[Test] Used Potion from slot ", pot_index, ". HP before/after: ", hp_before, " → ", hp_after)
		_print_compact_inventory()
	else:
		print("[Test] No potion stack found to use.")

	# Step 5: Unequip weapon back to inventory
	var uneq_ok: bool = InventorySys.try_unequip_to_inventory(leader, "weapon")
	print("[Test] Unequip weapon → ", uneq_ok)
	_print_compact_inventory()

	print("[TestInventoryHarness] Actor-dependent tests complete.")

# --------------------
# Helpers
# --------------------

func _on_inventory_changed() -> void:
	print("[Signal] Inventory changed.")

func _get_hp(actor: Node) -> int:
	if actor == null:
		return 0
	var stats: Node = actor.get_node_or_null("StatsComponent")
	if stats == null:
		return 0

	# Preferred: directly read your StatsComponent's current_hp via Object.get().
	var v: Variant = stats.get("current_hp")
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)

	# Fallbacks in case a test double is used:
	if stats.has_method("get_hp_current"):
		var hp_val: Variant = stats.call("get_hp_current")
		return int(hp_val)
	if stats.has_method("get_hp"):
		var hp_val2: Variant = stats.call("get_hp")
		return int(hp_val2)

	return 0


func _find_index_by_item_id(id: StringName) -> int:
	var stacks: Array = InventorySys.inventory_model.get_stacks()
	var i: int = 0
	while i < stacks.size():
		var st: ItemStack = stacks[i] as ItemStack
		if st != null:
			var itm: ItemDef = st.item
			if itm != null:
				if itm.id == id:
					return i
		i += 1
	return -1

func _print_compact_inventory() -> void:
	var stacks: Array = InventorySys.inventory_model.get_stacks()
	var parts: Array[String] = []
	var i: int = 0
	while i < stacks.size():
		var st: ItemStack = stacks[i] as ItemStack
		if st != null:
			var itm: ItemDef = st.item
			if itm != null:
				var entry: String = str(i) + ":" + String(itm.id) + "x" + str(st.count)
				parts.append(entry)
		i += 1
	var joined: String = ", ".join(parts)
	print("[INV] ", joined)
