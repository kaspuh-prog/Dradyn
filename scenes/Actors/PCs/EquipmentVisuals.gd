extends Node
class_name EquipmentVisuals
# Godot 4.5 — fully typed, no ternaries.
#
# Chest armor:
# - Reads ItemDef.equipment_class (StringName) from equipped chest item and swaps ArmorSprite SpriteFrames.
# - Nothing equipped => Cloth (default_armor_class_when_none).
# - Resolves from:
#   res://assets/sprites/characters/<Gender>/<LayerFolder>/<key>.tres|.res
#
# Cloaks:
# - CloakSprite + CloakBehindSprite are hidden unless a back item is equipped.
# - When equipped, reads ItemDef.cloak_frames_name (or ItemDef.get_cloak_frames_key()) and resolves from:
#   res://assets/sprites/characters/<Gender>/CloakSprites/<key>.tres|.res
#
# Weapons (Mainhand + Offhand):
# - WeaponRoot/Mainhand and WeaponRoot/Offhand are Sprite2D textures.
# - Reads ItemDef.weapon_sprite_name via ItemDef.load_weapon_sprite_texture().
# - Hidden unless MotionPlayer is currently playing an attack animation (begins with attack_anim_prefix).

@export_group("Character Sprites Root")
@export var sprites_root_male: String = "res://assets/sprites/characters/Male/"
@export var sprites_root_female: String = "res://assets/sprites/characters/Female/"
@export var gender_folder: StringName = &"male" # &"male" or &"female" (case-insensitive)

@export_group("Rig Paths (Optional Overrides)")
@export var visual_root_path: NodePath = NodePath("")
@export var body_sprite_path: NodePath = NodePath("")
@export var armor_sprite_path: NodePath = NodePath("")
@export var hair_sprite_path: NodePath = NodePath("")
@export var cloak_sprite_path: NodePath = NodePath("")
@export var cloak_behind_sprite_path: NodePath = NodePath("")
@export var head_sprite_path: NodePath = NodePath("")

@export_group("Weapon Rig Paths (Optional Overrides)")
@export var weapon_root_path: NodePath = NodePath("")
@export var mainhand_sprite_path: NodePath = NodePath("")
@export var offhand_sprite_path: NodePath = NodePath("")
@export var motion_player_path: NodePath = NodePath("")

@export_group("Enabled Layers")
@export var enable_chest_armor: bool = true
@export var enable_cloak: bool = true
@export var enable_weapons: bool = true

# default armor when nothing is equipped
@export var default_armor_class_when_none: StringName = &"cloth"

# Kept for flexibility: if you later want "no armor layer" when unequipped.
@export var hide_armor_when_none: bool = false

# Optional: if your equipped items use equipment_class values that differ from filenames,
# you can provide aliases here (keys and values are case-insensitive).
# Example: "robe" -> "cloth"
@export var equipment_class_aliases: Dictionary[StringName, StringName] = {}

@export_group("Weapon Visibility Rules")
@export var show_weapons_only_during_attacks: bool = true
@export var attack_anim_prefix: String = "attack" # compares lowercase begins_with()
@export var hide_weapons_on_ready: bool = true

@export_group("Debug")
@export var log_debug: bool = false

# Runtime nodes
var _actor: Node = null
var _visual_root: Node = null
var _weapon_root: Node = null

var _body: AnimatedSprite2D = null
var _armor: AnimatedSprite2D = null
var _hair: AnimatedSprite2D = null
var _cloak: AnimatedSprite2D = null
var _cloak_behind: AnimatedSprite2D = null
var _head: AnimatedSprite2D = null

var _mainhand: Sprite2D = null
var _offhand: Sprite2D = null
var _motion_player: AnimationPlayer = null

# Inventory / equipment
var _inventory_sys: Node = null
var _equip_model: Node = null

# Cache: "LayerFolder|gender|key" -> SpriteFrames (or null sentinel)
var _frames_cache: Dictionary = {}

# Cached weapon textures (so we can show/hide without re-loading)
var _cached_mainhand_tex: Texture2D = null
var _cached_offhand_tex: Texture2D = null

func _ready() -> void:
	_resolve_nodes()
	_try_bind_equipment()
	_try_bind_motion_player()
	_refresh_from_current_equipment()

	if enable_weapons and hide_weapons_on_ready:
		_apply_weapon_visibility(false)

func _exit_tree() -> void:
	_unbind_motion_player()

# -----------------------------------------------------------------------------
# Resolve rig nodes
# -----------------------------------------------------------------------------
func _resolve_nodes() -> void:
	_actor = _resolve_actor_root()
	_visual_root = _resolve_visual_root()
	_weapon_root = _resolve_weapon_root()

	_body = _resolve_layer_sprite("BodySprite", body_sprite_path)
	_armor = _resolve_layer_sprite("ArmorSprite", armor_sprite_path)
	_hair = _resolve_layer_sprite("HairSprite", hair_sprite_path)
	_cloak = _resolve_layer_sprite("CloakSprite", cloak_sprite_path)
	_cloak_behind = _resolve_layer_sprite("CloakBehindSprite", cloak_behind_sprite_path)
	_head = _resolve_layer_sprite("HeadSprite", head_sprite_path)

	_mainhand = _resolve_weapon_sprite("WeaponRoot/Mainhand", "Mainhand", mainhand_sprite_path)
	_offhand = _resolve_weapon_sprite("WeaponRoot/Offhand", "Offhand", offhand_sprite_path)
	_motion_player = _resolve_motion_player()

func _resolve_actor_root() -> Node:
	var actor: Node = self
	var p: Node = self
	while p != null:
		if p is CharacterBody2D:
			actor = p
			break
		if p is Node2D:
			actor = p
		p = p.get_parent()
	return actor

func _resolve_visual_root() -> Node:
	if visual_root_path != NodePath(""):
		var n0: Node = get_node_or_null(visual_root_path)
		if n0 != null:
			return n0

	if _actor != null:
		var vr: Node = _actor.find_child("VisualRoot", true, false)
		if vr != null:
			return vr

	return null

func _resolve_weapon_root() -> Node:
	if weapon_root_path != NodePath(""):
		var n0: Node = get_node_or_null(weapon_root_path)
		if n0 != null:
			return n0

	if _visual_root != null:
		var wr: Node = _visual_root.get_node_or_null(NodePath("WeaponRoot"))
		if wr != null:
			return wr

		var found: Node = _visual_root.find_child("WeaponRoot", true, false)
		if found != null:
			return found

	return null

func _resolve_layer_sprite(expected_name: String, explicit_path: NodePath) -> AnimatedSprite2D:
	if explicit_path != NodePath(""):
		var n: Node = get_node_or_null(explicit_path)
		if n != null:
			var s: AnimatedSprite2D = n as AnimatedSprite2D
			if s != null:
				return s

	if _visual_root != null:
		var direct: Node = _visual_root.get_node_or_null(NodePath(expected_name))
		if direct != null:
			var s2: AnimatedSprite2D = direct as AnimatedSprite2D
			if s2 != null:
				return s2

		var found: Node = _visual_root.find_child(expected_name, true, false)
		if found != null:
			var s3: AnimatedSprite2D = found as AnimatedSprite2D
			if s3 != null:
				return s3

	return null

func _resolve_weapon_sprite(preferred_path_under_visual_root: String, fallback_name: String, explicit_path: NodePath) -> Sprite2D:
	if explicit_path != NodePath(""):
		var n0: Node = get_node_or_null(explicit_path)
		if n0 != null and n0 is Sprite2D:
			return n0 as Sprite2D

	if _visual_root != null:
		var direct: Node = _visual_root.get_node_or_null(NodePath(preferred_path_under_visual_root))
		if direct != null and direct is Sprite2D:
			return direct as Sprite2D

		var found: Node = _visual_root.find_child(fallback_name, true, false)
		if found != null and found is Sprite2D:
			return found as Sprite2D

	if _weapon_root != null:
		var found2: Node = _weapon_root.find_child(fallback_name, true, false)
		if found2 != null and found2 is Sprite2D:
			return found2 as Sprite2D

	return null

func _resolve_motion_player() -> AnimationPlayer:
	if motion_player_path != NodePath(""):
		var n0: Node = get_node_or_null(motion_player_path)
		if n0 != null and n0 is AnimationPlayer:
			return n0 as AnimationPlayer

	if _visual_root != null:
		var direct: Node = _visual_root.get_node_or_null(NodePath("MotionPlayer"))
		if direct != null and direct is AnimationPlayer:
			return direct as AnimationPlayer

		var found: Node = _visual_root.find_child("MotionPlayer", true, false)
		if found != null and found is AnimationPlayer:
			return found as AnimationPlayer

	return null

func _ensure_nodes() -> void:
	if _actor == null or _visual_root == null:
		_resolve_nodes()

# -----------------------------------------------------------------------------
# Bind to equipment changes (InventorySystem -> EquipmentModel)
# -----------------------------------------------------------------------------
func _try_bind_equipment() -> void:
	_inventory_sys = _resolve_inventory_system()
	if _inventory_sys == null:
		return
	if _actor == null:
		_actor = _resolve_actor_root()
	if _actor == null:
		return

	if not _inventory_sys.has_method("ensure_equipment_model_for"):
		return

	var em_any: Variant = _inventory_sys.call("ensure_equipment_model_for", _actor)
	var em: Node = em_any as Node
	if em == null:
		return
	_equip_model = em

	if _equip_model.has_signal("equipped_changed"):
		var c: Callable = Callable(self, "_on_equipped_changed")
		if not _equip_model.is_connected("equipped_changed", c):
			_equip_model.connect("equipped_changed", c)

func _resolve_inventory_system() -> Node:
	var root: Viewport = get_tree().root
	if root == null:
		return null

	var n: Node = root.get_node_or_null("InventorySystem")
	if n != null:
		return n

	n = root.get_node_or_null("InventorySys")
	if n != null:
		return n
	return root.get_node_or_null("Inventory")

func _refresh_from_current_equipment() -> void:
	if _equip_model == null:
		_apply_chest_item(null)
		_apply_back_item(null)
		_apply_mainhand_item(null)
		_apply_offhand_item(null)
		return
	if not _equip_model.has_method("get_equipped"):
		_apply_chest_item(null)
		_apply_back_item(null)
		_apply_mainhand_item(null)
		_apply_offhand_item(null)
		return

	var chest_any: Variant = _equip_model.call("get_equipped", "chest")
	var chest_item: Resource = chest_any as Resource
	_apply_chest_item(chest_item)

	var back_any: Variant = _equip_model.call("get_equipped", "back")
	var back_item: Resource = back_any as Resource
	_apply_back_item(back_item)

	var main_any: Variant = _equip_model.call("get_equipped", "mainhand")
	var main_item: Resource = main_any as Resource
	_apply_mainhand_item(main_item)

	var off_any: Variant = _equip_model.call("get_equipped", "offhand")
	var off_item: Resource = off_any as Resource
	_apply_offhand_item(off_item)

func _on_equipped_changed(slot: String, _prev_item: Resource, new_item: Resource) -> void:
	if slot == "chest":
		_apply_chest_item(new_item)
		return
	if slot == "back":
		_apply_back_item(new_item)
		return
	if slot == "mainhand":
		_apply_mainhand_item(new_item)
		return
	if slot == "offhand":
		_apply_offhand_item(new_item)
		return

# -----------------------------------------------------------------------------
# Apply visuals — Chest (ArmorSprite)
# -----------------------------------------------------------------------------
func _apply_chest_item(item: Resource) -> void:
	if not enable_chest_armor:
		return

	_ensure_nodes()
	if _armor == null:
		return

	# If nothing equipped: default to cloth
	if item == null:
		var def_key: String = String(default_armor_class_when_none).strip_edges()
		if def_key == "":
			def_key = "cloth"
		def_key = _apply_equipment_class_alias(def_key)

		var def_frames: SpriteFrames = _resolve_frames_for("ArmorSprites", def_key)
		if def_frames == null:
			if hide_armor_when_none:
				_armor.visible = false
			return

		_swap_frames_and_sync(_armor, def_frames)
		return

	var eq_class: String = _read_equipment_class(item)
	if eq_class == "":
		_apply_chest_item(null)
		return

	eq_class = _apply_equipment_class_alias(eq_class)

	var frames: SpriteFrames = _resolve_frames_for("ArmorSprites", eq_class)
	if frames == null:
		_apply_chest_item(null)
		return

	_swap_frames_and_sync(_armor, frames)

func _read_equipment_class(item: Resource) -> String:
	if item == null:
		return ""
	if not ("equipment_class" in item):
		return ""
	var v: Variant = item.get("equipment_class")
	if typeof(v) == TYPE_STRING_NAME:
		return String(StringName(v)).strip_edges()
	if typeof(v) == TYPE_STRING:
		return String(v).strip_edges()
	return ""

func _apply_equipment_class_alias(eq_class: String) -> String:
	var key_lc: String = eq_class.to_lower()
	for k in equipment_class_aliases.keys():
		var kk: String = String(k).to_lower()
		if kk == key_lc:
			var vv: Variant = equipment_class_aliases[k]
			if typeof(vv) == TYPE_STRING_NAME:
				return String(StringName(vv)).strip_edges()
			if typeof(vv) == TYPE_STRING:
				return String(vv).strip_edges()
	return eq_class

# -----------------------------------------------------------------------------
# Apply visuals — Back (CloakSprite + CloakBehindSprite)
# -----------------------------------------------------------------------------
func _apply_back_item(item: Resource) -> void:
	if not enable_cloak:
		return

	_ensure_nodes()
	if _cloak == null and _cloak_behind == null:
		return

	if item == null:
		_set_cloak_visible(false)
		return

	var cloak_key: String = _read_cloak_frames_key(item)
	if cloak_key == "":
		_set_cloak_visible(false)
		return

	var frames: SpriteFrames = _resolve_frames_for("CloakSprites", cloak_key)
	if frames == null:
		_set_cloak_visible(false)
		return

	if _cloak != null:
		_swap_frames_and_sync(_cloak, frames)
	if _cloak_behind != null:
		_swap_frames_and_sync(_cloak_behind, frames)

	_set_cloak_visible(true)

func _read_cloak_frames_key(item: Resource) -> String:
	if item == null:
		return ""

	# Preferred: ItemDef.get_cloak_frames_key()
	if item.has_method("get_cloak_frames_key"):
		var v0: Variant = item.call("get_cloak_frames_key")
		var s0: String = String(v0).strip_edges()
		return s0

	# Fallback: raw field (String or StringName)
	if "cloak_frames_name" in item:
		var v1: Variant = item.get("cloak_frames_name")
		if typeof(v1) == TYPE_STRING_NAME:
			var s1: String = String(StringName(v1)).strip_edges()
			return _strip_frames_ext(s1)
		if typeof(v1) == TYPE_STRING:
			var s2: String = String(v1).strip_edges()
			return _strip_frames_ext(s2)

	# Last-resort fallback: equipment_class (optional legacy)
	var eq_class: String = _read_equipment_class(item)
	if eq_class != "":
		return eq_class

	return ""

func _strip_frames_ext(s: String) -> String:
	var lc: String = s.to_lower()
	if lc.ends_with(".tres") or lc.ends_with(".res"):
		return s.get_basename()
	return s

func _set_cloak_visible(on: bool) -> void:
	if _cloak != null:
		_cloak.visible = on and _cloak.sprite_frames != null
	if _cloak_behind != null:
		_cloak_behind.visible = on and _cloak_behind.sprite_frames != null

# -----------------------------------------------------------------------------
# Apply visuals — Weapons (Mainhand + Offhand textures)
# -----------------------------------------------------------------------------
func _apply_mainhand_item(item: Resource) -> void:
	if not enable_weapons:
		return

	_ensure_nodes()
	if _mainhand == null:
		return

	_cached_mainhand_tex = _read_weapon_texture(item)
	_mainhand.texture = _cached_mainhand_tex

	if not show_weapons_only_during_attacks:
		_mainhand.visible = _cached_mainhand_tex != null
	else:
		_mainhand.visible = false

func _apply_offhand_item(item: Resource) -> void:
	if not enable_weapons:
		return

	_ensure_nodes()
	if _offhand == null:
		return

	_cached_offhand_tex = _read_weapon_texture(item)
	_offhand.texture = _cached_offhand_tex

	if not show_weapons_only_during_attacks:
		_offhand.visible = _cached_offhand_tex != null
	else:
		_offhand.visible = false

func _read_weapon_texture(item: Resource) -> Texture2D:
	if item == null:
		return null

	# Preferred: ItemDef.load_weapon_sprite_texture()
	if item.has_method("load_weapon_sprite_texture"):
		var v0: Variant = item.call("load_weapon_sprite_texture")
		var t0: Texture2D = v0 as Texture2D
		return t0

	# Fallback: direct field (future-proof)
	if "weapon_texture" in item:
		var v1: Variant = item.get("weapon_texture")
		var t1: Texture2D = v1 as Texture2D
		return t1

	return null

func _apply_weapon_visibility(on: bool) -> void:
	if _mainhand != null:
		if on:
			_mainhand.visible = _cached_mainhand_tex != null
		else:
			_mainhand.visible = false

	if _offhand != null:
		if on:
			_offhand.visible = _cached_offhand_tex != null
		else:
			_offhand.visible = false

# -----------------------------------------------------------------------------
# Motion player binding (attack-driven weapon visibility)
# -----------------------------------------------------------------------------
func _try_bind_motion_player() -> void:
	if not enable_weapons:
		return

	_ensure_nodes()
	if _motion_player == null:
		if log_debug:
			print("[EquipmentVisuals] MotionPlayer not found; weapon visibility triggers disabled.")
		return

	var c1: Callable = Callable(self, "_on_motion_animation_started")
	if not _motion_player.is_connected("animation_started", c1):
		_motion_player.connect("animation_started", c1)

	var c2: Callable = Callable(self, "_on_motion_animation_finished")
	if not _motion_player.is_connected("animation_finished", c2):
		_motion_player.connect("animation_finished", c2)

func _unbind_motion_player() -> void:
	if _motion_player == null:
		return

	var c1: Callable = Callable(self, "_on_motion_animation_started")
	if _motion_player.is_connected("animation_started", c1):
		_motion_player.disconnect("animation_started", c1)

	var c2: Callable = Callable(self, "_on_motion_animation_finished")
	if _motion_player.is_connected("animation_finished", c2):
		_motion_player.disconnect("animation_finished", c2)

func _motion_anim_base_name(anim_full: String) -> String:
	var s: String = anim_full
	var slash_at: int = s.rfind("/")
	if slash_at >= 0:
		s = s.substr(slash_at + 1)

	# Our MotionPlayer convention uses "_weapon" suffix for weapon motion tracks.
	if s.ends_with("_weapon"):
		s = s.substr(0, s.length() - 7)

	return s

func _motion_anim_is_attack(anim_name: StringName) -> bool:
	var s_full: String = String(anim_name)
	var base: String = _motion_anim_base_name(s_full)
	var lower: String = base.to_lower()

	var want_prefix: String = attack_anim_prefix.to_lower()
	if want_prefix == "":
		want_prefix = "attack"

	return lower.begins_with(want_prefix)

func _on_motion_animation_started(anim_name: StringName) -> void:
	if not enable_weapons:
		return
	if not show_weapons_only_during_attacks:
		return

	if not _motion_anim_is_attack(anim_name):
		return

	_apply_weapon_visibility(true)

func _on_motion_animation_finished(anim_name: StringName) -> void:
	if not enable_weapons:
		return
	if not show_weapons_only_during_attacks:
		return

	if not _motion_anim_is_attack(anim_name):
		return

	_apply_weapon_visibility(false)

# -----------------------------------------------------------------------------
# Resource resolution (case-insensitive) for SpriteFrames
# -----------------------------------------------------------------------------
func _sprites_root() -> String:
	var g: String = String(gender_folder).to_lower()
	if g == "female":
		return sprites_root_female
	return sprites_root_male

func _resolve_frames_for(layer_folder: String, key: String) -> SpriteFrames:
	var base: String = _sprites_root()
	if not base.ends_with("/"):
		base += "/"
	var folder_path: String = base + layer_folder + "/"

	var key_lc: String = key.to_lower()
	var cache_key: String = layer_folder + "|" + String(gender_folder).to_lower() + "|" + key_lc
	if _frames_cache.has(cache_key):
		var cached: Variant = _frames_cache[cache_key]
		return cached as SpriteFrames

	var direct_tres: String = folder_path + key_lc + ".tres"
	if ResourceLoader.exists(direct_tres):
		var r0: Resource = ResourceLoader.load(direct_tres)
		var sf0: SpriteFrames = r0 as SpriteFrames
		_frames_cache[cache_key] = sf0
		return sf0

	var direct_res: String = folder_path + key_lc + ".res"
	if ResourceLoader.exists(direct_res):
		var r00: Resource = ResourceLoader.load(direct_res)
		var sf00: SpriteFrames = r00 as SpriteFrames
		_frames_cache[cache_key] = sf00
		return sf00

	var da: DirAccess = DirAccess.open(folder_path)
	if da == null:
		_frames_cache[cache_key] = null
		return null

	da.list_dir_begin()
	while true:
		var fn: String = da.get_next()
		if fn == "":
			break
		if da.current_is_dir():
			continue

		var ext: String = fn.get_extension().to_lower()
		if ext != "tres" and ext != "res":
			continue

		var stem: String = fn.get_basename().to_lower()
		if stem == key_lc:
			var full_path: String = folder_path + fn
			if ResourceLoader.exists(full_path):
				var r1: Resource = ResourceLoader.load(full_path)
				var sf1: SpriteFrames = r1 as SpriteFrames
				_frames_cache[cache_key] = sf1
				return sf1

	da.list_dir_end()

	_frames_cache[cache_key] = null
	return null

# -----------------------------------------------------------------------------
# Swap + sync (prevents popping)
# -----------------------------------------------------------------------------
func _swap_frames_and_sync(layer: AnimatedSprite2D, frames: SpriteFrames) -> void:
	if layer == null:
		return

	layer.sprite_frames = frames

	if frames == null:
		layer.visible = false
		return

	layer.visible = true

	var target_anim: String = ""
	var target_frame: int = 0
	var target_progress: float = 0.0
	var want_playing: bool = false

	if _body != null and _body.sprite_frames != null:
		target_anim = _body.animation
		target_frame = _body.frame
		target_progress = _body.frame_progress
		want_playing = _body.is_playing()

	if target_anim == "" or not frames.has_animation(target_anim):
		if frames.has_animation("idle_down"):
			target_anim = "idle_down"
		else:
			var names: PackedStringArray = frames.get_animation_names()
			if names.size() > 0:
				target_anim = names[0]
			else:
				target_anim = ""

	if target_anim == "":
		return

	var count: int = frames.get_frame_count(target_anim)
	if count <= 0:
		return
	if target_frame < 0:
		target_frame = 0
	if target_frame >= count:
		target_frame = count - 1

	layer.animation = target_anim
	layer.frame = target_frame
	layer.frame_progress = target_progress

	if want_playing:
		layer.play(target_anim)
	else:
		layer.stop()
