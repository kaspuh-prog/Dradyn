extends Node
class_name StatusConditions
# Godot 4.5; explicit types, no ternary. Additive-safe extension of “Dead + Invulnerable” core.

signal status_applied(id: StringName, data: Dictionary)
signal status_removed(id: StringName)
signal dead_state_changed(is_dead: bool)
signal animation_state_hint(name: StringName, data: Dictionary) # e.g. ("dead", { dir = "left" })

@export var stats_path: NodePath
@export var start_tick_immediately: bool = true

# --- DoT ticking defaults (editor-tunable) ---
@export var burn_tick_interval_sec: float = 0.75
@export var poison_tick_interval_sec: float = 1.00
@export var frozen_tick_interval_sec: float = 1.25
@export var burn_default_damage: float = 1.0
@export var poison_default_damage: float = 1.0
@export var frozen_default_damage: float = 0.5

# --- Movement / attack speed modifiers (editor-tunable) ---
@export var frozen_move_speed_mul: float = 0.6           # 40% slow to movement when frozen
@export var frozen_attack_speed_mul: float = 0.6         # 40% slow to attack speed when frozen
@export var snared_move_speed_mul: float = 0.6           # 40% slow to movement when snared
@export var slowed_attack_speed_mul: float = 0.7         # 30% slow to attack speed when slowed

# --- UI tuning for the status banner ---
@export var status_banner_scale: float = 0.85
@export var status_banner_offset: Vector2 = Vector2(0.0, -18.0)

# -----------------------------
# Status keys (StringName for cheap comparisons)
# -----------------------------
const DEAD: StringName = &"dead"
const INVULNERABLE: StringName = &"invulnerable"

const BURNING: StringName = &"burning"
const FROZEN: StringName = &"frozen"
const POISONED: StringName = &"poisoned"
const SNARED: StringName = &"snared"
const SLOWED: StringName = &"slowed"
const MESMERIZED: StringName = &"mesmerized"
const TRANSFORMED: StringName = &"transformed"
const STUNNED: StringName = &"stunned"
const CONFUSED: StringName = &"confused"
const BROKEN: StringName = &"broken"

# -----------------------------
# Default tint colors (used in animation_state_hint payloads)
# -----------------------------
const COLOR_POISONED: Color = Color8(0xA6, 0x4B, 0xD6, 0xFF)  # medium purple
const COLOR_BURNING: Color  = Color8(0xFF, 0x8A, 0x00, 0xFF)  # orange
const COLOR_FROZEN: Color   = Color8(0x66, 0xCC, 0xFF, 0xFF)  # light blue
const COLOR_NONE: Color     = Color(0, 0, 0, 0)                # sentinel: layer chooses default

# Internal storage:
# _statuses[id] = { stacks:int, expires_at:float|-1, source:Node, payload:Dictionary }
var _statuses: Dictionary = {}

var _stats: Node = null
var _time: float = 0.0
var _is_dead_cached: bool = false

# If a status is reapplied/stacked while active, we do not spam the banner.
var _banner_shown_active: Dictionary = {} # key: StringName -> bool

# next scheduled tick time per status id
var _tick_next_at: Dictionary = {} # key: StringName -> float

func _ready() -> void:
	if stats_path != NodePath():
		_stats = get_node(stats_path)
	else:
		_stats = _find_stats_component()
	if _stats != null:
		if _stats.has_signal("hp_changed"):
			_stats.connect("hp_changed", Callable(self, "_on_hp_changed"))
	set_process(true)
	_try_sync_dead_from_stats()

func _process(delta: float) -> void:
	_time += delta
	_tick_active_statuses()
	_expire_elapsed_statuses()

# =============================================================================
# Public query helpers
# =============================================================================

func has(id: StringName) -> bool:
	return _statuses.has(id)

func is_dead() -> bool:
	return has(DEAD)

func is_alive() -> bool:
	return not is_dead()

func is_invulnerable() -> bool:
	return has(INVULNERABLE)

# Convenience checks
func is_burning() -> bool: return has(BURNING)
func is_frozen() -> bool: return has(FROZEN)
func is_poisoned() -> bool: return has(POISONED)
func is_snared() -> bool: return has(SNARED)
func is_slowed() -> bool: return has(SLOWED)
func is_mesmerized() -> bool: return has(MESMERIZED)
func is_transformed() -> bool: return has(TRANSFORMED)
func is_stunned() -> bool: return has(STUNNED)
func is_confused() -> bool: return has(CONFUSED)
func is_broken() -> bool: return has(BROKEN)

# Movement multiplier for consumers (Player, CompanionFollow, enemies, etc.)
# Uses SNARED and FROZEN (stack multiplicatively).
func get_move_speed_multiplier() -> float:
	var mul: float = 1.0
	if is_frozen():
		mul *= clampf(frozen_move_speed_mul, 0.05, 1.0)
	if is_snared():
		mul *= clampf(snared_move_speed_mul, 0.05, 1.0)
	return mul

# Attack-speed multiplier for consumers (e.g., DerivedFormulas.calc_attack_speed).
# Uses SLOWED and FROZEN (stack multiplicatively).
func get_attack_speed_multiplier() -> float:
	var mul: float = 1.0
	if is_frozen():
		mul *= clampf(frozen_attack_speed_mul, 0.05, 1.0)
	if is_slowed():
		mul *= clampf(slowed_attack_speed_mul, 0.05, 1.0)
	return mul

# Gating (per design: TRANSFORMED can still move)
func can_act() -> bool:
	if is_dead():
		return false
	if is_stunned():
		return false
	if is_mesmerized():
		return false
	if is_transformed():
		return false
	return true

func can_move() -> bool:
	if is_dead():
		return false
	# Important: Frozen/Snared do NOT hard-block movement; they only slow.
	if is_stunned():
		return false
	if is_mesmerized():
		return false
	return true

func can_use_abilities() -> bool:
	if is_dead():
		return false
	if is_stunned():
		return false
	if is_mesmerized():
		return false
	if is_transformed():
		return false
	return true

# Optional helpers
func remaining_time(id: StringName) -> float:
	if not _statuses.has(id):
		return 0.0
	var entry: Dictionary = _statuses[id]
	var expires_at: float = float(entry.get("expires_at", -1.0))
	if expires_at < 0.0:
		return -1.0
	return max(0.0, expires_at - _time)

func stacks_of(id: StringName) -> int:
	if not _statuses.has(id):
		return 0
	var entry: Dictionary = _statuses[id]
	return int(entry.get("stacks", 0))

# =============================================================================
# Apply / remove
# =============================================================================

## Apply a status. Options:
##  - duration: float seconds (<=0 means infinite)
##  - stacks: int (>=1)
##  - source: Node (who applied it)
##  - payload: Dictionary
##     Supported DoT payload keys:
##       damage_per_tick: float (else magnitude; else default)
##       tick_interval_sec: float (else default per status)
##       damage_type: String (else Fire/Poison/Ice by status)
func apply(id: StringName, options: Dictionary = {}) -> void:
	var entry: Dictionary = _statuses.get(id, {})
	var stacks: int = 1
	var duration: float = -1.0
	var source: Node = null
	var payload: Dictionary = {}

	if options.has("stacks"):
		stacks = int(options["stacks"])
	if options.has("duration"):
		duration = float(options["duration"])
	if options.has("source"):
		source = options["source"]
	if options.has("payload"):
		payload = options["payload"]

	var expires_at: float = -1.0
	if duration > 0.0:
		expires_at = _time + duration

	var is_new: bool = entry.is_empty()

	if is_new:
		entry = {
			"stacks": max(1, stacks),
			"expires_at": expires_at,
			"source": source,
			"payload": payload
		}
	else:
		entry["stacks"] = int(entry["stacks"]) + max(1, stacks)
		if duration > 0.0:
			entry["expires_at"] = expires_at
		if not payload.is_empty():
			entry["payload"] = payload

	_statuses[id] = entry
	emit_signal("status_applied", id, entry)

	if is_new:
		_schedule_initial_tick_for(id, entry)

	# Visual hints only for first-time add
	if is_new:
		if id == DEAD:
			_handle_dead_entered()
		elif id == INVULNERABLE:
			emit_signal("animation_state_hint", StringName("invulnerable_on"), {"duration": duration})
		elif id == BURNING:
			emit_signal("animation_state_hint", StringName("burn_on"), {"color": _color_for_entry(id, entry), "duration": duration})
		elif id == POISONED:
			emit_signal("animation_state_hint", StringName("poison_on"), {"color": _color_for_entry(id, entry), "duration": duration})
		elif id == FROZEN:
			emit_signal("animation_state_hint", StringName("frozen_on"), {"color": _color_for_entry(id, entry), "duration": duration})
		elif id == STUNNED:
			emit_signal("animation_state_hint", StringName("stunned_on"), {"duration": duration})
		elif id == MESMERIZED:
			emit_signal("animation_state_hint", StringName("mesmerized_on"), {"duration": duration})
		elif id == CONFUSED:
			emit_signal("animation_state_hint", StringName("confused_on"), {"duration": duration})
		elif id == SNARED:
			emit_signal("animation_state_hint", StringName("snared_on"), {"duration": duration})
		elif id == SLOWED:
			emit_signal("animation_state_hint", StringName("slowed_on"), {"duration": duration})
		elif id == TRANSFORMED:
			emit_signal("animation_state_hint", StringName("transformed_on"), {"duration": duration})
		elif id == BROKEN:
			emit_signal("animation_state_hint", StringName("broken_on"), {"duration": duration})

	if not _banner_shown_active.get(id, false):
		_emit_status_banner(id, entry)
		_banner_shown_active[id] = true

func remove(id: StringName) -> void:
	if not _statuses.has(id):
		return
	_statuses.erase(id)
	emit_signal("status_removed", id)

	if _banner_shown_active.has(id):
		_banner_shown_active.erase(id)

	if _tick_next_at.has(id):
		_tick_next_at.erase(id)

	if id == DEAD:
		_handle_dead_exited()
	elif id == INVULNERABLE:
		emit_signal("animation_state_hint", StringName("invulnerable_off"), {})
	elif id == BURNING:
		emit_signal("animation_state_hint", StringName("burn_off"), {})
	elif id == POISONED:
		emit_signal("animation_state_hint", StringName("poison_off"), {})
	elif id == FROZEN:
		emit_signal("animation_state_hint", StringName("frozen_off"), {})
	elif id == STUNNED:
		emit_signal("animation_state_hint", StringName("stunned_off"), {})
	elif id == MESMERIZED:
		emit_signal("animation_state_hint", StringName("mesmerized_off"), {})
	elif id == CONFUSED:
		emit_signal("animation_state_hint", StringName("confused_off"), {})
	elif id == SNARED:
		emit_signal("animation_state_hint", StringName("snared_off"), {})
	elif id == SLOWED:
		emit_signal("animation_state_hint", StringName("slowed_off"), {})
	elif id == TRANSFORMED:
		emit_signal("animation_state_hint", StringName("transformed_off"), {})
	elif id == BROKEN:
		emit_signal("animation_state_hint", StringName("broken_off"), {})

func remove_many(ids: PackedStringArray) -> void:
	var i: int = 0
	while i < ids.size():
		remove(StringName(ids[i]))
		i += 1

# =============================================================================
# Revive helpers (explicit-only)
# =============================================================================

func clear_dead_with_invuln(invuln_seconds: float = 2.0, source: Node = null, payload: Dictionary = {}) -> void:
	if is_dead():
		remove(DEAD)
	if invuln_seconds > 0.0:
		apply(INVULNERABLE, {
			"duration": invuln_seconds,
			"source": source,
			"payload": payload
		})

func clear_dead_if_recovered() -> void:
	pass

func force_set_dead(source: Node = null, payload: Dictionary = {}) -> void:
	if not is_dead():
		apply(DEAD, {"duration": -1.0, "source": source, "payload": payload})

# =============================================================================
# Internals
# =============================================================================

func _find_stats_component() -> Node:
	var p: Node = get_parent()
	if p == null:
		return null
	var i: int = 0
	while i < p.get_child_count():
		var child: Node = p.get_child(i)
		if child != null:
			if child.has_method("get_hp") or child.has_signal("hp_changed"):
				return child
		i += 1
	return null

func _on_hp_changed(current_hp: int, _max_hp: int) -> void:
	if current_hp <= 0:
		if not is_dead():
			apply(DEAD, {"stacks": 1, "duration": -1.0})
	else:
		pass

func _try_sync_dead_from_stats() -> void:
	if _stats != null and _stats.has_method("get_hp"):
		var hp_any: Variant = _stats.call("get_hp")
		var hp: int = 0
		if typeof(hp_any) == TYPE_INT:
			hp = int(hp_any)
		elif typeof(hp_any) == TYPE_FLOAT:
			hp = int(hp_any)
		if hp <= 0 and not is_dead():
			apply(DEAD, {"duration": -1.0})

func _expire_elapsed_statuses() -> void:
	var to_remove: Array = []
	for id in _statuses.keys():
		var entry: Dictionary = _statuses[id]
		var expires_at: float = float(entry.get("expires_at", -1.0))
		if expires_at > 0.0 and _time >= expires_at:
			to_remove.append(id)
	var i: int = 0
	while i < to_remove.size():
		var rid: Variant = to_remove[i]
		if rid is StringName:
			remove(rid)
		elif typeof(rid) == TYPE_STRING:
			remove(StringName(rid))
		i += 1

# --- ticking -------------------------------------------------------------

func _tick_active_statuses() -> void:
	if _stats == null:
		return
	if _statuses.has(BURNING):
		_tick_once(BURNING, _statuses[BURNING])
	if _statuses.has(POISONED):
		_tick_once(POISONED, _statuses[POISONED])
	if _statuses.has(FROZEN):
		_tick_once(FROZEN, _statuses[FROZEN])

func _tick_once(id: StringName, entry: Dictionary) -> void:
	var next_at: float = float(_tick_next_at.get(id, -1.0))
	if next_at < 0.0:
		_schedule_initial_tick_for(id, entry)
		next_at = float(_tick_next_at.get(id, -1.0))

	if next_at >= 0.0 and _time >= next_at:
		var payload: Dictionary = _payload_from_entry(entry)
		var defaults: Dictionary = _defaults_for(id)
		var dmg: float = _resolve_damage_per_tick(id, payload, defaults)
		var dtype: String = _resolve_damage_type(id, payload, defaults)

		if _stats != null:
			_stats.call("apply_damage", dmg, dtype, "Status:" + String(id).capitalize())

		# colored tick popup (matches banner color/offset)
		var tick_col: Color = _color_for_entry(id, entry)
		get_tree().call_group("DamageNumberSpawners", "show_status_tick", _stats, dmg, id, tick_col, status_banner_offset)

		var interval: float = _resolve_tick_interval(id, payload, defaults)
		_tick_next_at[id] = _time + max(0.01, interval)

func _schedule_initial_tick_for(id: StringName, entry: Dictionary) -> void:
	var payload: Dictionary = _payload_from_entry(entry)
	var defaults: Dictionary = _defaults_for(id)
	var interval: float = _resolve_tick_interval(id, payload, defaults)
	if start_tick_immediately:
		_tick_next_at[id] = _time
	else:
		_tick_next_at[id] = _time + max(0.01, interval)

func _defaults_for(id: StringName) -> Dictionary:
	if id == BURNING:
		return { "interval": burn_tick_interval_sec, "damage": burn_default_damage, "type": "Fire" }
	if id == POISONED:
		return { "interval": poison_tick_interval_sec, "damage": poison_default_damage, "type": "Poison" }
	if id == FROZEN:
		return { "interval": frozen_tick_interval_sec, "damage": frozen_default_damage, "type": "Ice" }
	return { "interval": 1.0, "damage": 0.0, "type": "Neutral" }

func _payload_from_entry(entry: Dictionary) -> Dictionary:
	if entry.has("payload"):
		var v: Variant = entry["payload"]
		if typeof(v) == TYPE_DICTIONARY:
			return v
	return {}

func _resolve_damage_per_tick(id: StringName, payload: Dictionary, defaults: Dictionary) -> float:
	if payload.has("damage_per_tick"):
		var v: Variant = payload["damage_per_tick"]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return float(v)
	if payload.has("magnitude"):
		var m: Variant = payload["magnitude"]
		if typeof(m) == TYPE_FLOAT or typeof(m) == TYPE_INT:
			return float(m)
	return float(defaults.get("damage", 0.0))

func _resolve_tick_interval(id: StringName, payload: Dictionary, defaults: Dictionary) -> float:
	if payload.has("tick_interval_sec"):
		var v: Variant = payload["tick_interval_sec"]
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return max(0.01, float(v))
	return max(0.01, float(defaults.get("interval", 1.0)))

func _resolve_damage_type(id: StringName, payload: Dictionary, defaults: Dictionary) -> String:
	if payload.has("damage_type"):
		var v: Variant = payload["damage_type"]
		if typeof(v) == TYPE_STRING:
			return String(v)
	return String(defaults.get("type", "Neutral"))

# --- visuals & banners --------------------------------------------------

func _handle_dead_entered() -> void:
	if not _is_dead_cached:
		_is_dead_cached = true
		emit_signal("dead_state_changed", true)
		emit_signal("animation_state_hint", StringName("dead"), {})
		get_tree().call_group("PartyManager", "on_actor_dead", get_parent())

func _handle_dead_exited() -> void:
	if _is_dead_cached:
		_is_dead_cached = false
		emit_signal("dead_state_changed", false)
		emit_signal("animation_state_hint", StringName("revived"), {})
		get_tree().call_group("PartyManager", "on_actor_revived", get_parent())

func _color_for_entry(id: StringName, entry: Dictionary) -> Color:
	var payload: Dictionary = {}
	if entry.has("payload"):
		var v: Variant = entry["payload"]
		if typeof(v) == TYPE_DICTIONARY:
			payload = v
	if payload.has("color"):
		var c: Variant = payload["color"]
		if typeof(c) == TYPE_COLOR:
			return c
	var s: String = String(id)
	if s == "poisoned":
		return COLOR_POISONED
	if s == "burning":
		return COLOR_BURNING
	if s == "frozen":
		return COLOR_FROZEN
	return COLOR_NONE

func _emit_status_banner(id: StringName, entry: Dictionary) -> void:
	var col: Color = _color_for_entry(id, entry)
	var sent: bool = _emit_to_group_layers(id, col)
	if sent:
		return
	var layer: Node = _find_damage_number_layer()
	if layer != null:
		_call_status_banner(layer, get_parent(), id, col)

func _emit_to_group_layers(id: StringName, col: Color) -> bool:
	var group_nodes: Array = get_tree().get_nodes_in_group("DamageNumberSpawners")
	var any: bool = false
	var i: int = 0
	while i < group_nodes.size():
		var n: Node = group_nodes[i]
		if n != null:
			_call_status_banner(n, get_parent(), id, col)
			any = true
		i += 1
	return any

func _call_status_banner(layer: Node, target: Node, id: StringName, col: Color) -> void:
	if layer.has_method("show_status_applied_ex"):
		var opts: Dictionary = {
			"color": col,
			"scale": status_banner_scale,
			"offset": status_banner_offset
		}
		layer.call("show_status_applied_ex", target, id, opts)
		return
	if layer.has_method("show_status_applied"):
		layer.call("show_status_applied", target, id, col)

func _find_damage_number_layer() -> Node:
	var root: Node = get_tree().current_scene
	if root == null:
		return null
	var queue: Array = [root]
	var qi: int = 0
	while qi < queue.size():
		var n: Node = queue[qi]
		qi += 1
		if n != null:
			if n.get_class() == "DamageNumberLayer":
				return n
			if n.has_method("show_status_applied_ex") or n.has_method("show_status_applied"):
				return n
			var k: int = 0
			while k < n.get_child_count():
				queue.append(n.get_child(k))
				k += 1
	return null
