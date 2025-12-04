extends Node2D
class_name InteractableChest

@export var loot_path: NodePath = ^"Loot"
@export var sprite_path: NodePath = ^"Sprite"
@export var auto_register_group: bool = true

# InteractionSys compatibility
@export var interact_radius_override: float = 48.0
func get_interact_radius() -> float:
	return interact_radius_override

# Sprite control
@export var use_sprite_animations: bool = false
@export var open_anim: StringName = &"open"
@export var closed_anim: StringName = &"closed"
@export var closed_frame: int = 0
@export var open_frame: int = 1
@export var closed_on_ready: bool = true

# “Juice” bump
@export var bump_on_open: bool = true
@export var bump_scale: Vector2 = Vector2(1.05, 1.05)
@export var bump_duration: float = 0.12

# Highlight tinting
@export var highlight_modulate: Color = Color(1.1, 1.1, 1.1, 1.0)

# Despawn controls
@export var destroy_after_open: bool = false
@export var despawn_after_visuals: bool = true
@export var despawn_fallback_seconds: float = 0.35
@export var force_despawn_timeout: float = 1.25

# Debug
@export var verbose_debug: bool = false

var _loot: InteractableLoot
var _sprite: AnimatedSprite2D
var _orig_modulate: Color = Color(1, 1, 1, 1)
var _orig_modulate_set: bool = false
var _orig_scale: Vector2 = Vector2(1, 1)

var _opened: bool = false
var _opening_in_progress: bool = false

var _generated_loot: Array[Dictionary] = []
var _currency_to_grant: int = 0
var _currency_granted: bool = false
var _source_id: String = ""

# NEW: watchdog flags
var _despawn_started: bool = false
var _despawned: bool = false

func _ready() -> void:
	if auto_register_group and not is_in_group("interactable"):
		add_to_group("interactable")

	_loot = get_node_or_null(loot_path) as InteractableLoot
	_sprite = get_node_or_null(sprite_path) as AnimatedSprite2D

	if _loot != null:
		_loot.auto_register_group = false
		if _loot.is_in_group("interactable"):
			_loot.remove_from_group("interactable")
		if not _loot.is_connected("loot_given", Callable(self, "_on_loot_given")):
			_loot.connect("loot_given", Callable(self, "_on_loot_given"))
		if not _loot.is_connected("loot_already_claimed", Callable(self, "_on_loot_already_claimed")):
			_loot.connect("loot_already_claimed", Callable(self, "_on_loot_already_claimed"))
		_forward_item_payload_to_loot_node()

	if _sprite != null:
		_orig_modulate = _sprite.modulate
		_orig_modulate_set = true
		_orig_scale = _sprite.scale

	if _sprite != null and closed_on_ready:
		_apply_closed_pose()

func interact(actor: Node) -> void:
	if _loot == null:
		_grant_currency_once()
		_opened = true
		_opening_in_progress = false
		# Fire visuals; watchdog will force despawn if anything stalls
		_play_open_visual_and_bump_then_despawn()
		return

	if _loot.one_time:
		if _opened:
			return
		if _opening_in_progress:
			return
		if _loot.is_claimed():
			return
		_opening_in_progress = true

	_forward_item_payload_to_loot_node()
	_grant_currency_once()
	_loot.interact(actor)

func set_interact_highlight(on: bool) -> void:
	if _sprite == null:
		return
	if not _orig_modulate_set:
		_orig_modulate = _sprite.modulate
		_orig_modulate_set = true
	if on:
		_sprite.modulate = highlight_modulate
	else:
		_sprite.modulate = _orig_modulate

func get_interact_prompt() -> String:
	if _loot != null and _loot.one_time and (_opened or _loot.is_claimed()):
		return "Empty"
	return "Open Chest"

# --------- external setters ---------
func set_generated_loot(drops: Array[Dictionary]) -> void:
	_generated_loot = []
	_currency_to_grant = 0
	_currency_granted = false
	var i: int = 0
	while i < drops.size():
		var d: Dictionary = drops[i]
		var dtype: String = String(d.get("type", ""))
		if dtype == "currency":
			var amt: int = int(d.get("amount", 0))
			if amt > 0:
				_currency_to_grant += amt
		elif dtype == "item":
			var def_v: Variant = d.get("item_def", null)
			var qty: int = int(d.get("quantity", 1))
			if def_v is ItemDef:
				var row: Dictionary = {}
				row["item_def"] = def_v
				row["quantity"] = qty
				_generated_loot.append(row)
		i += 1
	_forward_item_payload_to_loot_node()

func set_destroy_after_open(flag: bool) -> void:
	destroy_after_open = flag
	if verbose_debug:
		print_debug("[Chest] destroy_after_open=", str(destroy_after_open), " src=", _source_id)

func set_source(source_id: String) -> void:
	_source_id = source_id

# --------- signals ---------
func _on_loot_given(total_added: int, total_leftover: int) -> void:
	if _opened:
		_opening_in_progress = false
		return
	_opened = true
	_opening_in_progress = false
	if verbose_debug:
		print_debug("[Chest] loot_given; opening visuals… src=", _source_id, " drops=", str(_generated_loot.size()), " currency=", str(_currency_to_grant))

	# Start the watchdog FIRST, then run visuals path in parallel.
	_start_despawn_watchdog()
	_play_open_visual_and_bump_then_despawn()

func _on_loot_already_claimed() -> void:
	_opening_in_progress = false
	if verbose_debug:
		print_debug("[Chest] loot_already_claimed. src=", _source_id)

# --------- visuals ---------
func _apply_closed_pose() -> void:
	if _sprite == null:
		return
	if use_sprite_animations:
		if _sprite.sprite_frames != null:
			if _sprite.sprite_frames.has_animation(String(closed_anim)):
				_sprite.play(String(closed_anim))
				return
	_sprite.stop()
	_sprite.frame = closed_frame

func _apply_open_pose() -> void:
	if _sprite == null:
		return
	if use_sprite_animations:
		if _sprite.sprite_frames != null:
			if _sprite.sprite_frames.has_animation(String(open_anim)):
				_sprite.play(String(open_anim))
				return
	_sprite.stop()
	_sprite.frame = open_frame

func _play_bump_if_enabled() -> void:
	if not bump_on_open:
		return
	if _sprite == null:
		return
	var tween: Tween = create_tween()
	if tween == null:
		return
	_sprite.scale = _orig_scale
	tween.tween_property(_sprite, "scale", bump_scale, bump_duration)
	tween.tween_property(_sprite, "scale", _orig_scale, bump_duration)

# NOTE: no awaits here; this function kicks off awaits internally but we don't block caller.
func _play_open_visual_and_bump_then_despawn() -> void:
	_apply_open_pose()
	_play_bump_if_enabled()
	if destroy_after_open and despawn_after_visuals:
		# Continue asynchronously; on success, it will call _despawn_if_configured()
		_run_visual_wait_then_despawn()
	else:
		_despawn_if_configured()

# Asynchronous waiter (internal)
func _run_visual_wait_then_despawn() -> void:
	await _wait_for_open_visuals()
	_despawn_if_configured()

# Wait for animation/timer; uses safe fallbacks
func _wait_for_open_visuals() -> void:
	var waited: bool = false
	if _sprite != null and use_sprite_animations:
		var frames: SpriteFrames = _sprite.sprite_frames
		if frames != null:
			if frames.has_animation(String(open_anim)):
				var original_loop: bool = frames.get_animation_loop(String(open_anim))
				frames.set_animation_loop(String(open_anim), false)
				var est: float = _estimate_anim_duration_sec(frames, String(open_anim))
				if est <= 0.0:
					est = despawn_fallback_seconds

				var finished: bool = false
				var timed_out: bool = false

				_sprite.animation_finished.connect(func() -> void: finished = true, CONNECT_ONE_SHOT)
				var timer: SceneTreeTimer = get_tree().create_timer(est)
				timer.timeout.connect(func() -> void: timed_out = true, CONNECT_ONE_SHOT)

				_sprite.play(String(open_anim))
				while not finished and not timed_out:
					await get_tree().process_frame

				waited = true
				frames.set_animation_loop(String(open_anim), original_loop)

	if not waited:
		var secs: float = despawn_fallback_seconds
		if bump_on_open:
			var bump_total: float = bump_duration * 2.0
			if bump_total > secs:
				secs = bump_total
		await get_tree().create_timer(secs).timeout

func _estimate_anim_duration_sec(frames: SpriteFrames, anim_name: String) -> float:
	var fc: int = frames.get_frame_count(anim_name)
	if fc <= 0:
		return 0.0
	var fps: float = frames.get_animation_speed(anim_name)
	if fps <= 0.0:
		fps = 10.0
	return float(fc) / fps

# --------- despawn helpers ---------
func _start_despawn_watchdog() -> void:
	if _despawn_started:
		return
	_despawn_started = true
	if not destroy_after_open:
		return
	# Independent backstop — even if visuals wait never resumes, this will fire.
	var t: SceneTreeTimer = get_tree().create_timer(force_despawn_timeout)
	t.timeout.connect(
		func() -> void:
			if _despawned:
				return
			if verbose_debug:
				print_debug("[Chest] Watchdog forcing despawn. src=", _source_id)
			_despawn_if_configured()
	, CONNECT_ONE_SHOT)

func _despawn_if_configured() -> void:
	if not destroy_after_open:
		return
	if _despawned:
		return
	_despawned = true
	if verbose_debug:
		print_debug("[Chest] Despawning now. src=", _source_id)
	call_deferred("queue_free")

# --------- internal helpers ---------
func _forward_item_payload_to_loot_node() -> void:
	if _loot == null:
		return
	if _generated_loot.is_empty():
		return
	if _loot.has_method("set_generated_items"):
		_loot.call("set_generated_items", _generated_loot)
		return
	if _loot.has_method("set_generated_loot"):
		_loot.call("set_generated_loot", _generated_loot)
		return
	var i: int = 0
	while i < _generated_loot.size():
		var row: Dictionary = _generated_loot[i]
		var def_v: Variant = row.get("item_def", null)
		var qty: int = int(row.get("quantity", 1))
		if def_v is ItemDef:
			if _loot.has_method("add_generated_item"):
				_loot.call("add_generated_item", def_v, qty)
		i += 1

func _grant_currency_once() -> void:
	if _currency_granted:
		return
	if _currency_to_grant <= 0:
		_currency_granted = true
		return
	var inv: Node = get_node_or_null("/root/InventorySys")
	if inv != null:
		if inv.has_method("add_currency"):
			inv.call("add_currency", _currency_to_grant)
	_currency_granted = true
