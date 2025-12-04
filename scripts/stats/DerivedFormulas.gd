extends Node
class_name DerivedFormulas
## All base combat stats are derived from GDD cores. Tweak constants to balance.

# ----- Core couplings -----
const END_PER_STA: float = 0.6   # END derives from STA (e.g., 20 STA => 12 END)

# ----- Max stat growth -----
const HP_PER_STA: float = 8.0
const MP_PER_INT: float = 5.0
const MP_PER_WIS: float = 4.5

# ----- Ratings -----
const ATK_PER_STR: float = 1.00
const ATK_PER_DEX: float = 0.25
const DEF_PER_STA: float = 0.30
const DEF_PER_DEX: float = 0.20

# ----- Movement -----
const MS_PER_DEX: float = 0.80
const MS_PER_END: float = 0.20

# ----- Regeneration (per second) -----
const HP_REGEN_BASE: float    = 0.00
const HP_REGEN_PER_STA: float = 0.00
const HP_REGEN_PER_WIS: float = 0.00

const MP_REGEN_BASE: float    = 0.50
const MP_REGEN_PER_WIS: float = 0.09
const MP_REGEN_PER_INT: float = 0.045

const END_REGEN_BASE: float    = 2.00
const END_REGEN_PER_STA: float = 0.05

# ----- Heals (scaling + variance) -----
const HEAL_SCALE_PER_STAT: float = 0.75   # was effectively 0.55; increase so +1 WIS is noticeable
const HEAL_VARIANCE_PCT: float = 0.10     # ±10% variance on heals

# ----- Avoid outrageous rates -----
const REGEN_MAX: float = 50.0

# =========================
# Derived helpers
# =========================

static func end_from_sta(stats: Object) -> float:
	var floor_end: float = stats.get_base_stat("END")
	var sta: float = stats.get_final_stat("STA")
	var derived: float = END_PER_STA * sta
	return floor_end + derived

static func hp_max(stats: Object) -> float:
	var base_hp: float = stats.get_base_stat("HP")
	var sta: float = stats.get_final_stat("STA")
	return base_hp + HP_PER_STA * sta

static func mp_max(stats: Object) -> float:
	var base_mp: float = stats.get_base_stat("MP")
	var intel: float = stats.get_final_stat("INT")
	var wis: float = stats.get_final_stat("WIS")

	var source: String = ""
	var weights: Dictionary = {}

	# Duck-typing via methods on StatsComponent
	if stats.has_method("get_mp_source"):
		source = String(stats.get_mp_source())
	if stats.has_method("get_mp_weights"):
		var w: Variant = stats.get_mp_weights()
		if typeof(w) == TYPE_DICTIONARY:
			weights = w

	if source == "int":
		return base_mp + MP_PER_INT * intel
	if source == "wis":
		return base_mp + MP_PER_WIS * wis
	if source == "hybrid":
		var w_int: float = float(weights.get("INT", 0.5))
		var w_wis: float = float(weights.get("WIS", 0.5))
		return base_mp + (MP_PER_INT * intel * w_int) + (MP_PER_WIS * wis * w_wis)

	# Legacy fallback: both contribute
	return base_mp + MP_PER_INT * intel + MP_PER_WIS * wis

static func move_speed(stats: Object) -> float:
	var base: float = stats.get_base_stat("MoveSpeed")
	var dex: float = stats.get_final_stat("DEX")
	var endu: float = end_from_sta(stats)
	return base + MS_PER_DEX * dex + MS_PER_END * endu

static func attack_rating(stats: Object) -> float:
	var base: float = stats.get_base_stat("Attack")
	var strn: float = stats.get_final_stat("STR")
	var dex: float = stats.get_final_stat("DEX")

	# DEBUG: show which resource is feeding this and the base Attack it returned
	var owner_name: String = ""
	var res_path: String = ""

	if stats.has_method("get_parent"):
		var p: Variant = stats.get_parent()
		if p != null:
			owner_name = String(p.name)

	var res: Variant = null
	if stats is Object:
		res = stats.get("stats")
	if typeof(res) == TYPE_OBJECT and res != null and res is Resource:
		res_path = String((res as Resource).resource_path)

	return base + ATK_PER_STR * strn + ATK_PER_DEX * dex

static func defense_rating(stats: Object) -> float:
	var base: float = stats.get_base_stat("Defense")
	var sta: float = stats.get_final_stat("STA")
	var dex: float = stats.get_final_stat("DEX")
	return base + DEF_PER_STA * sta + DEF_PER_DEX * dex

# ----- Chances (0..1) -----

static func block_chance(stats: Object) -> float:
	var base: float = stats.get_base_stat("BlockChance")
	var strn: float = stats.get_final_stat("STR")
	var dex: float  = stats.get_final_stat("DEX")
	var r: float = base + (0.00 + 0.0025 * strn + 0.0010 * dex)
	if r < 0.0:
		return 0.0
	if r > 0.95:
		return 0.95
	return r

static func parry_chance(stats: Object) -> float:
	var base: float = stats.get_base_stat("ParryChance")
	var dex: float  = stats.get_final_stat("DEX")
	var strn: float = stats.get_final_stat("STR")
	var r: float = base + (0.02 + 0.0030 * dex + 0.0010 * strn)
	if r < 0.0:
		return 0.0
	if r > 0.60:
		return 0.60
	return r

static func evasion(stats: Object) -> float:
	var base: float = stats.get_base_stat("Evasion")
	var dex: float  = stats.get_final_stat("DEX")
	var r: float = base + (0.03 + 0.0035 * dex)
	if r < 0.0:
		return 0.0
	if r > 0.60:
		return 0.60
	return r

static func crit_chance(stats: Object) -> float:
	var base: float = stats.get_base_stat("CritChance")
	var lck: float  = stats.get_final_stat("LCK")
	var dex: float  = stats.get_final_stat("DEX")
	var r: float = base + (0.05 + 0.0025 * lck + 0.0005 * dex)
	if r < 0.0:
		return 0.0
	if r > 0.75:
		return 0.75
	return r

static func crit_heal_chance(stats: Object) -> float:
	var base: float = stats.get_base_stat("CritHealChance")
	var lck: float  = stats.get_final_stat("LCK")
	var wis: float  = stats.get_final_stat("WIS")
	var r: float = base + (0.02 + 0.0020 * lck + 0.0015 * wis)
	if r < 0.0:
		return 0.0
	if r > 0.60:
		return 0.60
	return r

# ----- Regeneration -----
static func hp_regen_per_sec(stats: Object) -> float:
	var sta: float = stats.get_final_stat("STA")
	var wis: float = stats.get_final_stat("WIS")
	var r: float = HP_REGEN_BASE + HP_REGEN_PER_STA * sta + HP_REGEN_PER_WIS * wis
	if r < 0.0:
		return 0.0
	if r > REGEN_MAX:
		return REGEN_MAX
	return r

static func mp_regen_per_sec(stats: Object) -> float:
	var wis: float   = stats.get_final_stat("WIS")
	var intel: float = stats.get_final_stat("INT")
	var r: float = MP_REGEN_BASE + MP_REGEN_PER_WIS * wis + MP_REGEN_PER_INT * intel
	if r < 0.0:
		return 0.0
	if r > REGEN_MAX:
		return REGEN_MAX
	return r

static func end_regen_per_sec(stats: Object) -> float:
	var sta: float = stats.get_final_stat("STA")
	var r: float = END_REGEN_BASE + END_REGEN_PER_STA * sta
	if r < 0.0:
		return 0.0
	if r > REGEN_MAX:
		return REGEN_MAX
	return r

# -----------------------------------------------------------------------------
# Healing
# -----------------------------------------------------------------------------
static func calc_heal(caster_stats: Object, base_power: float, scale_stat: String = "WIS", crit: bool = false) -> int:
	var scale_val: float = 0.1
	var debug_val: float = -999.0

	# Primary path: StatsComponent has get_final_stat
	if caster_stats != null and caster_stats.has_method("get_final_stat"):
		scale_val = float(caster_stats.get_final_stat(scale_stat))
		debug_val = scale_val
	else:
		# Fallback: if handed the actor root, try to find its StatsComponent child
		if caster_stats != null and caster_stats.has_method("get_node_or_null"):
			var sc: Node = caster_stats.get_node_or_null("StatsComponent")
			if sc != null and sc.has_method("get_final_stat"):
				scale_val = float(sc.get_final_stat(scale_stat))
				debug_val = scale_val

	# Debug trace
	print("HEAL DEBUG: caster=", caster_stats, " final ", scale_stat, "=", debug_val)

	# Base scaling with stronger per-point weight so +1 WIS is visible with integer rounding
	var amount: float = base_power + (scale_val * HEAL_SCALE_PER_STAT)

	# Optional crit pass-through
	if crit:
		amount *= 1.5

	# Variance: ±HEAL_VARIANCE_PCT
	if HEAL_VARIANCE_PCT > 0.0:
		var low: float = 1.0 - HEAL_VARIANCE_PCT
		var high: float = 1.0 + HEAL_VARIANCE_PCT
		var roll: float = randf_range(low, high)
		amount *= roll

	return int(round(max(1.0, amount)))

# -----------------------------------------------------------------------------
# Attack speed / cadence (AGI vs WeaponWeight; STR negates weight)
# -----------------------------------------------------------------------------
const ATKSPD_PER_AGI: float = 0.022              # ~2.2% faster per AGI
const WEIGHT_SLOW_PER_POINT: float = 0.060       # ~6% slower per effective Weight
const STR_PER_WEIGHT: int = 20                   # every 20 STR negates 1 Weight
const ATKSPD_MIN_MUL: float = 0.50               # 0.5x floor
const ATKSPD_MAX_MUL: float = 2.00               # 2.0x ceiling

## Returns Dictionary:
##  "speed_mul", "attack_delay_sec", "attacks_per_sec", "base_attack_delay_sec", "effective_weight"
static func calc_attack_speed(stats: Object) -> Dictionary:
	var base_delay: float = 0.5
	var agi: float = 0.0
	var str_: float = 0.0
	var weight: float = 1.0

	if stats != null:
		# Read base delay from base stats if available; fall back to final
		if stats.has_method("get_base_stat"):
			var b: float = float(stats.get_base_stat("BaseAttackDelay"))
			if b > 0.0:
				base_delay = b
		if stats.has_method("get_final_stat"):
			agi = float(stats.get_final_stat("AGI"))
			str_ = float(stats.get_final_stat("STR"))
			weight = float(stats.get_final_stat("WeaponWeight"))

	# STR counters weight in whole-number chunks: floor(STR / 20) => -1 weight per 20 STR
	var weight_reduction: float = floor(str_ / float(STR_PER_WEIGHT))
	var effective_weight: float = maxf(0.0, weight - weight_reduction)

	var speed_mul: float = 1.0 + (agi * ATKSPD_PER_AGI) - (effective_weight * WEIGHT_SLOW_PER_POINT)
	speed_mul = clampf(speed_mul, ATKSPD_MIN_MUL, ATKSPD_MAX_MUL)

	# --- Status-based attack-speed modifier (SLOWED + FROZEN) ----------------
	var status_atk_mul: float = 1.0

	# Preferred: ask StatsComponent directly for a passthrough.
	if stats != null and stats.has_method("get_attack_speed_multiplier"):
		var m_any: Variant = stats.get_attack_speed_multiplier()
		if typeof(m_any) == TYPE_FLOAT:
			status_atk_mul = float(m_any)
	else:
		# Fallback: locate sibling StatusConditions and try there
		var status_node: Node = null
		if stats != null and stats.has_method("get_parent"):
			var actor_root: Variant = stats.get_parent()
			if actor_root != null and actor_root is Node:
				var root_node: Node = actor_root
				if root_node.has_method("get_node_or_null"):
					status_node = root_node.get_node_or_null("StatusConditions")

		if status_node != null:
			if status_node.has_method("get_attack_speed_multiplier"):
				var m2_any: Variant = status_node.call("get_attack_speed_multiplier")
				if typeof(m2_any) == TYPE_FLOAT:
					status_atk_mul = float(m2_any)
			else:
				# Legacy inference: read flags & exported multipliers if present
				var mul_legacy: float = 1.0

				var is_frozen: bool = false
				if status_node.has_method("is_frozen"):
					var v_f: Variant = status_node.call("is_frozen")
					if typeof(v_f) == TYPE_BOOL:
						is_frozen = bool(v_f)

				var is_slowed: bool = false
				if status_node.has_method("is_slowed"):
					var v_s: Variant = status_node.call("is_slowed")
					if typeof(v_s) == TYPE_BOOL:
						is_slowed = bool(v_s)

				if is_frozen:
					var fam_any: Variant = status_node.get("frozen_attack_speed_mul")
					var fam: float = 0.6
					if typeof(fam_any) == TYPE_FLOAT:
						fam = float(fam_any)
					mul_legacy *= clampf(fam, 0.05, 1.0)

				if is_slowed:
					var sam_any: Variant = status_node.get("slowed_attack_speed_mul")
					var sam: float = 0.7
					if typeof(sam_any) == TYPE_FLOAT:
						sam = float(sam_any)
					mul_legacy *= clampf(sam, 0.05, 1.0)

				status_atk_mul = mul_legacy

	# Apply status multiplier to speed, re-clamp to the same bounds
	speed_mul *= status_atk_mul
	speed_mul = clampf(speed_mul, ATKSPD_MIN_MUL, ATKSPD_MAX_MUL)

	var attack_delay_sec: float = base_delay / speed_mul
	var aps: float = 0.0
	if attack_delay_sec > 0.0:
		aps = 1.0 / attack_delay_sec

	return {
		"speed_mul": speed_mul,
		"attack_delay_sec": attack_delay_sec,
		"attacks_per_sec": aps,
		"base_attack_delay_sec": base_delay,
		"effective_weight": effective_weight
	}
