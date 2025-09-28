extends Node
class_name StatsComponent

signal hp_changed(current: float, max_value: float)
signal damage_taken(amount: float, dmg_type: String, source: String)
signal damage_taken_ex(amount: float, dmg_type: String, source: String, is_crit: bool)
signal mp_changed(current: float, max_value: float)
signal end_changed(current: float, max_value: float)
signal died
signal stat_changed(stat_name: String, final_value: float)

@export var debug_damage_log: bool = false

@export var stats: Resource
@export var damage_formula: String = "armor"

@export var use_gdd_derived: bool = true
@export var derive_end_from_sta: bool = true

@export var _mp_source_policy: String = ""
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

var current_hp: float = 0.0
var current_mp: float = 0.0
var current_end: float = 0.0
var modifiers: Array = []

const RES_KEYS := {
	"Slash": "SlashRes", "Pierce": "PierceRes", "Blunt": "BluntRes",
	"Fire": "FireRes", "Ice": "IceRes", "Wind": "WindRes", "Earth": "EarthRes",
	"Magic": "MagicRes", "Light": "LightRes", "Darkness": "DarknessRes", "Poison": "PoisonRes",
}

# Per-attack dedupe: source -> last attack_id seen
var _recent_attack_ids: Dictionary = {}

@export var auto_tick_modifiers: bool = false : set = _set_auto_tick_mods
@export var hp_regen_per_sec: float = 0.0    : set = _set_regen_hp
@export var mp_regen_per_sec: float = 0.0    : set = _set_regen_mp
@export var end_regen_per_sec: float = 0.0   : set = _set_regen_end

func _recalc_processing() -> void:
	var should_process: bool = false
	if auto_tick_modifiers: should_process = true
	if hp_regen_per_sec > 0.0: should_process = true
	if mp_regen_per_sec > 0.0: should_process = true
	if end_regen_per_sec > 0.0: should_process = true
	if use_gdd_derived: should_process = true
	set_process(should_process)

func _set_auto_tick_mods(v: bool) -> void: auto_tick_modifiers = v; _recalc_processing()
func _set_regen_hp(v: float) -> void: hp_regen_per_sec = v; _recalc_processing()
func _set_regen_mp(v: float) -> void: mp_regen_per_sec = v; _recalc_processing()
func _set_regen_end(v: float) -> void: end_regen_per_sec = v; _recalc_processing()

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

func _get_base_from_resource(stat_key: String, default_val: float = 0.0) -> float:
	if stats == null: return default_val
	var dict_v: Variant = stats.get("base_stats")
	if typeof(dict_v) == TYPE_DICTIONARY:
		var base_dict: Dictionary = dict_v
		if base_dict.has(stat_key):
			var v2: Variant = base_dict[stat_key]
			if typeof(v2) == TYPE_INT or typeof(v2) == TYPE_FLOAT:
				return float(v2)
		return default_val
	var v: Variant = stats.get(stat_key)
	if v == null: return default_val
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return float(v)
	return default_val

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
		"HP": return DerivedFormulas.hp_max(self)
		"MP": return DerivedFormulas.mp_max(self)
		"MoveSpeed": return DerivedFormulas.move_speed(self)
		"Attack": return DerivedFormulas.attack_rating(self)
		"Defense": return DerivedFormulas.defense_rating(self)
		"BlockChance": return DerivedFormulas.block_chance(self)
		"ParryChance": return DerivedFormulas.parry_chance(self)
		"Evasion": return DerivedFormulas.evasion(self)
		"CritChance":
			var derived_cc: float = DerivedFormulas.crit_chance(self)
			var extra_cc: float = get_base_stat("CritChance")
			if extra_cc > 1.0:
				extra_cc = extra_cc * 0.01
			var total_cc: float = derived_cc + extra_cc
			return clamp(total_cc, 0.0, 0.95)
		"CritHealChance": return DerivedFormulas.crit_heal_chance(self)
		_: return get_base_stat(stat_name)

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
	var final_val: float = (base_val + add_sum) * mul_prod
	if final_val < 0.0: final_val = 0.0
	return final_val

func get_all_final_stats() -> Dictionary:
	var out: Dictionary = {}
	if stats == null: return out
	var dict_v: Variant = stats.get("base_stats")
	if typeof(dict_v) == TYPE_DICTIONARY:
		var base_dict: Dictionary = dict_v
		for k in base_dict.keys():
			out[str(k)] = get_final_stat(str(k))
	else:
		var keys := [
			"HP","MP","END","MoveSpeed","Attack","Defense",
			"STR","DEX","STA","INT","WIS","CHA","LCK",
			"BlockChance","ParryChance","Evasion","CritChance","CritHealChance",
			"SlashRes","PierceRes","BluntRes","FireRes","IceRes",
			"WindRes","EarthRes","MagicRes","LightRes","DarknessRes","PoisonRes"
		]
		for k in keys:
			out[k] = get_final_stat(k)
	return out

func max_hp() -> float: return get_final_stat("HP")
func max_mp() -> float: return get_final_stat("MP")
func max_end() -> float: return get_final_stat("END")

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

func change_stamina(amount: float) -> void: change_end(amount)
func spend_stamina(amount: float) -> bool: return spend_end(amount)
func restore_stamina(amount: float) -> void: restore_end(amount)

func _mitigate_by_defense(amount: float, defense: float) -> float:
	if amount <= 0.0: return 0.0
	match damage_formula:
		"linear": return max(0.0, amount - max(0.0, defense))
		"expo":   return amount * pow(0.9, max(0.0, defense))
		_:        return amount * (100.0 / (100.0 + max(0.0, defense)))

func _get_resistance_for(type_name: String) -> float:
	var key: String = ""
	if RES_KEYS.has(type_name):
		key = str(RES_KEYS[type_name])
	var r: float = 0.0
	if key != "": r = get_final_stat(key)
	return clamp(r, -0.9, 0.9)

# Per-attack dedupe
func _should_accept_attack(packet: Dictionary) -> bool:
	if not packet.has("attack_id"):
		return true
	var aid_v: Variant = packet["attack_id"]
	if typeof(aid_v) != TYPE_INT:
		return true
	var aid: int = int(aid_v)
	var src: String = str(packet.get("source", ""))
	var last_id: int = int(_recent_attack_ids.get(src, -999999))
	if last_id == aid:
		return false
	_recent_attack_ids[src] = aid
	return true

func apply_damage(amount: float, dmg_type: String = "Physical", source: String = "") -> void:
	if amount <= 0.0: return
	var defense: float = get_final_stat("Defense")
	var after_def: float = _mitigate_by_defense(amount, defense)
	var resist: float = _get_resistance_for(dmg_type)
	var taken: float = after_def * (1.0 - resist)
	if taken <= 0.0: return
	change_hp(-taken)

	if debug_damage_log:
		print("[Stats] apply_damage taken=", taken, " type=", dmg_type, " crit=", false, " src=", source)

	emit_signal("damage_taken", taken, dmg_type, source)
	emit_signal("damage_taken_ex", taken, dmg_type, source, false)

func apply_damage_packet(packet: Dictionary) -> void:
	if not _should_accept_attack(packet):
		return

	var base_amt: float = 0.0
	if packet.has("amount"):
		base_amt = float(packet["amount"])
	var types: Dictionary = {}
	if packet.has("types") and typeof(packet["types"]) == TYPE_DICTIONARY:
		types = packet["types"]
	var source: String = str(packet.get("source", ""))

	var is_crit: bool = false
	if packet.has("is_crit"):
		is_crit = bool(packet["is_crit"])

	var def_val: float = get_final_stat("Defense")
	var total: float = 0.0
	var dtype: String = "Physical"

	# Decide how to interpret `types`
	var typed_sum_raw: float = 0.0
	for k in types.keys():
		var v: Variant = types[k]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			var f: float = float(v)
			if f > 0.0:
				typed_sum_raw += f

	var treat_types_as_weights: bool = false
	if base_amt > 0.0 and typed_sum_raw > 0.0 and typed_sum_raw <= 1.5:
		treat_types_as_weights = true

	if typed_sum_raw > 0.0:
		# We have typed components.
		if treat_types_as_weights:
			dtype = "Mixed"
			if types.size() == 1:
				for only_k in types.keys():
					dtype = str(only_k)
					break
			for t in types.keys():
				var wv: Variant = types[t]
				var w: float = 0.0
				if typeof(wv) == TYPE_INT or typeof(wv) == TYPE_FLOAT:
					w = float(wv)
				if w <= 0.0:
					continue
				var portion: float = base_amt * (w / typed_sum_raw)
				var after_def: float = _mitigate_by_defense(portion, def_val)
				total += after_def * (1.0 - _get_resistance_for(str(t)))
		else:
			# Treat typed values as absolute amounts; ignore base if both present.
			dtype = "Mixed"
			if types.size() == 1:
				for only_k2 in types.keys():
					dtype = str(only_k2)
					break
			for t2 in types.keys():
				var pv: Variant = types[t2]
				var portion2: float = 0.0
				if typeof(pv) == TYPE_INT or typeof(pv) == TYPE_FLOAT:
					portion2 = float(pv)
				if portion2 <= 0.0:
					continue
				var after_def2: float = _mitigate_by_defense(portion2, def_val)
				total += after_def2 * (1.0 - _get_resistance_for(str(t2)))
	else:
		# No types; use base only (apply defense AND default Physical resist).
		if base_amt > 0.0:
			dtype = "Physical"
			var after_def_base: float = _mitigate_by_defense(base_amt, def_val)
			total += after_def_base * (1.0 - _get_resistance_for("Physical"))

	if total > 0.0:
		change_hp(-total)

		if debug_damage_log:
			print("[Stats] packet taken=", total, " type=", dtype, " crit=", is_crit, " src=", source)

		emit_signal("damage_taken", total, dtype, source)
		emit_signal("damage_taken_ex", total, dtype, source, is_crit)

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

func _reconcile_all_vitals() -> void:
	_reconcile_vital_if_needed("HP")
	_reconcile_vital_if_needed("MP")
	_reconcile_vital_if_needed("END")

func add_modifier(modifier) -> void:
	modifiers.append(modifier)
	var s: String = ""
	if modifier is Dictionary:
		s = str(modifier.get("stat_name", ""))
	else:
		s = str(modifier.stat_name)
	if s != "":
		emit_signal("stat_changed", s, get_final_stat(s))
		_reconcile_vital_if_needed(s)

func remove_modifiers_by_source(source_id: String) -> void:
	var filtered: Array = []
	for m in modifiers:
		var sid: String = ""
		if m is Dictionary:
			sid = str(m.get("source_id", ""))
		else:
			sid = str(m.source_id)
		if sid != source_id:
			filtered.append(m)
	modifiers = filtered
	_reconcile_all_vitals()

func clear_modifiers() -> void:
	modifiers.clear()
	_reconcile_all_vitals()

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

	var hp_r: float = 0.0
	var mp_r: float = 0.0
	if use_gdd_derived:
		hp_r = DerivedFormulas.hp_regen_per_sec(self)
		mp_r = DerivedFormulas.mp_regen_per_sec(self)
	else:
		hp_r = hp_regen_per_sec
		mp_r = mp_regen_per_sec
	var end_r: float = end_regen_per_sec

	if hp_r > 0.0: change_hp(hp_r * delta)
	if mp_r > 0.0: change_mp(mp_r * delta)
	if end_r > 0.0: change_end(end_r * delta)

func can_allocate(stat_name: String) -> bool:
	return !(stat_name in ["HP","MP","END"])
