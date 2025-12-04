extends Resource
class_name StatModifier
## Godot 4.5
##
## Unified modifier for both timed buffs (spells/consumables) and permanent equipment bonuses.
## - Supports add/mul stacking and an optional override channel.
## - Compatible with Dictionary-style modifiers elsewhere in the project.

enum ModifierSourceType {
	OTHER,
	EQUIPMENT,
	CONSUMABLE,
	SPELL,
	AURA,
}

@export var stat_name: StringName = ""
@export var add_value: float = 0.0
@export var mul_value: float = 1.0
@export var source_id: String = ""
@export var duration_sec: float = 0.0

## Optional last-stage override.
@export var apply_override: bool = false
@export var override_value: float = 0.0

## Stacking controls.
@export var stacking_key: StringName = ""
@export var max_stacks: int = 1
@export var refresh_duration_on_stack: bool = true

## Informational source type (enum).
@export var source_type: ModifierSourceType = ModifierSourceType.OTHER

## --- Runtime state (not serialized by default) ---
var _time_left: float = 0.0
var _stacks: int = 1

func _init() -> void:
	_time_left = duration_sec
	_stacks = 1

func start() -> void:
	_time_left = duration_sec
	if _time_left < 0.0:
		_time_left = 0.0

func is_temporary() -> bool:
	return duration_sec > 0.0

func is_permanent() -> bool:
	return not is_temporary()

func time_left() -> float:
	return _time_left

func tick(delta: float) -> void:
	if is_temporary():
		var new_time: float = _time_left - delta
		if new_time < 0.0:
			new_time = 0.0
		_time_left = new_time

func expired() -> bool:
	if is_temporary():
		return _time_left <= 0.0
	return false

func get_stacks() -> int:
	return _stacks

func set_stacks(value: int) -> void:
	var v: int = value
	if v < 1:
		v = 1
	if v > max_stacks:
		v = max_stacks
	_stacks = v

func can_stack_with(other: StatModifier) -> bool:
	if String(stacking_key) == "":
		return false
	if String(other.stacking_key) == "":
		return false
	return str(stacking_key) == str(other.stacking_key)

func add_stack_from(other: StatModifier) -> bool:
	if not can_stack_with(other):
		return false
	if _stacks >= max_stacks:
		return false
	_stacks += 1
	if refresh_duration_on_stack:
		_time_left = duration_sec
	return true

func clone_for_runtime() -> StatModifier:
	var m := StatModifier.new()
	m.stat_name = stat_name
	m.add_value = add_value
	m.mul_value = mul_value
	m.source_id = source_id
	m.duration_sec = duration_sec

	m.apply_override = apply_override
	m.override_value = override_value
	m.stacking_key = stacking_key
	m.max_stacks = max_stacks
	m.refresh_duration_on_stack = refresh_duration_on_stack
	m.source_type = source_type

	m._time_left = duration_sec
	m._stacks = 1
	return m

func effective_mul() -> float:
	if _stacks <= 1:
		return mul_value
	var result: float = 1.0
	var i: int = 0
	while i < _stacks:
		result *= mul_value
		i += 1
	return result

func effective_add() -> float:
	return add_value * float(_stacks)

func has_override() -> bool:
	return apply_override

func to_dict() -> Dictionary:
	var d: Dictionary = {
		"stat_name": str(stat_name),
		"add_value": add_value,
		"mul_value": mul_value,
		"source_id": source_id,
		"duration_sec": duration_sec,
		"time_left": _time_left,
	}
	d["apply_override"] = apply_override
	d["override_value"] = override_value
	d["stacking_key"] = str(stacking_key)
	d["max_stacks"] = max_stacks
	d["refresh_duration_on_stack"] = refresh_duration_on_stack
	d["source_type"] = int(source_type)
	d["stacks"] = _stacks
	return d

func from_dict(d: Dictionary) -> void:
	stat_name    = StringName(d.get("stat_name", ""))
	add_value    = float(d.get("add_value", 0.0))
	mul_value    = float(d.get("mul_value", 1.0))
	source_id    = str(d.get("source_id", ""))
	duration_sec = float(d.get("duration_sec", 0.0))

	_time_left   = float(d.get("time_left", duration_sec))

	apply_override = bool(d.get("apply_override", false))
	override_value = float(d.get("override_value", 0.0))
	stacking_key = StringName(d.get("stacking_key", ""))
	max_stacks = int(d.get("max_stacks", 1))
	refresh_duration_on_stack = bool(d.get("refresh_duration_on_stack", true))

	# FIX: assign enum by underlying int (do not "call" the enum).
	var st_value: int = int(d.get("source_type", int(ModifierSourceType.OTHER)))
	if st_value < 0:
		st_value = int(ModifierSourceType.OTHER)
	source_type = st_value

	_stacks = int(d.get("stacks", 1))
	if _stacks < 1:
		_stacks = 1
	if _stacks > max_stacks:
		_stacks = max_stacks
