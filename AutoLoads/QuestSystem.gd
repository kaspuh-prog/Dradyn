extends CanvasLayer
class_name QuestSystem
# Godot 4.5 — fully typed, no ternaries.
# Autoload name should be: QuestSys (script name QuestSystem.gd is fine).
#
# Responsibilities:
#  - Provide should_route_to_quest(npc, actor, quest_giver_id) for NonCombatNPC quest override routing.
#  - Listen for NonCombatNPC.quest_requested and drive a simple quest interaction UI.
#  - Evaluate QuestDef gates and process completion (consume items, grant XP/currency/items, set/clear flags, advance story).
#
# NOTE: Reward popup UI is intentionally NOT owned here; we emit quest_rewards_granted so HUD/UI can display it.

signal quest_rewards_granted(def: QuestDef, rewards: Dictionary)

@export_group("UI")
@export var dialogue_box_scene: PackedScene = preload("res://scenes/ui/DialogueBox.tscn")

@export_group("Items")
@export var item_def_scan_roots: PackedStringArray = PackedStringArray(["res://Data/items"])

@export_group("Debug")
@export var debug_prints: bool = false

const _CHOICE_TURN_IN: StringName = &"quest_turn_in"
const _CHOICE_ACCEPT: StringName = &"quest_accept"
const _CHOICE_OK: StringName = &"quest_ok"
const _CHOICE_CANCEL: StringName = &"quest_cancel"

var _dialogue: DialogueBox = null
var _current_npc: NonCombatNPC = null
var _current_actor: Node = null
var _current_giver_id: StringName = &""
var _current_def: QuestDef = null

var _item_def_cache: Dictionary = {} # Dictionary[StringName, ItemDef]
var _item_def_cache_built: bool = false


func _ready() -> void:
	layer = 60
	add_to_group("quest_ui")
	set_process(true)

	_instantiate_dialogue_box()
	_connect_existing_npcs()
	get_tree().node_added.connect(_on_node_added)


# -------------------------------------------------
# Public API used by NonCombatNPC quest override
# -------------------------------------------------
func should_route_to_quest(npc: NonCombatNPC, actor: Node, quest_giver_id: StringName) -> bool:
	var giver: StringName = quest_giver_id
	if giver == &"" and npc != null:
		giver = npc.quest_giver_id

	var def: QuestDef = _get_actionable_quest_def(npc, actor, giver)
	return def != null


# -------------------------------------------------
# Setup / wiring
# -------------------------------------------------
func _instantiate_dialogue_box() -> void:
	if dialogue_box_scene == null:
		push_warning("QuestSystem: dialogue_box_scene is not assigned.")
		return

	var inst: Control = dialogue_box_scene.instantiate()
	_dialogue = inst as DialogueBox
	if _dialogue == null:
		push_error("QuestSystem: dialogue_box_scene does not instantiate a DialogueBox.")
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
		var npc: NonCombatNPC = node as NonCombatNPC
		if npc != null:
			_connect_npc(npc)
		i += 1


func _on_node_added(node: Node) -> void:
	var npc: NonCombatNPC = node as NonCombatNPC
	if npc != null:
		_connect_npc(npc)


func _connect_npc(npc: NonCombatNPC) -> void:
	if npc.quest_requested.is_connected(_on_npc_quest_requested):
		return
	npc.quest_requested.connect(_on_npc_quest_requested)


# -------------------------------------------------
# Entry from NPC
# -------------------------------------------------
func _on_npc_quest_requested(npc: NonCombatNPC, actor: Node, quest_giver_id: StringName) -> void:
	_current_npc = npc
	_current_actor = actor
	_current_giver_id = quest_giver_id

	var def: QuestDef = _get_actionable_quest_def(npc, actor, quest_giver_id)
	if def == null:
		_reset_state()
		return

	_current_def = def
	_open_quest_dialogue(npc, actor, def)


func _open_quest_dialogue(npc: NonCombatNPC, actor: Node, def: QuestDef) -> void:
	if _dialogue == null:
		_reset_state()
		return

	var speaker: String = ""
	if npc != null:
		speaker = npc.npc_name

	var quest_name: String = _quest_display_name(def)

	# Collection / turn-in quest
	if def.require_items_any_total > 0 and not def.require_items_any.is_empty():
		var have: int = _count_any_items_in_actor_bag(actor, def.require_items_any)
		var need: int = def.require_items_any_total

		var tokens: Dictionary = _build_tokens(def, have, need)

		var text: String = ""
		if def.dialogue_ready_to_turn_in != "":
			text = _apply_tokens(def.dialogue_ready_to_turn_in, tokens)
		else:
			text = quest_name + "\n\n"
			if def.description != "":
				text += def.description + "\n\n"
			text += "Proof collected: " + str(have) + "/" + str(need) + "."

		var choices: Array[String] = []
		choices.append("Turn in")
		choices.append("Not yet")

		var ids: Array[StringName] = []
		ids.append(_CHOICE_TURN_IN)
		ids.append(_CHOICE_CANCEL)

		_dialogue.show_message(text, speaker, choices, ids)
		return

	# Non-collection quests (offer / talk)
	var text2: String = ""
	if def.dialogue_offer != "":
		var tokens2: Dictionary = _build_tokens(def, 0, 0)
		text2 = _apply_tokens(def.dialogue_offer, tokens2)
	else:
		text2 = quest_name + "\n\n"
		if def.description != "":
			text2 += def.description
		else:
			text2 += "..."

	var choices2: Array[String] = []
	var ids2: Array[StringName] = []

	if _can_accept(def):
		choices2.append("Accept")
		ids2.append(_CHOICE_ACCEPT)

	choices2.append("Okay")
	ids2.append(_CHOICE_OK)

	_dialogue.show_message(text2, speaker, choices2, ids2)


# -------------------------------------------------
# Dialogue callbacks
# -------------------------------------------------
func _on_dialog_choice_selected(_index: int, id_value: StringName) -> void:
	if id_value == _CHOICE_TURN_IN:
		_try_complete_current_quest()
		return

	if id_value == _CHOICE_ACCEPT:
		_accept_current_quest()
		return

	if id_value == _CHOICE_OK:
		close_dialogue()
		return

	if id_value == _CHOICE_CANCEL:
		close_dialogue()
		return

	close_dialogue()


func _on_dialogue_closed() -> void:
	_reset_state()


func close_dialogue() -> void:
	if _dialogue != null:
		_dialogue.close_dialogue()
	_reset_state()


func _reset_state() -> void:
	_current_npc = null
	_current_actor = null
	_current_giver_id = &""
	_current_def = null


# -------------------------------------------------
# Quest selection / gating
# -------------------------------------------------
func _get_actionable_quest_def(npc: NonCombatNPC, actor: Node, giver_id: StringName) -> QuestDef:
	if npc == null:
		return null

	var cfg: QuestGiverConfig = _find_quest_giver_config(npc)
	if cfg == null:
		return null
	if not cfg.enabled:
		return null

	var defs: Array[QuestDef] = cfg.get_quests()
	var i: int = 0
	while i < defs.size():
		var def: QuestDef = defs[i]
		if _is_def_actionable(def, npc, actor, giver_id):
			return def
		i += 1

	return null


func _is_def_actionable(def: QuestDef, _npc: NonCombatNPC, actor: Node, giver_id: StringName) -> bool:
	if def == null:
		return false

	# Optional giver check
	if def.giver_id != &"" and def.giver_id != giver_id:
		return false

	var story: StoryStateSystem = StoryStateSys as StoryStateSystem
	if story == null:
		return false

	# Internal completion gate (optional; only if quest_id is set)
	if def.quest_id != &"":
		var complete_flag: StringName = _complete_flag_for(def.quest_id)
		if story.has_flag(complete_flag):
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
		if f != &"" and not story.has_flag(f):
			return false
		j += 1

	j = 0
	while j < def.require_flags_none.size():
		var f2: StringName = def.require_flags_none[j]
		if f2 != &"" and story.has_flag(f2):
			return false
		j += 1

	# Previous quest requirements (mapped to internal completion flags)
	j = 0
	while j < def.require_quests_complete.size():
		var qid: StringName = def.require_quests_complete[j]
		if qid != &"" and not story.has_flag(_complete_flag_for(qid)):
			return false
		j += 1

	j = 0
	while j < def.forbid_quests_complete.size():
		var qid2: StringName = def.forbid_quests_complete[j]
		if qid2 != &"" and story.has_flag(_complete_flag_for(qid2)):
			return false
		j += 1

	# Collection/turn-in style quests: only route when ready to turn in.
	if def.require_items_any_total > 0 and not def.require_items_any.is_empty():
		var have: int = _count_any_items_in_actor_bag(actor, def.require_items_any)
		if have < def.require_items_any_total:
			return false
		return true

	# Otherwise: actionable when gates pass.
	return true


func _can_accept(def: QuestDef) -> bool:
	if def == null:
		return false
	if def.quest_id == &"":
		return false

	var story: StoryStateSystem = StoryStateSys as StoryStateSystem
	if story == null:
		return false

	var active_flag: StringName = _active_flag_for(def.quest_id)
	var complete_flag: StringName = _complete_flag_for(def.quest_id)

	if story.has_flag(complete_flag):
		return false
	if story.has_flag(active_flag):
		return false

	return true


# -------------------------------------------------
# Accept / complete
# -------------------------------------------------
func _accept_current_quest() -> void:
	var def: QuestDef = _current_def
	if def == null:
		close_dialogue()
		return
	if def.quest_id == &"":
		close_dialogue()
		return

	var story: StoryStateSystem = StoryStateSys as StoryStateSystem
	if story == null:
		close_dialogue()
		return

	story.set_flag(_active_flag_for(def.quest_id), true)

	if _dialogue == null:
		close_dialogue()
		return

	var speaker: String = ""
	if _current_npc != null:
		speaker = _current_npc.npc_name

	var quest_name: String = _quest_display_name(def)
	var text: String = "Quest accepted: " + quest_name

	var choices: Array[String] = ["Okay"]
	var ids: Array[StringName] = [_CHOICE_OK]
	_dialogue.show_message(text, speaker, choices, ids)


func _try_complete_current_quest() -> void:
	var def: QuestDef = _current_def
	var npc: NonCombatNPC = _current_npc
	var actor: Node = _current_actor

	if def == null or npc == null or actor == null:
		close_dialogue()
		return

	var need: int = def.require_items_any_total
	var have: int = 0
	if need > 0 and not def.require_items_any.is_empty():
		have = _count_any_items_in_actor_bag(actor, def.require_items_any)
		if have < need:
			_show_not_ready(def, npc, have, need)
			return

	# Consume items
	if def.consume_items_on_complete and need > 0 and not def.require_items_any.is_empty():
		var to_consume: int = def.effective_consume_any_total()
		if to_consume <= 0:
			to_consume = need
		var removed: int = _remove_any_items_total_from_actor_bag(actor, def.require_items_any, to_consume)
		if removed < to_consume:
			_show_not_ready(def, npc, have, need)
			return

	# Rewards
	var rewards: Dictionary = {}
	rewards["xp"] = def.reward_xp
	rewards["gold"] = def.reward_gold
	rewards["items"] = def.get_reward_items_map()

	if def.reward_xp > 0:
		_grant_xp_to_actor(actor, def.reward_xp)

	if def.reward_gold > 0:
		var inv: InventorySystem = InventorySys as InventorySystem
		if inv != null:
			inv.add_currency(def.reward_gold)

	_grant_reward_items(def, actor)

	# Flags + story advance
	var story: StoryStateSystem = StoryStateSys as StoryStateSystem
	if story != null:
		var i: int = 0
		while i < def.set_flags_on_complete.size():
			var f: StringName = def.set_flags_on_complete[i]
			if f != &"":
				story.set_flag(f, true)
			i += 1

		i = 0
		while i < def.clear_flags_on_complete.size():
			var f2: StringName = def.clear_flags_on_complete[i]
			if f2 != &"":
				story.set_flag(f2, false)
			i += 1

		# Internal completion flags (optional)
		if def.quest_id != &"":
			story.set_flag(_complete_flag_for(def.quest_id), true)
			story.set_flag(_active_flag_for(def.quest_id), false)

		if def.advance_story_position_on_complete:
			story.set_current_story_position(def.advance_act_id, def.advance_step_id, def.advance_part_id)

	quest_rewards_granted.emit(def, rewards)
	_show_completed(def, npc, have, need)


func _show_not_ready(def: QuestDef, npc: NonCombatNPC, have: int, need: int) -> void:
	if _dialogue == null:
		close_dialogue()
		return

	var speaker: String = npc.npc_name
	var tokens: Dictionary = _build_tokens(def, have, need)

	var quest_name: String = _quest_display_name(def)
	var text: String = ""
	if def.dialogue_not_ready != "":
		text = _apply_tokens(def.dialogue_not_ready, tokens)
	else:
		text = quest_name + "\n\nYou don't have enough yet.\nProof collected: " + str(have) + "/" + str(need) + "."

	var choices: Array[String] = ["Okay"]
	var ids: Array[StringName] = [_CHOICE_OK]
	_dialogue.show_message(text, speaker, choices, ids)


func _show_completed(def: QuestDef, npc: NonCombatNPC, have: int, need: int) -> void:
	if _dialogue == null:
		close_dialogue()
		return

	var speaker: String = npc.npc_name
	var tokens: Dictionary = _build_tokens(def, have, need)

	var quest_name: String = _quest_display_name(def)
	var text: String = ""
	if def.dialogue_completed != "":
		text = _apply_tokens(def.dialogue_completed, tokens)
	else:
		text = "Quest completed: " + quest_name

		var rewards_line: String = _build_rewards_line(def)
		if rewards_line != "":
			text += "\n\nRewards: " + rewards_line

	var choices: Array[String] = ["Okay"]
	var ids: Array[StringName] = [_CHOICE_OK]
	_dialogue.show_message(text, speaker, choices, ids)


# -------------------------------------------------
# Dialogue token helpers
# -------------------------------------------------
func _quest_display_name(def: QuestDef) -> String:
	if def == null:
		return ""
	if def.display_name != "":
		return def.display_name
	if def.quest_id != &"":
		return String(def.quest_id)
	return "Quest"


func _build_tokens(def: QuestDef, have: int, need: int) -> Dictionary:
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


func _build_rewards_line(def: QuestDef) -> String:
	if def == null:
		return ""

	var parts: Array[String] = []

	if def.reward_xp > 0:
		parts.append(str(def.reward_xp) + " XP")
	if def.reward_gold > 0:
		parts.append(str(def.reward_gold) + " gold")

	var reward_items: Dictionary = def.get_reward_items_map()
	if not reward_items.is_empty():
		parts.append("items")

	var out: String = ""
	var i: int = 0
	while i < parts.size():
		if out != "":
			out += ", "
		out += parts[i]
		i += 1

	return out


# -------------------------------------------------
# Inventory helpers (per-actor bag)
# -------------------------------------------------
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
		if st != null and st.item != null and item_ids.has(st.item.id):
			if st.count > 0:
				total += st.count
		i += 1

	return total


func _remove_any_items_total_from_actor_bag(actor: Node, item_ids: Array[StringName], amount: int) -> int:
	if actor == null:
		return 0
	if item_ids.is_empty():
		return 0
	if amount <= 0:
		return 0

	var inv: InventorySystem = InventorySys as InventorySystem
	if inv == null:
		return 0

	var bag: InventoryModel = inv.get_inventory_model_for(actor)
	if bag == null:
		bag = inv.ensure_inventory_model_for(actor)
	if bag == null:
		return 0

	var remaining: int = amount
	var removed_total: int = 0

	var i: int = 0
	var slots: int = bag.slot_count()
	while i < slots and remaining > 0:
		var st: ItemStack = bag.get_slot_stack(i)
		if st != null and st.item != null and item_ids.has(st.item.id):
			if st.count > 0:
				var take: int = remaining
				if take > st.count:
					take = st.count
				var removed_here: int = bag.remove_amount(i, take)
				if removed_here > 0:
					removed_total += removed_here
					remaining -= removed_here
		i += 1

	return removed_total


# -------------------------------------------------
# Reward helpers
# -------------------------------------------------
func _grant_xp_to_actor(actor: Node, amount: int) -> void:
	if actor == null:
		return
	if amount <= 0:
		return

	var level_node: Node = _find_level_component(actor)
	if level_node != null and level_node.has_method("add_xp"):
		level_node.call("add_xp", amount)


func _find_level_component(root: Node) -> Node:
	if root == null:
		return null

	var direct: Node = root.get_node_or_null("LevelComponent")
	if direct != null:
		return direct

	var found: Node = root.find_child("LevelComponent", true, false)
	if found != null:
		return found

	var q: Array[Node] = []
	q.append(root)
	while q.size() > 0:
		var node: Node = q.pop_back()
		if node != null and node != root and node.has_method("add_xp"):
			return node
		if node != null:
			var children: Array[Node] = node.get_children()
			for c in children:
				q.append(c)

	return null


func _grant_reward_items(def: QuestDef, actor: Node) -> void:
	if def == null:
		return
	if actor == null:
		return

	var rewards: Dictionary = def.get_reward_items_map()
	if rewards.is_empty():
		return

	var inv: InventorySystem = InventorySys as InventorySystem
	if inv == null:
		return

	for k in rewards.keys():
		var item_id: StringName = k as StringName
		var count_any: Variant = rewards[k]
		var count: int = 0
		if typeof(count_any) == TYPE_INT:
			count = int(count_any)
		if count <= 0:
			continue

		var item_def: ItemDef = _resolve_item_def(item_id)
		if item_def == null:
			if debug_prints:
				push_warning("QuestSystem: could not resolve ItemDef for id: " + String(item_id))
			continue

		inv.add_item_for(actor, item_def, count)


func _resolve_item_def(item_id: StringName) -> ItemDef:
	if item_id == &"":
		return null

	_ensure_item_def_cache()

	if _item_def_cache.has(item_id):
		var v: Variant = _item_def_cache[item_id]
		return v as ItemDef

	return null


func _ensure_item_def_cache() -> void:
	if _item_def_cache_built:
		return

	_item_def_cache_built = true
	_item_def_cache.clear()

	var i: int = 0
	while i < item_def_scan_roots.size():
		var root: String = String(item_def_scan_roots[i])
		if root != "":
			_scan_item_defs_recursive(root)
		i += 1


func _scan_item_defs_recursive(path: String) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue

		var full_path: String = path.path_join(name)

		if dir.current_is_dir():
			_scan_item_defs_recursive(full_path)
		else:
			if name.to_lower().ends_with(".tres"):
				var res: Resource = ResourceLoader.load(full_path)
				var item_def: ItemDef = res as ItemDef
				if item_def != null:
					var id: StringName = item_def.id
					if id != &"" and not _item_def_cache.has(id):
						_item_def_cache[id] = item_def

		name = dir.get_next()

	dir.list_dir_end()


# -------------------------------------------------
# Internal flags
# -------------------------------------------------
func _active_flag_for(quest_id: StringName) -> StringName:
	return StringName("quest_" + String(quest_id) + "_active")


func _complete_flag_for(quest_id: StringName) -> StringName:
	return StringName("quest_" + String(quest_id) + "_complete")


# -------------------------------------------------
# Range / cancel handling
# -------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _dialogue != null and _dialogue.visible:
			close_dialogue()
			get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if _current_npc == null:
		return
	if _current_actor == null:
		return
	if _dialogue == null:
		return
	if not _dialogue.visible:
		return

	if not _is_actor_in_range(_current_actor, _current_npc):
		close_dialogue()


func _is_actor_in_range(actor: Node, npc: NonCombatNPC) -> bool:
	if actor == null or npc == null:
		return false

	var actor_2d: Node2D = actor as Node2D
	var npc_2d: Node2D = npc as Node2D
	if actor_2d == null or npc_2d == null:
		return false

	var npc_radius: float = npc.get_interact_radius()

	var base_radius: float = 0.0
	var isys: InteractionSystem = InteractionSys as InteractionSystem
	if isys != null:
		base_radius = isys.interact_radius

	var r: float = npc_radius
	if base_radius > r:
		r = base_radius
	if r <= 0.0:
		r = 32.0

	var dist: float = npc_2d.global_position.distance_to(actor_2d.global_position)
	return dist <= r


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
