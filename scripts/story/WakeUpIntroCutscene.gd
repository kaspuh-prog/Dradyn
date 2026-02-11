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

@export_group("SFX")
@export var door_knock_volume_db: float = -12.0
@export var door_knock_bus_name: StringName = &"Master"

# Set this to: res://assets/audio/sfx/DoorKnock.mp3
@export_file("*.mp3", "*.ogg", "*.wav")
var door_knock_stream_path: String = "res://assets/audio/sfx/DoorKnock.mp3"

@export_group("Reward")
@export_file("*.tres")
var wooden_sword_item_path: String = "res://Data/items/equipment/WoodenSword.tres"

var _dialogue: DialogueBox = null
var _gate: StoryGate = null

var _orphan: Node2D = null
var _orphan_anim: AnimatedSprite2D = null
var _door: Node2D = null
var _bed_sleep_sprite: AnimatedSprite2D = null

var _sequence_running: bool = false
var _waiting_for_choice: bool = false
var _last_choice_id: StringName = StringName("")

# Local, guaranteed SFX playback
var _knock_player: AudioStreamPlayer = null
var _knock_stream: AudioStream = null


func _ready() -> void:
	# If the tree is paused during cutscenes, we still want audio to play.
	process_mode = Node.PROCESS_MODE_ALWAYS

	visible = false

	_instantiate_dialogue_box()
	_cache_nodes()
	_setup_knock_player()

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
	else:
		_door = null

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


func _setup_knock_player() -> void:
	if _knock_player == null:
		_knock_player = AudioStreamPlayer.new()
		_knock_player.name = "DoorKnockPlayer"
		add_child(_knock_player)

	# If the tree is paused, audio must still process.
	_knock_player.process_mode = Node.PROCESS_MODE_ALWAYS

	# TEMP: make it obviously audible for debugging.
	_knock_player.volume_db = 0.0

	# Force Master to eliminate bus routing issues.
	_knock_player.bus = "Master"

	# DEBUG: print Master bus state and force it audible.
	var master_idx: int = AudioServer.get_bus_index("Master")
	if master_idx >= 0:
		var was_muted: bool = AudioServer.is_bus_mute(master_idx)
		var was_vol: float = AudioServer.get_bus_volume_db(master_idx)
		print("[WakeUpIntroCutscene] Master BEFORE: muted=", was_muted, " vol_db=", was_vol)

		AudioServer.set_bus_mute(master_idx, false)

		if AudioServer.get_bus_volume_db(master_idx) < -40.0:
			AudioServer.set_bus_volume_db(master_idx, 0.0)

		var now_muted: bool = AudioServer.is_bus_mute(master_idx)
		var now_vol: float = AudioServer.get_bus_volume_db(master_idx)
		print("[WakeUpIntroCutscene] Master AFTER:  muted=", now_muted, " vol_db=", now_vol)

	_knock_stream = null
	if door_knock_stream_path != "":
		var res: Resource = ResourceLoader.load(door_knock_stream_path)
		_knock_stream = res as AudioStream
		if _knock_stream == null:
			push_warning("[WakeUpIntroCutscene] Knock SFX path did not load as AudioStream: %s" % door_knock_stream_path)
		else:
			_knock_player.stream = _knock_stream
			print("[WakeUpIntroCutscene] Knock stream loaded OK: ", door_knock_stream_path, " bus=", _knock_player.bus, " player_vol_db=", _knock_player.volume_db)
	else:
		push_warning("[WakeUpIntroCutscene] door_knock_stream_path is empty. Set it to your DoorKnock file to enable knock audio.")


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
	# Always respect the "already done" flag even if a StoryGate is assigned.
	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story != null:
		if intro_done_flag_name != StringName("") and story.has_flag(intro_done_flag_name):
			return false

	# If we have a gate, require it too (but do NOT skip the flag check above).
	if _gate != null:
		return _gate.is_passing()

	# No gate: fall back to act/step checks.
	if story == null:
		return true

	var act: int = story.get_current_act_id()
	var step: int = story.get_current_step_id()

	if default_required_act_id > 0 and act != default_required_act_id:
		return false

	if default_required_step_id > 0 and step != default_required_step_id:
		return false

	return true


# -------------------------------------------------
# Main sequence
# -------------------------------------------------

func _run_sequence() -> void:
	var player: Node2D = _get_player_node()

	# 0) Apply "enter" flags for the current story position (CSV-driven).
	var story: StoryStateSystem = get_node_or_null("/root/StoryStateSys") as StoryStateSystem
	if story != null:
		story.enter_story_position(
			story.get_current_act_id(),
			story.get_current_step_id(),
			story.get_current_part_id()
		)

	_enter_sleep_pose(player)

	var day_node: DayNight = get_node_or_null("/root/DayandNight") as DayNight
	if use_night_to_morning and day_node != null:
		day_node.set_running(false)
		day_node.rest_until_dusk()
	await get_tree().process_frame

	if use_night_to_morning and sleep_duration > 0.0:
		var sleep_timer: SceneTreeTimer = get_tree().create_timer(sleep_duration)
		await sleep_timer.timeout

	if use_night_to_morning and day_node != null:
		day_node.rest_until_dawn()
	await get_tree().process_frame

	if use_night_to_morning and dawn_hold_duration > 0.0:
		var dawn_timer: SceneTreeTimer = get_tree().create_timer(dawn_hold_duration)
		await dawn_timer.timeout

	if use_night_to_morning and day_node != null:
		day_node.set_running(true)

	_exit_sleep_pose(player)

	await _play_knock_and_shout()

	var player_name: String = _get_player_name()
	var hm_line: String = "%s, you're the oldest, so it falls to you to cull the rats in the cellar!" % player_name
	await _show_line_and_wait("House Mother", hm_line)

	if orphan_enter_delay > 0.0:
		var enter_timer: SceneTreeTimer = get_tree().create_timer(orphan_enter_delay)
		await enter_timer.timeout

	if player != null:
		await _move_orphan_toward_player(player)

	await _show_line_and_wait("Orphan", "Here, Richard always used this before he aged out.")
	_give_wooden_sword()

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

	if story != null:
		story.complete_current_part()
		_ensure_story_flags_for_rats_quest(story)
	else:
		if _gate != null:
			_gate.apply_after_effects()
		else:
			_apply_default_story_after_effects()

	_finish_sequence()


func _ensure_story_flags_for_rats_quest(story: StoryStateSystem) -> void:
	if story == null:
		return

	if intro_done_flag_name != StringName(""):
		story.set_flag(intro_done_flag_name, true)

	if rats_quest_flag_name != StringName(""):
		story.set_flag(rats_quest_flag_name, true)


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
# Knock + door shake
# -------------------------------------------------

func _play_knock_once() -> void:
	_setup_knock_player()

	if _knock_player == null:
		push_warning("[WakeUpIntroCutscene] Knock player is null.")
		return

	if _knock_player.stream == null and _knock_stream != null:
		_knock_player.stream = _knock_stream

	if _knock_player.stream == null:
		push_warning("[WakeUpIntroCutscene] Knock stream is null at play-time. Path='%s'" % door_knock_stream_path)
		return

	_knock_player.stream_paused = false
	_knock_player.stop()
	_knock_player.play()

	print("[WakeUpIntroCutscene] Knock play() called. playing_now=", _knock_player.playing, " pos_now=", _knock_player.get_playback_position())
	call_deferred("_debug_knock_mix_after_play")


func _debug_knock_mix_after_play() -> void:
	await get_tree().process_frame
	await get_tree().create_timer(0.06).timeout

	if _knock_player == null:
		return

	var bus_name: String = _knock_player.bus
	var bus_idx: int = AudioServer.get_bus_index(bus_name)
	var master_idx: int = AudioServer.get_bus_index("Master")

	var playing_now: bool = _knock_player.playing
	var pos_now: float = _knock_player.get_playback_position()

	print("[WakeUpIntroCutscene] Knock after 60ms: playing=", playing_now, " pos=", pos_now, " bus=", bus_name)

	if bus_idx >= 0:
		var l: float = AudioServer.get_bus_peak_volume_left_db(bus_idx, 0)
		var r: float = AudioServer.get_bus_peak_volume_right_db(bus_idx, 0)
		print("[WakeUpIntroCutscene] Bus peaks (", bus_name, "): L=", l, " dB  R=", r, " dB")

	if master_idx >= 0:
		var ml: float = AudioServer.get_bus_peak_volume_left_db(master_idx, 0)
		var mr: float = AudioServer.get_bus_peak_volume_right_db(master_idx, 0)
		print("[WakeUpIntroCutscene] Master peaks: L=", ml, " dB  R=", mr, " dB")


func _play_knock_and_shout() -> void:
	print("[WakeUpIntroCutscene] _play_knock_and_shout: door_node_path=", door_node_path, " door_found=", _door != null)

	# Play the knock sound ONCE (the file already contains 3 knocks).
	_play_knock_once()

	# If we have a door node, do the shake animation (visual only).
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



# -------------------------------------------------
# Orphan movement
# -------------------------------------------------

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
		_orphan_anim.flip_h = dir.x < 0.0
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
		_orphan_anim.flip_h = dir.x < 0.0
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

	var choices: Array[String] = ["▶"]
	var ids: Array[StringName] = [StringName("continue")]

	_dialogue.show_message(text, speaker, choices, ids)
	await _dialogue.dialogue_closed

	_waiting_for_choice = false


func _show_magic_choice(player_name: String) -> StringName:
	if _dialogue == null:
		return StringName("")

	_waiting_for_choice = true
	_last_choice_id = StringName("")

	var choices: Array[String] = [
		"Thanks, I will use it.",
		"Thanks, but I will stick to my magic."
	]
	var ids: Array[StringName] = [
		StringName("take_and_use"),
		StringName("stick_to_magic")
	]

	_dialogue.show_message("", player_name, choices, ids)
	await _dialogue.dialogue_closed

	_waiting_for_choice = false
	return _last_choice_id


func _on_dialogue_choice_selected(_index: int, id: StringName) -> void:
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
