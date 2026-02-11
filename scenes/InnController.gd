extends Control
class_name InnController

@export var dialogue_box_scene: PackedScene
@export var default_inn_price: int = 25

# NEW: Save slot picker (SaveSelectScreen.tscn)
@export var save_select_scene: PackedScene

# Inn + Quest option IDs
const _ID_YES: StringName = &"yes"
const _ID_NO: StringName = &"no"
const _ID_DUSK: StringName = &"dusk"
const _ID_DAWN: StringName = &"dawn"
const _ID_OK_INSUFFICIENT: StringName = &"ok_insufficient"

const _ID_QUEST: StringName = &"quest"
const _ID_QUEST_BACK: StringName = &"quest_back"
const _ID_QUEST_TURN_IN: StringName = &"quest_turn_in"

# NEW: Save prompt IDs (after sleeping)
const _ID_SAVE_YES: StringName = &"save_yes"
const _ID_SAVE_NO: StringName = &"save_no"

var _dialogue: DialogueBox = null
var _current_innkeeper: NonCombatNPC = null
var _current_guest: Node = null
var _current_price: int = 0
var _current_is_free: bool = false

# NEW: Used to distinguish the post-rest save prompt from other menus
var _awaiting_save_prompt: bool = false

# NEW: overlay instance (when choosing a slot)
var _save_select: SaveSelectScreen = null

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
	# If slot picker already open, ignore new requests.
	if _save_select != null:
		return

	_current_innkeeper = npc
	_current_guest = actor
	_open_inn_dialog_for_npc(npc)

func _open_inn_dialog_for_npc(npc: NonCombatNPC) -> void:
	if _dialogue == null:
		return

	_awaiting_save_prompt = false

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

	var show_quest: bool = _inn_should_show_quest_option(npc, _current_guest)

	var choices: Array[String] = []
	choices.append("Yes")
	if show_quest:
		choices.append("Quest")
	choices.append("No")

	var ids: Array[StringName] = []
	ids.append(_ID_YES)
	if show_quest:
		ids.append(_ID_QUEST)
	ids.append(_ID_NO)

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
	_awaiting_save_prompt = false

# -------------------------------------------------
# Dialogue callbacks
# -------------------------------------------------

func _on_dialog_choice_selected(_index: int, id_value: StringName) -> void:
	if id_value == _ID_YES:
		_show_rest_until_prompt()
		return

	if id_value == _ID_QUEST:
		_show_quest_prompt()
		return

	if id_value == _ID_QUEST_BACK:
		if _current_innkeeper != null:
			_open_inn_dialog_for_npc(_current_innkeeper)
		else:
			close_menu()
		return

	if id_value == _ID_QUEST_TURN_IN:
		_try_quest_turn_in_or_fallback()
		return

	if id_value == _ID_NO:
		close_menu()
		return

	if id_value == _ID_DUSK:
		_try_rest_and_set_time(false)
		return

	if id_value == _ID_DAWN:
		_try_rest_and_set_time(true)
		return

	if id_value == _ID_OK_INSUFFICIENT:
		close_menu()
		return

	# Save prompt handling
	if id_value == _ID_SAVE_YES:
		# NEW: same as SavePointController — open the slot picker overlay on YES.
		_awaiting_save_prompt = false
		if _dialogue != null:
			_dialogue.close_dialogue()
		_open_save_select_overlay()
		return

	if id_value == _ID_SAVE_NO:
		close_menu()
		return

	close_menu()

func _on_dialogue_closed() -> void:
	_reset_state()

func _show_rest_until_prompt() -> void:
	if _dialogue == null:
		return

	_awaiting_save_prompt = false

	var npc: NonCombatNPC = _current_innkeeper
	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = "Rest until:"

	var choices: Array[String] = []
	choices.append("Dusk")
	choices.append("Dawn")

	var ids: Array[StringName] = []
	ids.append(_ID_DUSK)
	ids.append(_ID_DAWN)

	_dialogue.show_message(text, speaker, choices, ids)

func _show_insufficient_gold_message() -> void:
	if _dialogue == null:
		return

	_awaiting_save_prompt = false

	var npc: NonCombatNPC = _current_innkeeper
	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = "You do not have enough gold."

	var choices: Array[String] = []
	choices.append("OK")

	var ids: Array[StringName] = []
	ids.append(_ID_OK_INSUFFICIENT)

	_dialogue.show_message(text, speaker, choices, ids)

# -------------------------------------------------
# Optional quest helper for innkeepers
# -------------------------------------------------
# (UNCHANGED)
func _inn_should_show_quest_option(npc: NonCombatNPC, actor: Node) -> bool:
	return _find_relevant_quest_def_for_inn(npc, actor) != null

func _show_quest_prompt() -> void:
	if _dialogue == null:
		return

	_awaiting_save_prompt = false

	var npc: NonCombatNPC = _current_innkeeper
	var actor: Node = _current_guest
	if npc == null or actor == null:
		close_menu()
		return

	var def: QuestDef = _find_relevant_quest_def_for_inn(npc, actor)
	if def == null:
		_open_inn_dialog_for_npc(npc)
		return

	var speaker: String = _get_npc_speaker_name(npc)
	var quest_name: String = _quest_display_name(def)

	# Collection quest: show progress; offer turn-in only when ready.
	if def.require_items_any_total > 0 and not def.require_items_any.is_empty():
		var have: int = _count_any_items_in_actor_bag(actor, def.require_items_any)
		var need: int = def.require_items_any_total
		var tokens: Dictionary = _build_quest_tokens(def, have, need)

		if have >= need:
			var text_ready: String = ""
			if def.dialogue_ready_to_turn_in != "":
				text_ready = _apply_tokens(def.dialogue_ready_to_turn_in, tokens)
			else:
				text_ready = quest_name + "\n\n"
				if def.description != "":
					text_ready += def.description + "\n\n"
				text_ready += "Proof collected: " + str(have) + "/" + str(need) + "."

			var choices_ready: Array[String] = []
			choices_ready.append("Turn in")
			choices_ready.append("Back")

			var ids_ready: Array[StringName] = []
			ids_ready.append(_ID_QUEST_TURN_IN)
			ids_ready.append(_ID_QUEST_BACK)

			_dialogue.show_message(text_ready, speaker, choices_ready, ids_ready)
			return

		var text_not_ready: String = ""
		if def.dialogue_not_ready != "":
			text_not_ready = _apply_tokens(def.dialogue_not_ready, tokens)
		else:
			text_not_ready = quest_name + "\n\n"
			if def.description != "":
				text_not_ready += def.description + "\n\n"
			text_not_ready += "Proof collected: " + str(have) + "/" + str(need) + "."

		var choices_not_ready: Array[String] = []
		choices_not_ready.append("Back")

		var ids_not_ready: Array[StringName] = []
		ids_not_ready.append(_ID_QUEST_BACK)

		_dialogue.show_message(text_not_ready, speaker, choices_not_ready, ids_not_ready)
		return

	# Non-collection quest: show offer/info text.
	var tokens2: Dictionary = _build_quest_tokens(def, 0, 0)
	var text2: String = ""
	if def.dialogue_offer != "":
		text2 = _apply_tokens(def.dialogue_offer, tokens2)
	else:
		text2 = quest_name + "\n\n"
		if def.description != "":
			text2 += def.description
		else:
			text2 += "..."

	var choices2: Array[String] = []
	choices2.append("Back")

	var ids2: Array[StringName] = []
	ids2.append(_ID_QUEST_BACK)

	_dialogue.show_message(text2, speaker, choices2, ids2)

func _try_quest_turn_in_or_fallback() -> void:
	var npc: NonCombatNPC = _current_innkeeper
	var actor: Node = _current_guest
	if npc == null or actor == null:
		close_menu()
		return

	var def: QuestDef = _find_relevant_quest_def_for_inn(npc, actor)
	if def == null:
		_open_inn_dialog_for_npc(npc)
		return

	# Only collection quests support immediate turn-in from this menu.
	if def.require_items_any_total > 0 and not def.require_items_any.is_empty():
		var have: int = _count_any_items_in_actor_bag(actor, def.require_items_any)
		var need: int = def.require_items_any_total
		if have < need:
			_show_quest_prompt()
			return

		# Hand off to QuestSys for actual completion (consume items, rewards, flags, story advance).
		var giver_id: StringName = npc.quest_giver_id
		close_menu()
		npc.emit_signal("quest_requested", npc, actor, giver_id)
		return

	_show_quest_prompt()

func _find_relevant_quest_def_for_inn(npc: NonCombatNPC, _actor: Node) -> QuestDef:
	if npc == null:
		return null

	var cfg: QuestGiverConfig = _find_quest_giver_config(npc)
	if cfg == null:
		return null
	if not cfg.enabled:
		return null

	var giver_id: StringName = npc.quest_giver_id
	var defs: Array[QuestDef] = cfg.get_quests()

	var i: int = 0
	while i < defs.size():
		var def: QuestDef = defs[i]
		if _is_def_relevant_for_inn(def, giver_id):
			return def
		i += 1

	return null

func _is_def_relevant_for_inn(def: QuestDef, giver_id: StringName) -> bool:
	if def == null:
		return false

	# Optional giver validation
	if def.giver_id != &"" and def.giver_id != giver_id:
		return false

	var story: StoryStateSystem = StoryStateSys as StoryStateSystem
	if story == null:
		return false

	# Hide if already complete via internal completion flag (QuestSys-managed).
	if def.quest_id != &"":
		if story.has_flag(_complete_flag_for(def.quest_id)):
			return false

	# Story position requirement
	if def.require_story_position:
		if story.get_current_act_id() != def.require_act_id:
			return false
		if story.get_current_step_id() != def.require_step_id:
			return false
		if story.get_current_part_id() != def.require_part_id:
			return false

	# Flag requirements
	var j: int = 0
	while j < def.require_flags_all.size():
		var f: StringName = def.require_flags_all[j]
		if f != &"":
			if not story.has_flag(f):
				return false
		j += 1

	j = 0
	while j < def.require_flags_none.size():
		var f2: StringName = def.require_flags_none[j]
		if f2 != &"":
			if story.has_flag(f2):
				return false
		j += 1

	# Previous quest gating (mapped to internal completion flags).
	j = 0
	while j < def.require_quests_complete.size():
		var qid: StringName = def.require_quests_complete[j]
		if qid != &"":
			if not story.has_flag(_complete_flag_for(qid)):
				return false
		j += 1

	j = 0
	while j < def.forbid_quests_complete.size():
		var qid2: StringName = def.forbid_quests_complete[j]
		if qid2 != &"":
			if story.has_flag(_complete_flag_for(qid2)):
				return false
		j += 1

	# Inventory readiness is NOT required just to show the quest option.
	return true

func _find_quest_giver_config(npc: NonCombatNPC) -> QuestGiverConfig:
	if npc == null:
		return null

	var q: Array[Node] = []
	q.append(npc)

	while q.size() > 0:
		var node: Node = q.pop_back()
		if node != null:
			var cfg: QuestGiverConfig = node as QuestGiverConfig
			if cfg != null and cfg != npc:
				return cfg

			var children: Array[Node] = node.get_children()
			for c in children:
				q.append(c)

	return null

func _quest_display_name(def: QuestDef) -> String:
	if def == null:
		return "Quest"
	if def.display_name != "":
		return def.display_name
	if def.quest_id != &"":
		return String(def.quest_id)
	return "Quest"

func _build_quest_tokens(def: QuestDef, have: int, need: int) -> Dictionary:
	var tokens: Dictionary = {}
	tokens["quest_name"] = _quest_display_name(def)
	tokens["have"] = str(have)
	tokens["need"] = str(need)
	tokens["xp"] = str(def.reward_xp)
	tokens["gold"] = str(def.reward_gold)
	return tokens

func _apply_tokens(text: String, tokens: Dictionary) -> String:
	var out: String = text
	for k in tokens.keys():
		var key_str: String = str(k)
		var token: String = "{" + key_str + "}"
		var val: String = str(tokens[k])
		out = out.replace(token, val)
	return out

func _count_any_items_in_actor_bag(actor: Node, item_ids: Array[StringName]) -> int:
	if actor == null:
		return 0
	if item_ids.is_empty():
		return 0

	var inv: InventorySystem = InventorySys as InventorySystem
	if inv == null:
		return 0

	var bag: InventoryModel = inv.get_inventory_model_for(actor)
	if bag == null:
		bag = inv.ensure_inventory_model_for(actor)
	if bag == null:
		return 0

	var total: int = 0
	var i: int = 0
	var slots: int = bag.slot_count()
	while i < slots:
		var st: ItemStack = bag.get_slot_stack(i)
		if st != null and st.item != null:
			if item_ids.has(st.item.id):
				if st.count > 0:
					total += st.count
		i += 1

	return total

func _complete_flag_for(quest_id: StringName) -> StringName:
	return StringName("quest_" + String(quest_id) + "_complete")

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

	# After sleeping, offer to save.
	_show_save_prompt_after_rest()

func _show_save_prompt_after_rest() -> void:
	if _dialogue == null:
		close_menu()
		return

	_awaiting_save_prompt = true

	var npc: NonCombatNPC = _current_innkeeper
	var speaker: String = _get_npc_speaker_name(npc)
	var text: String = "Save your game?"

	var choices: Array[String] = []
	choices.append("Yes")
	choices.append("No")

	var ids: Array[StringName] = []
	ids.append(_ID_SAVE_YES)
	ids.append(_ID_SAVE_NO)

	_dialogue.show_message(text, speaker, choices, ids)

# --------------------------------------------------------------------
# NEW: Slot picker overlay (SAVE intent)
# --------------------------------------------------------------------
func _open_save_select_overlay() -> void:
	if _save_select != null:
		return

	if save_select_scene == null:
		push_warning("[InnController] save_select_scene not assigned; cannot open slot picker.")
		close_menu()
		return

	var inst: Node = save_select_scene.instantiate()
	var s: SaveSelectScreen = inst as SaveSelectScreen
	if s == null:
		push_error("[InnController] save_select_scene does not instantiate SaveSelectScreen.")
		add_child(inst)
		close_menu()
		return

	# IMPORTANT: Configure BEFORE add_child so _ready builds in SAVE intent.
	s.intent = SaveSelectScreen.SaveSelectIntent.SAVE
	s.overlay_mode = true
	s.close_after_action = true

	_save_select = s
	add_child(_save_select)

	if not _save_select.close_requested.is_connected(_on_save_select_closed):
		_save_select.close_requested.connect(_on_save_select_closed)

	if not _save_select.slot_action_completed.is_connected(_on_save_select_action_completed):
		_save_select.slot_action_completed.connect(_on_save_select_action_completed)

func _on_save_select_action_completed(intent_value: int, slot_index: int) -> void:
	# SaveSelectScreen performs the save internally.
	if intent_value == int(SaveSelectScreen.SaveSelectIntent.SAVE):
		# Optional: toast later.
		pass

func _on_save_select_closed() -> void:
	_save_select = null
	# Don’t re-open the inn menu; just clear state.
	_reset_state()

# --------------------------------------------------------------------
# Legacy direct-save code preserved (shim) — no longer used.
# --------------------------------------------------------------------
func _try_save_after_rest() -> void:
	_awaiting_save_prompt = false

	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		push_warning("[InnController] SaveSys not found; cannot save.")
		return

	var slot_index: int = save_sys.get_current_slot()
	if slot_index < 1:
		slot_index = save_sys.get_last_played_slot()
	if slot_index < 1:
		slot_index = 1

	var payload: Dictionary = _build_basic_save_payload(slot_index)
	if payload.is_empty():
		push_warning("[InnController] Save payload was empty; skipping save.")
		return

	save_sys.save_to_slot(slot_index, payload)

func _build_basic_save_payload(slot_index: int) -> Dictionary:
	var payload: Dictionary = {}

	var area_path: String = ""
	var entry_tag: String = "default"

	var sm: SceneManager = get_node_or_null("/root/SceneMgr") as SceneManager
	if sm != null:
		var area_node: Node = sm.get_current_area()
		if area_node != null:
			area_path = area_node.scene_file_path

	if area_path == "":
		# Fallback to BootArea start config so Continue still works.
		var boot: BootArea = get_tree().root.find_child("BootArea", true, false) as BootArea
		if boot != null:
			area_path = boot.start_area
			entry_tag = boot.start_entry_tag

	if area_path == "":
		return {}

	payload["version"] = 1
	payload["slot_index"] = slot_index
	payload["area_path"] = area_path
	payload["entry_tag"] = entry_tag

	# Player name: use controlled party member name when possible.
	var pm: PartyManager = Party as PartyManager
	var player_name: String = "Unknown"
	if pm != null:
		var controlled: Node = pm.get_controlled()
		if controlled != null:
			if controlled.has_method("get_name"):
				player_name = str(controlled.get_name())
			else:
				player_name = str(controlled.name)
	payload["player_name"] = player_name

	payload["play_time_sec"] = 0

	# Story: include state so cutscenes/quests persist.
	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story != null:
		payload["story_state"] = story.get_save_state()

	return payload

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
	# If the slot picker is open, let it handle cancel.
	if _save_select != null:
		return

	if _dialogue == null:
		return
	if not _dialogue.visible:
		return

	if event.is_action_pressed("ui_cancel"):
		close_menu()
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	# If slot picker is open, don’t auto-close.
	if _save_select != null:
		return

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
