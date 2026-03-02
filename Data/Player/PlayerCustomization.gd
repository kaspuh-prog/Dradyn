extends Resource
class_name PlayerCustomization
# Godot 4.5 — fully typed, no ternaries.

@export_group("Identity")
@export var display_name: String = ""
@export var gender: StringName = &"unspecified" # e.g. &"male", &"female", &"other"
@export var class_def_path: String = "" # e.g. "res://Data/Classes/Warrior.tres" (or whatever you standardize)

@export_group("Appearance")
@export var hair_id: StringName = &"hair_00" # stable ID that your rig builder resolves later
@export var hair_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var skin_tone: Color = Color(1.0, 1.0, 1.0, 1.0)

func to_dict() -> Dictionary:
	var d: Dictionary = {}
	d["display_name"] = display_name
	d["gender"] = String(gender)
	d["class_def_path"] = class_def_path
	d["hair_id"] = String(hair_id)
	d["hair_color"] = hair_color
	d["skin_tone"] = skin_tone
	return d

static func from_dict(d: Dictionary) -> PlayerCustomization:
	var pc: PlayerCustomization = PlayerCustomization.new()

	if d.has("display_name"):
		pc.display_name = str(d["display_name"])

	if d.has("gender"):
		pc.gender = StringName(str(d["gender"]))

	if d.has("class_def_path"):
		pc.class_def_path = str(d["class_def_path"])

	if d.has("hair_id"):
		pc.hair_id = StringName(str(d["hair_id"]))

	if d.has("hair_color") and typeof(d["hair_color"]) == TYPE_COLOR:
		pc.hair_color = d["hair_color"]

	if d.has("skin_tone") and typeof(d["skin_tone"]) == TYPE_COLOR:
		pc.skin_tone = d["skin_tone"]

	return pc

func is_valid() -> bool:
	if display_name.strip_edges() == "":
		return false
	if class_def_path.strip_edges() == "":
		return false
	if String(hair_id).strip_edges() == "":
		return false
	return true
