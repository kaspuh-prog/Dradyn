extends Node
class_name LevelComponent

signal xp_changed(current_xp: int, xp_to_next: int, level: int)
signal level_up(new_level: int, levels_gained: int)
signal points_changed(unspent: int) # Stat/attribute points (existing, for StatsSheet)

# NEW: separate pool for SkillTree buying
signal skill_points_changed(unspent: int, total_awarded: int)

@export var stats_component_path: NodePath
@onready var stats_component: Node = null

@export var class_def: ClassDefinition

@export var level: int = 1
@export var current_xp: int = 0
@export var max_level: int = 50
@export var levelup_anchor: NodePath

@export var base_xp_to_next: int = 100
@export var xp_growth_per_level: float = 1.20

# --- Existing: STAT/ATTRIBUTE points (left panel / StatsSheet) ---
@export var points_per_level: int = 1
@export var spendable_stats: PackedStringArray = [
	"STR", "DEX", "STA", "INT", "WIS", "LCK"
]
var unspent_points: int = 0

# --- NEW: SKILL points (for SkillTree purchases) ---
@export var use_skill_points_formula: bool = true
@export var skill_points_per_level: int = 1 # used only if use_skill_points_formula == false

var unspent_skill_points: int = 0
var total_skill_points_awarded: int = 0

func _ready() -> void:
	_resolve_stats_component()
	# Defer so StatsComponent + other siblings complete _ready() first
	call_deferred("_post_ready_finalize")

func _post_ready_finalize() -> void:
	# Extra safety for late-bound resources (e.g., ClassDefinition)
	await get_tree().process_frame
	_apply_class_to_stats(true)
	# Nudge again one frame later so HUD receives final values/signals
	await get_tree().process_frame
	_force_refill_and_emit()

	# Initialize SKILL points pool to proper cumulative amount for current level.
	# For fresh characters at level 1 this becomes 1; for loaded saves, this ensures consistency.
	var cumulative_skill: int = skill_points_cumulative_for(level)
	unspent_skill_points = cumulative_skill
	total_skill_points_awarded = cumulative_skill
	emit_signal("skill_points_changed", unspent_skill_points, total_skill_points_awarded)

# -------------------------------------------------------------------
# Public API — XP/Level
# -------------------------------------------------------------------
func get_xp_to_next() -> int:
	var lv: int = max(level - 1, 0)
	var req: float = float(base_xp_to_next) * pow(xp_growth_per_level, float(lv))
	return int(round(req))

func add_xp(amount: int) -> void:
	if amount <= 0:
		return
	# NEW: Do not accept XP if owner is dead.
	if _is_owner_dead():
		return

	current_xp += amount
	var cap: int = get_xp_to_next()
	while current_xp >= cap and level < max_level:
		current_xp -= cap
		level += 1
		_on_level_up()
		cap = get_xp_to_next()
	emit_signal("xp_changed", current_xp, cap, level)

# -------------------------------------------------------------------
# Public API — STAT/ATTRIBUTE points (existing)
# -------------------------------------------------------------------
func get_unspent_points() -> int:
	return unspent_points

func can_allocate(stat_name: String) -> bool:
	if stats_component != null and stats_component.has_method("can_allocate"):
		var v: Variant = stats_component.call("can_allocate", stat_name)
		if typeof(v) == TYPE_BOOL:
			return bool(v)
	var norm: String = _normalize_stat_key(stat_name)
	var i: int = 0
	while i < spendable_stats.size():
		if _normalize_stat_key(spendable_stats[i]) == norm:
			return true
		i += 1
	return false

func allocate_points(allocation: Dictionary) -> void:
	if allocation.is_empty():
		return
	if unspent_points <= 0:
		return
	var spent: int = 0

	for raw_key in allocation.keys():
		var stat_name: String = str(raw_key)
		if can_allocate(stat_name) == false:
			continue

		var cnt_v: Variant = allocation[raw_key]
		var count: int = 0
		if typeof(cnt_v) == TYPE_INT:
			count = int(cnt_v)
		if count <= 0:
			continue

		var remaining: int = unspent_points - spent
		if remaining <= 0:
			break
		var grant: int = count
		if grant > remaining:
			grant = remaining

		var applied: int = _apply_points_to_stats_component(stat_name, grant)
		if applied > 0:
			spent += applied

	if spent > 0:
		unspent_points = max(unspent_points - spent, 0)
		emit_signal("points_changed", unspent_points)

func allocate_stat_point(stat_name: String, count: int = 1) -> void:
	if count <= 0:
		return
	var d: Dictionary = {}
	d[stat_name] = count
	allocate_points(d)

func spend_points(stat_name: String, count: int) -> void:
	allocate_stat_point(stat_name, count)

func spend_point(stat_name: String) -> void:
	allocate_stat_point(stat_name, 1)

func consume_points(count: int) -> void:
	if count <= 0:
		return
	unspent_points = max(unspent_points - count, 0)
	emit_signal("points_changed", unspent_points)

# -------------------------------------------------------------------
# Public API — SKILL points (NEW, for SkillTree)
# -------------------------------------------------------------------
func get_unspent_skill_points() -> int:
	return unspent_skill_points

func get_total_skill_points_awarded() -> int:
	return total_skill_points_awarded

func spend_skill_points(count: int) -> bool:
	if count <= 0:
		return false
	if unspent_skill_points < count:
		return false
	unspent_skill_points = unspent_skill_points - count
	emit_signal("skill_points_changed", unspent_skill_points, total_skill_points_awarded)
	return true

func grant_skill_points(count: int) -> void:
	if count <= 0:
		return
	unspent_skill_points = unspent_skill_points + count
	total_skill_points_awarded = total_skill_points_awarded + count
	emit_signal("skill_points_changed", unspent_skill_points, total_skill_points_awarded)

# -------------------------------------------------------------------
# Resolve where to place the popup over this actor
# -------------------------------------------------------------------
func _resolve_levelup_anchor() -> Node2D:
	if levelup_anchor != NodePath() and has_node(levelup_anchor):
		var n := get_node(levelup_anchor)
		if n is Node2D:
			return n as Node2D
	var p: Node = self
	while p != null:
		if p is Node2D:
			return p as Node2D
		p = p.get_parent()
	return null

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------
func _resolve_stats_component() -> void:
	stats_component = get_node_or_null(stats_component_path)
	if stats_component == null:
		var p: Node = get_parent()
		if p != null:
			var cand: Node = p.get_node_or_null("StatsComponent")
			if cand != null:
				stats_component = cand

func _apply_class_to_stats(refill_after: bool) -> void:
	_resolve_stats_component()
	if stats_component == null:
		return

	if stats_component.has_method("set_class_def"):
		stats_component.call("set_class_def", class_def)

	if class_def != null and class_def.has_method("initialize_character"):
		class_def.initialize_character(stats_component)

	if stats_component.has_method("_recalc_processing"):
		stats_component.call("_recalc_processing")

	_reconcile_all_vitals()
	if refill_after == true:
		_refill_all_vitals_to_max()

func _on_level_up() -> void:
	if stats_component == null:
		# We still award points even if stats_component is missing
		pass
	if class_def != null and class_def.has_method("apply_level_growth"):
		class_def.apply_level_growth(stats_component, level)

	if stats_component != null and stats_component.has_method("_recalc_processing"):
		stats_component.call("_recalc_processing")

	_reconcile_all_vitals()

	# NEW: do not refill HP/MP/END if dead (prevents level-up revive)
	if _is_owner_dead() == false:
		_refill_all_vitals_to_max()

	# --- Award STAT/ATTRIBUTE points (existing behavior) ---
	if points_per_level > 0:
		unspent_points = unspent_points + points_per_level
		emit_signal("points_changed", unspent_points)

	# --- Award SKILL points (NEW) ---
	var awarded_skill: int = 0
	if use_skill_points_formula:
		var now_total: int = skill_points_cumulative_for(level)
		var prev_total: int = skill_points_cumulative_for(max(level - 1, 0))
		awarded_skill = max(now_total - prev_total, 0)
	else:
		if skill_points_per_level > 0:
			awarded_skill = skill_points_per_level

	if awarded_skill > 0:
		unspent_skill_points = unspent_skill_points + awarded_skill
		total_skill_points_awarded = total_skill_points_awarded + awarded_skill
		emit_signal("skill_points_changed", unspent_skill_points, total_skill_points_awarded)

	# Show 'Level Up!' popup via DamageNumber system
	var anchor := _resolve_levelup_anchor()
	if anchor != null:
		get_tree().call_group("LevelUpPopups", "show_for_node", anchor, level)
	else:
		get_tree().call_group("LevelUpPopups", "show_center", level)

	emit_signal("level_up", level, 1)

func _reconcile_all_vitals() -> void:
	if stats_component == null:
		return

	# HP
	if stats_component.has_method("max_hp") and "current_hp" in stats_component:
		var cur := float(stats_component.get("current_hp"))
		var cap := float(stats_component.call("max_hp"))
		if cur > cap:
			stats_component.set("current_hp", cap)
			if stats_component.has_signal("hp_changed"):
				stats_component.emit_signal("hp_changed", cap, cap)

	# MP
	if stats_component.has_method("max_mp") and "current_mp" in stats_component:
		var curm := float(stats_component.get("current_mp"))
		var capm := float(stats_component.call("max_mp"))
		if curm > capm:
			stats_component.set("current_mp", capm)
			if stats_component.has_signal("mp_changed"):
				stats_component.emit_signal("mp_changed", capm, capm)

	# END
	if stats_component.has_method("max_end") and "current_end" in stats_component:
		var cure := float(stats_component.get("current_end"))
		var cape := float(stats_component.call("max_end"))
		if cure > cape:
			stats_component.set("current_end", cape)
			if stats_component.has_signal("end_changed"):
				stats_component.emit_signal("end_changed", cape, cape)

func _refill_all_vitals_to_max() -> void:
	if stats_component == null:
		return

	if stats_component.has_method("max_hp") and "current_hp" in stats_component and stats_component.has_method("change_hp"):
		var dh := float(stats_component.call("max_hp")) - float(stats_component.get("current_hp"))
		if dh > 0.0:
			stats_component.call("change_hp", dh)

	if stats_component.has_method("max_mp") and "current_mp" in stats_component and stats_component.has_method("change_mp"):
		var dm := float(stats_component.call("max_mp")) - float(stats_component.get("current_mp"))
		if dm > 0.0:
			stats_component.call("change_mp", dm)

	if stats_component.has_method("max_end") and "current_end" in stats_component and stats_component.has_method("change_end"):
		var de := float(stats_component.call("max_end")) - float(stats_component.get("current_end"))
		if de > 0.0:
			stats_component.call("change_end", de)

func _force_refill_and_emit() -> void:
	_reconcile_all_vitals()
	_refill_all_vitals_to_max()

# -------------------------------------------------------------------
# Points → StatsComponent bridge (existing)
# -------------------------------------------------------------------
func _apply_points_to_stats_component(stat_name: String, count: int) -> int:
	if count <= 0:
		return 0
	if stats_component == null:
		return 0

	if stats_component.has_method("increment_base_stat"):
		stats_component.call("increment_base_stat", stat_name, count)
		return count

	if stats_component.has_method("add_base_stat"):
		stats_component.call("add_base_stat", stat_name, count)
		return count

	if stats_component.has_method("add_modifier"):
		var mod: Dictionary = {
			"stat_name": stat_name,
			"add_value": float(count),
			"source_id": "points:" + _normalize_stat_key(stat_name)
		}
		stats_component.call("add_modifier", mod)
		return count

	return 0

# -------------------------------------------------------------------
# Utilities
# -------------------------------------------------------------------
func _normalize_stat_key(s: String) -> String:
	var t: String = s.strip_edges()
	t = t.replace("_", "")
	t = t.replace("-", "")
	return t.to_upper()

# NEW: spreadsheet-accurate cumulative skill points = floor(1.5 * level)
func skill_points_cumulative_for(lv: int) -> int:
	var l: int = lv
	if l < 0:
		l = 0
	if l > max_level:
		l = max_level
	var half: int = int(floor(float(l) * 0.5))
	return l + half

# -------------------------------------------------------------------
# Dead-state helpers (no hard dependency on class name)
# -------------------------------------------------------------------
func _get_status_node() -> Node:
	var p: Node = get_parent()
	if p == null:
		return null
	var s: Node = p.get_node_or_null("StatusConditions")
	return s

func _is_owner_dead() -> bool:
	var s: Node = _get_status_node()
	if s == null:
		return false
	if s.has_method("is_dead"):
		var v: Variant = s.call("is_dead")
		if typeof(v) == TYPE_BOOL:
			return bool(v)
	return false
