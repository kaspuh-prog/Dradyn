extends Node
class_name DerivedFormulas
## All base combat stats are derived from GDD cores. Tweak constants to balance.

# ----- Core couplings -----
const END_PER_STA: float = 0.6   # END derives from STA (e.g., 20 STA => 12 END)

# ----- Max stat growth -----
const HP_PER_STA: float = 8.0
const MP_PER_INT: float = 5.0
const MP_PER_WIS: float = 3.0

# ----- Ratings -----
const ATK_PER_STR: float = 1.00
const ATK_PER_DEX: float = 0.25
const DEF_PER_END: float = 0.70
const DEF_PER_STA: float = 0.20
const DEF_PER_DEX: float = 0.10

# ----- Movement -----
const MS_PER_DEX: float = 0.80
const MS_PER_END: float = 0.20

# ----- Regeneration (per second) -----
const HP_REGEN_BASE: float    = 0.00
const HP_REGEN_PER_STA: float = 0.00
const HP_REGEN_PER_WIS: float = 0.00

const MP_REGEN_BASE: float    = 0.50
const MP_REGEN_PER_WIS: float = 0.06
const MP_REGEN_PER_INT: float = 0.03

const END_REGEN_BASE: float    = 2.00
const END_REGEN_PER_STA: float = 0.05

# ----- Avoid outrageous rates -----
const REGEN_MAX: float = 50.0

# =========================
# Derived helpers
# =========================

static func end_from_sta(stats) -> float:
	# END capacity is the max of a floor (resource's END) and STA-derived value.
	var floor_end: float = stats.get_base_stat("END")
	var sta: float = stats.get_final_stat("STA")
	var derived: float = END_PER_STA * sta
	if derived < floor_end:
		return floor_end
	return derived

static func hp_max(stats) -> float:
	var base_hp: float = stats.get_base_stat("HP")
	var sta: float = stats.get_final_stat("STA")
	return base_hp + HP_PER_STA * sta

static func mp_max(stats) -> float:
	var base_mp: float = stats.get_base_stat("MP")
	var intel: float = stats.get_final_stat("INT")
	var wis: float = stats.get_final_stat("WIS")

	var source: String = ""
	var weights: Dictionary = {}

	# Duck-typing via methods on StatsComponent
	if stats.has_method("get_mp_source"):
		source = String(stats.get_mp_source())
	if stats.has_method("get_mp_weights"):
		var w = stats.get_mp_weights()
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

static func move_speed(stats) -> float:
	var base: float = stats.get_base_stat("MoveSpeed")
	var dex: float = stats.get_final_stat("DEX")
	var endu: float = end_from_sta(stats)
	return base + MS_PER_DEX * dex + MS_PER_END * endu

static func attack_rating(stats) -> float:
	var base: float = stats.get_base_stat("Attack")
	var strn: float = stats.get_final_stat("STR")
	var dex: float = stats.get_final_stat("DEX")
	return base + ATK_PER_STR * strn + ATK_PER_DEX * dex

static func defense_rating(stats) -> float:
	var base: float = stats.get_base_stat("Defense")
	var endu: float = end_from_sta(stats)
	var sta: float = stats.get_final_stat("STA")
	var dex: float = stats.get_final_stat("DEX")
	return base + DEF_PER_END * endu + DEF_PER_STA * sta + DEF_PER_DEX * dex

# ----- Chances (0..1) -----
# These ADD the base authored in StatsResource to the derived component, then clamp.

static func block_chance(stats) -> float:
	var base: float = stats.get_base_stat("BlockChance")
	var strn: float = stats.get_final_stat("STR")
	var dex: float  = stats.get_final_stat("DEX")
	var r: float = base + (0.00 + 0.0025 * strn + 0.0010 * dex)
	if r < 0.0:
		return 0.0
	if r > 0.95:
		return 0.95
	return r

static func parry_chance(stats) -> float:
	var base: float = stats.get_base_stat("ParryChance")
	var dex: float  = stats.get_final_stat("DEX")
	var strn: float = stats.get_final_stat("STR")
	var r: float = base + (0.02 + 0.0030 * dex + 0.0010 * strn)
	if r < 0.0:
		return 0.0
	if r > 0.60:
		return 0.60
	return r

static func evasion(stats) -> float:
	var base: float = stats.get_base_stat("Evasion")
	var dex: float  = stats.get_final_stat("DEX")
	var r: float = base + (0.03 + 0.0035 * dex)
	if r < 0.0:
		return 0.0
	if r > 0.60:
		return 0.60
	return r

static func crit_chance(stats) -> float:
	var base: float = stats.get_base_stat("CritChance")
	var lck: float  = stats.get_final_stat("LCK")
	var dex: float  = stats.get_final_stat("DEX")
	var r: float = base + (0.05 + 0.0025 * lck + 0.0005 * dex)
	if r < 0.0:
		return 0.0
	if r > 0.75:
		return 0.75
	return r

static func crit_heal_chance(stats) -> float:
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
static func hp_regen_per_sec(stats) -> float:
	var sta: float = stats.get_final_stat("STA")
	var wis: float = stats.get_final_stat("WIS")
	var r: float = HP_REGEN_BASE + HP_REGEN_PER_STA * sta + HP_REGEN_PER_WIS * wis
	if r < 0.0:
		return 0.0
	if r > REGEN_MAX:
		return REGEN_MAX
	return r

static func mp_regen_per_sec(stats) -> float:
	var wis: float   = stats.get_final_stat("WIS")
	var intel: float = stats.get_final_stat("INT")
	var r: float = MP_REGEN_BASE + MP_REGEN_PER_WIS * wis + MP_REGEN_PER_INT * intel
	if r < 0.0:
		return 0.0
	if r > REGEN_MAX:
		return REGEN_MAX
	return r

static func end_regen_per_sec(stats) -> float:
	var sta: float = stats.get_final_stat("STA")
	var r: float = END_REGEN_BASE + END_REGEN_PER_STA * sta
	if r < 0.0:
		return 0.0
	if r > REGEN_MAX:
		return REGEN_MAX
	return r
