extends Node2D
class_name VisualRootPreview
# Godot 4.5 — fully typed, no ternaries.

@export var body_anim_name: String = "Attack1_down"
@export var weapon_anim_name: String = "Attack1_down_weapon"

@export var play_on_ready: bool = false
@export var speed_scale: float = 1.0

@export_node_path("Node") var visual_root_path: NodePath = NodePath("VisualRoot")
@export_node_path("AnimationPlayer") var weapon_player_path: NodePath = NodePath("VisualRoot/AnimationPlayer")

@export var weapon_trail_node_name: String = "WeaponTrail"

# NEW: Godot 4 AnimationLibrary name used by the weapon AnimationPlayer (ex: "CombatAnimations")
@export var weapon_anim_library: String = "CombatAnimations"

# --- Cached nodes ---
var _visual_root: Node = null
var _weapon_player: AnimationPlayer = null

var _body_layers: Array[AnimatedSprite2D] = []

var _weapon_root: Node2D = null
var _mainhand: Sprite2D = null
var _offhand: Sprite2D = null
var _trail_anchor: Node2D = null
var _mainhand_pivot: Node2D = null
var _weapon_trail: Node = null

# Named layer caches (optional; used for toggles)
var _layer_body: AnimatedSprite2D = null
var _layer_armor: AnimatedSprite2D = null
var _layer_hair_behind: AnimatedSprite2D = null
var _layer_hair: AnimatedSprite2D = null
var _layer_cloak_behind: AnimatedSprite2D = null
var _layer_cloak: AnimatedSprite2D = null
var _layer_head: AnimatedSprite2D = null

# One-shot state
var _is_slash_playing: bool = false
var _resolved_weapon_anim: String = ""
var _resolved_body_anim: String = ""

func _ready() -> void:
	_visual_root = get_node_or_null(visual_root_path)
	_weapon_player = get_node_or_null(weapon_player_path) as AnimationPlayer

	_cache_visual_root_nodes()

	if _weapon_player != null:
		if not _weapon_player.animation_finished.is_connected(_on_weapon_anim_finished):
			_weapon_player.animation_finished.connect(_on_weapon_anim_finished)

	if play_on_ready:
		play_once()

func _unhandled_input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null:
		return
	if not key_event.pressed:
		return

	# F = play one slash (body + weapon) once
	if key_event.keycode == KEY_F:
		play_once()

	# R = re-cache nodes (useful if you edited the rig/paths)
	if key_event.keycode == KEY_R:
		_cache_visual_root_nodes()

	# SPACE = pause/unpause weapon player
	if key_event.keycode == KEY_SPACE:
		_toggle_pause()

	# - / = slow down, + = speed up
	if key_event.keycode == KEY_MINUS:
		speed_scale = maxf(0.1, speed_scale - 0.1)
		_apply_speed()
	if key_event.keycode == KEY_EQUAL:
		speed_scale = minf(3.0, speed_scale + 0.1)
		_apply_speed()

	# Layer toggles
	# 1 Body, 2 Armor, 3 HairBehind, 4 Hair, 5 CloakBehind, 6 Cloak, 7 Head
	if key_event.keycode == KEY_1:
		_toggle_node_visible(_layer_body)
	if key_event.keycode == KEY_2:
		_toggle_node_visible(_layer_armor)
	if key_event.keycode == KEY_3:
		_toggle_node_visible(_layer_hair_behind)
	if key_event.keycode == KEY_4:
		_toggle_node_visible(_layer_hair)
	if key_event.keycode == KEY_5:
		_toggle_node_visible(_layer_cloak_behind)
	if key_event.keycode == KEY_6:
		_toggle_node_visible(_layer_cloak)
	if key_event.keycode == KEY_7:
		_toggle_node_visible(_layer_head)

	# 8 = toggle weapon visibility (main/off)
	if key_event.keycode == KEY_8:
		_toggle_node_visible(_mainhand)
		_toggle_node_visible(_offhand)

	# 9 = toggle trail visibility (if present)
	if key_event.keycode == KEY_9:
		_toggle_node_visible(_weapon_trail)

func play_once() -> void:
	_cache_visual_root_nodes()
	_apply_speed()

	_resolved_body_anim = _resolve_body_anim_name()
	_resolved_weapon_anim = _resolve_weapon_anim_name()

	# Start all body layers at the same time (game-like).
	_play_body_layers_restart(_resolved_body_anim)

	# Start weapon animation from t=0.
	_play_weapon_anim_restart(_resolved_weapon_anim)

	_is_slash_playing = true

func _apply_speed() -> void:
	if _weapon_player == null:
		return
	_weapon_player.speed_scale = speed_scale

func _toggle_pause() -> void:
	if _weapon_player == null:
		return
	_weapon_player.playback_active = not _weapon_player.playback_active

func _resolve_body_anim_name() -> String:
	# Resolve against the first layer that actually has sprite_frames.
	for s: AnimatedSprite2D in _body_layers:
		if s == null:
			continue
		if s.sprite_frames == null:
			continue
		if s.sprite_frames.has_animation(body_anim_name):
			return body_anim_name
		var found: String = _find_anim_case_insensitive(s.sprite_frames, body_anim_name)
		if found != "":
			return found
	return body_anim_name

func _resolve_weapon_anim_name() -> String:
	if _weapon_player == null:
		return weapon_anim_name

	# 1) Try unqualified name
	if _weapon_player.has_animation(weapon_anim_name):
		return weapon_anim_name

	var found: String = _find_player_anim_case_insensitive(_weapon_player, weapon_anim_name)
	if found != "":
		return found

	# 2) Try qualified "Library/Name" (Godot 4 Animation Libraries)
	var lib: String = weapon_anim_library
	if lib == "":
		return weapon_anim_name

	var qualified: String = lib + "/" + weapon_anim_name
	if _weapon_player.has_animation(qualified):
		return qualified

	var found2: String = _find_player_anim_case_insensitive(_weapon_player, qualified)
	if found2 != "":
		return found2

	# 3) As a last-resort, if the user typed a qualified name already, keep it.
	return weapon_anim_name

func _play_body_layers_restart(anim_name: String) -> void:
	for s: AnimatedSprite2D in _body_layers:
		if s == null:
			continue
		if s.sprite_frames == null:
			continue

		var to_play: String = anim_name
		if not s.sprite_frames.has_animation(to_play):
			to_play = _find_anim_case_insensitive(s.sprite_frames, anim_name)

		if to_play == "":
			continue

		# Restart from frame 0, but do NOT change loop flags on the resource.
		s.play(to_play)
		s.frame = 0
		s.frame_progress = 0.0

func _stop_body_layers() -> void:
	for s: AnimatedSprite2D in _body_layers:
		if s == null:
			continue
		s.stop()

func _play_weapon_anim_restart(anim_name: String) -> void:
	if _weapon_player == null:
		return
	if anim_name == "":
		return

	_weapon_player.stop()
	_weapon_player.play(anim_name)
	_weapon_player.seek(0.0, true)

func _on_weapon_anim_finished(anim_name: StringName) -> void:
	if not _is_slash_playing:
		return

	var finished: String = String(anim_name)
	if finished != _resolved_weapon_anim:
		return

	# Weapon clip ended — stop all layers to make this a clean one-shot preview.
	_stop_body_layers()
	_is_slash_playing = false

func _cache_visual_root_nodes() -> void:
	_body_layers.clear()

	_weapon_root = null
	_mainhand = null
	_offhand = null
	_trail_anchor = null
	_mainhand_pivot = null
	_weapon_trail = null

	_layer_body = null
	_layer_armor = null
	_layer_hair_behind = null
	_layer_hair = null
	_layer_cloak_behind = null
	_layer_cloak = null
	_layer_head = null

	if _visual_root == null:
		_visual_root = get_node_or_null(visual_root_path)

	if _visual_root == null:
		return

	_collect_body_layers(_visual_root)
	_cache_named_layers(_visual_root)
	_cache_weapon_nodes(_visual_root)

func _collect_body_layers(root: Node) -> void:
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		var as2d: AnimatedSprite2D = n as AnimatedSprite2D
		if as2d != null:
			_body_layers.append(as2d)
		for c: Node in n.get_children():
			stack.append(c)

func _cache_named_layers(root: Node) -> void:
	_layer_body = _find_first_node_by_name(root, "BodySprite") as AnimatedSprite2D
	_layer_armor = _find_first_node_by_name(root, "ArmorSprite") as AnimatedSprite2D
	_layer_hair_behind = _find_first_node_by_name(root, "HairBehindSprite") as AnimatedSprite2D
	_layer_hair = _find_first_node_by_name(root, "HairSprite") as AnimatedSprite2D
	_layer_cloak_behind = _find_first_node_by_name(root, "CloakBehindSprite") as AnimatedSprite2D
	_layer_cloak = _find_first_node_by_name(root, "CloakSprite") as AnimatedSprite2D
	_layer_head = _find_first_node_by_name(root, "HeadSprite") as AnimatedSprite2D

func _cache_weapon_nodes(root: Node) -> void:
	_weapon_root = _find_first_node_by_name(root, "WeaponRoot") as Node2D
	_mainhand = _find_first_node_by_name(root, "Mainhand") as Sprite2D
	_offhand = _find_first_node_by_name(root, "Offhand") as Sprite2D
	_trail_anchor = _find_first_node_by_name(root, "TrailAnchor") as Node2D
	_mainhand_pivot = _find_first_node_by_name(root, "MainhandPivot") as Node2D
	_weapon_trail = _find_first_node_by_name(root, weapon_trail_node_name)

func _find_first_node_by_name(root: Node, wanted_name: String) -> Node:
	if root == null:
		return null

	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n.name == wanted_name:
			return n
		for c: Node in n.get_children():
			stack.append(c)

	return null

func _toggle_node_visible(n: Node) -> void:
	if n == null:
		return

	var canvas_item: CanvasItem = n as CanvasItem
	if canvas_item == null:
		return

	canvas_item.visible = not canvas_item.visible

func _find_anim_case_insensitive(frames: SpriteFrames, requested: String) -> String:
	var req: String = requested.to_lower()
	for a: StringName in frames.get_animation_names():
		var actual: String = String(a)
		if actual.to_lower() == req:
			return actual
	return ""

func _find_player_anim_case_insensitive(player: AnimationPlayer, requested: String) -> String:
	var req: String = requested.to_lower()
	for name: StringName in player.get_animation_list():
		var actual: String = String(name)
		if actual.to_lower() == req:
			return actual
	return ""
