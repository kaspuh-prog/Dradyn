extends Control
class_name PlayerCustomizationScreen
# Godot 4.5 — fully typed, no ternaries.

signal customization_confirmed(customization: PlayerCustomization)
signal customization_cancelled()

const PlayerCustomizationRes: Script = preload("res://Data/Player/PlayerCustomization.gd")
const VisualRootScene: PackedScene = preload("res://scenes/Actors/PCs/VisualRoot.tscn")

# ------------------------------------------------------------
# UI NodePaths (optional; if empty, we auto-discover using scene conventions)
# ------------------------------------------------------------
@export_group("Core UI")
@export var start_button_path: NodePath
@export var back_button_path: NodePath
@export var name_line_edit_path: NodePath

@export_group("Preview")
@export var preview_viewport_path: NodePath = NodePath("")
@export var preview_center: Vector2 = Vector2(32.0, 32.0)
@export var preview_offset: Vector2 = Vector2(0.0, 8.0)

@export_group("Preview Asset Roots")
@export var characters_root_dir: String = "res://assets/sprites/characters"
@export var body_folder: String = "BodySprites"
@export var hair_folder: String = "HairSprites"

# NEW: armor folder + default armor for preview
@export var armor_folder: String = "ArmorSprites"
@export var default_armor_base_name: String = "Cloth"

@export_group("Preview Naming")
@export var body_base_name: String = "Body" # default frames: Body.res
@export var ignore_hair_suffixes: PackedStringArray = PackedStringArray(["_behind"]) # excluded from style list

@export_group("Female Hair Behind")
@export var enable_female_hair_behind: bool = true
@export var female_hair_behind_styles: PackedStringArray = PackedStringArray(["Braids", "Long"])
@export var hair_behind_suffix: String = "_behind"

@export_group("Preview Animation")
@export var preview_idle_cycle_seconds: float = 5.0
@export var preview_idle_cycle_names: PackedStringArray = PackedStringArray(["idle_down", "idle_up", "idle_side"])
@export var preview_idle_fallbacks: PackedStringArray = PackedStringArray([
	"idle_down",
	"idle",
	"idle_front",
	"idle_south"
])

@export_group("Preview Debug")
@export var preview_debug_print: bool = false

@export_group("Preview Visibility")
@export var hide_weapon_in_preview: bool = true
@export var hide_cloak_in_preview: bool = true
@export var hide_behind_layers_in_preview: bool = true

@export_group("Class Info")
@export var class_title_label_path: NodePath
@export var class_desc_richtext_path: NodePath # RichTextLabel recommended
@export var class_desc_textedit_path: NodePath # OR TextEdit (read-only)

@export_group("Row: Gender")
@export var gender_left_path: NodePath
@export var gender_right_path: NodePath
@export var gender_value_label_path: NodePath

@export_group("Row: Class")
@export var class_left_path: NodePath
@export var class_right_path: NodePath
@export var class_value_label_path: NodePath

@export_group("Row: Skin Tone")
@export var skin_left_path: NodePath
@export var skin_right_path: NodePath
@export var skin_value_label_path: NodePath

@export_group("Row: Hair")
@export var hair_left_path: NodePath
@export var hair_right_path: NodePath
@export var hair_value_label_path: NodePath

@export_group("Row: Hair Color")
@export var hair_color_left_path: NodePath
@export var hair_color_right_path: NodePath
@export var hair_color_value_label_path: NodePath

# ------------------------------------------------------------
# Options
# ------------------------------------------------------------
@export_group("Options: Gender")
@export var genders: PackedStringArray = PackedStringArray(["Male", "Female"])

@export_group("Options: Class (Resource-driven)")
@export var class_def_paths: PackedStringArray = PackedStringArray([
	"res://Data/BaseClasses/Warrior.tres",
	"res://Data/BaseClasses/Rogue.tres",
	"res://Data/BaseClasses/Priest.tres",
	"res://Data/BaseClasses/Necromancer.tres",
	"res://Data/BaseClasses/Magician.tres"
])

# If class_def_paths is empty/overridden or invalid, scan these directories for .tres/.res.
@export_group("Options: Class (Scan Fallback)")
@export var class_def_scan_dirs: PackedStringArray = PackedStringArray([
	"res://Data/BaseClasses"
])
@export var class_def_scan_recursive: bool = false

# Hair styles are overwritten at runtime when scanning is enabled.
@export_group("Options: Hair (Fallback if scan fails)")
@export var hair_ids: PackedStringArray = PackedStringArray(["Braids", "Long", "Pigtails", "Short_2"])

# These arrays define how many tone/color options exist in the UI (size = count).
@export_group("Options: Skin Tones (Count)")
@export var skin_tones: PackedColorArray = PackedColorArray([
	Color(1, 1, 1, 1),
	Color(1, 1, 1, 1),
	Color(1, 1, 1, 1),
	Color(1, 1, 1, 1)
])

@export_group("Options: Hair Colors (Count)")
@export var hair_colors: PackedColorArray = PackedColorArray([
	Color(1, 1, 1, 1),
	Color(1, 1, 1, 1),
	Color(1, 1, 1, 1),
	Color(1, 1, 1, 1)
])

# ------------------------------------------------------------
# Runtime state
# ------------------------------------------------------------
var _start_button: BaseButton
var _back_button: BaseButton
var _name_line: LineEdit

var _class_title: Label
var _class_desc_rich: RichTextLabel
var _class_desc_text: TextEdit

var _gender_left: BaseButton
var _gender_right: BaseButton
var _gender_value: Label

var _class_left: BaseButton
var _class_right: BaseButton
var _class_value: Label

var _skin_left: BaseButton
var _skin_right: BaseButton
var _skin_value: Label

var _hair_left: BaseButton
var _hair_right: BaseButton
var _hair_value: Label

var _hair_color_left: BaseButton
var _hair_color_right: BaseButton
var _hair_color_value: Label

var _gender_i: int = 0
var _class_i: int = 0
var _skin_i: int = 0
var _hair_i: int = 0
var _hair_color_i: int = 0

# Class cache: store title/desc/path per entry so we never “lose classes” due to casting quirks.
class ClassEntry:
	var path: String = ""
	var title: String = ""
	var desc: String = ""

var _classes: Array[ClassEntry] = []

# Preview runtime
var _preview_viewport: SubViewport
var _preview_root: Node2D
var _preview_rig: Node2D
var _preview_body: AnimatedSprite2D

# NEW: preview armor layer
var _preview_armor: AnimatedSprite2D

var _preview_hair: AnimatedSprite2D

# Preview-only behind hair layer
var _preview_hair_behind: AnimatedSprite2D

# Folder scan caches (per gender)
var _hair_styles_by_gender: Dictionary = {} # "Male"/"Female" -> PackedStringArray
var _dir_index_cache: Dictionary = {} # dir_path -> Dictionary(lower_basename -> full_path)

# Idle cycling
var _idle_cycle_index: int = 0
var _idle_cycle_timer: float = 0.0


func _ready() -> void:
	_auto_fill_paths_from_scene_conventions()
	_cache_nodes()
	_wire_buttons()
	_load_class_entries()

	_setup_preview()
	_rescan_hair_styles_for_current_gender()

	_refresh_all()


func _process(delta: float) -> void:
	# Preview idle cycling
	if preview_idle_cycle_seconds <= 0.0:
		return
	if _preview_body == null:
		return

	_idle_cycle_timer += delta
	if _idle_cycle_timer < preview_idle_cycle_seconds:
		return

	_idle_cycle_timer = 0.0
	_idle_cycle_index += 1
	if preview_idle_cycle_names.size() > 0:
		_idle_cycle_index = _wrap_index(_idle_cycle_index, preview_idle_cycle_names.size())
	else:
		_idle_cycle_index = 0

	_apply_preview_anim_cycle()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return

	if event.is_action_pressed("ui_cancel"):
		_emit_cancel()
		return

	if event.is_action_pressed("ui_accept"):
		_try_confirm()
		return


# ------------------------------------------------------------
# Auto-discovery (matches your PlayerCustomizationScreen.tscn conventions)
# ------------------------------------------------------------
func _auto_fill_paths_from_scene_conventions() -> void:
	if start_button_path.is_empty():
		start_button_path = NodePath("ClassInfoPanel/StartButton")
	if name_line_edit_path.is_empty():
		name_line_edit_path = NodePath("PickersPanel/NameLineEdit")
	if back_button_path.is_empty():
		back_button_path = NodePath("BackButton")

	if preview_viewport_path.is_empty():
		preview_viewport_path = NodePath("PreviewPanel/PreviewViewportContainer/PreviewViewport")

	if class_title_label_path.is_empty():
		class_title_label_path = NodePath("ClassInfoPanel/ClassTitle")
	if class_desc_richtext_path.is_empty():
		class_desc_richtext_path = NodePath("ClassInfoPanel/ClassDescription")

	if gender_left_path.is_empty():
		gender_left_path = NodePath("PickersPanel/Row_Gender/LeftBtn")
	if gender_right_path.is_empty():
		gender_right_path = NodePath("PickersPanel/Row_Gender/RightBtn")
	if gender_value_label_path.is_empty():
		gender_value_label_path = NodePath("PickersPanel/Row_Gender/Value")

	if class_left_path.is_empty():
		class_left_path = NodePath("PickersPanel/Row_Class/LeftBtn")
	if class_right_path.is_empty():
		class_right_path = NodePath("PickersPanel/Row_Class/RightBtn")
	if class_value_label_path.is_empty():
		class_value_label_path = NodePath("PickersPanel/Row_Class/Value")

	if skin_left_path.is_empty():
		skin_left_path = NodePath("PickersPanel/Row_SkinTone/LeftBtn")
	if skin_right_path.is_empty():
		skin_right_path = NodePath("PickersPanel/Row_SkinTone/RightBtn")
	if skin_value_label_path.is_empty():
		skin_value_label_path = NodePath("PickersPanel/Row_SkinTone/Value")

	if hair_left_path.is_empty():
		hair_left_path = NodePath("PickersPanel/Row_Hair/LeftBtn")
	if hair_right_path.is_empty():
		hair_right_path = NodePath("PickersPanel/Row_Hair/RightBtn")
	if hair_value_label_path.is_empty():
		hair_value_label_path = NodePath("PickersPanel/Row_Hair/Value")

	if hair_color_left_path.is_empty():
		hair_color_left_path = NodePath("PickersPanel/Row_HairColor/LeftBtn")
	if hair_color_right_path.is_empty():
		hair_color_right_path = NodePath("PickersPanel/Row_HairColor/RightBtn")
	if hair_color_value_label_path.is_empty():
		hair_color_value_label_path = NodePath("PickersPanel/Row_HairColor/Value")


# ------------------------------------------------------------
# Setup
# ------------------------------------------------------------
func _cache_nodes() -> void:
	_start_button = _get_button(start_button_path)
	_back_button = _get_button(back_button_path)
	_name_line = _get_line_edit(name_line_edit_path)

	_class_title = _get_label(class_title_label_path)
	_class_desc_rich = _get_richtext(class_desc_richtext_path)
	_class_desc_text = _get_textedit(class_desc_textedit_path)

	_gender_left = _get_button(gender_left_path)
	_gender_right = _get_button(gender_right_path)
	_gender_value = _get_label(gender_value_label_path)

	_class_left = _get_button(class_left_path)
	_class_right = _get_button(class_right_path)
	_class_value = _get_label(class_value_label_path)

	_skin_left = _get_button(skin_left_path)
	_skin_right = _get_button(skin_right_path)
	_skin_value = _get_label(skin_value_label_path)

	_hair_left = _get_button(hair_left_path)
	_hair_right = _get_button(hair_right_path)
	_hair_value = _get_label(hair_value_label_path)

	_hair_color_left = _get_button(hair_color_left_path)
	_hair_color_right = _get_button(hair_color_right_path)
	_hair_color_value = _get_label(hair_color_value_label_path)

	var vp_node: Node = get_node_or_null(preview_viewport_path)
	_preview_viewport = vp_node as SubViewport


func _wire_buttons() -> void:
	if _start_button != null and not _start_button.pressed.is_connected(_on_start_pressed):
		_start_button.pressed.connect(_on_start_pressed)

	if _back_button != null and not _back_button.pressed.is_connected(_on_back_pressed):
		_back_button.pressed.connect(_on_back_pressed)

	if _name_line != null and not _name_line.text_changed.is_connected(_on_name_changed):
		_name_line.text_changed.connect(_on_name_changed)

	_wire_pair(_gender_left, _gender_right, Callable(self, "_on_gender_left"), Callable(self, "_on_gender_right"))
	_wire_pair(_class_left, _class_right, Callable(self, "_on_class_left"), Callable(self, "_on_class_right"))
	_wire_pair(_skin_left, _skin_right, Callable(self, "_on_skin_left"), Callable(self, "_on_skin_right"))
	_wire_pair(_hair_left, _hair_right, Callable(self, "_on_hair_left"), Callable(self, "_on_hair_right"))
	_wire_pair(_hair_color_left, _hair_color_right, Callable(self, "_on_hair_color_left"), Callable(self, "_on_hair_color_right"))


func _wire_pair(left_btn: BaseButton, right_btn: BaseButton, left_cb: Callable, right_cb: Callable) -> void:
	if left_btn != null and not left_btn.pressed.is_connected(left_cb):
		left_btn.pressed.connect(left_cb)
	if right_btn != null and not right_btn.pressed.is_connected(right_cb):
		right_btn.pressed.connect(right_cb)


# ------------------------------------------------------------
# Classes (robust)
# ------------------------------------------------------------
func _load_class_entries() -> void:
	_classes.clear()

	var candidates: PackedStringArray = PackedStringArray()

	# Prefer explicit list, but only if it exists + isn't "hidden" (_*)
	var i: int = 0
	while i < class_def_paths.size():
		var p: String = String(class_def_paths[i]).strip_edges()
		if p != "":
			if ResourceLoader.exists(p):
				var base0: String = p.get_file().get_basename()
				if not base0.begins_with("_"):
					candidates.append(p)
		i += 1

	# If nothing usable, scan fallback dirs.
	if candidates.size() <= 0:
		candidates = _scan_class_def_paths()

	# Load entries
	i = 0
	while i < candidates.size():
		var p2: String = String(candidates[i]).strip_edges()
		if p2 != "":
			var e: ClassEntry = ClassEntry.new()
			e.path = p2
			_fill_class_entry_from_resource(e, p2)
			_classes.append(e)
		i += 1

	if preview_debug_print:
		print("Classes loaded: ", _classes.size())


func _scan_class_def_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}

	var d: int = 0
	while d < class_def_scan_dirs.size():
		var root: String = String(class_def_scan_dirs[d]).strip_edges()
		if root != "":
			_scan_class_dir(root, out, seen, class_def_scan_recursive)
		d += 1

	out.sort()
	return out


func _scan_class_dir(dir_path: String, out: PackedStringArray, seen: Dictionary, recursive: bool) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return

	da.list_dir_begin()
	var fn: String = da.get_next()
	while fn != "":
		if da.current_is_dir():
			if recursive:
				if fn != "." and fn != "..":
					var sub_path: String = "%s/%s" % [dir_path, fn]
					_scan_class_dir(sub_path, out, seen, recursive)
		else:
			var lower: String = fn.to_lower()
			var ok: bool = lower.ends_with(".tres") or lower.ends_with(".res")
			if ok:
				var base: String = fn.get_basename()

				# omit hidden classes starting with underscore
				if fn.begins_with("_") or base.begins_with("_"):
					fn = da.get_next()
					continue

				var full_path: String = "%s/%s" % [dir_path, fn]
				if ResourceLoader.exists(full_path):
					var key: String = full_path.to_lower()
					if not seen.has(key):
						seen[key] = true
						out.append(full_path)

		fn = da.get_next()
	da.list_dir_end()


func _fill_class_entry_from_resource(e: ClassEntry, path_str: String) -> void:
	var title: String = ""
	var desc: String = ""

	var res: Resource = null
	if ResourceLoader.exists(path_str):
		res = load(path_str)

	if res != null:
		# Preferred: real ClassDefinition fields
		if _resource_has_property(res, "class_title"):
			var v1: Variant = res.get("class_title")
			if typeof(v1) == TYPE_STRING:
				title = String(v1)
		if _resource_has_property(res, "description"):
			var v2: Variant = res.get("description")
			if typeof(v2) == TYPE_STRING:
				desc = String(v2)

		# Fallbacks (if your resource uses different field names in the future)
		if title == "" and _resource_has_property(res, "display_name"):
			var v3: Variant = res.get("display_name")
			if typeof(v3) == TYPE_STRING:
				title = String(v3)
		if desc == "" and _resource_has_property(res, "desc"):
			var v4: Variant = res.get("desc")
			if typeof(v4) == TYPE_STRING:
				desc = String(v4)

	if title == "":
		# Last resort: filename
		title = path_str.get_file().get_basename()

	e.title = title
	e.desc = desc


func _resource_has_property(res: Resource, prop: String) -> bool:
	var plist: Array = res.get_property_list()
	var i: int = 0
	while i < plist.size():
		var d: Dictionary = plist[i]
		if d.has("name"):
			if String(d["name"]) == prop:
				return true
		i += 1
	return false


# ------------------------------------------------------------
# Preview setup + apply
# ------------------------------------------------------------
func _setup_preview() -> void:
	if _preview_viewport == null:
		return

	_preview_viewport.transparent_bg = true
	_preview_viewport.handle_input_locally = false

	_preview_root = Node2D.new()
	_preview_root.name = "PreviewRoot"
	_preview_viewport.add_child(_preview_root)

	_spawn_preview_rig()
	_apply_preview_full()


func _spawn_preview_rig() -> void:
	if _preview_root == null:
		return

	if _preview_rig != null and is_instance_valid(_preview_rig):
		_preview_rig.queue_free()

	var inst: Node = VisualRootScene.instantiate()
	_preview_rig = inst as Node2D
	if _preview_rig == null:
		return

	_preview_rig.name = "PreviewRig"
	_preview_root.add_child(_preview_rig)
	_preview_rig.position = preview_center + preview_offset

	_preview_body = _preview_rig.get_node_or_null(NodePath("BodySprite")) as AnimatedSprite2D

	# NEW: pick up ArmorSprite if present
	_preview_armor = _preview_rig.get_node_or_null(NodePath("ArmorSprite")) as AnimatedSprite2D

	_preview_hair = _preview_rig.get_node_or_null(NodePath("HairSprite")) as AnimatedSprite2D

	# Ensure preview-only behind layer exists (but only visible when we load frames into it)
	_ensure_hair_behind_layer()

	_apply_preview_visibility_rules()


func _ensure_hair_behind_layer() -> void:
	if _preview_rig == null:
		return

	if _preview_hair_behind != null and is_instance_valid(_preview_hair_behind):
		return

	_preview_hair_behind = AnimatedSprite2D.new()
	_preview_hair_behind.name = "HairBehindPreview"
	_preview_rig.add_child(_preview_hair_behind)

	# Put it behind body. Use body z_index if we can.
	var bz: int = 0
	if _preview_body != null:
		bz = _preview_body.z_index
	_preview_hair_behind.z_index = bz - 1
	_preview_hair_behind.visible = false


func _apply_preview_visibility_rules() -> void:
	# Character creation preview should only show the layers we explicitly drive here.
	# Runtime-only layers (weapons, cloaks, behind layers) are hidden to avoid leaking
	# in-progress combat rig/animation work into the customization UI.
	if _preview_rig == null:
		return

	if hide_weapon_in_preview:
		_set_node_visible_by_path(NodePath("WeaponRoot"), false)
		_set_node_visible_by_name("Mainhand", false)
		_set_node_visible_by_name("Offhand", false)
		_set_node_visible_by_name("TrailAnchor", false)
		_set_node_visible_by_name("WeaponTrail", false)
		_set_node_visible_by_name("MainhandPivot", false)

	if hide_cloak_in_preview:
		_set_node_visible_by_name("CloakSprite", false)
		_set_node_visible_by_name("CloakBehindSprite", false)

	if hide_behind_layers_in_preview:
		_set_node_visible_by_name("HairBehindSprite", false)
		# Our preview-only behind layer is intentionally hidden unless we loaded frames into it.
		# Leave HairBehindPreview visibility unchanged here.

	# Ensure any AnimationPlayer embedded in the rig does not autoplay in the UI preview.
	var ap: AnimationPlayer = _preview_rig.get_node_or_null(NodePath("AnimationPlayer")) as AnimationPlayer
	if ap != null:
		ap.stop()


func _set_node_visible_by_path(p: NodePath, v: bool) -> void:
	if _preview_rig == null:
		return
	if p.is_empty():
		return
	var n: Node = _preview_rig.get_node_or_null(p)
	_set_node_visible(n, v)


func _set_node_visible_by_name(name_str: String, v: bool) -> void:
	if _preview_rig == null:
		return
	if name_str.strip_edges() == "":
		return

	var stack: Array[Node] = [_preview_rig]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		if n.name == name_str:
			_set_node_visible(n, v)
		for c: Node in n.get_children():
			stack.append(c)


func _set_node_visible(n: Node, v: bool) -> void:
	if n == null:
		return
	var ci: CanvasItem = n as CanvasItem
	if ci == null:
		return
	ci.visible = v


func _apply_preview_full() -> void:
	_apply_preview_body_frames()

	# NEW: armor frames (default Cloth)
	_apply_preview_armor_frames()

	_apply_preview_hair_frames()
	_apply_preview_anim_cycle()

func _apply_preview_body_frames() -> void:
	if _preview_body == null:
		return

	var gender_folder: String = _gender_folder_name()
	var dir_path: String = "%s/%s/%s" % [characters_root_dir, gender_folder, body_folder]

	# Default: Body
	var base_frames: SpriteFrames = _load_frames_ci(dir_path, body_base_name)
	if base_frames != null:
		_preview_body.sprite_frames = base_frames

	# Variant: Body_01.. if present for tone selection
	var tone_num: int = _wrap_index(_skin_i, max(1, skin_tones.size())) + 1
	var variant_name: String = "%s_%02d" % [body_base_name, tone_num]
	var variant_frames: SpriteFrames = _load_frames_ci(dir_path, variant_name)
	if variant_frames != null:
		_preview_body.sprite_frames = variant_frames


# NEW: default Cloth armor frames for preview
func _apply_preview_armor_frames() -> void:
	if _preview_armor == null:
		return

	var gender_folder: String = _gender_folder_name()
	var dir_path: String = "%s/%s/%s" % [characters_root_dir, gender_folder, armor_folder]

	var armor_base: String = default_armor_base_name.strip_edges()
	if armor_base == "":
		armor_base = "Cloth"

	# Base: Cloth
	var base_frames: SpriteFrames = _load_frames_ci(dir_path, armor_base)
	if base_frames != null:
		_preview_armor.sprite_frames = base_frames

	# Optional authored variants: Cloth_01.. (uses skin_tones count as a simple "variation selector")
	# If you later want a separate "armor color" picker, we can wire it cleanly.
	var var_num: int = _wrap_index(_skin_i, max(1, skin_tones.size())) + 1
	var variant_name: String = "%s_%02d" % [armor_base, var_num]
	var variant_frames: SpriteFrames = _load_frames_ci(dir_path, variant_name)
	if variant_frames != null:
		_preview_armor.sprite_frames = variant_frames


func _apply_preview_hair_frames() -> void:
	if _preview_hair == null:
		return
	if hair_ids.size() <= 0:
		return

	var gender_folder: String = _gender_folder_name()
	var dir_path: String = "%s/%s/%s" % [characters_root_dir, gender_folder, hair_folder]

	var style: String = String(hair_ids[_wrap_index(_hair_i, hair_ids.size())]).strip_edges()
	if style == "":
		return

	# Base: <Style>
	var base_frames: SpriteFrames = _load_frames_ci(dir_path, style)
	if base_frames != null:
		_preview_hair.sprite_frames = base_frames

	# Variant: <Style>_01.. if present for color selection
	var color_num: int = _wrap_index(_hair_color_i, max(1, hair_colors.size())) + 1
	var variant_name: String = "%s_%02d" % [style, color_num]
	var variant_frames: SpriteFrames = _load_frames_ci(dir_path, variant_name)
	if variant_frames != null:
		_preview_hair.sprite_frames = variant_frames

	# Female behind layer for specific styles
	_apply_female_hair_behind(dir_path, style, color_num)


func _apply_female_hair_behind(dir_path: String, style: String, color_num: int) -> void:
	if not enable_female_hair_behind:
		if _preview_hair_behind != null:
			_preview_hair_behind.visible = false
		return

	var is_female: bool = _gender_folder_name() == "Female"
	if not is_female:
		if _preview_hair_behind != null:
			_preview_hair_behind.visible = false
		return

	var needs_behind: bool = false
	var i: int = 0
	while i < female_hair_behind_styles.size():
		var s: String = String(female_hair_behind_styles[i])
		if s != "" and s.to_lower() == style.to_lower():
			needs_behind = true
		i += 1

	if not needs_behind:
		if _preview_hair_behind != null:
			_preview_hair_behind.visible = false
		return

	_ensure_hair_behind_layer()
	if _preview_hair_behind == null:
		return

	# Try behind variant first: <Style>_behind_02, then base <Style>_behind
	var behind_base: String = style + hair_behind_suffix
	var behind_variant: String = "%s_%02d" % [behind_base, color_num]

	var frames: SpriteFrames = _load_frames_ci(dir_path, behind_variant)
	if frames == null:
		frames = _load_frames_ci(dir_path, behind_base)

	if frames == null:
		_preview_hair_behind.visible = false
		return

	_preview_hair_behind.sprite_frames = frames
	_preview_hair_behind.visible = true


func _apply_preview_anim_cycle() -> void:
	# Choose target anim name (idle_down / idle_up / idle_side) based on cycle index
	var want: String = "idle_down"
	if preview_idle_cycle_names.size() > 0:
		var idx: int = _wrap_index(_idle_cycle_index, preview_idle_cycle_names.size())
		want = String(preview_idle_cycle_names[idx])

	_play_preview_idle_ci(_preview_body, want)

	# NEW: play armor anim too
	_play_preview_idle_ci(_preview_armor, want)

	_play_preview_idle_ci(_preview_hair, want)
	if _preview_hair_behind != null and _preview_hair_behind.visible:
		_play_preview_idle_ci(_preview_hair_behind, want)

	# Keep frames aligned (best effort)
	_sync_preview_frames()


func _sync_preview_frames() -> void:
	if _preview_body == null:
		return
	var f: int = _preview_body.frame
	var p: float = _preview_body.frame_progress

	# NEW: sync armor
	if _preview_armor != null:
		_preview_armor.frame = f
		_preview_armor.frame_progress = p

	if _preview_hair != null:
		_preview_hair.frame = f
		_preview_hair.frame_progress = p
	if _preview_hair_behind != null and _preview_hair_behind.visible:
		_preview_hair_behind.frame = f
		_preview_hair_behind.frame_progress = p


func _play_preview_idle_ci(s: AnimatedSprite2D, want_anim: String) -> void:
	if s == null:
		return
	if s.sprite_frames == null:
		return

	var chosen: String = _pick_anim_case_insensitive(s.sprite_frames, want_anim)
	if chosen == "":
		chosen = _pick_idle_fallback_case_insensitive(s.sprite_frames)

	if chosen == "":
		return

	s.play(chosen)


func _pick_anim_case_insensitive(frames: SpriteFrames, want: String) -> String:
	if frames == null:
		return ""
	var names: PackedStringArray = frames.get_animation_names()
	if names.size() <= 0:
		return ""

	var w: String = want.strip_edges().to_lower()
	if w == "":
		return ""

	var i: int = 0
	while i < names.size():
		var nm: String = String(names[i])
		if nm.to_lower() == w:
			return nm
		i += 1

	return ""


func _pick_idle_fallback_case_insensitive(frames: SpriteFrames) -> String:
	if frames == null:
		return ""
	var names: PackedStringArray = frames.get_animation_names()
	if names.size() <= 0:
		return ""

	# 1) preview_default_anim (case-insensitive)
	var defw: String = preview_idle_fallbacks[0]
	if preview_idle_fallbacks.size() > 0:
		defw = String(preview_idle_fallbacks[0])

	var def_try: String = _pick_anim_case_insensitive(frames, defw)
	if def_try != "":
		return def_try

	# 2) fallbacks list (case-insensitive)
	var j: int = 0
	while j < preview_idle_fallbacks.size():
		var want: String = String(preview_idle_fallbacks[j])
		var found: String = _pick_anim_case_insensitive(frames, want)
		if found != "":
			return found
		j += 1

	# 3) any idle*
	var k: int = 0
	while k < names.size():
		var nm2: String = String(names[k])
		if nm2.to_lower().begins_with("idle"):
			return nm2
		k += 1

	# 4) last resort
	return String(names[0])


# ------------------------------------------------------------
# Folder scanning: hair styles only from selected gender folder
# ------------------------------------------------------------
func _rescan_hair_styles_for_current_gender() -> void:
	var g: String = _gender_folder_name()
	var styles: PackedStringArray = _scan_hair_styles_for_gender(g)
	if styles.size() > 0:
		hair_ids = styles
		_hair_i = _wrap_index(_hair_i, hair_ids.size())

	if preview_debug_print:
		print("Rescan gender=", g, " hair_styles=", hair_ids.size())


func _scan_hair_styles_for_gender(gender_folder: String) -> PackedStringArray:
	var dir_path: String = "%s/%s/%s" % [characters_root_dir, gender_folder, hair_folder]
	var da: DirAccess = DirAccess.open(dir_path)
	var styles: PackedStringArray = PackedStringArray()
	if da == null:
		return styles

	var seen: Dictionary = {}

	da.list_dir_begin()
	var fn: String = da.get_next()
	while fn != "":
		if not da.current_is_dir():
			var lower: String = fn.to_lower()
			var ok: bool = lower.ends_with(".res") or lower.ends_with(".tres")
			if ok:
				var base: String = fn.get_basename()

				# omit hidden styles starting with underscore (both filename and basename)
				if fn.begins_with("_") or base.begins_with("_"):
					fn = da.get_next()
					continue

				# ignore explicit suffixes like _behind
				if _ends_with_any_ci(base, ignore_hair_suffixes):
					fn = da.get_next()
					continue

				# strip only trailing _NN (color variant), preserve Short_2
				base = _strip_trailing_two_digit_variant(base)

				# re-check after stripping variant
				if base.begins_with("_"):
					fn = da.get_next()
					continue

				var key: String = base.to_lower()
				if key != "" and not seen.has(key):
					seen[key] = true
					styles.append(base)

		fn = da.get_next()
	da.list_dir_end()

	styles.sort()
	return styles


func _ends_with_any_ci(s: String, suffixes: PackedStringArray) -> bool:
	var sl: String = s.to_lower()
	var i: int = 0
	while i < suffixes.size():
		var suf: String = String(suffixes[i]).to_lower()
		if suf != "" and sl.ends_with(suf):
			return true
		i += 1
	return false


func _strip_trailing_two_digit_variant(name_in: String) -> String:
	var s: String = name_in
	var u: int = s.rfind("_")
	if u == -1:
		return s
	var tail: String = s.substr(u + 1, s.length() - (u + 1))
	if tail.length() != 2:
		return s
	if not tail.is_valid_int():
		return s
	return s.substr(0, u)


# ------------------------------------------------------------
# Directory index + frames load (case-insensitive)
# ------------------------------------------------------------
func _load_frames_ci(dir_path: String, base_name: String) -> SpriteFrames:
	if dir_path.strip_edges() == "":
		return null
	if base_name.strip_edges() == "":
		return null

	var index: Dictionary = _get_or_build_dir_index(dir_path)
	var key: String = base_name.to_lower()
	if index.has(key):
		var p: Variant = index[key]
		if typeof(p) == TYPE_STRING:
			var path_str: String = String(p)
			if ResourceLoader.exists(path_str):
				var res: Resource = load(path_str)
				return res as SpriteFrames

	return null


func _get_or_build_dir_index(dir_path: String) -> Dictionary:
	if _dir_index_cache.has(dir_path):
		var cached: Variant = _dir_index_cache[dir_path]
		if cached is Dictionary:
			return cached

	var out: Dictionary = {}
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		_dir_index_cache[dir_path] = out
		return out

	da.list_dir_begin()
	var fn: String = da.get_next()
	while fn != "":
		if not da.current_is_dir():
			var lower: String = fn.to_lower()
			var ok: bool = lower.ends_with(".res") or lower.ends_with(".tres")
			if ok:
				var base: String = fn.get_basename()
				out[base.to_lower()] = dir_path + "/" + fn
		fn = da.get_next()
	da.list_dir_end()

	_dir_index_cache[dir_path] = out
	return out


# ------------------------------------------------------------
# UI refresh
# ------------------------------------------------------------
func _refresh_all() -> void:
	_refresh_gender()
	_refresh_class()
	_refresh_skin()
	_refresh_hair()
	_refresh_hair_color()
	_refresh_start_enabled()
	_apply_preview_full()


func _refresh_gender() -> void:
	if _gender_value == null:
		return
	if genders.size() <= 0:
		_gender_value.text = "-"
		return
	_gender_i = _wrap_index(_gender_i, genders.size())
	_gender_value.text = genders[_gender_i]


func _refresh_class() -> void:
	if _classes.size() <= 0:
		if _class_value != null:
			_class_value.text = "-"
		if _class_title != null:
			_class_title.text = ""
		_set_class_desc("")
		return

	_class_i = _wrap_index(_class_i, _classes.size())
	var e: ClassEntry = _classes[_class_i]

	if _class_value != null:
		_class_value.text = e.title
	if _class_title != null:
		_class_title.text = e.title
	_set_class_desc(e.desc)


func _set_class_desc(desc: String) -> void:
	if _class_desc_rich != null:
		_class_desc_rich.clear()
		_class_desc_rich.add_text(desc)
	if _class_desc_text != null:
		_class_desc_text.text = desc


func _refresh_skin() -> void:
	if _skin_value == null:
		return
	var count: int = skin_tones.size()
	if count <= 0:
		_skin_value.text = "-"
		return
	_skin_i = _wrap_index(_skin_i, count)
	_skin_value.text = "Tone %d" % (_skin_i + 1)


func _refresh_hair() -> void:
	if _hair_value == null:
		return
	if hair_ids.size() <= 0:
		_hair_value.text = "-"
		return
	_hair_i = _wrap_index(_hair_i, hair_ids.size())
	_hair_value.text = String(hair_ids[_hair_i])


func _refresh_hair_color() -> void:
	if _hair_color_value == null:
		return
	var count: int = hair_colors.size()
	if count <= 0:
		_hair_color_value.text = "-"
		return
	_hair_color_i = _wrap_index(_hair_color_i, count)
	_hair_color_value.text = "Color %d" % (_hair_color_i + 1)


func _refresh_start_enabled() -> void:
	if _start_button == null:
		return

	var ok: bool = true
	if _name_line == null:
		ok = false
	else:
		if _name_line.text.strip_edges() == "":
			ok = false

	if _classes.size() <= 0:
		ok = false

	_start_button.disabled = not ok


# ------------------------------------------------------------
# Callbacks
# ------------------------------------------------------------
func _on_name_changed(_new_text: String) -> void:
	_refresh_start_enabled()


func _on_start_pressed() -> void:
	_try_confirm()


func _on_back_pressed() -> void:
	_emit_cancel()


func _on_gender_left() -> void:
	_gender_i -= 1
	_refresh_gender()
	_rescan_hair_styles_for_current_gender()
	_refresh_hair()
	_apply_preview_full()


func _on_gender_right() -> void:
	_gender_i += 1
	_refresh_gender()
	_rescan_hair_styles_for_current_gender()
	_refresh_hair()
	_apply_preview_full()


func _on_class_left() -> void:
	_class_i -= 1
	_refresh_class()
	_refresh_start_enabled()


func _on_class_right() -> void:
	_class_i += 1
	_refresh_class()
	_refresh_start_enabled()


func _on_skin_left() -> void:
	_skin_i -= 1
	_refresh_skin()
	_apply_preview_full()


func _on_skin_right() -> void:
	_skin_i += 1
	_refresh_skin()
	_apply_preview_full()


func _on_hair_left() -> void:
	_hair_i -= 1
	_refresh_hair()
	_apply_preview_full()


func _on_hair_right() -> void:
	_hair_i += 1
	_refresh_hair()
	_apply_preview_full()


func _on_hair_color_left() -> void:
	_hair_color_i -= 1
	_refresh_hair_color()
	_apply_preview_full()


func _on_hair_color_right() -> void:
	_hair_color_i += 1
	_refresh_hair_color()
	_apply_preview_full()


# ------------------------------------------------------------
# Confirm / Cancel
# ------------------------------------------------------------
func _try_confirm() -> void:
	_refresh_start_enabled()
	if _start_button != null:
		if _start_button.disabled:
			return

	var pc: PlayerCustomization = PlayerCustomizationRes.new() as PlayerCustomization
	if pc == null:
		return

	if _name_line != null:
		pc.display_name = _name_line.text.strip_edges()

	if genders.size() > 0:
		pc.gender = StringName(String(genders[_wrap_index(_gender_i, genders.size())]))

	if _classes.size() > 0:
		var e: ClassEntry = _classes[_wrap_index(_class_i, _classes.size())]
		pc.class_def_path = e.path

	if hair_ids.size() > 0:
		pc.hair_id = StringName(String(hair_ids[_wrap_index(_hair_i, hair_ids.size())]))

	# You’re using authored variants; keep these neutral for now.
	pc.hair_color = Color(1.0, 1.0, 1.0, 1.0)
	pc.skin_tone = Color(1.0, 1.0, 1.0, 1.0)

	if not pc.is_valid():
		return

	customization_confirmed.emit(pc)


func _emit_cancel() -> void:
	customization_cancelled.emit()


# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------
func _gender_folder_name() -> String:
	var g: String = "Male"
	if genders.size() > 0:
		_gender_i = _wrap_index(_gender_i, genders.size())
		var gv: String = String(genders[_gender_i]).to_lower()
		if gv == "female":
			g = "Female"
		elif gv == "male":
			g = "Male"
		else:
			g = "Male"
	return g


func _wrap_index(i: int, size: int) -> int:
	if size <= 0:
		return 0
	while i < 0:
		i += size
	while i >= size:
		i -= size
	return i


func _get_button(path: NodePath) -> BaseButton:
	if path.is_empty():
		return null
	var n: Node = get_node_or_null(path)
	if n == null:
		return null
	return n as BaseButton


func _get_label(path: NodePath) -> Label:
	if path.is_empty():
		return null
	var n: Node = get_node_or_null(path)
	if n == null:
		return null
	return n as Label


func _get_line_edit(path: NodePath) -> LineEdit:
	if path.is_empty():
		return null
	var n: Node = get_node_or_null(path)
	if n == null:
		return null
	return n as LineEdit


func _get_richtext(path: NodePath) -> RichTextLabel:
	if path.is_empty():
		return null
	var n: Node = get_node_or_null(path)
	if n == null:
		return null
	return n as RichTextLabel


func _get_textedit(path: NodePath) -> TextEdit:
	if path.is_empty():
		return null
	var n: Node = get_node_or_null(path)
	if n == null:
		return null
	return n as TextEdit
