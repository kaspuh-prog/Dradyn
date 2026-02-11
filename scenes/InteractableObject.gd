extends Node2D
class_name InteractableObject
# Godot 4.5 — typed, no ternaries.
# Generic interactable prop:
# - Always compatible with InteractionSys (group "interactable", interact(actor))
# - Optional InteractableLoot child (default path "Loot") for hidden items
# - Supports generated loot payloads from AreaLootProvider (set_generated_loot, set_destroy_after_open, set_source)
# - Optional currency payload (from LootTable currency picks)
# - Visuals: highlight + open/closed sprite pose + optional bump + optional despawn

signal interacted(actor: Node)
signal loot_opened(actor: Node, total_added: int, total_leftover: int)
signal loot_empty(actor: Node)
signal loot_already_claimed(actor: Node)

@export var auto_register_group: bool = true

# InteractionSys compatibility
@export var interact_radius_override: float = 48.0
func get_interact_radius() -> float:
	return interact_radius_override

# Optional authored loot node
@export var loot_path: NodePath = ^"Loot"

# Visual target (AnimatedSprite2D or Sprite2D)
@export var sprite_path: NodePath = ^"Sprite"

# Prompt strings (not currently used by InteractionSys directly, but matches other interactables)
@export var prompt_default: String = "Interact"
@export var prompt_with_loot: String = "Search"
@export var prompt_empty: String = "Empty"

# Highlight visuals
@export var highlight_modulate: Color = Color(1.25, 1.25, 1.25, 1.0)
@export var highlight_scale: Vector2 = Vector2(1.05, 1.05)

# Open/Closed visuals (AnimatedSprite2D)
@export var use_sprite_animations: bool = false
@export var closed_anim: StringName = &"closed"
@export var open_anim: StringName = &"open"
@export var closed_frame: int = 0
@export var open_frame: int = 1
@export var closed_on_ready: bool = true

# Open/Closed visuals (Sprite2D texture swap)
@export var closed_texture: Texture2D
@export var open_texture: Texture2D

# “Juice” bump when opening
@export var bump_on_open: bool = true
@export var bump_scale: Vector2 = Vector2(1.10, 1.10)
@export var bump_time_sec: float = 0.10

# Despawn controls (optional; used by AreaLootProvider spawned props, etc.)
@export var destroy_after_open: bool = false
@export var despawn_after_visuals: bool = true
@export var despawn_fallback_seconds: float = 0.8

# -------------------------
# Runtime
# -------------------------
var _loot: InteractableLoot = null
var _sprite_anim: AnimatedSprite2D = null
var _sprite_static: Sprite2D = null

var _opened: bool = false
var _opening_in_progress: bool = false

var _orig_modulate: Color = Color.WHITE
var _orig_modulate_set: bool = false
var _orig_scale: Vector2 = Vector2.ONE
var _orig_scale_set: bool = false
var _orig_texture: Texture2D = null
var _orig_texture_set: bool = false

# Generated payload (supports LootTable results)
var _generated_items: Array[Dictionary] = []
var _currency_to_grant: int = 0
var _currency_granted: bool = false

var _source_id: StringName = StringName("")

func _ready() -> void:
	if auto_register_group and not is_in_group("interactable"):
		add_to_group("interactable")

	_resolve_nodes()

	# If Loot exists, keep it from becoming its own interactable.
	if _loot != null:
		_loot.auto_register_group = false
		if _loot.is_in_group("interactable"):
			_loot.remove_from_group("interactable")

		if not _loot.is_connected("loot_given", Callable(self, "_on_loot_given")):
			_loot.connect("loot_given", Callable(self, "_on_loot_given"))
		if not _loot.is_connected("loot_already_claimed", Callable(self, "_on_loot_already_claimed")):
			_loot.connect("loot_already_claimed", Callable(self, "_on_loot_already_claimed"))

		# If loot was already claimed (e.g., saved state later), show open.
		if _loot.one_time and _loot.is_claimed():
			_opened = true

	if closed_on_ready and not _opened:
		_apply_closed_pose()
	elif _opened:
		_apply_open_pose()

func _resolve_nodes() -> void:
	_loot = get_node_or_null(loot_path) as InteractableLoot

	var n: Node = get_node_or_null(sprite_path)
	_sprite_anim = n as AnimatedSprite2D
	_sprite_static = n as Sprite2D

	if _sprite_anim != null:
		_orig_modulate = _sprite_anim.modulate
		_orig_modulate_set = true
		_orig_scale = _sprite_anim.scale
		_orig_scale_set = true
	elif _sprite_static != null:
		_orig_modulate = _sprite_static.modulate
		_orig_modulate_set = true
		_orig_scale = _sprite_static.scale
		_orig_scale_set = true
		_orig_texture = _sprite_static.texture
		_orig_texture_set = true

# -------------------------
# InteractionSys entrypoints
# -------------------------
func interact(actor: Node) -> void:
	interacted.emit(actor)

	# Ensure loot node exists if we were given generated item payloads but no authored Loot node.
	if _loot == null and not _generated_items.is_empty():
		_ensure_loot_node()

	# Currency-only payload (or no loot available)
	if _loot == null:
		var had_currency: bool = (_currency_to_grant > 0)
		if had_currency:
			_grant_currency_once()

		if had_currency:
			_opened = true
			_opening_in_progress = false
			_play_open_visual_and_maybe_despawn()
			loot_opened.emit(actor, 0, 0)
		else:
			loot_empty.emit(actor)

		return

	# One-time guard
	if _loot.one_time:
		if _opened:
			return
		if _opening_in_progress:
			return
		if _loot.is_claimed():
			_opened = true
			_apply_open_pose()
			return
		_opening_in_progress = true

	_forward_generated_items_to_loot_node()
	_grant_currency_once()
	_loot.interact(actor)

func get_interact_prompt() -> String:
	# If it has loot/currency pending, show "Search" (or your custom prompt).
	if _loot != null:
		if _loot.one_time:
			if _loot.is_claimed() or _opened:
				return prompt_empty
		return prompt_with_loot

	if _currency_to_grant > 0:
		return prompt_with_loot

	if _opened:
		return prompt_empty

	return prompt_default

func set_interact_highlight(on: bool) -> void:
	if _sprite_anim == null and _sprite_static == null:
		return

	if on:
		_set_sprite_modulate(highlight_modulate)
		_set_sprite_scale(_get_orig_scale() * highlight_scale)
	else:
		_set_sprite_modulate(_get_orig_modulate())
		_set_sprite_scale(_get_orig_scale())

# -------------------------
# Chest-spawn compatibility (AreaLootProvider)
# -------------------------
func set_generated_loot(drops: Array[Dictionary]) -> void:
	_generated_items.clear()
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
				row["quantity"] = max(1, qty)
				_generated_items.append(row)
		i += 1

	# If we already have Loot, forward now.
	_forward_generated_items_to_loot_node()

func set_destroy_after_open(v: bool) -> void:
	destroy_after_open = v

func set_source(source_id: String) -> void:
	_source_id = StringName(source_id)

# -------------------------
# Loot callbacks
# -------------------------
func _on_loot_given(total_added: int, total_leftover: int) -> void:
	_opening_in_progress = false

	if total_added <= 0:
		# Not considered "claimed" by InteractableLoot, so keep closed.
		loot_empty.emit(null)
		return

	_opened = true
	_play_open_visual_and_maybe_despawn()
	loot_opened.emit(null, total_added, total_leftover)

func _on_loot_already_claimed() -> void:
	_opening_in_progress = false
	_opened = true
	_apply_open_pose()
	loot_already_claimed.emit(null)

# -------------------------
# Generated payload helpers
# -------------------------
func _ensure_loot_node() -> void:
	if _loot != null:
		return

	var node: InteractableLoot = InteractableLoot.new()
	node.name = "Loot"
	node.one_time = true
	node.disable_after_claim = false
	node.auto_register_group = false
	add_child(node)

	_loot = node

	if _loot.is_in_group("interactable"):
		_loot.remove_from_group("interactable")

	if not _loot.is_connected("loot_given", Callable(self, "_on_loot_given")):
		_loot.connect("loot_given", Callable(self, "_on_loot_given"))
	if not _loot.is_connected("loot_already_claimed", Callable(self, "_on_loot_already_claimed")):
		_loot.connect("loot_already_claimed", Callable(self, "_on_loot_already_claimed"))

func _forward_generated_items_to_loot_node() -> void:
	if _loot == null:
		return
	if _generated_items.is_empty():
		return

	if _loot.has_method("set_generated_items"):
		_loot.call("set_generated_items", _generated_items)

# -------------------------
# Currency helper
# -------------------------
func _grant_currency_once() -> void:
	if _currency_granted:
		return
	if _currency_to_grant <= 0:
		_currency_granted = true
		return

	var inv: Node = get_node_or_null("/root/InventorySys")
	if inv == null:
		inv = get_node_or_null("/root/InventorySystem")

	if inv != null and inv.has_method("add_currency"):
		inv.call("add_currency", _currency_to_grant)

	_currency_granted = true

# -------------------------
# Visuals
# -------------------------
func _play_open_visual_and_maybe_despawn() -> void:
	_apply_open_pose()
	_play_bump_if_enabled()

	if not destroy_after_open:
		return

	if not despawn_after_visuals:
		queue_free()
		return

	var wait_sec: float = _estimate_open_visual_wait_sec()
	if wait_sec <= 0.0:
		wait_sec = despawn_fallback_seconds

	var timer: SceneTreeTimer = get_tree().create_timer(wait_sec)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(self) and is_inside_tree():
			queue_free()
	)

func _estimate_open_visual_wait_sec() -> float:
	if _sprite_anim == null:
		return 0.0
	if not use_sprite_animations:
		return 0.0

	var frames: SpriteFrames = _sprite_anim.sprite_frames
	if frames == null:
		return 0.0

	var anim_name: String = String(open_anim)
	if anim_name == "":
		return 0.0
	if not frames.has_animation(anim_name):
		return 0.0

	var frame_count: int = frames.get_frame_count(anim_name)
	var fps: float = frames.get_animation_speed(anim_name)
	if fps <= 0.0:
		return 0.0
	return float(frame_count) / fps

func _apply_closed_pose() -> void:
	if _sprite_anim != null:
		if use_sprite_animations and String(closed_anim) != "":
			var anim_name: String = String(closed_anim)
			if _sprite_anim.sprite_frames != null and _sprite_anim.sprite_frames.has_animation(anim_name):
				_sprite_anim.play(anim_name)
				return
		_sprite_anim.stop()
		_sprite_anim.frame = max(0, closed_frame)
		return

	if _sprite_static != null:
		if closed_texture != null:
			_sprite_static.texture = closed_texture
		elif _orig_texture_set and _orig_texture != null:
			_sprite_static.texture = _orig_texture

func _apply_open_pose() -> void:
	if _sprite_anim != null:
		if use_sprite_animations and String(open_anim) != "":
			var anim_name: String = String(open_anim)
			if _sprite_anim.sprite_frames != null and _sprite_anim.sprite_frames.has_animation(anim_name):
				_sprite_anim.play(anim_name)
				return
		_sprite_anim.stop()
		_sprite_anim.frame = max(0, open_frame)
		return

	if _sprite_static != null:
		if open_texture != null:
			_sprite_static.texture = open_texture

func _play_bump_if_enabled() -> void:
	if not bump_on_open:
		return
	if bump_time_sec <= 0.0:
		return

	var base_scale: Vector2 = _get_orig_scale()
	_set_sprite_scale(base_scale * bump_scale)

	var tw: Tween = create_tween()
	if tw == null:
		return
	tw.tween_property(self, "_dummy", 0.0, bump_time_sec)

	# Reset via deferred to avoid fighting highlight tick ordering.
	var timer: SceneTreeTimer = get_tree().create_timer(bump_time_sec)
	timer.timeout.connect(func() -> void:
		_set_sprite_scale(base_scale)
	)

# Dummy property target for tween bookkeeping (we don't need to animate anything real here).
var _dummy: float = 0.0

# -------------------------
# Sprite setters/getters (shared)
# -------------------------
func _get_orig_modulate() -> Color:
	if _orig_modulate_set:
		return _orig_modulate
	return Color.WHITE

func _get_orig_scale() -> Vector2:
	if _orig_scale_set:
		return _orig_scale
	return Vector2.ONE

func _set_sprite_modulate(c: Color) -> void:
	if _sprite_anim != null:
		_sprite_anim.modulate = c
	elif _sprite_static != null:
		_sprite_static.modulate = c

func _set_sprite_scale(s: Vector2) -> void:
	if _sprite_anim != null:
		_sprite_anim.scale = s
	elif _sprite_static != null:
		_sprite_static.scale = s
