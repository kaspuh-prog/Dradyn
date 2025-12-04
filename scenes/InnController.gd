extends Control
class_name InnController

@export var dialogue_box_scene: PackedScene
@export var default_inn_price: int = 25

var _dialogue: DialogueBox = null
var _current_innkeeper: NonCombatNPC = null
var _current_guest: Node = null
var _current_price: int = 0
var _current_is_free: bool = false


func _ready() -> void:
	add_to_group("inn_ui")
	set_process(true)

	_instantiate_dialogue_box()
	_connect_existing_npcs()
	get_tree().node_added.connect(_on_node_added)


# -------------------------------------------------
# Setup helpers
# -------------------------------------------------

func _instantiate_dialogue_box() -> void:
	if dialogue_box_scene == null:
		push_warning("InnController: dialogue_box_scene is not assigned.")
		return

	var inst: Control = dialogue_box_scene.instantiate()
	_dialogue = inst as DialogueBox
	if _dialogue == null:
		push_error("InnController: dialogue_box_scene does not instantiate a DialogueBox.")
		add_child(inst)
		return

	add_child(_dialogue)
	_dialogue.visible = false

	_dialogue.choice_selected.connect(_on_dialog_choice_selected)
	_dialogue.dialogue_closed.connect(_on_dialogue_closed)


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
	if npc.inn_requested.is_connected(_on_npc_inn_requested):
		return
	npc.inn_requested.connect(_on_npc_inn_requested)


# -------------------------------------------------
# Entry from NPC
# -------------------------------------------------

func _on_npc_inn_requested(npc: NonCombatNPC, actor: Node) -> void:
	_current_innkeeper = npc
	_current_guest = actor
	_open_inn_dialog_for_npc(npc)


func _open_inn_dialog_for_npc(npc: NonCombatNPC) -> void:
	if _dialogue == null:
		return

	var price: int = _get_npc_price(npc)
	var is_free: bool = _get_npc_is_free(npc, price)

	_current_price = price
	_current_is_free = is_free

	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = ""

	if is_free or price <= 0:
		text = "Need to rest a while? You can stay here for free."
	else:
		text = "Need to rest a while? It costs " + str(price) + " gold a room."

	var choices: Array[String] = []
	choices.append("Yes")
	choices.append("No")

	var ids: Array[StringName] = []
	ids.append(StringName("yes"))
	ids.append(StringName("no"))

	_dialogue.show_message(text, speaker, choices, ids)


func _get_npc_speaker_name(npc: NonCombatNPC) -> String:
	if npc == null:
		return "Innkeeper"
	if npc.npc_name != "":
		return npc.npc_name
	return "Innkeeper"


func _get_npc_price(npc: NonCombatNPC) -> int:
	var price: int = default_inn_price
	if npc == null:
		return price

	# We assume NonCombatNPC has: @export var inn_price: int = -1
	if "inn_price" in npc:
		var v: Variant = npc.get("inn_price")
		if v is int:
			var npc_price_int: int = int(v)
			if npc_price_int >= 0:
				price = npc_price_int
		elif v is float:
			var npc_price_float: float = float(v)
			if npc_price_float >= 0.0:
				price = int(npc_price_float)

	return price


func _get_npc_is_free(npc: NonCombatNPC, price: int) -> bool:
	if npc == null:
		return false

	# We assume NonCombatNPC has: @export var inn_is_free: bool = false
	if "inn_is_free" in npc:
		var v: Variant = npc.get("inn_is_free")
		if v is bool:
			if bool(v):
				return true

	# Also treat price <= 0 as free, even if inn_is_free is false.
	if price <= 0:
		return true

	return false


func close_menu() -> void:
	if _dialogue != null:
		_dialogue.close_dialogue()
	_reset_state()


func _reset_state() -> void:
	_current_innkeeper = null
	_current_guest = null
	_current_price = 0
	_current_is_free = false


# -------------------------------------------------
# Dialogue callbacks
# -------------------------------------------------

func _on_dialog_choice_selected(index: int, id_value: StringName) -> void:
	var id_str: String = String(id_value)

	if id_str == "yes":
		_show_rest_until_prompt()
	elif id_str == "no":
		close_menu()
	elif id_str == "dusk":
		_try_rest_and_set_time(false)
	elif id_str == "dawn":
		_try_rest_and_set_time(true)
	elif id_str == "ok_insufficient":
		close_menu()
	else:
		close_menu()


func _on_dialogue_closed() -> void:
	_reset_state()


func _show_rest_until_prompt() -> void:
	if _dialogue == null:
		return

	var npc: NonCombatNPC = _current_innkeeper
	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = "Rest until:"

	var choices: Array[String] = []
	choices.append("Dusk")
	choices.append("Dawn")

	var ids: Array[StringName] = []
	ids.append(StringName("dusk"))
	ids.append(StringName("dawn"))

	_dialogue.show_message(text, speaker, choices, ids)


func _show_insufficient_gold_message() -> void:
	if _dialogue == null:
		return

	var npc: NonCombatNPC = _current_innkeeper
	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = "You do not have enough gold."

	var choices: Array[String] = []
	choices.append("OK")

	var ids: Array[StringName] = []
	ids.append(StringName("ok_insufficient"))

	_dialogue.show_message(text, speaker, choices, ids)


# -------------------------------------------------
# Rest logic: pay, fade, heal, cure, set time
# -------------------------------------------------

func _try_rest_and_set_time(to_dawn: bool) -> void:
	var price: int = _current_price
	var is_free: bool = _current_is_free

	var can_pay: bool = true

	if not is_free and price > 0:
		var inv: InventorySystem = InventorySys
		if inv != null:
			can_pay = inv.try_spend_currency(price)
		else:
			can_pay = false

	if not can_pay:
		_show_insufficient_gold_message()
		return

	# Run the actual rest sequence (fade, heal, cure, time jump).
	_run_rest_sequence(to_dawn)


func _run_rest_sequence(to_dawn: bool) -> void:
	var tr: TransitionLayer = Transition
	var dn: Node = DayandNight

	# Fade to black (uses configured fade_out_time).
	if tr != null:
		await tr.fade_to_black()
	else:
		# At least yield once so the UI can update.
		await get_tree().process_frame

	# Stay faded out for ~3 seconds to “sell” the rest.
	var timer: SceneTreeTimer = get_tree().create_timer(3.0)
	await timer.timeout

	# Apply rest effects while the screen is black.
	_apply_rest_effects_to_party()

	# Jump the time of day.
	if dn != null:
		if to_dawn:
			if dn.has_method("rest_until_dawn"):
				dn.call("rest_until_dawn")
		else:
			if dn.has_method("rest_until_dusk"):
				dn.call("rest_until_dusk")

	# Fade back in.
	if tr != null:
		await tr.fade_from_black()

	# Close dialogue and clear state.
	close_menu()


func _apply_rest_effects_to_party() -> void:
	var pm: PartyManager = Party
	if pm == null:
		return

	var members: Array = pm.get_members()
	var i: int = 0
	while i < members.size():
		var actor: Node = members[i]
		if actor != null:
			_restore_actor_stats_and_statuses(actor)
		i += 1


func _restore_actor_stats_and_statuses(actor: Node) -> void:
	if actor == null:
		return

	# --- Stats: HP / MP / END full restore ---
	var stats: StatsComponent = actor.get_node_or_null("StatsComponent") as StatsComponent
	if stats == null:
		var found_stats: Node = actor.find_child("StatsComponent", true, false)
		if found_stats != null and found_stats is StatsComponent:
			stats = found_stats as StatsComponent

	if stats != null:
		var hp_missing: float = stats.max_hp() - stats.current_hp
		if hp_missing > 0.0:
			stats.change_hp(hp_missing)

		var mp_missing: float = stats.max_mp() - stats.current_mp
		if mp_missing > 0.0:
			stats.change_mp(mp_missing)

		var end_missing: float = stats.max_end() - stats.current_end
		if end_missing > 0.0:
			stats.change_end(end_missing)

	# --- StatusConditions: clear dead + all other statuses ---
	var sc: StatusConditions = actor.get_node_or_null("StatusConditions") as StatusConditions
	if sc == null:
		var found_sc: Node = actor.find_child("StatusConditions", true, false)
		if found_sc != null and found_sc is StatusConditions:
			sc = found_sc as StatusConditions

	if sc != null:
		# Clear dead and avoid granting temporary invulnerability (0.0 seconds).
		if sc.has_method("clear_dead_with_invuln"):
			sc.clear_dead_with_invuln(0.0, self, {})

		# Remove all the normal debuff statuses (and invulnerable if present).
		if sc.has_method("remove"):
			var ids: Array[StringName] = []
			ids.append(StatusConditions.BURNING)
			ids.append(StatusConditions.FROZEN)
			ids.append(StatusConditions.POISONED)
			ids.append(StatusConditions.SNARED)
			ids.append(StatusConditions.SLOWED)
			ids.append(StatusConditions.MESMERIZED)
			ids.append(StatusConditions.TRANSFORMED)
			ids.append(StatusConditions.STUNNED)
			ids.append(StatusConditions.CONFUSED)
			ids.append(StatusConditions.BROKEN)
			ids.append(StatusConditions.INVULNERABLE)

			var j: int = 0
			while j < ids.size():
				var sid: StringName = ids[j]
				sc.remove(sid)
				j += 1


# -------------------------------------------------
# Close conditions (Esc / walking away)
# -------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _dialogue == null:
		return
	if not _dialogue.visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_menu()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _dialogue == null:
		return
	if not _dialogue.visible:
		return
	if _current_innkeeper == null:
		return
	if _current_guest == null:
		return

	if not _is_actor_in_range():
		close_menu()


func _is_actor_in_range() -> bool:
	var inn_2d: Node2D = _current_innkeeper as Node2D
	var actor_2d: Node2D = _current_guest as Node2D

	if inn_2d == null or actor_2d == null:
		return true

	var npc_radius: float = 0.0
	if _current_innkeeper.has_method("get_interact_radius"):
		var r_v: Variant = _current_innkeeper.call("get_interact_radius")
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

	var dist: float = inn_2d.global_position.distance_to(actor_2d.global_position)
	var max_dist: float = r * 1.2
	return dist <= max_dist
