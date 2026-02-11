extends Node
class_name CompanionAbilityAI

enum CombatMode { NON_COMBAT, COMBAT }

@export var think_hz: float = 6.0
@export var min_retry_ms: int = 150

# Kept for scene compatibility; no hardcoded fallback anymore.
@export var fallback_attack_id: String = "attack"
@export var use_gcd_for_fallback_attack: bool = false

@export var default_melee_range_px: float = 56.0
@export var default_arc_deg: float = 70.0

# NEW: visual “contact” range for companions.
# Even if the underlying melee hit check is generous, companions should close in so it *looks* like a hit.
# If <= 0, we use the chosen ability/context range as-is.
@export var melee_contact_range_px: float = 22.0

# Small padding so we don't stutter right on the boundary.
@export var melee_range_padding_px: float = 2.0

@export var enemy_groups: PackedStringArray = ["Enemies", "Enemy"]
@export var ally_groups: PackedStringArray = ["PartyMembers"]

@export var debug_companion_ai: bool = false
@export var debug_melee_gate: bool = true
@export var debug_gap_close: bool = true
@export var debug_print_interval_ms: int = 220

# Decision tuning
@export var heal_threshold_ratio: float = 0.55
@export var noncombat_heal_threshold_ratio: float = 0.80
@export var pursue_melee: bool = true
@export var max_target_radius_px: float = 220.0
@export var prefer_ranged_outside_melee: bool = true

# Noncombat / combat detection
@export var noncombat_leader_leash_px: float = 100.0
@export var noncombat_enemy_threat_radius_px: float = 220.0

# When remaining buff time is above this, we do NOT refresh it.
# When time_left <= buff_refresh_threshold_sec, CAI will allow a refresh cast.
@export var buff_refresh_threshold_sec: float = 5.0

# When below this HP ratio in COMBAT, Hybrid prefers ranged-only behavior.
@export var low_hp_combat_ratio: float = 0.5

# Threshold for "urgent" support tasks when deciding whether to enter Combat.
# If <= 0.0, a default of 0.65 is used internally.
@export var combat_support_urgent_threshold_ratio: float = 0.65

# Explicit melee / ranged offense type mapping
const MELEE_OFFENSE_TYPES: Array[String] = ["MELEE"]
const RANGED_OFFENSE_TYPES: Array[String] = [
	"PROJECTILE",
	"DAMAGE_SPELL",
	"DOT_SPELL",
	"DEBUFF"
]

var _owner_body: Node2D = null
var _actor_root: Node2D = null
var _think_accum: float = 0.0
var _last_attempt_msec: int = 0
var _active: bool = true

# Movement / follow integration
var _cf_node: Node = null

# Known Abilities component (may spawn later)
var _kac: Node = null
var _known_ids: PackedStringArray = []

# Ability type cache: ability_id -> String ("MELEE", "PROJECTILE", ...)
var _type_cache: Dictionary = {}

# Combat role: "MELEE", "RANGED", "HYBRID", "UNKNOWN"
var _combat_role: String = "UNKNOWN"

# Combat mode state
var _combat_mode: int = CombatMode.NON_COMBAT

# Support capability overlay: true if we have any REVIVE/HEAL/CURE abilities.
var _has_support_capability: bool = false

# Debug throttling
var _dbg_last_msec: int = 0


func _ready() -> void:
	_actor_root = _resolve_actor_root()
	_owner_body = _actor_root
	if _actor_root != null and is_instance_valid(_actor_root):
		_cf_node = _actor_root.find_child("CompanionFollow", true, false)
	_kac = _resolve_known_abilities()
	_sync_known_abilities_from_component()
	_connect_kac_signals()
	set_active(true)
	_connect_party_manager()


func set_active(active: bool) -> void:
	_active = active
	set_process(_active)
	if debug_companion_ai:
		_dbg("[CAI] set_active(" + str(active) + ")")


func _process(delta: float) -> void:
	if not _active:
		return
	if _is_currently_controlled():
		return
	if _is_dead():
		_halt_motion()
		return

	_think_accum += delta
	var interval: float = 0.0
	if think_hz > 0.01:
		interval = 1.0 / think_hz
	if _think_accum >= interval:
		_think_accum = 0.0
		_think()


func _think() -> void:
	if not _active:
		return
	if _is_currently_controlled():
		return
	if _owner_body == null or not is_instance_valid(_owner_body):
		return

	# Late-resolve KnownAbilities when it spawns after purchases/hotbar.
	if _kac == null or not is_instance_valid(_kac):
		_kac = _resolve_known_abilities()
		if _kac != null and is_instance_valid(_kac):
			_connect_kac_signals()
			_sync_known_abilities_from_component()
			if debug_companion_ai:
				_dbg("[CAI] Found KnownAbilities component late and connected.")

	if _is_dead():
		_halt_motion()
		return

	var now: int = Time.get_ticks_msec()
	if now - _last_attempt_msec < min_retry_ms:
		return
	_last_attempt_msec = now

	# Update our combat mode based on current situation.
	var in_combat: bool = _is_in_combat()

	# Let CompanionFollow know when we've left combat so it can drop back to NonCombat follow.
	if _cf_node != null and is_instance_valid(_cf_node):
		if not in_combat and _cf_node.has_method("clear_combat_target"):
			_cf_node.call("clear_combat_target")

	var choice: Dictionary = _choose_best_ability(in_combat)

	# In COMBAT and no ability chosen: try melee gap-close (unless ranged-only),
	# but only for actors that do NOT have CompanionFollow (legacy fallback).
	# In NON-COMBAT and no ability: do nothing; CompanionFollow owns movement.
	if choice.is_empty():
		if in_combat and not _is_ranged_only() and (_cf_node == null or not is_instance_valid(_cf_node)):
			if debug_gap_close and debug_companion_ai:
				_dbg("[CAI] choice empty -> legacy gap close attempt")
			_try_gap_close_for_melee_attack()
		return

	var ability_id_any: Variant = choice.get("ability_id", "")
	var ability_id: String = String(ability_id_any)
	var ctx_any: Variant = choice.get("context", {})
	var ctx: Dictionary = {}
	if ctx_any is Dictionary:
		ctx = ctx_any

	if ability_id == "":
		if in_combat and not _is_ranged_only() and (_cf_node == null or not is_instance_valid(_cf_node)):
			if debug_gap_close and debug_companion_ai:
				_dbg("[CAI] ability_id empty -> legacy gap close attempt")
			_try_gap_close_for_melee_attack()
		return

	if not ctx.has("aim_dir"):
		ctx["aim_dir"] = _aim_towards_target_in_ctx(ctx)

	if _is_dead():
		_halt_motion()
		return

	# ---------------------------------------------------------
	# MELEE GATE
	# - Always enforced for melee-like abilities in combat.
	# - Debug only controls printing, not gating.
	# - Uses a tighter "contact" range (melee_contact_range_px) so hits look right.
	# ---------------------------------------------------------
	if in_combat and _is_melee_like(ability_id):
		var targ2d: Node2D = null
		if ctx.has("target"):
			var t_any2: Variant = ctx["target"]
			targ2d = t_any2 as Node2D

		if targ2d != null and is_instance_valid(targ2d):
			var range_px: float = default_melee_range_px
			if ctx.has("range"):
				var r_any: Variant = ctx["range"]
				if typeof(r_any) == TYPE_FLOAT or typeof(r_any) == TYPE_INT:
					range_px = float(r_any)

			# Tighten for visuals if configured.
			var gate_range_px: float = range_px
			if melee_contact_range_px > 0.0:
				if gate_range_px > melee_contact_range_px:
					gate_range_px = melee_contact_range_px

			var d: float = (_owner_body.global_position - targ2d.global_position).length()
			var in_range: bool = _in_melee_range(targ2d, gate_range_px)

			if debug_companion_ai and debug_melee_gate:
				_dbg("[CAI][MELEE_GATE] ability=" + ability_id
					+ " target=" + _node_name(targ2d)
					+ " d=" + _fmt(d)
					+ " range_ctx=" + _fmt(range_px)
					+ " range_gate=" + _fmt(gate_range_px)
					+ " in_range=" + str(in_range)
					+ " role=" + _combat_role
					+ " has_CF=" + str(_cf_node != null and is_instance_valid(_cf_node))
				)

			if not in_range:
				# With CompanionFollow: CF keeps closing gap; we just do not cast yet.
				# Without CF: use legacy gap-close steering.
				if _cf_node == null or not is_instance_valid(_cf_node):
					if debug_gap_close and debug_companion_ai:
						_dbg("[CAI][MELEE_GATE] not in range -> legacy gap close")
					_try_gap_close_for_melee_attack()
				return

	var asys: Node = _ability_system()
	if asys == null:
		return

	var ok_any: Variant = asys.call("request_cast", _owner_body, ability_id, ctx)
	var ok: bool = (typeof(ok_any) == TYPE_BOOL and bool(ok_any))

	if debug_companion_ai:
		var tn: String = ""
		if ctx.has("target"):
			var t_any: Variant = ctx["target"]
			var t: Node = t_any as Node
			if t != null and is_instance_valid(t):
				tn = t.name
		_dbg("[CAI] cast ability=" + ability_id + " ok=" + str(ok) + " target=" + tn + " role=" + _combat_role + " mode=" + str(_combat_mode))

	if ok:
		# After a cast, we briefly clear motion for legacy actors without CompanionFollow.
		# For actors with CompanionFollow, movement is fully owned by CF.
		_halt_motion()
	else:
		if _is_melee_like(ability_id) and in_combat and not _is_ranged_only() and (_cf_node == null or not is_instance_valid(_cf_node)):
			if debug_gap_close and debug_companion_ai:
				_dbg("[CAI] cast failed -> legacy gap close attempt")
			_try_gap_close_for_melee_attack()


# ------------------------------------------------------------------ #
# Ability selection via AbilityDef.ability_type
# ------------------------------------------------------------------ #
func _choose_best_ability(in_combat: bool) -> Dictionary:
	_sync_known_abilities_from_component()

	if _known_ids.is_empty() and debug_companion_ai:
		_dbg("[CAI] No known abilities yet (waiting for purchases/hotbar).")

	# Situation reads shared across branches
	var dead_ally: Node2D = _find_dead_ally()
	var lowest_ally_noncombat: Node2D = _find_lowest_hp_ally(noncombat_heal_threshold_ratio)

	var enemy: Node2D = _current_enemy_target()
	if enemy == null or not is_instance_valid(enemy):
		enemy = _pick_enemy_target(max_target_radius_px)

	# Bucket known abilities by type
	var revive_ids: Array[String] = []
	var heal_ids: Array[String] = []
	var cure_ids: Array[String] = []
	var melee_ids: Array[String] = []
	var ranged_ids: Array[String] = []
	var buffish_ids: Array[String] = []
	var summon_ids: Array[String] = []

	var i: int = 0
	while i < _known_ids.size():
		var aid: String = _known_ids[i]
		var atype: String = _ability_type_for(aid)

		if atype == "":
			i += 1
			continue

		if atype == "REVIVE_SPELL":
			revive_ids.append(aid)
		elif atype == "HEAL_SPELL" or atype == "HOT_SPELL":
			heal_ids.append(aid)
		elif atype == "CURE_SPELL":
			cure_ids.append(aid)
		elif atype == "BUFF":
			buffish_ids.append(aid)
		elif atype == "SUMMON_SPELL":
			summon_ids.append(aid)
		elif MELEE_OFFENSE_TYPES.has(atype):
			melee_ids.append(aid)
		elif RANGED_OFFENSE_TYPES.has(atype):
			ranged_ids.append(aid)

		i += 1

	if in_combat:
		return _choose_combat_ability(
			dead_ally,
			enemy,
			revive_ids,
			heal_ids,
			cure_ids,
			melee_ids,
			ranged_ids,
			buffish_ids,
			summon_ids
		)
	else:
		return _choose_noncombat_ability(
			dead_ally,
			lowest_ally_noncombat,
			revive_ids,
			heal_ids,
			cure_ids,
			buffish_ids,
			summon_ids
		)


func _choose_combat_ability(
	dead_ally: Node2D,
	enemy: Node2D,
	revive_ids: Array[String],
	heal_ids: Array[String],
	cure_ids: Array[String],
	melee_ids: Array[String],
	ranged_ids: Array[String],
	buffish_ids: Array[String],
	summon_ids: Array[String]
) -> Dictionary:
	# --- Support overlay in Combat (65% threshold) ---
	# 1) REVIVE
	if dead_ally != null and is_instance_valid(dead_ally) and revive_ids.size() > 0:
		var ri: int = 0
		while ri < revive_ids.size():
			var id_revive: String = revive_ids[ri]
			if _can_cast(id_revive):
				return {"ability_id": id_revive, "context": {"target": dead_ally}}
			ri += 1

	# 2) HEAL (combat threshold ~65%)
	var combat_heal_threshold: float = combat_support_urgent_threshold_ratio
	if combat_heal_threshold <= 0.0:
		combat_heal_threshold = 0.65

	if heal_ids.size() > 0:
		var low_ally: Node2D = _find_lowest_hp_ally(combat_heal_threshold)
		if low_ally != null and is_instance_valid(low_ally):
			var hi: int = 0
			while hi < heal_ids.size():
				var id_heal: String = heal_ids[hi]
				if _can_cast(id_heal):
					return {"ability_id": id_heal, "context": {"target": low_ally}}
				hi += 1

	# 3) CURE if any ally has a status we can cure
	var cure_choice: Dictionary = _choose_cure_target(cure_ids)
	if not cure_choice.is_empty():
		return cure_choice

	# --- Offensive behavior: role-based ---
	if enemy == null or not is_instance_valid(enemy):
		return {}

	var self_ratio: float = _get_self_hp_ratio()
	var role: String = _combat_role

	# Ranged-only role: never intentionally close to melee; only ranged abilities.
	if role == "RANGED":
		return _choose_combat_offense_ranged(enemy, ranged_ids)

	# Melee-only role: always try to engage via melee.
	if role == "MELEE":
		return _choose_combat_offense_melee(enemy, melee_ids)

	# Hybrid role: HP < 50% => ranged-only. Otherwise, pick highest damage overall.
	if role == "HYBRID":
		var hp_threshold: float = low_hp_combat_ratio
		if hp_threshold <= 0.0:
			hp_threshold = 0.5
		if self_ratio > 0.0 and self_ratio < hp_threshold:
			# Low HP hybrid => ranged-only behavior.
			return _choose_combat_offense_ranged(enemy, ranged_ids)
		return _choose_combat_offense_hybrid(enemy, melee_ids, ranged_ids)

	# UNKNOWN fallback: prefer melee if any, otherwise ranged.
	if melee_ids.size() > 0:
		return _choose_combat_offense_melee(enemy, melee_ids)
	return _choose_combat_offense_ranged(enemy, ranged_ids)


func _choose_combat_offense_melee(enemy: Node2D, melee_ids: Array[String]) -> Dictionary:
	if melee_ids.size() == 0:
		return {}

	var best_id: String = _pick_best_ability_by_score(melee_ids)
	if best_id == "":
		return {}

	# Phase 3: tell CompanionFollow this is a melee-style combat target.
	if _cf_node != null and is_instance_valid(_cf_node) and _cf_node.has_method("set_combat_target"):
		_cf_node.call("set_combat_target", enemy, StringName("MELEE"))

	if debug_companion_ai:
		var d: float = 0.0
		if _owner_body != null and is_instance_valid(_owner_body):
			d = (_owner_body.global_position - enemy.global_position).length()
		_dbg("[CAI] choose MELEE id=" + best_id + " enemy=" + _node_name(enemy) + " d=" + _fmt(d))

	return {
		"ability_id": best_id,
		"context": {
			"target": enemy,
			"aim_dir": _aim_towards(enemy),
			"range": default_melee_range_px,
			"arc_deg": default_arc_deg,
			"prefer": "target"
		}
	}


func _choose_combat_offense_ranged(enemy: Node2D, ranged_ids: Array[String]) -> Dictionary:
	if ranged_ids.size() == 0:
		return {}

	var best_id: String = _pick_best_ability_by_score(ranged_ids)
	if best_id == "":
		return {}

	# Phase 3: tell CompanionFollow this is a ranged-style combat target.
	if _cf_node != null and is_instance_valid(_cf_node) and _cf_node.has_method("set_combat_target"):
		_cf_node.call("set_combat_target", enemy, StringName("RANGED"))

	if debug_companion_ai:
		var d: float = 0.0
		if _owner_body != null and is_instance_valid(_owner_body):
			d = (_owner_body.global_position - enemy.global_position).length()
		_dbg("[CAI] choose RANGED id=" + best_id + " enemy=" + _node_name(enemy) + " d=" + _fmt(d))

	return {
		"ability_id": best_id,
		"context": {
			"target": enemy,
			"aim_dir": _aim_towards(enemy)
		}
	}


func _choose_combat_offense_hybrid(
	enemy: Node2D,
	melee_ids: Array[String],
	ranged_ids: Array[String]
) -> Dictionary:
	var best_melee_id: String = _pick_best_ability_by_score(melee_ids)
	var best_ranged_id: String = _pick_best_ability_by_score(ranged_ids)

	var best_melee_score: float = -1.0
	if best_melee_id != "":
		best_melee_score = _damage_score_for(best_melee_id)

	var best_ranged_score: float = -1.0
	if best_ranged_id != "":
		best_ranged_score = _damage_score_for(best_ranged_id)

	if best_melee_score <= 0.0 and best_ranged_score <= 0.0:
		return {}

	# If melee is stronger or tied, prioritize melee. Otherwise, ranged.
	if best_melee_score >= best_ranged_score and best_melee_id != "":
		if _cf_node != null and is_instance_valid(_cf_node) and _cf_node.has_method("set_combat_target"):
			_cf_node.call("set_combat_target", enemy, StringName("MELEE"))
		return {
			"ability_id": best_melee_id,
			"context": {
				"target": enemy,
				"aim_dir": _aim_towards(enemy),
				"range": default_melee_range_px,
				"arc_deg": default_arc_deg,
				"prefer": "target"
			}
		}

	if best_ranged_id != "":
		if _cf_node != null and is_instance_valid(_cf_node) and _cf_node.has_method("set_combat_target"):
			_cf_node.call("set_combat_target", enemy, StringName("RANGED"))
		return {
			"ability_id": best_ranged_id,
			"context": {
				"target": enemy,
				"aim_dir": _aim_towards(enemy)
			}
		}

	return {}


func _choose_noncombat_ability(
	dead_ally: Node2D,
	lowest_ally: Node2D,
	revive_ids: Array[String],
	heal_ids: Array[String],
	cure_ids: Array[String],
	buffish_ids: Array[String],
	summon_ids: Array[String]
) -> Dictionary:
	# NON-COMBAT PRIORITY:
	# 1) REVIVE
	if dead_ally != null and is_instance_valid(dead_ally) and revive_ids.size() > 0:
		var id_revive: String = revive_ids[0]
		if _can_cast(id_revive):
			return {"ability_id": id_revive, "context": {"target": dead_ally}}

	# 2) HEAL (80% threshold)
	if lowest_ally != null and is_instance_valid(lowest_ally) and heal_ids.size() > 0:
		var id_heal: String = heal_ids[0]
		if _can_cast(id_heal):
			return {"ability_id": id_heal, "context": {"target": lowest_ally}}

	# 3) CURE (use ability.cure_status_ids + StatusConditions)
	var cure_choice: Dictionary = _choose_cure_target(cure_ids)
	if not cure_choice.is_empty():
		return cure_choice

	# 4) BUFF — timer-aware using StatModifier.time_left()
	# Prefer buffing self; if self missing, use leader.
	if buffish_ids.size() > 0:
		var target: Node2D = _owner_body
		if target == null or not is_instance_valid(target):
			target = _get_party_leader()
		if target != null and is_instance_valid(target):
			var bi: int = 0
			while bi < buffish_ids.size():
				var buff_id: String = buffish_ids[bi]
				if _should_cast_buff_on_target(buff_id, target):
					var ctx_buff: Dictionary = {}
					# For ALLY_PARTY buffs (like ReinforcedByFaith), do NOT set ctx["target"].
					if not _is_party_buff(buff_id):
						ctx_buff["target"] = target
					return {"ability_id": buff_id, "context": ctx_buff}
				bi += 1

	# 5) FUTURE: SUMMON support hook (currently a stub)
	if summon_ids.size() > 0:
		var sum_id: String = summon_ids[0]
		if _should_cast_summon(sum_id):
			return {"ability_id": sum_id, "context": {}}

	return {}

# ---------------- Ability typing & utils -------------------- #
# (everything below here is identical to your pasted file)

func _choose_cure_target(cure_ids: Array[String]) -> Dictionary:
	if cure_ids.is_empty():
		return {}

	var tree: SceneTree = get_tree()
	if tree == null:
		return {}

	# Gather valid allies once.
	var allies: Array[Node2D] = []
	var i: int = 0
	while i < ally_groups.size():
		var g: String = ally_groups[i]
		var nodes: Array = tree.get_nodes_in_group(g)
		var j: int = 0
		while j < nodes.size():
			var n: Node = nodes[j]
			if n is Node2D and is_instance_valid(n):
				var n2d: Node2D = n as Node2D
				if not _node_in_any_group(n2d, enemy_groups) and not _target_is_dead(n2d):
					allies.append(n2d)
			j += 1
		i += 1

	var ci: int = 0
	while ci < cure_ids.size():
		var aid: String = cure_ids[ci]
		if not _can_cast(aid):
			ci += 1
			continue

		var def_res: Resource = _get_ability_def(aid)
		if def_res == null:
			ci += 1
			continue

		if not ("cure_status_ids" in def_res):
			ci += 1
			continue

		var cure_any: Variant = def_res.get("cure_status_ids")
		if typeof(cure_any) != TYPE_PACKED_STRING_ARRAY:
			ci += 1
			continue

		var cure_ids_arr: PackedStringArray = cure_any
		if cure_ids_arr.is_empty():
			ci += 1
			continue

		var ai: int = 0
		while ai < allies.size():
			var ally: Node2D = allies[ai]
			if ally == null or not is_instance_valid(ally):
				ai += 1
				continue

			var sc: Node = ally.get_node_or_null("StatusConditions")
			if sc == null or not sc.has_method("has"):
				ai += 1
				continue

			var si: int = 0
			var has_any: bool = false
			while si < cure_ids_arr.size():
				var status_name: String = cure_ids_arr[si]
				var sname: StringName = StringName(status_name)
				var hv: Variant = sc.call("has", sname)
				if typeof(hv) == TYPE_BOOL and bool(hv):
					has_any = true
					break
				si += 1

			if has_any:
				return {"ability_id": aid, "context": {"target": ally}}

			ai += 1

		ci += 1

	return {}

func _ability_type_for(ability_id: String) -> String:
	if ability_id == "":
		return ""
	if _type_cache.has(ability_id):
		return String(_type_cache[ability_id])

	var asys: Node = _ability_system()
	var t: String = ""
	if asys != null:
		if asys.has_method("get_ability_type"):
			var v: Variant = asys.call("get_ability_type", ability_id)
			if typeof(v) == TYPE_STRING:
				t = String(v)
		if t == "" and asys.has_method("_resolve_ability_def"):
			var def_any: Variant = asys.call("_resolve_ability_def", ability_id)
			if def_any is Resource:
				var r: Resource = def_any
				if "ability_type" in r:
					var at: Variant = r.get("ability_type")
					if typeof(at) == TYPE_STRING:
						t = String(at)
	if t != "":
		t = t.strip_edges().to_upper()
	_type_cache[ability_id] = t
	return t

func _get_ability_def(ability_id: String) -> Resource:
	if ability_id == "":
		return null
	var asys: Node = _ability_system()
	if asys == null:
		return null
	if asys.has_method("_resolve_ability_def"):
		var def_any: Variant = asys.call("_resolve_ability_def", ability_id)
		if def_any is Resource:
			return def_any
	return null

func _is_party_buff(ability_id: String) -> bool:
	var def_res: Resource = _get_ability_def(ability_id)
	if def_res == null:
		return false
	if "target_rule" in def_res:
		var tr_any: Variant = def_res.get("target_rule")
		if typeof(tr_any) == TYPE_STRING:
			var tr_s: String = String(tr_any)
			if tr_s == "ALLY_PARTY":
				return true
	return false

func _prefer_attack_id(melee_ids: Array[String]) -> String:
	var i: int = 0
	while i < melee_ids.size():
		if melee_ids[i] == "attack":
			return melee_ids[i]
		i += 1
	if melee_ids.size() > 0:
		return melee_ids[0]
	return ""

func _can_cast(ability_id: String) -> bool:
	var asys: Node = _ability_system()
	if asys == null:
		return false
	if asys.has_method("can_cast"):
		var v: Variant = asys.call("can_cast", _owner_body, ability_id)
		return (typeof(v) == TYPE_BOOL and bool(v))
	return false

func _is_melee_like(ability_id: String) -> bool:
	return _ability_type_for(ability_id) == "MELEE" or ability_id == "attack"

func _should_cast_summon(ability_id: String) -> bool:
	return _can_cast(ability_id)

func _damage_score_for(ability_id: String) -> float:
	var def_res: Resource = _get_ability_def(ability_id)
	if def_res == null:
		return 0.0

	if "cooldown_sec" in def_res:
		var any_cd: Variant = def_res.get("cooldown_sec")
		if typeof(any_cd) == TYPE_FLOAT or typeof(any_cd) == TYPE_INT:
			var cd: float = float(any_cd)
			if cd > 0.0:
				return cd
	return 1.0

func _pick_best_ability_by_score(candidates: Array[String]) -> String:
	var best_id: String = ""
	var best_score: float = -1.0

	var i: int = 0
	while i < candidates.size():
		var aid: String = candidates[i]
		if _can_cast(aid):
			var s: float = _damage_score_for(aid)
			if s > best_score:
				best_score = s
				best_id = aid
		i += 1

	return best_id

func _recompute_combat_role() -> void:
	var has_melee: bool = false
	var has_ranged: bool = false
	var has_support: bool = false

	var i: int = 0
	while i < _known_ids.size():
		var aid: String = _known_ids[i]
		var atype: String = _ability_type_for(aid)

		if atype == "":
			i += 1
			continue

		if MELEE_OFFENSE_TYPES.has(atype):
			has_melee = true
		elif RANGED_OFFENSE_TYPES.has(atype):
			has_ranged = true
		elif atype == "REVIVE_SPELL" or atype == "HEAL_SPELL" or atype == "HOT_SPELL" or atype == "CURE_SPELL":
			has_support = true

		i += 1

	var new_role: String = "UNKNOWN"
	if has_melee and has_ranged:
		new_role = "HYBRID"
	elif has_ranged:
		new_role = "RANGED"
	elif has_melee:
		new_role = "MELEE"
	else:
		new_role = "MELEE"

	_combat_role = new_role
	_has_support_capability = has_support

	if debug_companion_ai:
		_dbg("[CAI] combat_role=" + _combat_role + " support=" + str(_has_support_capability))

func _is_ranged_only() -> bool:
	return _combat_role == "RANGED"

func _get_self_hp_ratio() -> float:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return 1.0
	return _hp_ratio_for(_owner_body)

func _should_cast_buff_on_target(ability_id: String, target: Node2D) -> bool:
	if ability_id == "":
		return false
	if target == null or not is_instance_valid(target):
		return false
	if not _can_cast(ability_id):
		return false

	var stats: Node = _get_stats_node(target)
	if stats == null or not is_instance_valid(stats):
		return true

	if not ("modifiers" in stats):
		return true

	var mods_any: Variant = stats.get("modifiers")
	if typeof(mods_any) != TYPE_ARRAY:
		return true

	var mods: Array = mods_any
	var i: int = 0
	while i < mods.size():
		var m: Variant = mods[i]
		i += 1
		if not (m is Resource):
			continue

		var mod: Resource = m

		var sid: String = ""
		if "source_id" in mod:
			var sid_any: Variant = mod.get("source_id")
			if typeof(sid_any) == TYPE_STRING:
				sid = String(sid_any)
		if sid == "":
			continue
		if not sid.begins_with("ability:"):
			continue

		var aid: String = sid.substr(8)
		if aid != ability_id:
			continue

		var is_temp: bool = false
		if mod.has_method("is_temporary"):
			var it_any: Variant = mod.call("is_temporary")
			if typeof(it_any) == TYPE_BOOL:
				is_temp = bool(it_any)

		if not is_temp:
			return false

		var tl: float = 999999.0
		if mod.has_method("time_left"):
			var tl_any: Variant = mod.call("time_left")
			if typeof(tl_any) == TYPE_FLOAT or typeof(tl_any) == TYPE_INT:
				tl = float(tl_any)
		if tl < 0.0:
			tl = 0.0

		if tl > buff_refresh_threshold_sec:
			return false

		return true

	return true

func _halt_motion() -> void:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return

	var has_cf: bool = (_cf_node != null and is_instance_valid(_cf_node))

	if not has_cf and _owner_body.has_method("set_move_dir"):
		_owner_body.call("set_move_dir", Vector2.ZERO)
	if not has_cf and _owner_body is CharacterBody2D:
		var cb: CharacterBody2D = _owner_body as CharacterBody2D
		cb.velocity = Vector2.ZERO

func _try_gap_close_for_melee_attack() -> void:
	if not pursue_melee:
		if debug_gap_close and debug_companion_ai:
			_dbg("[CAI][GAP] pursue_melee=false")
		return
	if _is_ranged_only():
		if debug_gap_close and debug_companion_ai:
			_dbg("[CAI][GAP] ranged-only role; no chase")
		return

	var has_melee: bool = false
	var i: int = 0
	while i < _known_ids.size():
		if MELEE_OFFENSE_TYPES.has(_ability_type_for(_known_ids[i])):
			has_melee = true
			break
		i += 1
	if not has_melee:
		if debug_gap_close and debug_companion_ai:
			_dbg("[CAI][GAP] no melee abilities known")
		return

	var targ: Node2D = _current_enemy_target()
	if targ == null or not is_instance_valid(targ):
		targ = _pick_enemy_target(max_target_radius_px)
		if targ == null or not is_instance_valid(targ):
			if debug_gap_close and debug_companion_ai:
				_dbg("[CAI][GAP] no enemy target")
			return

	var d: float = (_owner_body.global_position - targ.global_position).length()
	var in_rng: bool = _in_melee_range(targ, default_melee_range_px)

	if debug_gap_close and debug_companion_ai:
		_dbg("[CAI][GAP] targ=" + _node_name(targ) + " d=" + _fmt(d) + " in_range=" + str(in_rng) + " has_CF=" + str(_cf_node != null and is_instance_valid(_cf_node)))

	if not in_rng:
		if _movement_blocked():
			if debug_gap_close and debug_companion_ai:
				_dbg("[CAI][GAP] movement blocked")
			_halt_motion()
			return
		_close_gap_towards(targ)

func _request_return_to_leader() -> void:
	if _cf_node == null or not is_instance_valid(_cf_node):
		return
	if _cf_node.has_method("_force_return_to_leader"):
		_cf_node.call("_force_return_to_leader")
		return

	var leader: Node2D = _get_party_leader()
	if leader != null and is_instance_valid(leader):
		if _cf_node.has_method("set_follow_target"):
			_cf_node.call("set_follow_target", leader)

func _resolve_known_abilities() -> Node:
	if _actor_root == null or not is_instance_valid(_actor_root):
		return null
	var cand: Node = _actor_root.get_node_or_null("KnownAbilities")
	if cand != null:
		return cand
	cand = _actor_root.get_node_or_null("KnownAbilitiesComponent")
	if cand != null:
		return cand
	cand = _actor_root.get_node_or_null("KnownAbilitiesCmponent")
	if cand != null:
		return cand

	var q: Array = [_actor_root]
	while not q.is_empty():
		var cur_any: Variant = q.pop_front()
		var cur: Node = cur_any as Node
		if cur != null and is_instance_valid(cur) and cur != self:
			var has_api: bool = false
			if cur.has_method("has_ability"):
				if "known_abilities" in cur:
					has_api = true
			if has_api:
				return cur
			for c in cur.get_children():
				q.append(c)
	return null

func _connect_kac_signals() -> void:
	if _kac == null or not is_instance_valid(_kac):
		return
	if _kac.has_signal("abilities_changed"):
		var cb: Callable = Callable(self, "_on_kac_abilities_changed")
		if not _kac.is_connected("abilities_changed", cb):
			_kac.connect("abilities_changed", cb)

func _on_kac_abilities_changed(current: PackedStringArray) -> void:
	_known_ids = current.duplicate()
	_recompute_combat_role()
	if debug_companion_ai:
		_dbg("[CAI] abilities_changed -> " + str(_known_ids))
	var keys: Array = _type_cache.keys()
	var idx: int = 0
	while idx < keys.size():
		var key: Variant = keys[idx]
		if key is String:
			var sid: String = key
			if not _known_ids.has(sid):
				_type_cache.erase(sid)
		idx += 1

func _sync_known_abilities_from_component() -> void:
	if _kac != null and is_instance_valid(_kac):
		if "known_abilities" in _kac:
			var any_arr: Variant = _kac.get("known_abilities")
			if typeof(any_arr) == TYPE_PACKED_STRING_ARRAY:
				_known_ids = (any_arr as PackedStringArray).duplicate()
				_recompute_combat_role()

func _find_lowest_hp_ally(threshold_ratio: float) -> Node2D:
	var best: Node2D = null
	var best_ratio: float = 1.0
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var i: int = 0
	while i < ally_groups.size():
		var g: String = ally_groups[i]
		var nodes: Array = tree.get_nodes_in_group(g)
		var j: int = 0
		while j < nodes.size():
			var n: Node = nodes[j]
			if n is Node2D and is_instance_valid(n) and not _target_is_dead(n as Node2D):
				var n2d: Node2D = n as Node2D
				if _node_in_any_group(n2d, enemy_groups):
					j += 1
					continue
				var r: float = _hp_ratio_for(n2d)
				if r <= threshold_ratio and r < best_ratio:
					best = n2d
					best_ratio = r
			j += 1
		i += 1
	return best

func _find_dead_ally() -> Node2D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var i: int = 0
	while i < ally_groups.size():
		var g: String = ally_groups[i]
		var nodes: Array = tree.get_nodes_in_group(g)
		var j: int = 0
		while j < nodes.size():
			var n: Node = nodes[j]
			if n is Node2D and is_instance_valid(n):
				var n2d: Node2D = n as Node2D
				if _node_in_any_group(n2d, enemy_groups):
					j += 1
					continue
				if _target_is_dead(n2d):
					return n2d
			j += 1
		i += 1
	return null

func _node_in_any_group(n: Node, groups: PackedStringArray) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	var i: int = 0
	while i < groups.size():
		if n.is_in_group(groups[i]):
			return true
		i += 1
	return false

func _hp_ratio_for(n: Node2D) -> float:
	var stats: Node = n.find_child("StatsComponent", true, false)
	if stats == null:
		return 1.0

	var cur: float = 0.0
	var maxv: float = 1.0

	if "current_hp" in stats:
		var chv: Variant = stats.get("current_hp")
		if typeof(chv) == TYPE_INT or typeof(chv) == TYPE_FLOAT:
			cur = float(chv)

	if cur <= 0.0 and stats.has_method("get_hp"):
		var gh: Variant = stats.call("get_hp")
		if typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT:
			cur = float(gh)

	if stats.has_method("max_hp"):
		var mh: Variant = stats.call("max_hp")
		if typeof(mh) == TYPE_INT or typeof(mh) == TYPE_FLOAT:
			maxv = max(1.0, float(mh))

	if maxv <= 0.0:
		maxv = 1.0
	return clamp(cur / maxv, 0.0, 1.0)

func _current_enemy_target() -> Node2D:
	var ts: Node = _targeting_system()
	if ts == null or not is_instance_valid(ts):
		return null
	if not ts.has_method("current_enemy_target"):
		return null

	var v: Variant = ts.call("current_enemy_target")
	if not is_instance_valid(v):
		return null
	if not (v is Node2D):
		return null

	var n2d: Node2D = v as Node2D
	if n2d == null or not is_instance_valid(n2d):
		return null

	return n2d

func _pick_enemy_target(max_radius_px: float) -> Node2D:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return null
	var best: Node2D = null
	var best_d2: float = max_radius_px * max_radius_px
	var self_pos: Vector2 = _owner_body.global_position
	var i: int = 0
	while i < enemy_groups.size():
		var g: String = enemy_groups[i]
		var nodes: Array = get_tree().get_nodes_in_group(g)
		var j: int = 0
		while j < nodes.size():
			var e: Node = nodes[j]
			if e is Node2D and is_instance_valid(e):
				var n2d: Node2D = e as Node2D
				if _target_is_dead(n2d):
					j += 1
					continue
				var d2: float = (n2d.global_position - self_pos).length_squared()
				if d2 < best_d2:
					best = n2d
					best_d2 = d2
			j += 1
		i += 1
	return best

func _resolve_actor_root() -> Node2D:
	if owner is Node2D:
		return owner as Node2D
	var p: Node = get_parent()
	while p != null and is_instance_valid(p):
		if p is Node2D:
			return p as Node2D
		p = p.get_parent()
	return null

func _is_currently_controlled() -> bool:
	if _actor_root != null and ("_controlled" in _actor_root):
		var v: Variant = _actor_root.get("_controlled")
		if typeof(v) == TYPE_BOOL and bool(v):
			return true
	var tree: SceneTree = get_tree()
	if tree != null:
		var pm: Node = tree.get_first_node_in_group("PartyManager")
		if pm != null and pm.has_method("get_controlled"):
			var any_c: Variant = pm.call("get_controlled")
			var cur: Node = any_c as Node
			if cur != null and is_instance_valid(cur) and _actor_root != null and is_instance_valid(_actor_root):
				if cur == _actor_root:
					return true
				if cur.is_ancestor_of(_actor_root) or _actor_root.is_ancestor_of(cur):
					return true
	return false

func _ability_system() -> Node:
	var root: Viewport = get_tree().root
	if root == null:
		return null
	var n: Node = root.get_node_or_null("AbilitySys")
	if n != null:
		return n
	return root.get_node_or_null("AbilitySystem")

func _targeting_system() -> Node:
	var root: Viewport = get_tree().root
	if root == null:
		return null
	var n: Node = root.get_node_or_null("TargetingSys")
	if n != null:
		return n
	return root.get_node_or_null("/root/TargetingSys")

func _party_manager() -> Node:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("PartyManager")

func _get_party_leader() -> Node2D:
	var pm: Node = _party_manager()
	if pm == null:
		return null
	if pm.has_method("get_controlled"):
		var any_c: Variant = pm.call("get_controlled")
		var n: Node2D = any_c as Node2D
		if n != null and is_instance_valid(n):
			return n
	return null

func _leader_distance() -> float:
	if _actor_root == null or not is_instance_valid(_actor_root):
		return 0.0
	var leader: Node2D = _get_party_leader()
	if leader == null or not is_instance_valid(leader):
		return 0.0
	return (_actor_root.global_position - leader.global_position).length()

func _leader_is_too_far() -> bool:
	if noncombat_leader_leash_px <= 0.0:
		return false
	var d: float = _leader_distance()
	return d > noncombat_leader_leash_px

func _has_enemy_threat() -> bool:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return false
	var radius: float = noncombat_enemy_threat_radius_px
	if radius <= 0.0:
		return false

	var enemy: Node2D = _current_enemy_target()
	if enemy != null and is_instance_valid(enemy):
		var d: float = (_owner_body.global_position - enemy.global_position).length()
		if d <= radius:
			return true

	var nearest: Node2D = _pick_enemy_target(radius)
	if nearest != null and is_instance_valid(nearest):
		return true

	return false

func _has_urgent_support_task() -> bool:
	if not _has_support_capability:
		return false

	var tree: SceneTree = get_tree()
	if tree == null:
		return false

	var revive_ids: Array[String] = []
	var heal_ids: Array[String] = []
	var cure_ids: Array[String] = []

	var i: int = 0
	while i < _known_ids.size():
		var aid: String = _known_ids[i]
		var atype: String = _ability_type_for(aid)
		match atype:
			"REVIVE_SPELL":
				revive_ids.append(aid)
			"HEAL_SPELL", "HOT_SPELL":
				heal_ids.append(aid)
			"CURE_SPELL":
				cure_ids.append(aid)
			_:
				pass
		i += 1

	var threshold: float = combat_support_urgent_threshold_ratio
	if threshold <= 0.0:
		threshold = 0.65

	if revive_ids.size() > 0:
		var dead_ally: Node2D = _find_dead_ally()
		if dead_ally != null and is_instance_valid(dead_ally):
			var ri: int = 0
			while ri < revive_ids.size():
				if _can_cast(revive_ids[ri]):
					return true
				ri += 1

	if heal_ids.size() > 0:
		var low_ally: Node2D = _find_lowest_hp_ally(threshold)
		if low_ally != null and is_instance_valid(low_ally):
			var hi: int = 0
			while hi < heal_ids.size():
				if _can_cast(heal_ids[hi]):
					return true
				hi += 1

	if cure_ids.size() > 0:
		var cure_choice: Dictionary = _choose_cure_target(cure_ids)
		if not cure_choice.is_empty():
			return true

	return false

func _update_combat_mode() -> void:
	if _owner_body == null or not is_instance_valid(_owner_body):
		_combat_mode = CombatMode.NON_COMBAT
		return

	var enemy_threat: bool = _has_enemy_threat()
	var urgent_support: bool = _has_urgent_support_task()

	if enemy_threat and not urgent_support:
		_combat_mode = CombatMode.COMBAT
	else:
		_combat_mode = CombatMode.NON_COMBAT

func _is_in_combat() -> bool:
	_update_combat_mode()
	return _combat_mode == CombatMode.COMBAT

func _aim_towards_target_in_ctx(ctx: Dictionary) -> Vector2:
	if ctx.has("target"):
		var t_any: Variant = ctx["target"]
		var t: Node2D = t_any as Node2D
		if t != null and is_instance_valid(t) and _owner_body != null:
			return _aim_towards(t)
	return Vector2.DOWN

func _aim_towards(t: Node2D) -> Vector2:
	if t == null or _owner_body == null:
		return Vector2.DOWN
	var diff: Vector2 = t.global_position - _owner_body.global_position
	if diff.length() > 0.001:
		return diff.normalized()
	return Vector2.DOWN

func _connect_party_manager() -> void:
	var tree: SceneTree = get_tree()
	if tree == null:
		return
	var pm: Node = tree.get_first_node_in_group("PartyManager")
	if pm == null:
		return
	if pm.has_signal("controlled_changed"):
		pm.controlled_changed.connect(_on_pm_controlled_changed)

	var cur: Node = null
	if pm.has_method("get_controlled"):
		var any_c: Variant = pm.call("get_controlled")
		cur = any_c as Node

	var same_actor: bool = false
	if cur != null and is_instance_valid(cur) and _actor_root != null and is_instance_valid(_actor_root):
		if cur == _actor_root:
			same_actor = true
		elif cur.is_ancestor_of(_actor_root) or _actor_root.is_ancestor_of(cur):
			same_actor = true
	set_active(not same_actor)

func _on_pm_controlled_changed(cur: Node) -> void:
	if _actor_root == null or not is_instance_valid(_actor_root):
		return
	var same_actor: bool = false
	if cur != null and is_instance_valid(cur):
		if cur == _actor_root:
			same_actor = true
		elif cur.is_ancestor_of(_actor_root) or _actor_root.is_ancestor_of(cur):
			same_actor = true
	set_active(not same_actor)

func _movement_blocked() -> bool:
	if _cf_node != null and is_instance_valid(_cf_node) and _cf_node.has_method("is_movement_suppressed"):
		var any_b: Variant = _cf_node.call("is_movement_suppressed")
		if typeof(any_b) == TYPE_BOOL and bool(any_b):
			return true
	return false

func _in_melee_range(targ: Node2D, range_px: float) -> bool:
	if _owner_body == null or targ == null:
		return false
	var d: float = (_owner_body.global_position - targ.global_position).length()
	var pad: float = melee_range_padding_px
	if pad < 0.0:
		pad = 0.0
	return d <= (range_px - pad)

func _close_gap_towards(targ: Node2D) -> void:
	if _owner_body == null or targ == null:
		return
	if _movement_blocked():
		if debug_gap_close and debug_companion_ai:
			_dbg("[CAI] _close_gap_towards blocked.")
		_halt_motion()
		return
	if _owner_body.has_method("set_move_dir"):
		var dir: Vector2 = (targ.global_position - _owner_body.global_position).normalized()
		_owner_body.call("set_move_dir", dir)

func _target_is_dead(n: Node2D) -> bool:
	if n == null or not is_instance_valid(n):
		return true

	if n.has_method("is_dead"):
		var dead_direct_raw: Variant = n.call("is_dead")
		if typeof(dead_direct_raw) == TYPE_BOOL and bool(dead_direct_raw):
			return true

	var sc: Node = n.get_node_or_null("StatusConditions")
	if sc != null and sc.has_method("is_dead"):
		var sv: Variant = sc.call("is_dead")
		if typeof(sv) == TYPE_BOOL and bool(sv):
			return true

	var stats: Node = n.find_child("StatsComponent", true, false)
	if stats != null:
		if "current_hp" in stats:
			var hp_raw: Variant = stats.get("current_hp")
			if (typeof(hp_raw) == TYPE_INT or typeof(hp_raw) == TYPE_FLOAT) and float(hp_raw) <= 0.0:
				return true
		if stats.has_method("get_hp"):
			var gh: Variant = stats.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true

	if "dead" in n:
		var dead_raw: Variant = n.get("dead")
		if typeof(dead_raw) == TYPE_BOOL and bool(dead_raw):
			return true

	return false

func _get_stats_node(target: Node) -> Node:
	if target == null or not is_instance_valid(target):
		return null
	var stats: Node = target.get_node_or_null("StatsComponent")
	if stats != null:
		return stats
	return target.find_child("StatsComponent", true, false)

func _is_dead() -> bool:
	var root: Node = _actor_root
	if root == null or not is_instance_valid(root):
		return false

	if root.has_method("is_dead"):
		var dv: Variant = root.call("is_dead")
		if typeof(dv) == TYPE_BOOL and bool(dv):
			return true
	if "dead" in root:
		var df: Variant = root.get("dead")
		if typeof(df) == TYPE_BOOL and bool(df):
			return true

	var sc: Node = root.get_node_or_null("StatusConditions")
	if sc != null and sc.has_method("is_dead"):
		var sv: Variant = sc.call("is_dead")
		if typeof(sv) == TYPE_BOOL and bool(sv):
			return true

	var stats: Node = root.get_node_or_null("StatsComponent")
	if stats != null:
		if "current_hp" in stats:
			var ch: Variant = stats.get("current_hp")
			if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
				return true
		if stats.has_method("get_hp"):
			var gh: Variant = stats.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true

	return false

# ---------------- Debug helpers ----------------
func _dbg(msg: String) -> void:
	var now: int = Time.get_ticks_msec()
	if debug_print_interval_ms > 0:
		if now - _dbg_last_msec < debug_print_interval_ms:
			return
	_dbg_last_msec = now
	var who: String = "null"
	if _actor_root != null and is_instance_valid(_actor_root):
		who = _actor_root.name
	print_rich(msg + " user=" + who)

func _node_name(n: Node) -> String:
	if n == null:
		return "null"
	if not is_instance_valid(n):
		return "freed"
	return n.name

func _fmt(v: float) -> String:
	return String.num(v, 2)
