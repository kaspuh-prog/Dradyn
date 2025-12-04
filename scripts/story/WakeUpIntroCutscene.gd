extends Control
class_name WakeUpIntroCutscene

@export_group("Dialogue")
@export var dialogue_box_scene: PackedScene

@export_group("Story Gating")
@export var story_gate_path: NodePath = NodePath("")

@export var default_required_act_id: int = 1
@export var default_required_step_id: int = 1
@export var intro_done_flag_name: StringName = &"story_orphanage_intro_done"
@export var rats_quest_flag_name: StringName = &"quest_rats_active"

@export_group("Scene Actors / Props")
@export var orphan_node_path: NodePath = NodePath("")
@export var door_node_path: NodePath = NodePath("")

@export_group("Bed Sleep Pose")
@export var bed_sleep_sprite_path: NodePath = NodePath("")

@export_group("Timing / Movement")
@export var use_night_to_morning: bool = true
@export var orphan_walk_duration: float = 1.2
@export var orphan_stop_distance: float = 16.0
@export var sleep_duration: float = 1.0
@export var dawn_hold_duration: float = 0.5
@export var orphan_enter_delay: float = 0.35

@export_group("Player Info")
@export var default_player_name: String = "Child"
@export var player_is_melee: bool = true

@export_group("Reward")
@export_file("*.tres")
var wooden_sword_item_path: String = "res://Data/items/weaponresources/WoodenSword.tres"

var _dialogue: DialogueBox = null
var _gate: StoryGate = null

var _orphan: Node2D = null
var _orphan_anim: AnimatedSprite2D = null
var _door: Node2D = null
var _bed_sleep_sprite: AnimatedSprite2D = null

var _sequence_running: bool = false
var _waiting_for_choice: bool = false
var _last_choice_id: StringName = StringName("")


func _ready() -> void:
	visible = false

	_instantiate_dialogue_box()
	_cache_nodes()

	if story_gate_path != NodePath(""):
		_gate = get_node_or_null(story_gate_path) as StoryGate

	call_deferred("_maybe_start_cutscene")


# -------------------------------------------------
# Node / setup helpers
# -------------------------------------------------

func _instantiate_dialogue_box() -> void:
	if dialogue_box_scene == null:
		push_warning("[WakeUpIntroCutscene] dialogue_box_scene is not assigned.")
		return

	if _dialogue != null:
		return

	var inst: Control = dialogue_box_scene.instantiate()
	var dlg: DialogueBox = inst as DialogueBox
	if dlg == null:
		push_error("[WakeUpIntroCutscene] dialogue_box_scene does not instantiate a DialogueBox.")
		add_child(inst)
		return

	_dialogue = dlg

	var hud_layer_node: Node = get_node_or_null("/root/GameRoot/HUDLayer")
	if hud_layer_node != null:
		hud_layer_node.add_child(_dialogue)
	else:
		add_child(_dialogue)

	_dialogue.visible = false

	_dialogue.choice_selected.connect(_on_dialogue_choice_selected)
	_dialogue.dialogue_closed.connect(_on_dialogue_closed)


func _cache_nodes() -> void:
	if orphan_node_path != NodePath(""):
		_orphan = get_node_or_null(orphan_node_path) as Node2D
		if _orphan != null:
			_orphan_anim = _find_animated_sprite(_orphan)

	if door_node_path != NodePath(""):
		_door = get_node_or_null(door_node_path) as Node2D

	if bed_sleep_sprite_path != NodePath(""):
		var node: Node = get_node_or_null(bed_sleep_sprite_path)
		_bed_sleep_sprite = node as AnimatedSprite2D


func _find_animated_sprite(root: Node) -> AnimatedSprite2D:
	var direct: AnimatedSprite2D = root.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if direct != null:
		return direct

	var children: Array[Node] = root.get_children()
	var i: int = 0
	while i < children.size():
		var child: Node = children[i]
		var as_sprite: AnimatedSprite2D = child as AnimatedSprite2D
		if as_sprite != null:
			return as_sprite
		i += 1

	return null


# -------------------------------------------------
# Player lookup (from Party autoload)
# -------------------------------------------------

func _get_player_node() -> Node2D:
	var party: PartyManager = get_node_or_null("/root/Party") as PartyManager
	if party == null:
		return null

	var actor: Node = party.get_controlled()
	var as_node2d: Node2D = actor as Node2D
	if as_node2d != null:
		return as_node2d

	return null


# -------------------------------------------------
# Public entry / auto-start
# -------------------------------------------------

func start_cutscene() -> void:
	if _sequence_running:
		return

	if not _passes_story_gate():
		return

	_sequence_running = true
	visible = true

	call_deferred("_run_sequence_wrapper")


func _run_sequence_wrapper() -> void:
	await _run_sequence()


func _maybe_start_cutscene() -> void:
	if _sequence_running:
		return

	if not _passes_story_gate():
		return

	start_cutscene()


func _passes_story_gate() -> bool:
	if _gate != null:
		return _gate.is_passing()

	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story == null:
		return true

	var act: int = story.get_current_act_id()
	var step: int = story.get_current_step_id()

	if default_required_act_id > 0 and act != default_required_act_id:
		return false

	if default_required_step_id > 0 and step != default_required_step_id:
		return false

	if intro_done_flag_name != StringName("") and story.has_flag(intro_done_flag_name):
		return false

	return true


# -------------------------------------------------
# Main sequence
# -------------------------------------------------

func _run_sequence() -> void:
	var player: Node2D = _get_player_node()

	# 0) Start with player "in bed" via the sleep sprite.
	_enter_sleep_pose(player)

	# 0.5) Snap to NIGHT, hold for a bit.
	var day_node: DayNight = get_node_or_null("/root/DayandNight") as DayNight
	if use_night_to_morning and day_node != null:
		day_node.set_running(false)
		day_node.rest_until_dusk()
	await get_tree().process_frame

	if use_night_to_morning and sleep_duration > 0.0:
		var sleep_timer: SceneTreeTimer = get_tree().create_timer(sleep_duration)
		await sleep_timer.timeout

	# 0.75) Snap to MORNING, hold for a bit.
	if use_night_to_morning and day_node != null:
		day_node.rest_until_dawn()
	await get_tree().process_frame

	if use_night_to_morning and dawn_hold_duration > 0.0:
		var dawn_timer: SceneTreeTimer = get_tree().create_timer(dawn_hold_duration)
		await dawn_timer.timeout

	if use_night_to_morning and day_node != null:
		day_node.set_running(true)

	# 1) Stand the player up next to the bed.
	_exit_sleep_pose(player)

	# 2) House Mother knocks + shouts (off-screen).
	await _play_knock_and_shout()

	# 3) House Mother gives the rats quest.
	var player_name: String = _get_player_name()
	var hm_line: String = "%s, you're the oldest, so it falls to you to cull the rats in the cellar!" % player_name
	await _show_line_and_wait("House Mother", hm_line)

	# 3.5) Small pause before the orphan moves.
	if orphan_enter_delay > 0.0:
		var enter_timer: SceneTreeTimer = get_tree().create_timer(orphan_enter_delay)
		await enter_timer.timeout

	# 4) Orphan walks from behind the dressing screen toward the player.
	if player != null:
		await _move_orphan_toward_player(player)

	# 5) Orphan gives the wooden sword.
	await _show_line_and_wait("Orphan", "Here, Richard always used this before he aged out.")
	_give_wooden_sword()

	# 6) Player response / magic branch.
	if player_is_melee:
		await _show_line_and_wait(player_name, "Thanks, I will put it to good use.")
	else:
		var choice_id: StringName = await _show_magic_choice(player_name)
		if choice_id == StringName("take_and_use"):
			await _show_line_and_wait(player_name, "Thanks, I will use it.")
		elif choice_id == StringName("stick_to_magic"):
			await _show_line_and_wait(player_name, "Thanks, but I will stick to my magic.")
		else:
			await _show_line_and_wait(player_name, "Thank you.")

	# 7) Story flags.
	if _gate != null:
		_gate.apply_after_effects()
	else:
		_apply_default_story_after_effects()

	_finish_sequence()


func _finish_sequence() -> void:
	_sequence_running = false
	visible = false


# -------------------------------------------------
# Bed sleep pose helpers
# -------------------------------------------------

func _enter_sleep_pose(player: Node2D) -> void:
	if _bed_sleep_sprite != null:
		_bed_sleep_sprite.visible = true
		_bed_sleep_sprite.play("sleep")

	if player != null:
		player.visible = false


func _exit_sleep_pose(player: Node2D) -> void:
	if _bed_sleep_sprite != null:
		_bed_sleep_sprite.stop()
		_bed_sleep_sprite.visible = false

	if player != null:
		player.visible = true


# -------------------------------------------------
# Environment / movement
# -------------------------------------------------

func _play_knock_and_shout() -> void:
	if _door != null:
		var start_pos: Vector2 = _door.position
		var knock_offset: float = 3.0

		var tween: Tween = create_tween()
		tween.set_trans(Tween.TRANS_SINE)
		tween.set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(_door, "position:x", start_pos.x + knock_offset, 0.08)
		tween.tween_property(_door, "position:x", start_pos.x - knock_offset, 0.08)
		tween.tween_property(_door, "position:x", start_pos.x, 0.06)
		await tween.finished

	await _show_line_and_wait("House Mother", "*BANG BANG BANG*")


func _move_orphan_toward_player(player: Node2D) -> void:
	if _orphan == null:
		return

	if orphan_stop_distance < 0.0:
		orphan_stop_distance = 0.0

	_play_orphan_walk_animation_toward(player)

	var player_pos: Vector2 = player.global_position
	var orphan_pos: Vector2 = _orphan.global_position
	var dir: Vector2 = player_pos - orphan_pos
	var dist: float = dir.length()

	if dist <= orphan_stop_distance + 0.1:
		_set_orphan_idle_facing_player(player)
		return

	var dir_norm: Vector2 = dir.normalized()
	var target_pos: Vector2 = player_pos - dir_norm * orphan_stop_distance

	var tween: Tween = create_tween()
	tween.set_trans(Tween.TRANS_SINE)
	tween.set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_orphan, "global_position", target_pos, orphan_walk_duration)
	await tween.finished

	_set_orphan_idle_facing_player(player)


func _play_orphan_walk_animation_toward(target: Node2D) -> void:
	if _orphan == null or _orphan_anim == null:
		return

	var dir: Vector2 = target.global_position - _orphan.global_position
	if dir.length() < 0.001:
		_orphan_anim.play("idle_down")
		_orphan_anim.flip_h = false
		return

	var abs_x: float = absf(dir.x)
	var abs_y: float = absf(dir.y)

	if abs_x >= abs_y:
		_orphan_anim.play("walk_side")
		if dir.x < 0.0:
			_orphan_anim.flip_h = true
		else:
			_orphan_anim.flip_h = false
	else:
		if dir.y > 0.0:
			_orphan_anim.play("walk_down")
		else:
			_orphan_anim.play("walk_up")
		_orphan_anim.flip_h = false


func _set_orphan_idle_facing_player(target: Node2D) -> void:
	if _orphan == null or _orphan_anim == null:
		return

	var dir: Vector2 = target.global_position - _orphan.global_position
	if dir.length() < 0.001:
		_orphan_anim.play("idle_down")
		_orphan_anim.flip_h = false
		return

	var abs_x: float = absf(dir.x)
	var abs_y: float = absf(dir.y)

	if abs_x >= abs_y:
		_orphan_anim.play("idle_side")
		if dir.x < 0.0:
			_orphan_anim.flip_h = true
		else:
			_orphan_anim.flip_h = false
	else:
		if dir.y > 0.0:
			_orphan_anim.play("idle_down")
		else:
			_orphan_anim.play("idle_up")
		_orphan_anim.flip_h = false


# -------------------------------------------------
# Dialogue helpers
# -------------------------------------------------

func _show_line_and_wait(speaker: String, text: String) -> void:
	if _dialogue == null:
		return

	_waiting_for_choice = true
	_last_choice_id = StringName("")

	var choices: Array[String] = []
	choices.append("▶")

	var ids: Array[StringName] = []
	ids.append(StringName("continue"))

	_dialogue.show_message(text, speaker, choices, ids)
	await _dialogue.dialogue_closed

	_waiting_for_choice = false


func _show_magic_choice(player_name: String) -> StringName:
	if _dialogue == null:
		return StringName("")

	_waiting_for_choice = true
	_last_choice_id = StringName("")

	var choices: Array[String] = []
	choices.append("Thanks, I will use it.")
	choices.append("Thanks, but I will stick to my magic.")

	var ids: Array[StringName] = []
	ids.append(StringName("take_and_use"))
	ids.append(StringName("stick_to_magic"))

	var line_text: String = ""

	_dialogue.show_message(line_text, player_name, choices, ids)
	await _dialogue.dialogue_closed

	_waiting_for_choice = false
	return _last_choice_id


func _on_dialogue_choice_selected(index: int, id: StringName) -> void:
	_last_choice_id = id
	if _dialogue != null:
		_dialogue.close_dialogue()


func _on_dialogue_closed() -> void:
	pass


# -------------------------------------------------
# Story + reward helpers
# -------------------------------------------------

func _get_player_name() -> String:
	var save_sys: SaveSystem = get_node_or_null("/root/SaveSys") as SaveSystem
	if save_sys == null:
		return default_player_name

	var payload_any: Variant = save_sys.get_last_loaded_payload()
	if typeof(payload_any) != TYPE_DICTIONARY:
		return default_player_name

	var payload: Dictionary = payload_any
	if payload.has("player_name"):
		var v: Variant = payload["player_name"]
		if typeof(v) == TYPE_STRING:
			var name_value: String = v
			if name_value != "":
				return name_value

	return default_player_name


func _give_wooden_sword() -> void:
	if wooden_sword_item_path == "":
		return

	var player: Node2D = _get_player_node()
	if player == null:
		push_warning("[WakeUpIntroCutscene] No controlled player; cannot give wooden sword.")
		return

	if not has_node("/root/InventorySys"):
		push_warning("[WakeUpIntroCutscene] /root/InventorySys not found; cannot give wooden sword.")
		return

	var res: Resource = ResourceLoader.load(wooden_sword_item_path)
	var item_def: ItemDef = res as ItemDef
	if item_def == null:
		push_warning("[WakeUpIntroCutscene] Failed to load ItemDef from path: %s" % wooden_sword_item_path)
		return

	var inv: InventorySystem = InventorySys as InventorySystem
	if inv == null:
		push_warning("[WakeUpIntroCutscene] InventorySys autoload is not an InventorySystem; cannot give wooden sword.")
		return

	var leftover: int = inv.add_item_for(player, item_def, 1)
	if leftover > 0:
		push_warning("[WakeUpIntroCutscene] Wooden sword could not be fully added (leftover=%d)." % leftover)


func _apply_default_story_after_effects() -> void:
	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story == null:
		return

	if intro_done_flag_name != StringName(""):
		story.set_flag(intro_done_flag_name, true)

	if rats_quest_flag_name != StringName(""):
		story.set_flag(rats_quest_flag_name, true)
