extends Node
class_name StatsComponent
## Godot 4.5 — END-as-runtime-resource (derived from Stamina)

# ------ Signals ------
signal hp_changed(current: float, max_value: float)
signal damage_taken(amount: float, dmg_type: String, source: String)
signal mp_changed(current: float, max_value: float)
signal end_changed(current: float, max_value: float)
signal died
signal stat_changed(stat_name: String, final_value: float)

# ------ Config / Exports ------
@export var stats: Resource
@export var damage_formula: String = "armor"   # "linear" | "armor" | "expo"

@export var use_gdd_derived: bool = true
@export var derive_end_from_sta: bool = true

# MP derivation policy (duck-typed by DerivedFormulas)
@export var _mp_source_policy: String = ""               # "", "int", "wis", "hybrid"
@export var _mp_hybrid_weights: Dictionary = {"INT": 0.5, "WIS": 0.5}

func get_mp_source() -> String: return _mp_source_policy
func get_mp_weights() -> Dictionary: return _mp_hybrid_weights
func set_mp_source(source: String, weights: Dictionary = {}) -> void:
	match source:
		"int", "wis", "hybrid":
			_mp_source_policy = source
		_:
			_mp_source_policy = ""
	if source == "hybrid" and typeof(weights) == TYPE_DICTIONARY:
		_mp_hybrid_weights = {
			"INT": float(weights.get("INT", 0.5)),
			"WIS": float(weights.get("WIS", 0.5))
		}

# ------ Runtime vitals ------
var current_hp: float = 0.0
var current_mp: float = 0.0
var current_end: float = 0.0   # ← the sprint/dodge resource (derived from Stamina)
var modifiers: Array = []

const RES_KEYS := {
	"Slash": "SlashRes", "Pierce": "PierceRes", "Blunt": "BluntRes",
	"Fire": "FireRes", "Ice": "IceRes", "Wind": "WindRes", "Earth": "EarthRes",
	"Magic": "MagicRes", "Light": "LightRes", "Darkness": "DarknessRes", "Poison": "PoisonRes",
}

# Passive regen (per second) – END uses this directly unless you have a derived formula for it
@export var auto_tick_modifiers: bool = false : set = _set_auto_tick_mods
@export var hp_regen_per_sec: float = 0.0    : set = _set_regen_hp
@export var mp_regen_per_sec: float = 0.0    : set = _set_regen_mp
@export var end_regen_per_sec: float = 0.0   : set = _set_regen_end

func _recalc_processing() -> void:
	var should_process: bool = (
		auto_tick_modifiers
		or hp_regen_per_sec > 0.0
		or mp_regen_per_sec > 0.0
		or end_regen_per_sec > 0.0
		or use_gdd_derived
	)
	set_process(should_process)

func _set_auto_tick_mods(v: bool) -> void: auto_tick_modifiers = v; _recalc_processing()
func _set_regen_hp(v: float) -> void: hp_regen_per_sec = v; _recalc_processing()
func _set_regen_mp(v: float) -> void: mp_regen_per_sec = v; _recalc_processing()
func _set_regen_end(v: float) -> void: end_regen_per_sec = v; _recalc_processing()

# ------ Lifecycle ------
func _ready() -> void:
	if stats == null:
		push_warning("StatsComponent: no StatsResource assigned.")
	current_hp = max_hp()
	current_mp = max_mp()
	current_end = max_end()
	emit_signal("hp_changed", current_hp, max_hp())
	emit_signal("mp_changed", current_mp, max_mp())
	emit_signal("end_changed", current_end, max_end())
	_recalc_processing()

# ------ Stat access ------
func _get_base_from_resource(stat_key: String, default_val: float = 0.0) -> float:
	if stats == null:
		return default_val
	var dict_v: Variant = stats.get("base_stats")
	if typeof(dict_v) == TYPE_DICTIONARY:
		var base_dict: Dictionary = dict_v
		if base_dict.has(stat_key):
			return float(base_dict[stat_key])
		return default_val
	var v: Variant = stats.get(stat_key)
	if v == null: return default_val
	return float(v)

func get_base_stat(stat_name: String) -> float:
	return _get_base_from_resource(stat_name, 0.0)

func _derived_base_for(stat_name: String) -> float:
	if not use_gdd_derived:
		return get_base_stat(stat_name)
	match stat_name:
		"END":
			if derive_end_from_sta:
				return DerivedFormulas.end_from_sta(self)
			else:
				return get_base_stat("END")
		"HP":
			return DerivedFormulas.hp_max(self)
		"MP":
			return DerivedFormulas.mp_max(self)
		"Stamina":
			return DerivedFormulas.stamina_max(self)
		"MoveSpeed":
			return DerivedFormulas.move_speed(self)
		"Attack":
			return DerivedFormulas.attack_rating(self)
		"Defense":
			return DerivedFormulas.defense_rating(self)
		"BlockChance":
			return DerivedFormulas.block_chance(self)
		"ParryChance":
			return DerivedFormulas.parry_chance(self)
		"Evasion":
			return DerivedFormulas.evasion(self)
		"CritChance":
			return DerivedFormulas.crit_chance(self)
		"CritHealChance":
			return DerivedFormulas.crit_heal_chance(self)
		_:
			return get_base_stat(stat_name)

func get_final_stat(stat_name: String) -> float:
	var base_val: float = _derived_base_for(stat_name)
	var add_sum: float = 0.0
	var mul_prod: float = 1.0
	for m in modifiers:
		if m is Dictionary:
			if m.get("stat_name", "") == stat_name:
				add_sum += float(m.get("add_value", 0.0))
				mul_prod *= float(m.get("mul_value", 1.0))
		else:
			if str(m.stat_name) == stat_name:
				add_sum += float(m.add_value)
				mul_prod *= float(m.mul_value)
	return max(0.0, (base_val + add_sum) * mul_prod)

func get_all_final_stats() -> Dictionary:
	var out: Dictionary = {}
	if stats == null:
		return out
	var dict_v: Variant = stats.get("base_stats")
	if typeof(dict_v) == TYPE_DICTIONARY:
		var base_dict: Dictionary = dict_v
		for k in base_dict.keys():
			out[str(k)] = get_final_stat(str(k))
	else:
		var keys := [
			"HP","MP","END","Stamina","MoveSpeed","Attack","Defense",
			"STR","DEX","STA","INT","WIS","CHA","LCK",
			"BlockChance","ParryChance","Evasion","CritChance","CritHealChance",
			"SlashRes","PierceRes","BluntRes","FireRes","IceRes",
			"WindRes","EarthRes","MagicRes","LightRes","DarknessRes","PoisonRes"
		]
		for k in keys:
			out[k] = get_final_stat(k)
	return out

# ------ Max vitals (derived) ------
func max_hp() -> float: return get_final_stat("HP")
func max_mp() -> float: return get_final_stat("MP")
func max_end() -> float: return get_final_stat("END")
func max_stamina() -> float: return get_final_stat("Stamina")  # base stat capacity (not the runtime resource)

# ------ Vital adjustments ------
func change_hp(amount: float) -> void:
	current_hp = clamp(current_hp + amount, 0.0, max_hp())
	emit_signal("hp_changed", current_hp, max_hp())
	if current_hp <= 0.0:
		emit_signal("died")

func change_mp(amount: float) -> void:
	current_mp = clamp(current_mp + amount, 0.0, max_mp())
	emit_signal("mp_changed", current_mp, max_mp())

func change_end(amount: float) -> void:
	current_end = clamp(current_end + amount, 0.0, max_end())
	emit_signal("end_changed", current_end, max_end())

func spend_mp(amount: float) -> bool:
	if amount <= 0.0: return true
	if current_mp + 1e-6 < amount: return false
	change_mp(-amount)
	return true

func spend_end(amount: float) -> bool:
	if amount <= 0.0: return true
	if current_end + 1e-6 < amount: return false
	change_end(-amount)
	return true

func restore_mp(amount: float) -> void:
	if amount > 0.0: change_mp(amount)

func restore_end(amount: float) -> void:
	if amount > 0.0: change_end(amount)

# ------ (Temporary) stamina wrappers – keep game stable; remove when migrated ------
func change_stamina(amount: float) -> void:
	# Deprecated: END is the runtime resource; keeping as wrapper to avoid breakage.
	change_end(amount)

func spend_stamina(amount: float) -> bool:
	return spend_end(amount)

func restore_stamina(amount: float) -> void:
	restore_end(amount)

# ------ Damage mitigation ------
func _mitigate_by_defense(amount: float, defense: float) -> float:
	match damage_formula:
		"linear": return max(0.0, amount - max(0.0, defense))
		"expo":   return amount * pow(0.9, max(0.0, defense))
		_:        return amount * (100.0 / (100.0 + max(0.0, defense)))  # armor curve

func _get_resistance_for(type_name: String) -> float:
	var key: String = str(RES_KEYS[type_name]) if RES_KEYS.has(type_name) else ""
	var r: float = 0.0
	if key != "":
		r = get_final_stat(key)
	return clamp(r, -0.9, 0.9)

func apply_damage(amount: float, dmg_type: String = "Physical", source: String = "") -> void:
	if amount <= 0.0:
		return
	var defense: float = get_final_stat("Defense")
	var after_def: float = _mitigate_by_defense(amount, defense)
	var resist: float = _get_resistance_for(dmg_type)  # 0.0 if not found / Physical
	var taken: float = after_def * (1.0 - resist)
	change_hp(-taken)
	emit_signal("damage_taken", taken, dmg_type, source)

func apply_damage_packet(packet: Dictionary) -> void:
	var base: float = 0.0
	if packet.has("amount"):
		base = float(packet["amount"])
	var types: Dictionary = {}
	if packet.has("types") and typeof(packet["types"]) == TYPE_DICTIONARY:
		types = packet["types"]
	var source: String = str(packet.get("source", ""))
	var def_val: float = get_final_stat("Defense")
	var total: float = 0.0

	if base > 0.0:
		total += _mitigate_by_defense(base, def_val)

	if types.size() > 0:
		for t in types.keys():
			var portion: float = float(types[t])
			var after_def: float = _mitigate_by_defense(portion, def_val)
			total += after_def * (1.0 - _get_resistance_for(str(t)))

	if total > 0.0:
		change_hp(-total)
		var dtype: String = "Mixed"
		if types.size() == 1:
			for k in types.keys():
				dtype = str(k)
				break
		emit_signal("damage_taken", total, dtype, source)

# ------ Modifiers ------
func _reconcile_vital_if_needed(stat_name: String) -> void:
	match stat_name:
		"HP":
			current_hp = clamp(current_hp, 0.0, max_hp())
			emit_signal("hp_changed", current_hp, max_hp())
		"MP":
			current_mp = clamp(current_mp, 0.0, max_mp())
			emit_signal("mp_changed", current_mp, max_mp())
		"END":
			current_end = clamp(current_end, 0.0, max_end())
			emit_signal("end_changed", current_end, max_end())
		"Stamina":
			# Base Stamina changed -> END max may change; clamp & emit END
			current_end = clamp(current_end, 0.0, max_end())
			emit_signal("end_changed", current_end, max_end())

func _reconcile_all_vitals() -> void:
	_reconcile_vital_if_needed("HP")
	_reconcile_vital_if_needed("MP")
	_reconcile_vital_if_needed("END")

func add_modifier(modifier) -> void:
	modifiers.append(modifier)
	var s: String = (str(modifier.get("stat_name","")) if modifier is Dictionary else str(modifier.stat_name))
	if s != "":
		emit_signal("stat_changed", s, get_final_stat(s))
		_reconcile_vital_if_needed(s)

func remove_modifiers_by_source(source_id: String) -> void:
	var filtered: Array = []
	for m in modifiers:
		var sid: String = (str(m.get("source_id", "")) if m is Dictionary else str(m.source_id))
		if sid != source_id:
			filtered.append(m)
	modifiers = filtered
	_reconcile_all_vitals()

func clear_modifiers() -> void:
	modifiers.clear()
	_reconcile_all_vitals()

# ------ Process (buff ticking + derived regen) ------
func _process(delta: float) -> void:
	if auto_tick_modifiers:
		var removed: Array = []
		for m in modifiers:
			if m is StatModifier and m.is_temporary():
				m.tick(delta)
				if m.expired():
					removed.append(m)
		for m in removed:
			modifiers.erase(m)
			var s: String = str(m.stat_name)
			if s != "":
				emit_signal("stat_changed", s, get_final_stat(s))
		if removed.size() > 0:
			_reconcile_all_vitals()

	var hp_r: float = (DerivedFormulas.hp_regen_per_sec(self) if use_gdd_derived else hp_regen_per_sec)
	var mp_r: float = (DerivedFormulas.mp_regen_per_sec(self) if use_gdd_derived else mp_regen_per_sec)
	var end_r: float = end_regen_per_sec  # use derived if you implement it: DerivedFormulas.end_regen_per_sec(self)

	if hp_r > 0.0: change_hp(hp_r * delta)
	if mp_r > 0.0: change_mp(mp_r * delta)
	if end_r > 0.0: change_end(end_r * delta)

# ------ Debug on enter ------
func _enter_tree() -> void:
	print("STA:", get_final_stat("STA"),
		  "  END(derived):", get_final_stat("END"),
		  "  HP max:", max_hp(),
		  "  MP max:", max_mp(),
		  "  Stamina max:", max_stamina(),
		  "  MoveSpeed:", get_final_stat("MoveSpeed"))

# ------ Allocation helper ------
func can_allocate(stat_name: String) -> bool:
	return !(stat_name in ["HP","MP","END"])
