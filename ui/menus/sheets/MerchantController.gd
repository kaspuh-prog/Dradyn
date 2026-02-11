extends Control
class_name MerchantController

@export var merchant_menu_scene: PackedScene
@export var default_buy_stock: Array[ItemDef] = []
## Alchemy: unlock recipes available at this merchant (SPECIAL tab).
@export var alchemy_unlocks: Array[AlchemyUnlockDef] = []

# ---------------- UI SFX ----------------
@export_group("UI SFX")
@export var debug_log: bool = false

# Open/close merchant menu
@export var ui_open_close_event: StringName = &"UI_open_close.mp3"
@export var ui_open_close_volume_db: float = 0.0

# Normal UI clicks (including BUY/SELL/SPECIAL tab swaps)
@export var ui_click_event: StringName = &"UI_click"
@export var ui_click_volume_db: float = 0.0

# Purchase/Sell confirmations
@export var ui_coins_event: StringName = &"UI_coins"
@export var ui_coins_volume_db: float = 0.0

# Cancel button in menu
@export var ui_deny_event: StringName = &"UI_deny"
@export var ui_deny_volume_db: float = 0.0

# Autoload lookup list (safe; avoids assuming the autoload name).
@export var audio_autoload_names: PackedStringArray = PackedStringArray(["AudioSys", "AudioSystem"])

var _menu: MerchantMenu = null
var _current_merchant: NonCombatNPC = null
var _current_buyer: Node = null

var _inv: InventorySystem = null

var _buy_stock_items: Array[ItemDef] = []
var _buy_stock_counts_by_index: Dictionary = {}   # index -> remaining stock (99 = effectively infinite)

var _pending_sell_item: ItemDef = null

# SPECIAL / Alchemy state
var _alchemy_stock_items: Array[ItemDef] = []     # grid items (potions)
var _alchemy_unlock_by_index: Dictionary = {}     # index -> AlchemyUnlockDef
var _unlocked_alchemy_ids: Dictionary = {}        # id:StringName -> bool

var _current_is_alchemy_merchant: bool = false

# Audio autoload cache
var _audio_obj: Object = null
var _audio_checked_once: bool = false

# Prevent open/close SFX from double-firing if something calls open/close repeatedly.
var _was_menu_visible: bool = false


func _ready() -> void:
	add_to_group("merchant_ui")
	set_process(true)

	_resolve_audio_sys()

	_resolve_inventory_autoload()
	_instantiate_menu()

	_connect_existing_npcs()
	get_tree().node_added.connect(_on_node_added)


# -------------------------------------------------
# Setup helpers
# -------------------------------------------------

func _resolve_inventory_autoload() -> void:
	var n: Node = get_node_or_null("/root/InventorySys")
	if n == null:
		n = get_node_or_null("/root/InventorySystem")
	_inv = n as InventorySystem

func _instantiate_menu() -> void:
	if merchant_menu_scene == null:
		push_warning("MerchantController: merchant_menu_scene is not assigned.")
		return

	var inst: Control = merchant_menu_scene.instantiate()
	_menu = inst as MerchantMenu
	if _menu == null:
		push_error("MerchantController: merchant_menu_scene does not instantiate a MerchantMenu.")
		add_child(inst)
		return

	add_child(_menu)
	_menu.visible = false
	_was_menu_visible = false
	_wire_menu_signals()

func _wire_menu_signals() -> void:
	if _menu == null:
		return

	_menu.mode_changed.connect(_on_menu_mode_changed)
	_menu.transaction_confirmed.connect(_on_menu_transaction_confirmed)
	_menu.transaction_cancelled.connect(_on_menu_transaction_cancelled)

	var grid: MerchantGridView = _menu.get_grid()
	if grid != null:
		grid.selection_changed.connect(_on_grid_selection_changed)
		grid.activated.connect(_on_grid_activated)
		grid.sell_payload_dropped.connect(_on_grid_sell_payload_dropped)


# -------------------------------------------------
# Auto-wire NonCombatNPCs
# -------------------------------------------------

func _connect_existing_npcs() -> void:
	var nodes: Array[Node] = get_tree().get_nodes_in_group("interactable")
	var i: int = 0
	while i < nodes.size():
		var node: Node = nodes[i]
		if node is NonCombatNPC:
			_connect_npc(node as NonCombatNPC)
		i += 1

func _on_node_added(node: Node) -> void:
	if node is NonCombatNPC:
		_connect_npc(node as NonCombatNPC)

func _connect_npc(npc: NonCombatNPC) -> void:
	if npc.merchant_requested.is_connected(on_npc_merchant_requested):
		return
	npc.merchant_requested.connect(on_npc_merchant_requested)


# -------------------------------------------------
# Entry from NPC
# -------------------------------------------------

func on_npc_merchant_requested(npc: NonCombatNPC, actor: Node) -> void:
	_current_merchant = npc
	_current_buyer = actor
	_current_is_alchemy_merchant = _determine_is_alchemy_merchant(npc)
	_open_menu()

func _determine_is_alchemy_merchant(npc: NonCombatNPC) -> bool:
	if npc == null:
		return false

	if npc.npc_role != "merchant":
		return false

	if npc.merchant_id == &"alchemy":
		return true

	return false


# -------------------------------------------------
# Menu visibility helpers
# -------------------------------------------------

func _open_menu() -> void:
	if _menu == null:
		return

	_menu.visible = true

	if not _was_menu_visible:
		_play_ui_open_close()
	_was_menu_visible = true

	# Name the third tab appropriately.
	if _current_is_alchemy_merchant:
		_menu.set_special_tab_label("Alchemy")
	else:
		_menu.set_special_tab_label("Extra")

	_menu.set_mode(MerchantMenu.Mode.BUY)
	_refresh_for_current_buyer()

func close_menu() -> void:
	if _menu == null:
		return

	if _was_menu_visible:
		_play_ui_open_close()

	_menu.visible = false
	_was_menu_visible = false

	# Let the current merchant revert any interaction animation (e.g. alchemy witch back to brewing).
	if _current_merchant != null and _current_merchant.has_method("reset_interaction_animation"):
		_current_merchant.reset_interaction_animation()

	_current_merchant = null
	_current_buyer = null
	_pending_sell_item = null
	_current_is_alchemy_merchant = false


func _refresh_for_current_buyer() -> void:
	_populate_buy_stock()
	_update_gold_ui()
	_select_first_buy_item()


func _populate_buy_stock() -> void:
	_buy_stock_items.clear()
	_buy_stock_counts_by_index.clear()

	# Base merchant stock from default_buy_stock
	var i: int = 0
	while i < default_buy_stock.size():
		var v: Variant = default_buy_stock[i]
		if v is ItemDef:
			var item: ItemDef = v
			_buy_stock_items.append(item)
		i += 1

	# Add potions unlocked via alchemy to BUY stock, but only for alchemy merchants.
	if _current_is_alchemy_merchant:
		var j: int = 0
		while j < alchemy_unlocks.size():
			var unlock_v: Variant = alchemy_unlocks[j]
			if unlock_v is AlchemyUnlockDef:
				var unlock_def: AlchemyUnlockDef = unlock_v
				if unlock_def != null and unlock_def.is_valid():
					if _is_alchemy_unlocked(unlock_def):
						var potion: ItemDef = unlock_def.potion
						if potion != null:
							var already: bool = false
							var k: int = 0
							while k < _buy_stock_items.size():
								if _buy_stock_items[k] == potion:
									already = true
									break
								k += 1
							if not already:
								_buy_stock_items.append(potion)
			j += 1

	# Initialize stock counts
	i = 0
	while i < _buy_stock_items.size():
		_buy_stock_counts_by_index[i] = 99
		i += 1

	if _menu == null:
		return

	var grid: MerchantGridView = _menu.get_grid()
	if grid != null:
		if _menu.get_mode() == MerchantMenu.Mode.BUY:
			grid.set_sell_drop_enabled(false)
			grid.set_stock(_buy_stock_items)


func _update_gold_ui() -> void:
	if _menu == null:
		return
	if _inv == null:
		_resolve_inventory_autoload()
		if _inv == null:
			return

	var gold: int = _inv.get_currency()
	_menu.set_gold_amount(gold)


func _select_first_buy_item() -> void:
	if _menu == null:
		return

	var grid: MerchantGridView = _menu.get_grid()
	if grid == null:
		return
	if _buy_stock_items.size() <= 0:
		return

	grid.set_selected_index(0)
	_show_buy_item_at_index(0)


func _show_buy_item_at_index(index: int) -> void:
	if _menu == null:
		return
	if index < 0:
		return
	if index >= _buy_stock_items.size():
		return

	var item: ItemDef = _buy_stock_items[index]
	if item == null:
		return

	var player_owned: int = 0
	if _inv == null:
		_resolve_inventory_autoload()
	if _inv != null and _current_buyer != null:
		var bag: InventoryModel = _inv.get_inventory_model_for(_current_buyer)
		player_owned = _count_item_in_bag(bag, item)

	var base_value: int = item.base_gold_value
	if base_value < 1:
		base_value = 1
	var unit_price: int = _calc_buy_price(base_value, _current_buyer)

	_menu.show_item(item, player_owned, unit_price, 1)


# -------------------------------------------------
# SPECIAL / Alchemy helpers
# -------------------------------------------------

func _populate_alchemy_stock() -> void:
	_alchemy_stock_items.clear()
	_alchemy_unlock_by_index.clear()

	var i: int = 0
	while i < alchemy_unlocks.size():
		var v: Variant = alchemy_unlocks[i]
		if v is AlchemyUnlockDef:
			var def: AlchemyUnlockDef = v
			if def != null and def.is_valid():
				var should_add: bool = true
				if def.once_per_party and _is_alchemy_unlocked(def):
					should_add = false

				if should_add and def.potion != null:
					var idx: int = _alchemy_stock_items.size()
					_alchemy_stock_items.append(def.potion)
					_alchemy_unlock_by_index[idx] = def
		i += 1

	if _menu == null:
		return

	var grid: MerchantGridView = _menu.get_grid()
	if grid != null:
		if _menu.get_mode() == MerchantMenu.Mode.SPECIAL:
			grid.set_sell_drop_enabled(false)
			grid.set_stock(_alchemy_stock_items)

func _select_first_alchemy_item() -> void:
	if _menu == null:
		return
	if _alchemy_stock_items.size() <= 0:
		# No recipes available; show a generic message.
		_menu.clear_selection()
		_menu.set_special_prompt("I have no potions to unlock for you right now.")
		return

	var grid: MerchantGridView = _menu.get_grid()
	if grid == null:
		return

	grid.set_selected_index(0)
	_show_alchemy_item_at_index(0)

func _show_alchemy_item_at_index(index: int) -> void:
	if _menu == null:
		return
	if index < 0:
		return
	if index >= _alchemy_stock_items.size():
		return

	if not _alchemy_unlock_by_index.has(index):
		return

	var def_v: Variant = _alchemy_unlock_by_index[index]
	var def: AlchemyUnlockDef = def_v as AlchemyUnlockDef
	if def == null:
		return

	var potion: ItemDef = def.potion
	if potion == null:
		return

	# How many of this potion the player already owns.
	var player_owned: int = 0
	if _inv == null:
		_resolve_inventory_autoload()
	if _inv != null and _current_buyer != null:
		var bag: InventoryModel = _inv.get_inventory_model_for(_current_buyer)
		player_owned = _count_item_in_bag(bag, potion)

	# Price is irrelevant for SPECIAL; cost is reagents only.
	var unit_price: int = 0
	_menu.show_item(potion, player_owned, unit_price, 1)

	var prompt_text: String = _build_alchemy_prompt(def)
	_menu.set_special_prompt(prompt_text)

func _build_alchemy_prompt(def: AlchemyUnlockDef) -> String:
	if def == null:
		return ""

	var lines: Array[String] = []

	var base_line: String = def.get_cost_summary()
	if base_line != "":
		lines.append(base_line)

	if def.unlock_description != "":
		lines.append(def.unlock_description)

	var bag: InventoryModel = null

	if _inv == null:
		_resolve_inventory_autoload()
	if _inv != null and _current_buyer != null:
		bag = _inv.get_inventory_model_for(_current_buyer)

	# Per-reagent “you have X/Y” lines
	if bag != null:
		var pair_count: int = min(def.cost_items.size(), def.cost_counts.size())
		var i: int = 0
		while i < pair_count:
			var reagent: ItemDef = def.cost_items[i]
			var needed: int = def.cost_counts[i]

			if reagent != null and needed > 0:
				var owned: int = _count_item_in_bag(bag, reagent)

				var name_text: String = ""
				if reagent.display_name != "":
					name_text = reagent.display_name
				else:
					name_text = String(reagent.id)

				var line: String = str(owned) + "/" + str(needed) + " " + name_text
				lines.append(line)
			i += 1
	else:
		if base_line == "":
			lines.append("Turn in reagents to unlock this potion.")
		else:
			lines.append("Turn in reagents to unlock this potion.")

	var result: String = ""
	var j: int = 0
	while j < lines.size():
		if j > 0:
			result += "\n"
		result += lines[j]
		j += 1

	return result

func _count_item_in_bag(bag: InventoryModel, item: ItemDef) -> int:
	if bag == null:
		return 0
	if item == null:
		return 0

	var total: int = 0
	var slots: int = bag.slot_count()
	var i: int = 0
	while i < slots:
		var st_v: Variant = bag.get_slot_stack(i)
		if st_v is ItemStack:
			var st: ItemStack = st_v
			if st.item == item:
				total += st.count
		i += 1
	return total

func _find_alchemy_def_for_potion(item: ItemDef) -> AlchemyUnlockDef:
	if item == null:
		return null

	var i: int = 0
	while i < alchemy_unlocks.size():
		var v: Variant = alchemy_unlocks[i]
		if v is AlchemyUnlockDef:
			var def: AlchemyUnlockDef = v
			if def != null and def.potion == item:
				return def
		i += 1

	return null

func _mark_alchemy_unlocked(def: AlchemyUnlockDef) -> void:
	if def == null:
		return
	if def.id == StringName():
		return
	_unlocked_alchemy_ids[def.id] = true

func _is_alchemy_unlocked(def: AlchemyUnlockDef) -> bool:
	if def == null:
		return false
	if def.id == StringName():
		return false
	if not _unlocked_alchemy_ids.has(def.id):
		return false
	var v: Variant = _unlocked_alchemy_ids[def.id]
	if v is bool:
		return bool(v)
	return false


# -------------------------------------------------
# Mode + Grid callbacks
# -------------------------------------------------

func _on_menu_mode_changed(mode: int) -> void:
	if _menu == null:
		return
	var grid: MerchantGridView = _menu.get_grid()
	if grid == null:
		return

	# Tab swap BUY/SELL/SPECIAL uses click.
	_play_ui_click()

	if mode == MerchantMenu.Mode.BUY:
		grid.set_sell_drop_enabled(false)
		_populate_buy_stock()
		_select_first_buy_item()
	elif mode == MerchantMenu.Mode.SELL:
		_pending_sell_item = null
		grid.clear_stock()
		grid.set_sell_drop_enabled(true)
		_menu.clear_selection()
	elif mode == MerchantMenu.Mode.SPECIAL:
		_pending_sell_item = null
		_menu.clear_selection()
		grid.set_sell_drop_enabled(false)

		if _current_is_alchemy_merchant:
			_populate_alchemy_stock()
			_select_first_alchemy_item()
		else:
			_alchemy_stock_items.clear()
			_alchemy_unlock_by_index.clear()
			grid.clear_stock()
			_menu.set_special_prompt("I do not dabble in alchemy.")


func _on_grid_selection_changed(index: int) -> void:
	if _menu == null:
		return
	if not _menu.visible:
		return

	# Normal click feedback for navigating items
	_play_ui_click()

	var mode: int = _menu.get_mode()
	if mode == MerchantMenu.Mode.BUY:
		_show_buy_item_at_index(index)
	elif mode == MerchantMenu.Mode.SPECIAL:
		if _current_is_alchemy_merchant:
			_show_alchemy_item_at_index(index)

func _on_grid_activated(index: int) -> void:
	# Activated usually means “confirm/enter on selection” -> still a click.
	_play_ui_click()
	_on_grid_selection_changed(index)


func _on_grid_sell_payload_dropped(data: Dictionary) -> void:
	# Drag-drop into SELL is a normal UI action -> click.
	_play_ui_click()

	if _menu == null:
		return
	if _menu.get_mode() != MerchantMenu.Mode.SELL:
		_menu.set_mode(MerchantMenu.Mode.SELL)

	if _inv == null:
		_resolve_inventory_autoload()
	if _inv == null:
		return
	if _current_buyer == null:
		return

	var t: String = String(data.get("type", ""))
	if t != "inv_item":
		return
	if not data.has("index"):
		return

	var from_index: int = int(data["index"])

	var bag: InventoryModel = _inv.get_inventory_model_for(_current_buyer)
	if bag == null:
		return

	var total_owned: int = 0
	var item: ItemDef = null

	var slots: int = bag.slot_count()
	var i: int = 0
	while i < slots:
		var st_v: Variant = bag.get_slot_stack(i)
		if st_v is ItemStack:
			var st: ItemStack = st_v
			if st.item != null:
				if item == null and i == from_index:
					item = st.item
				if item != null and st.item == item:
					total_owned += st.count
		i += 1

	if item == null:
		return
	if total_owned <= 0:
		return

	var base_value: int = item.base_gold_value
	if base_value < 1:
		base_value = 1
	var unit_price: int = _calc_sell_price(base_value, _current_buyer)

	_pending_sell_item = item
	_menu.set_mode(MerchantMenu.Mode.SELL)
	_menu.show_item(item, total_owned, unit_price, 1)
	_update_gold_ui()


func _on_menu_transaction_confirmed(mode: int, item: ItemDef, quantity: int, unit_price: int) -> void:
	if item == null:
		return

	# Purchase/Sell confirmations get coins.
	if mode == MerchantMenu.Mode.BUY or mode == MerchantMenu.Mode.SELL:
		_play_ui_coins()

	if mode == MerchantMenu.Mode.BUY:
		_handle_buy_confirm(item, quantity, unit_price)
	elif mode == MerchantMenu.Mode.SELL:
		_handle_sell_confirm(item, quantity, unit_price)
	elif mode == MerchantMenu.Mode.SPECIAL:
		# SPECIAL confirm is not a buy/sell; treat as a normal click.
		_play_ui_click()
		_handle_special_confirm(item, quantity, unit_price)


func _on_menu_transaction_cancelled(mode: int, item: ItemDef, quantity: int, unit_price: int) -> void:
	# Cancel button uses deny.
	_play_ui_deny()


# -------------------------------------------------
# BUY / SELL / SPECIAL logic
# -------------------------------------------------

func _handle_buy_confirm(item: ItemDef, quantity: int, unit_price: int) -> void:
	if _inv == null:
		_resolve_inventory_autoload()
	if _inv == null:
		push_warning("[MerchantController] InventorySystem not found; cannot process purchase.")
		return
	if _current_buyer == null:
		return
	if quantity < 1:
		quantity = 1

	var grid: MerchantGridView = null
	if _menu != null:
		grid = _menu.get_grid()

	var idx: int = -1
	if grid != null:
		idx = grid.get_selected_index()

	var stock_limit: int = -1
	if idx >= 0 and _buy_stock_counts_by_index.has(idx):
		var v_stock: Variant = _buy_stock_counts_by_index[idx]
		if v_stock is int:
			stock_limit = int(v_stock)

	if stock_limit >= 0 and quantity > stock_limit:
		quantity = stock_limit

	if quantity < 1:
		return

	var currency: int = _inv.get_currency()
	if currency <= 0:
		# --- FEEDBACK: no gold at all ---
		if _menu != null:
			_menu.set_special_prompt("You do not have enough gold.")
		return

	if unit_price <= 0:
		unit_price = 1

	var total_cost: int = unit_price * quantity
	if total_cost > currency:
		var max_affordable: int = currency / unit_price
		if max_affordable <= 0:
			# --- FEEDBACK: cannot afford even 1 ---
			if _menu != null:
				_menu.set_special_prompt("You do not have enough gold.")
			return
		quantity = max_affordable
		total_cost = unit_price * quantity

	if quantity < 1:
		return

	var leftover: int = _inv.add_item_for(_current_buyer, item, quantity)
	var added: int = quantity - leftover
	if added <= 0:
		return

	var cost_for_added: int = unit_price * added
	var spent_ok: bool = _inv.try_spend_currency(cost_for_added)
	if not spent_ok:
		var removed: int = _inv.remove_item_for(_current_buyer, item, added)
		push_warning("[MerchantController] Currency changed; could not spend for purchase. Removed %d items." % removed)
		_update_gold_ui()
		return

	if idx >= 0 and stock_limit >= 0:
		var new_stock: int = stock_limit - added
		if new_stock < 0:
			new_stock = 0
		_buy_stock_counts_by_index[idx] = new_stock

	_update_gold_ui()

	if idx >= 0:
		_show_buy_item_at_index(idx)


func _handle_sell_confirm(item: ItemDef, quantity: int, unit_price: int) -> void:
	if _inv == null:
		_resolve_inventory_autoload()
	if _inv == null:
		return
	if _current_buyer == null:
		return
	if item == null:
		return
	if quantity < 1:
		quantity = 1
	if unit_price <= 0:
		unit_price = 1

	var bag: InventoryModel = _inv.get_inventory_model_for(_current_buyer)
	if bag == null:
		return

	var total_owned: int = 0
	var slots: int = bag.slot_count()
	var i: int = 0
	while i < slots:
		var st_v: Variant = bag.get_slot_stack(i)
		if st_v is ItemStack:
			var st: ItemStack = st_v
			if st.item == item:
				total_owned += st.count
		i += 1

	if total_owned <= 0:
		return
	if quantity > total_owned:
		quantity = total_owned

	var removed: int = _inv.remove_item_for(_current_buyer, item, quantity)
	if removed <= 0:
		return

	var gold_gain: int = removed * unit_price
	_inv.give_currency(gold_gain)
	_update_gold_ui()

	total_owned = 0
	i = 0
	while i < slots:
		var st_v2: Variant = bag.get_slot_stack(i)
		if st_v2 is ItemStack:
			var st2: ItemStack = st_v2
			if st2.item == item:
				total_owned += st2.count
		i += 1

	if total_owned > 0:
		_menu.set_mode(MerchantMenu.Mode.SELL)
		_menu.show_item(item, total_owned, unit_price, 1)
	else:
		_pending_sell_item = null
		_menu.clear_selection()


func _handle_special_confirm(item: ItemDef, quantity: int, unit_price: int) -> void:
	if item == null:
		return
	if _menu == null:
		return

	# Always give immediate visual feedback that the button did something.
	_menu.set_special_prompt("Attempting to unlock potion...")

	# Prefer to resolve the AlchemyUnlockDef from the currently selected grid index.
	var def: AlchemyUnlockDef = null
	var grid: MerchantGridView = _menu.get_grid()
	if grid != null:
		var idx: int = grid.get_selected_index()
		if idx >= 0 and _alchemy_unlock_by_index.has(idx):
			var def_v: Variant = _alchemy_unlock_by_index[idx]
			def = def_v as AlchemyUnlockDef

	# Fallback: search by potion resource if index lookup failed.
	if def == null:
		def = _find_alchemy_def_for_potion(item)

	if def == null:
		_menu.set_special_prompt("No matching alchemy recipe definition found for this potion.")
		return

	if def.once_per_party and _is_alchemy_unlocked(def):
		_menu.set_special_prompt("You have already unlocked this potion.")
		return

	if _inv == null:
		_resolve_inventory_autoload()
	if _inv == null:
		_menu.set_special_prompt("I cannot access your inventory right now.")
		return
	if _current_buyer == null:
		_menu.set_special_prompt("No buyer is set for this transaction.")
		return

	var bag: InventoryModel = _inv.get_inventory_model_for(_current_buyer)
	if bag == null:
		_menu.set_special_prompt("I cannot find your inventory bag.")
		return

	# ------------------------------------
	# Check reagents
	# ------------------------------------
	var has_all: bool = true
	var pair_count: int = min(def.cost_items.size(), def.cost_counts.size())
	var i: int = 0
	while i < pair_count:
		var reagent: ItemDef = def.cost_items[i]
		var needed: int = def.cost_counts[i]

		if reagent != null and needed > 0:
			var owned: int = _count_item_in_bag(bag, reagent)
			if owned < needed:
				has_all = false
		i += 1

	if not has_all:
		# Explicit feedback on click: show error + refreshed requirements.
		var requirements_text: String = _build_alchemy_prompt(def)
		var final_text: String = "You do not have enough reagents to unlock this potion."
		if requirements_text != "":
			final_text += "\n\n" + requirements_text
		_menu.set_special_prompt(final_text)
		return

	# ------------------------------------
	# Consume reagents (success case)
	# ------------------------------------
	i = 0
	while i < pair_count:
		var reagent2: ItemDef = def.cost_items[i]
		var needed2: int = def.cost_counts[i]
		if reagent2 != null and needed2 > 0:
			_inv.remove_item_for(_current_buyer, reagent2, needed2)
		i += 1

	_mark_alchemy_unlocked(def)

	# Rebuild SPECIAL list to remove the recipe (if once_per_party).
	_populate_alchemy_stock()
	_select_first_alchemy_item()

	_menu.set_special_prompt("Potion unlocked! You can now purchase it from my wares.")


# -------------------------------------------------
# LCK-based pricing
# -------------------------------------------------

func _get_lck_for(actor: Node) -> float:
	if actor == null:
		return 0.0

	if actor.has_node("StatsComponent"):
		var stats_node: Node = actor.get_node("StatsComponent")
		if stats_node != null and stats_node.has_method("get_final_stat"):
			var v: Variant = stats_node.call("get_final_stat", "LCK")
			if v is float or v is int:
				return float(v)

	return 0.0

func _calc_buy_price(base_value: int, buyer: Node) -> int:
	var lck: float = _get_lck_for(buyer)
	var mult: float = 1.0 - 0.005 * (lck - 10.0)
	if mult < 0.5:
		mult = 0.5
	if mult > 1.25:
		mult = 1.25

	var price_f: float = float(base_value) * mult
	var price_i: int = int(round(price_f))
	if price_i < 1:
		price_i = 1
	return price_i

func _calc_sell_price(base_value: int, buyer: Node) -> int:
	var lck: float = _get_lck_for(buyer)
	var mult: float = 0.5 + 0.0025 * (lck - 10.0)
	if mult < 0.25:
		mult = 0.25
	if mult > 0.9:
		mult = 0.9

	var price_f: float = float(base_value) * mult
	var price_i: int = int(round(price_f))
	if price_i < 1:
		price_i = 1
	return price_i


# -------------------------------------------------
# Close conditions
# -------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _menu == null:
		return
	if not _menu.visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_menu()
		get_viewport().set_input_as_handled()

func _process(delta: float) -> void:
	if _menu == null:
		return
	if not _menu.visible:
		return
	if _current_merchant == null:
		return
	if _current_buyer == null:
		return

	if not _is_actor_in_range():
		close_menu()

func _is_actor_in_range() -> bool:
	var merchant_2d: Node2D = _current_merchant as Node2D
	var actor_2d: Node2D = _current_buyer as Node2D

	if merchant_2d == null or actor_2d == null:
		return true

	var npc_radius: float = 0.0
	if _current_merchant.has_method("get_interact_radius"):
		var r_v: Variant = _current_merchant.call("get_interact_radius")
		if r_v is float or r_v is int:
			npc_radius = float(r_v)

	var base_radius: float = 0.0
	var isys: InteractionSystem = InteractionSys
	if isys != null:
		base_radius = isys.interact_radius

	var r: float = npc_radius
	if base_radius > r:
		r = base_radius
	if r <= 0.0:
		r = 32.0

	var dist: float = merchant_2d.global_position.distance_to(actor_2d.global_position)
	return dist <= r * 1.2


# -------------------------------------------------
# Audio helpers
# -------------------------------------------------

func _resolve_audio_sys() -> void:
	if _audio_checked_once and _audio_obj != null and is_instance_valid(_audio_obj):
		return
	if _audio_checked_once and _audio_obj == null:
		return

	_audio_checked_once = true
	_audio_obj = null

	var root: Node = get_tree().get_root()
	var i: int = 0
	while i < audio_autoload_names.size():
		var nm: String = audio_autoload_names[i]
		var path: String = "/root/" + nm
		if root.has_node(path):
			var obj: Object = root.get_node(path)
			if obj != null:
				_audio_obj = obj
				if debug_log:
					print("[MerchantController] Resolved audio autoload: ", path)
				return
		i += 1

func _play_ui_sound(event_name: StringName, volume_db: float) -> void:
	if event_name == StringName(""):
		return

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		_audio_checked_once = false
		_resolve_audio_sys()

	if _audio_obj == null or not is_instance_valid(_audio_obj):
		return

	if _audio_obj.has_method("play_ui_sfx"):
		_audio_obj.call("play_ui_sfx", event_name, volume_db)
		return

	# Fallback (if some older AudioSystem only exposes play_sfx_event)
	if _audio_obj.has_method("play_sfx_event"):
		_audio_obj.call("play_sfx_event", event_name, Vector2.INF, volume_db)
		return

func _play_ui_open_close() -> void:
	_play_ui_sound(ui_open_close_event, ui_open_close_volume_db)

func _play_ui_click() -> void:
	_play_ui_sound(ui_click_event, ui_click_volume_db)

func _play_ui_coins() -> void:
	_play_ui_sound(ui_coins_event, ui_coins_volume_db)

func _play_ui_deny() -> void:
	_play_ui_sound(ui_deny_event, ui_deny_volume_db)
