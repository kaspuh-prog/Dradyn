extends Control
class_name MerchantController

@export var merchant_menu_scene: PackedScene
@export var default_buy_stock: Array[ItemDef] = []

var _menu: MerchantMenu = null
var _current_merchant: NonCombatNPC = null
var _current_buyer: Node = null

var _inv: InventorySystem = null

var _buy_stock_items: Array[ItemDef] = []
var _buy_stock_counts_by_index: Dictionary = {}   # index -> remaining stock (99 = effectively infinite)

var _pending_sell_item: ItemDef = null


func _ready() -> void:
	add_to_group("merchant_ui")
	set_process(true)

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
	for node in nodes:
		if node is NonCombatNPC:
			_connect_npc(node as NonCombatNPC)

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
	_open_menu()


# -------------------------------------------------
# Menu visibility helpers
# -------------------------------------------------

func _open_menu() -> void:
	if _menu == null:
		return

	_menu.visible = true
	_menu.set_mode(MerchantMenu.Mode.BUY)
	_refresh_for_current_buyer()

func close_menu() -> void:
	if _menu == null:
		return
	_menu.visible = false
	_current_merchant = null
	_current_buyer = null
	_pending_sell_item = null


func _refresh_for_current_buyer() -> void:
	_populate_buy_stock()
	_update_gold_ui()
	_select_first_buy_item()


func _populate_buy_stock() -> void:
	_buy_stock_items.clear()
	_buy_stock_counts_by_index.clear()

	var i: int = 0
	while i < default_buy_stock.size():
		var v: Variant = default_buy_stock[i]
		if v is ItemDef:
			var item: ItemDef = v
			_buy_stock_items.append(item)
		i += 1

	i = 0
	while i < _buy_stock_items.size():
		_buy_stock_counts_by_index[i] = 99
		i += 1

	if _menu == null:
		return

	var grid: MerchantGridView = _menu.get_grid()
	if grid != null:
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

	# SHOW PLAYER'S CURRENT STOCK (not merchant stock)
	var player_owned: int = 0
	if _inv == null:
		_resolve_inventory_autoload()
	if _inv != null and _current_buyer != null:
		var bag: InventoryModel = _inv.get_inventory_model_for(_current_buyer)
		if bag != null:
			var slots: int = bag.slot_count()
			var i: int = 0
			while i < slots:
				var st_v: Variant = bag.get_slot_stack(i)
				if st_v is ItemStack:
					var st: ItemStack = st_v
					if st.item == item:
						player_owned += st.count
				i += 1

	var base_value: int = item.base_gold_value
	if base_value < 1:
		base_value = 1
	var unit_price: int = _calc_buy_price(base_value, _current_buyer)

	_menu.show_item(item, player_owned, unit_price, 1)


# -------------------------------------------------
# Mode + Grid callbacks
# -------------------------------------------------

func _on_menu_mode_changed(mode: int) -> void:
	if _menu == null:
		return
	var grid: MerchantGridView = _menu.get_grid()
	if grid == null:
		return

	if mode == MerchantMenu.Mode.BUY:
		grid.set_sell_drop_enabled(false)
		_populate_buy_stock()
		_select_first_buy_item()
	elif mode == MerchantMenu.Mode.SELL:
		_pending_sell_item = null
		grid.clear_stock()
		grid.set_sell_drop_enabled(true)
		_menu.clear_selection()
	else:
		grid.set_sell_drop_enabled(false)


func _on_grid_selection_changed(index: int) -> void:
	if _menu == null:
		return
	if not _menu.visible:
		return
	if _menu.get_mode() != MerchantMenu.Mode.BUY:
		return
	_show_buy_item_at_index(index)

func _on_grid_activated(index: int) -> void:
	_on_grid_selection_changed(index)


func _on_grid_sell_payload_dropped(data: Dictionary) -> void:
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

	if mode == MerchantMenu.Mode.BUY:
		_handle_buy_confirm(item, quantity, unit_price)
	elif mode == MerchantMenu.Mode.SELL:
		_handle_sell_confirm(item, quantity, unit_price)

func _on_menu_transaction_cancelled(mode: int, item: ItemDef, quantity: int, unit_price: int) -> void:
	pass


# -------------------------------------------------
# BUY / SELL logic
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
		return

	if unit_price <= 0:
		unit_price = 1

	var total_cost: int = unit_price * quantity
	if total_cost > currency:
		var max_affordable: int = currency / unit_price
		if max_affordable <= 0:
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
