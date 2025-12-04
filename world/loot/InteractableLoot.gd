extends Node
class_name InteractableLoot

signal loot_given(total_added: int, total_leftover: int)
signal loot_already_claimed()

@export var one_time: bool = true
@export var disable_after_claim: bool = true
@export var auto_emit_inventory_changed: bool = false
@export var auto_register_group: bool = true
@export var cooldown_seconds: float = 0.0

@export var items: Array[ItemDef] = []
@export var quantities: PackedInt32Array = PackedInt32Array()

# IMPORTANT: default to no group gating. Set this per-instance if desired.
@export var require_player_in_group: StringName = &""
@export var require_not_empty: bool = true

# Optional debug
@export var verbose_debug: bool = false

@export var highlight_modulate: Color = Color(1.1, 1.1, 1.1, 1.0)
@export var highlight_speed: float = 6.0

var _claimed: bool = false
var _cooldown_until: float = 0.0
var _orig_modulate_set: bool = false
var _orig_modulate: Color = Color(1, 1, 1, 1)
var _highlight_on: bool = false

# ---- NEW: generated loot buffer (populated by InteractableChest) ----
var _gen_items: Array[ItemDef] = []
var _gen_quantities: PackedInt32Array = PackedInt32Array()
var _gen_payload_present: bool = false

func is_claimed() -> bool:
	return _claimed

func reset_claimed() -> void:
	_claimed = false
	if disable_after_claim and is_inside_tree():
		set_process(false)
		set_physics_process(false)

func _ready() -> void:
	var target_len: int = items.size()
	if quantities.size() < target_len:
		var i: int = quantities.size()
		while i < target_len:
			quantities.append(1)
			i += 1

	if auto_register_group and not is_in_group("interactable"):
		add_to_group("interactable")

	var vis: Node2D = _find_visual()
	if vis != null:
		_orig_modulate = vis.modulate
		_orig_modulate_set = true

	if disable_after_claim:
		set_process(false)
		set_physics_process(false)
	else:
		set_process(true)

# -----------------------------
# Interaction
# -----------------------------
func interact(actor: Node) -> void:
	if one_time and _claimed:
		if verbose_debug:
			print_debug("[InteractableLoot] Rejected: already claimed")
		loot_already_claimed.emit()
		return

	if cooldown_seconds > 0.0:
		var now: float = float(Time.get_unix_time_from_system())
		if now < _cooldown_until:
			if verbose_debug:
				print_debug("[InteractableLoot] Rejected: cooldown")
			return

	# Actor group guard (only if a group name is set)
	if String(require_player_in_group) != "":
		if actor == null:
			if verbose_debug:
				print_debug("[InteractableLoot] Rejected: actor is null")
			return
		if not actor.is_in_group(String(require_player_in_group)):
			if verbose_debug:
				print_debug("[InteractableLoot] Rejected: actor not in group '%s'" % [String(require_player_in_group)])
			return

	if require_not_empty:
		var any_valid: bool = _has_any_valid_payload()
		if not any_valid:
			if verbose_debug:
				print_debug("[InteractableLoot] Rejected: payload empty/invalid")
			return

	var inv: InventorySystem = _resolve_inventory()
	if inv == null:
		if verbose_debug:
			print_debug("[InteractableLoot] Rejected: InventorySystem not found")
		return

	# Per-actor recipient (controlled first, else the interacting actor)
	var recipient: Node = _get_controlled_actor()
	if recipient == null:
		recipient = actor

	var total_added: int = 0
	var total_leftover: int = 0

	# Grant authored items to the recipient's personal bag
	var i: int = 0
	while i < items.size():
		var def: ItemDef = items[i]
		var qty: int = 1
		if i < quantities.size():
			qty = int(quantities[i])
		if def != null and qty > 0:
			var before: int = qty
			var leftover: int = qty
			if inv.has_method("add_item_for") and recipient != null:
				leftover = int(inv.call("add_item_for", recipient, def, qty))
			else:
				# Fallback to legacy party bag if needed
				leftover = int(inv.call("give_item", def, qty))
			var added: int = before - leftover
			if added > 0:
				total_added += added
			if leftover > 0:
				total_leftover += leftover
		i += 1

	# Grant generated items (once per claim), then clear the buffer
	var j: int = 0
	while j < _gen_items.size():
		var gdef: ItemDef = _gen_items[j]
		var gqty: int = 1
		if j < _gen_quantities.size():
			gqty = int(_gen_quantities[j])
		if gdef != null and gqty > 0:
			var g_before: int = gqty
			var g_leftover: int = gqty
			if inv.has_method("add_item_for") and recipient != null:
				g_leftover = int(inv.call("add_item_for", recipient, gdef, gqty))
			else:
				g_leftover = int(inv.call("give_item", gdef, gqty))
			var g_added: int = g_before - g_leftover
			if g_added > 0:
				total_added += g_added
			if g_leftover > 0:
				total_leftover += g_leftover
		j += 1

	if _gen_payload_present:
		clear_generated_items()

	if total_added > 0:
		if one_time:
			_claimed = true
			if disable_after_claim and is_inside_tree():
				set_process(false)
				set_physics_process(false)
		elif cooldown_seconds > 0.0:
			_cooldown_until = float(Time.get_unix_time_from_system()) + cooldown_seconds

	if auto_emit_inventory_changed and inv.has_signal("inventory_changed"):
		inv.emit_signal("inventory_changed")

	if verbose_debug:
		print_debug("[InteractableLoot] loot_given added=%d leftover=%d → recipient=%s" % [total_added, total_leftover, _safe_actor_name(recipient)])
	loot_given.emit(total_added, total_leftover)

# -----------------------------
# Generated loot API (NEW)
# -----------------------------
## Preferred entry point from InteractableChest:
## accepts Array of { "item_def": ItemDef, "quantity": int }
func set_generated_items(drops: Array[Dictionary]) -> void:
	_gen_items.clear()
	_gen_quantities = PackedInt32Array()
	_gen_payload_present = false

	var i: int = 0
	while i < drops.size():
		var d: Dictionary = drops[i]
		var v_def: Variant = d.get("item_def", null)
		var v_qty: int = int(d.get("quantity", 1))
		if v_def is ItemDef:
			_gen_items.append(v_def)
			if v_qty <= 0:
				v_qty = 1
			_gen_quantities.append(v_qty)
			_gen_payload_present = true
		i += 1

## Back-compat alias if a caller uses the older name
func set_generated_loot(drops: Array[Dictionary]) -> void:
	set_generated_items(drops)

## Convenience: add one generated item
func add_generated_item(item_def: ItemDef, quantity: int) -> void:
	if item_def == null:
		return
	var qty: int = quantity
	if qty <= 0:
		qty = 1
	_gen_items.append(item_def)
	_gen_quantities.append(qty)
	_gen_payload_present = true

## Clear the generated buffer (used after successful claim)
func clear_generated_items() -> void:
	_gen_items.clear()
	_gen_quantities = PackedInt32Array()
	_gen_payload_present = false

# -----------------------------
# Helpers / validation
# -----------------------------
func _has_any_valid_payload() -> bool:
	var i: int = 0
	while i < items.size():
		var def: ItemDef = items[i]
		var qty: int = 1
		if i < quantities.size():
			qty = int(quantities[i])
		if def != null and qty > 0:
			return true
		i += 1

	var j: int = 0
	while j < _gen_items.size():
		var gdef: ItemDef = _gen_items[j]
		var gqty: int = 1
		if j < _gen_quantities.size():
			gqty = int(_gen_quantities[j])
		if gdef != null and gqty > 0:
			return true
		j += 1

	return false

func _resolve_inventory() -> InventorySystem:
	var root: Node = get_tree().get_root()
	if root == null:
		return null
	var n: Node = root.get_node_or_null("InventorySystem")
	if n != null:
		return n as InventorySystem
	n = root.get_node_or_null("InventorySys")
	if n != null:
		return n as InventorySystem
	n = get_node_or_null("/root/InventorySystem")
	if n != null:
		return n as InventorySystem
	return get_node_or_null("/root/InventorySys") as InventorySystem

func _resolve_party() -> Node:
	# Primary autoload name is "Party" in this project; fall back to group.
	var p: Node = get_node_or_null("/root/Party")
	if p != null:
		return p
	return get_tree().get_first_node_in_group("PartyManager")

func _get_controlled_actor() -> Node:
	var p: Node = _resolve_party()
	if p == null:
		return null
	if p.has_method("get_controlled"):
		var v: Variant = p.call("get_controlled")
		return v as Node
	return null

func _safe_actor_name(a: Node) -> String:
	if a == null:
		return "(null)"
	if a.has_method("get_display_name"):
		var v: Variant = a.call("get_display_name")
		return String(v)
	return String(a.name)

# -----------------------------
# Visual highlight
# -----------------------------
func set_interact_highlight(on: bool) -> void:
	_highlight_on = on
	if not _highlight_on:
		_apply_highlight_immediate(false)

func _process(delta: float) -> void:
	if not _highlight_on:
		return
	_apply_highlight_step(delta)

func _apply_highlight_step(delta: float) -> void:
	var vis: Node2D = _find_visual()
	if vis == null:
		return
	if not _orig_modulate_set:
		_orig_modulate = vis.modulate
		_orig_modulate_set = true
	var t: float = clampf(delta * highlight_speed, 0.0, 1.0)
	var blended: Color = vis.modulate.lerp(highlight_modulate, t)
	vis.modulate = blended

func _apply_highlight_immediate(on: bool) -> void:
	var vis: Node2D = _find_visual()
	if vis == null:
		return
	if not _orig_modulate_set:
		_orig_modulate = vis.modulate
		_orig_modulate_set = true
	if on:
		vis.modulate = highlight_modulate
	else:
		vis.modulate = _orig_modulate

func _find_visual() -> Node2D:
	var n2d: Node2D = get_node_or_null("InteractAnchor") as Node2D
	if n2d != null:
		return n2d
	n2d = get_node_or_null("Sprite2D") as Node2D
	if n2d != null:
		return n2d
	var i: int = 0
	while i < get_child_count():
		var c: Node = get_child(i)
		if c is Node2D:
			return c as Node2D
		i += 1
	return null
