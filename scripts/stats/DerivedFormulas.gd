extends Node
class_name DerivedFormulas
## All base combat stats are derived from GDD cores. Tweak constants to balance.

# ----- Core couplings -----
const END_PER_STA: float      = 0.6      # END derives from STA (e.g., 20 STA => 12 END)

# ----- Max stat growth -----
const HP_PER_STA: float       = 8.0      # each STA adds this much max HP
const MP_PER_INT: float       = 5.0      # each INT adds this much max MP
const MP_PER_WIS: float       = 3.0      # each WIS adds this much max MP
const STAM_PER_STA: float     = 4.0      # each STA adds to max Stamina
const STAM_PER_END: float     = 6.0      # each END adds to max Stamina

# ----- Ratings -----
const ATK_PER_STR: float      = 1.00     # Attack rating from STR (melee leaning)
const ATK_PER_DEX: float      = 0.25     # small general Attack from DEX
const DEF_PER_END: float      = 0.70     # Defense from END
const DEF_PER_STA: float      = 0.20     # small Defense from STA
const DEF_PER_DEX: float      = 0.10     # tiny Defense from DEX (nimbleness)

# ----- Movement -----
const MS_PER_DEX: float       = 0.80     # MoveSpeed from DEX
const MS_PER_END: float       = 0.20     # small MoveSpeed from END

# ----- Regeneration (per second) -----
const HP_REGEN_BASE: float    = 0.00
const HP_REGEN_PER_STA: float = 0.03
const HP_REGEN_PER_WIS: float = 0.02

const MP_REGEN_BASE: float    = 0.50
const MP_REGEN_PER_WIS: float = 0.06
const MP_REGEN_PER_INT: float = 0.03

const STAM_REGEN_BASE: float    = 2.00
const STAM_REGEN_PER_END: float = 0.12
const STAM_REGEN_PER_STA: float = 0.04

# ----- Avoid outrageous rates -----
const REGEN_MAX: float = 50.0

# =========================
# Derived helpers
# =========================
static func end_from_sta(stats) -> float:
	var sta: float = stats.get_final_stat("STA") as float
	return max(0.0, sta * END_PER_STA)

static func hp_max(stats) -> float:
	# Base HP + growth from STA. Do NOT call get_final_stat("HP") here.
	var base_hp: float = stats.get_base_stat("HP") as float
	var sta: float = stats.get_final_stat("STA") as float
	return base_hp + HP_PER_STA * sta

static func mp_max(stats) -> float:
	# Base MP + growth from INT/WIS by class policy (INT, WIS, or HYBRID).
	# Backwards compatible: if stats doesn't provide a policy, use legacy (INT + WIS).
	var base_mp: float = stats.get_base_stat("MP") as float
	var intel: float = stats.get_final_stat("INT") as float
	var wis: float = stats.get_final_stat("WIS") as float

	var source := ""
	var weights := {}
	# Duck-typing: use if present; otherwise fall back gracefully.
	if "get_mp_source" in stats and stats.get_mp_source is Callable:
		source = String(stats.get_mp_source.call())
	if "get_mp_weights" in stats and stats.get_mp_weights is Callable:
		var w = stats.get_mp_weights.call()
		if typeof(w) == TYPE_DICTIONARY:
			weights = w

	match source:
		"int":
			# INT casters only
			return base_mp + MP_PER_INT * intel
		"wis":
			# WIS casters only
			return base_mp + MP_PER_WIS * wis
		"hybrid":
			# Hybrid (weighted)
			var w_int := float(weights.get("INT", 0.5))
			var w_wis := float(weights.get("WIS", 0.5))
			return base_mp + (MP_PER_INT * intel * w_int) + (MP_PER_WIS * wis * w_wis)
		_:
			# Legacy fallback: both contribute (your previous behavior)
			return base_mp + MP_PER_INT * intel + MP_PER_WIS * wis

static func stamina_max(stats) -> float:
	# Base Stamina + growth from STA and derived END. Do NOT call get_final_stat("Stamina") here.
	var base_st: float = stats.get_base_stat("Stamina") as float
	var sta: float = stats.get_final_stat("STA") as float
	var endu: float = end_from_sta(stats)
	return base_st + STAM_PER_STA * sta + STAM_PER_END * endu

static func move_speed(stats) -> float:
	var base: float = stats.get_base_stat("MoveSpeed") as float
	var dex: float = stats.get_final_stat("DEX") as float
	var endu: float = end_from_sta(stats)
	return base + MS_PER_DEX * dex + MS_PER_END * endu

static func attack_rating(stats) -> float:
	var base: float = stats.get_base_stat("Attack") as float
	var strn: float = stats.get_final_stat("STR") as float
	var dex: float = stats.get_final_stat("DEX") as float
	return base + ATK_PER_STR * strn + ATK_PER_DEX * dex

static func defense_rating(stats) -> float:
	var base: float = stats.get_base_stat("Defense") as float
	var endu: float = end_from_sta(stats)
	var sta: float = stats.get_final_stat("STA") as float
	var dex: float = stats.get_final_stat("DEX") as float
	return base + DEF_PER_END * endu + DEF_PER_STA * sta + DEF_PER_DEX * dex

# ----- Chances (0..1) -----
static func block_chance(stats) -> float:
	var strn: float = stats.get_final_stat("STR") as float
	var dex: float = stats.get_final_stat("DEX") as float
	return clamp(0.00 + 0.0025 * strn + 0.0010 * dex, 0.0, 0.75)

static func parry_chance(stats) -> float:
	var dex: float = stats.get_final_stat("DEX") as float
	var strn: float = stats.get_final_stat("STR") as float
	return clamp(0.02 + 0.0030 * dex + 0.0010 * strn, 0.0, 0.60)

static func evasion(stats) -> float:
	var dex: float = stats.get_final_stat("DEX") as float
	return clamp(0.03 + 0.0035 * dex, 0.0, 0.60)

static func crit_chance(stats) -> float:
	var lck: float = stats.get_final_stat("LCK") as float
	var dex: float = stats.get_final_stat("DEX") as float
	return clamp(0.05 + 0.0025 * lck + 0.0005 * dex, 0.0, 0.75)

static func crit_heal_chance(stats) -> float:
	var lck: float = stats.get_final_stat("LCK") as float
	var wis: float = stats.get_final_stat("WIS") as float
	return clamp(0.02 + 0.0020 * lck + 0.0015 * wis, 0.0, 0.60)

# ----- Regeneration -----
static func hp_regen_per_sec(stats) -> float:
	var sta: float = stats.get_final_stat("STA") as float
	var wis: float = stats.get_final_stat("WIS") as float
	var r: float = HP_REGEN_BASE + HP_REGEN_PER_STA * sta + HP_REGEN_PER_WIS * wis
	return clamp(r, 0.0, REGEN_MAX)

static func mp_regen_per_sec(stats) -> float:
	var wis: float = stats.get_final_stat("WIS") as float
	var intel: float = stats.get_final_stat("INT") as float
	var r: float = MP_REGEN_BASE + MP_REGEN_PER_WIS * wis + MP_REGEN_PER_INT * intel
	return clamp(r, 0.0, REGEN_MAX)

static func stamina_regen_per_sec(stats) -> float:
	var endu: float = end_from_sta(stats)
	var sta: float = stats.get_final_stat("STA") as float
	var r: float = STAM_REGEN_BASE + STAM_REGEN_PER_END * endu + STAM_REGEN_PER_STA * sta
	return clamp(r, 0.0, REGEN_MAX)
