extends Node
class_name StatsComponent

signal hp_changed(current: float, max_value: float)
signal damage_taken(amount: float, dmg_type: String, source: String)
signal damage_taken_ex(amount: float, dmg_type: String, source: String, is_crit: bool)
signal mp_changed(current: float, max_value: float)
signal end_changed(current: float, max_value: float)
signal died
signal stat_changed(stat_name: String, final_value: float)
signal healed(amount: float, source: String, is_crit: bool)

@export var debug_damage_log: bool = false

@export var stats: Resource
@export var damage_formula: String = "armor"

# --- Class overlay that StatsResource can read at access time ---
@export var class_def: Resource = null
func set_class_def(cd: Resource) -> void:
	class_def = cd
func get_class_def() -> Resource:
	return class_def

@export var _mp_source_policy: String = ""
@export var _mp_hybrid_weights: Dictionary = {"INT": 0.5, "WIS": 0.5}

func get_mp_source() -> String:
	return _mp_source_policy
func get_mp_weights() -> Dictionary:
	return _mp_hybrid_weights
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

# Backward-compatible store; may contain Dictionary and/or StatModifier.
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

# --- StatusConditions cache (invulnerability + status reads) ---
var _status_cache: Node = null

func _status() -> Node:
	if _status_cache != null and is_instance_valid(_status_cache):
		return _status_cache
	var parent_node: Node = get_parent()
	if parent_node != null:
		var sc: Node = parent_node.find_child("StatusConditions", true, false)
		if sc != null:
			_status_cache = sc
			return _status_cache
	for c in get_children():
		if c != null and (c.name == "StatusConditions" or c.has_method("is_invulnerable")):
			_status_cache = c
			return _status_cache
	return null

func _is_invulnerable_now() -> bool:
	var s: Node = _status()
	if s != null and s.has_method("is_invulnerable"):
		var any_v: Variant = s.call("is_invulnerable")
		if typeof(any_v) == TYPE_BOOL:
			return bool(any_v)
	return false
# -----------------------------------------------

# NEW: Movement-speed scaling from StatusConditions (Frozen, Snared, etc.)
func _status_move_speed_multiplier() -> float:
	var mul: float = 1.0
	var sc: Node = _status()
	if sc != null:
		# Preferred helper on StatusConditions
		if sc.has_method("get_move_speed_multiplier"):
			var v: Variant = sc.call("get_move_speed_multiplier")
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				mul = float(v)
		# Legacy fallback: if only frozen flag exists, assume 0.6
		elif sc.has_method("is_frozen"):
			var fr: Variant = sc.call("is_frozen")
			if typeof(fr) == TYPE_BOOL and bool(fr):
				mul = 0.6
	# Guard rails
	if mul < 0.05:
		mul = 0.05
	if mul > 2.0:
		mul = 2.0
	return mul

# NEW: Attack-speed scaling passthrough (SLOWED, FROZEN).
# Public on purpose so other systems (e.g., DerivedFormulas) can read from the same place as other stats.
func get_attack_speed_multiplier() -> float:
	var sc: Node = _status()
	if sc != null:
		# Preferred helper on StatusConditions
		if sc.has_method("get_attack_speed_multiplier"):
			var v: Variant = sc.call("get_attack_speed_multiplier")
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				var mul: float = float(v)
				if mul < 0.05:
					return 0.05
				if mul > 2.0:
					return 2.0
				return mul
		# Legacy inference if helper not present
		var legacy_mul: float = 1.0
		var had_flag: bool = false
		if sc.has_method("is_frozen"):
			var fr2: Variant = sc.call("is_frozen")
			if typeof(fr2) == TYPE_BOOL and bool(fr2):
				had_flag = true
				var fam_any: Variant = sc.get("frozen_attack_speed_mul")
				var fam: float = 0.6
				if typeof(fam_any) == TYPE_FLOAT:
					fam = float(fam_any)
				legacy_mul *= clampf(fam, 0.05, 1.0)
		if sc.has_method("is_slowed"):
			var sl2: Variant = sc.call("is_slowed")
			if typeof(sl2) == TYPE_BOOL and bool(sl2):
				had_flag = true
				var sam_any: Variant = sc.get("slowed_attack_speed_mul")
				var sam: float = 0.7
				if typeof(sam_any) == TYPE_FLOAT:
					sam = float(sam_any)
				legacy_mul *= clampf(sam, 0.05, 1.0)
		if had_flag:
			return legacy_mul
	return 1.0

func _recalc_processing() -> void:
	var should_process: bool = false
	if auto_tick_modifiers:
		should_process = true
	if should_process == false and hp_regen_per_sec > 0.0:
		should_process = true
	if should_process == false and mp_regen_per_sec > 0.0:
		should_process = true
	if should_process == false and end_regen_per_sec > 0.0:
		should_process = true
	if should_process == false and DerivedFormulas.hp_regen_per_sec(self) > 0.0:
		should_process = true
	if should_process == false and DerivedFormulas.mp_regen_per_sec(self) > 0.0:
		should_process = true
	if should_process == false and DerivedFormulas.end_regen_per_sec(self) > 0.0:
		should_process = true
	set_process(should_process)

func _set_auto_tick_mods(v: bool) -> void:
	auto_tick_modifiers = v
	_recalc_processing()
func _set_regen_hp(v: float) -> void:
	hp_regen_per_sec = v
	_recalc_processing()
func _set_regen_mp(v: float) -> void:
	mp_regen_per_sec = v
	_recalc_processing()
func _set_regen_end(v: float) -> void:
	end_regen_per_sec = v
	_recalc_processing()

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

# --- Base + derived access (class-aware) ---
func _get_base_from_resource(stat_key: String, default_val: float = 0.0) -> float:
	if stats == null:
		return default_val

	# Preferred: class-aware accessor on StatsResource
	if class_def != null and stats.has_method("get_base_for_class"):
		var v3: Variant = stats.call("get_base_for_class", stat_key, default_val, class_def)
		if typeof(v3) == TYPE_INT or typeof(v3) == TYPE_FLOAT:
			return float(v3)

	# Raw base (legacy)
	var dict_v: Variant = stats.get("base_stats")
	if typeof(dict_v) == TYPE_DICTIONARY:
		var base_dict: Dictionary = dict_v
		if base_dict.has(stat_key):
			var v2: Variant = base_dict[stat_key]
			if typeof(v2) == TYPE_INT or typeof(v2) == TYPE_FLOAT:
				return float(v2)
		return default_val
	var v: Variant = stats.get(stat_key)
	if v == null:
		return default_val
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return float(v)
	return default_val

func get_base_stat(stat_name: String) -> float:
	return _get_base_from_resource(stat_name, 0.0)

func _derived_base_for(stat_name: String) -> float:
	match stat_name:
		"END":
			return DerivedFormulas.end_from_sta(self)
		"HP":
			return DerivedFormulas.hp_max(self)
		"MP":
			return DerivedFormulas.mp_max(self)
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
			var derived_cc: float = DerivedFormulas.crit_chance(self)
			var extra_cc: float = get_base_stat("CritChance")
			return derived_cc + extra_cc
		_:
			return get_base_stat(stat_name)

# --- Modifier aggregation helpers ---
func _collect_modifiers_for(stat_name: String) -> Dictionary:
	# Returns:
	# {
	#   "add_sum": float,
	#   "mul_prod": float,
	#   "override_present": bool,
	#   "override_value": float
	# }
	var add_sum: float = 0.0
	var mul_prod: float = 1.0
	var override_present: bool = false
	var override_value: float = 0.0

	var i: int = 0
	while i < modifiers.size():
		var m: Variant = modifiers[i]
		if m is Dictionary:
			# Legacy dictionary modifier
			var m_stat: String = str(m.get("stat_name", ""))
			if m_stat == stat_name:
				add_sum += float(m.get("add_value", 0.0))
				mul_prod *= float(m.get("mul_value", 1.0))
		elif m is StatModifier:
			if str(m.stat_name) == stat_name:
				add_sum += m.effective_add()
				mul_prod *= m.effective_mul()
				if m.has_override():
					override_present = true
					override_value = float(m.override_value)
		i += 1

	var out: Dictionary = {}
	out["add_sum"] = add_sum
	out["mul_prod"] = mul_prod
	out["override_present"] = override_present
	out["override_value"] = override_value
	return out

func get_final_stat(stat_name: String) -> float:
	var base_val: float = _derived_base_for(stat_name)
	var agg: Dictionary = _collect_modifiers_for(stat_name)
	var add_sum: float = float(agg["add_sum"])
	var mul_prod: float = float(agg["mul_prod"])
	var override_present: bool = bool(agg["override_present"])
	var override_value: float = float(agg["override_value"])

	var final_val: float = (base_val + add_sum) * mul_prod
	if override_present:
		final_val = override_value
	if final_val < 0.0:
		final_val = 0.0

	# Status-based movement scaling globally
	if stat_name == "MoveSpeed":
		final_val = final_val * _status_move_speed_multiplier()

	return final_val

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
		var keys: Array[String] = [
			"HP","MP","END","MoveSpeed","Attack","Defense",
			"STR","DEX","STA","INT","WIS","LCK",
			"BlockChance","ParryChance","Evasion","CritChance","CritHealChance",
			"SlashRes","PierceRes","BluntRes","FireRes","IceRes",
			"WindRes","EarthRes","MagicRes","LightRes","DarknessRes","PoisonRes"
		]
		var i: int = 0
		while i < keys.size():
			var k: String = keys[i]
			out[k] = get_final_stat(k)
			i += 1
	return out

func max_hp() -> float:
	return get_final_stat("HP")
func max_mp() -> float:
	return get_final_stat("MP")
func max_end() -> float:
	return get_final_stat("END")

# --- Vitals change helpers ---
func change_hp(amount: float) -> void:
	current_hp = clamp(current_hp + amount, 0.0, max_hp())
	emit_signal("hp_changed", current_hp, max_hp())
	if current_hp <= 0.0:
		emit_signal("died")

func apply_heal(amount: float, source: String = "", is_crit: bool = false) -> int:
	if amount <= 0.0:
		return 0
	var before: float = current_hp
	change_hp(amount)  # clamps & emits hp_changed
	var after: float = current_hp
	var landed_f: float = max(0.0, after - before)
	var landed: int = int(landed_f)
	if landed > 0:
		emit_signal("healed", float(landed), source, is_crit)
	return landed

func change_mp(amount: float) -> void:
	current_mp = clamp(current_mp + amount, 0.0, max_mp())
	emit_signal("mp_changed", current_mp, max_mp())

func change_end(amount: float) -> void:
	current_end = clamp(current_end + amount, 0.0, max_end())
	emit_signal("end_changed", current_end, max_end())

func spend_mp(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if current_mp + 0.000001 < amount:
		return false
	change_mp(-amount)
	return true

func spend_end(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if current_end + 0.000001 < amount:
		return false
	change_end(-amount)
	return true

func restore_mp(amount: float) -> void:
	if amount > 0.0:
		change_mp(amount)
func restore_end(amount: float) -> void:
	if amount > 0.0:
		change_end(amount)

# --- Incoming damage ---
func _mitigate_by_defense(amount: float, defense: float) -> float:
	if amount <= 0.0:
		return 0.0
	match damage_formula:
		"linear":
			return max(0.0, amount - max(0.0, defense))
		"expo":
			return amount * pow(0.9, max(0.0, defense))
		_:
			return amount * (100.0 / (100.0 + max(0.0, defense)))

func _get_resistance_for(type_name: String) -> float:
	var key: String = ""
	if RES_KEYS.has(type_name):
		key = str(RES_KEYS[type_name])
	var r: float = 0.0
	if key != "":
		r = get_final_stat(key)
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

func _owner_node_name() -> String:
	var parent_node: Node = get_parent()
	if parent_node != null:
		return parent_node.name
	return name

func apply_damage(amount: float, dmg_type: String = "Physical", source: String = "") -> void:
	# Invulnerability gate
	if _is_invulnerable_now():
		if debug_damage_log:
			print("[Stats] damage blocked by INVULNERABLE (apply_damage).")
		return
	if amount <= 0.0:
		return

	var defense: float = get_final_stat("Defense")

	# --------- DEBUG: defender-side trace (simple damage) ---------
	if debug_damage_log:
		var res_pre: float = _get_resistance_for(dmg_type)
		var node_name: String = _owner_node_name()
		print("[ENEMY DMG IN] node=", node_name,
			" raw=", amount,
			" def=", defense,
			" formula=", damage_formula,
			" type=", dmg_type,
			" res=", res_pre)

	var after_def: float = _mitigate_by_defense(amount, defense)
	var resist: float = _get_resistance_for(dmg_type)
	var taken: float = after_def * (1.0 - resist)
	if taken <= 0.0:
		return

	# Optional post line
	if debug_damage_log:
		print("[ENEMY DMG OUT] taken=", taken, " after_def=", after_def, " src=", source)

	change_hp(-taken)

	if debug_damage_log:
		print("[Stats] apply_damage taken=", taken, " type=", dmg_type, " crit=", false, " src=", source)

	emit_signal("damage_taken", taken, dmg_type, source)
	emit_signal("damage_taken_ex", taken, dmg_type, source, false)

func apply_damage_packet(packet: Dictionary) -> void:
	# Invulnerability gate
	if _is_invulnerable_now():
		if debug_damage_log:
			print("[Stats] damage blocked by INVULNERABLE (apply_damage_packet).")
		return
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

	# --------- DEBUG: defender-side trace (packets) ---------
	if debug_damage_log:
		var node_name2: String = _owner_node_name()
		print("[ENEMY DMG IN] node=", node_name2,
			" raw=", base_amt,
			" def=", def_val,
			" formula=", damage_formula,
			" crit=", is_crit,
			" source=", source,
			" has_types=", not types.is_empty(),
			" treat_as_weights=", treat_types_as_weights)
		if not types.is_empty():
			for t_dbg in types.keys():
				var rv: Variant = types[t_dbg]
				var rvf: float = 0.0
				if typeof(rv) == TYPE_INT or typeof(rv) == TYPE_FLOAT:
					rvf = float(rv)
				print("    [type] ", str(t_dbg), "=", rvf, " res=", _get_resistance_for(str(t_dbg)))

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
			for t in types.keys():
				var pv: Variant = types[t]
				var portion2: float = 0.0
				if typeof(pv) == TYPE_INT or typeof(pv) == TYPE_FLOAT:
					portion2 = float(pv)
				if portion2 <= 0.0:
					continue
				var after_def2: float = _mitigate_by_defense(portion2, def_val)
				# Correct: use str(t) here
				total += after_def2 * (1.0 - _get_resistance_for(str(t)))
	else:
		# No types; use base only (apply defense AND default Physical resist).
		if base_amt > 0.0:
			dtype = "Physical"
			var after_def_base: float = _mitigate_by_defense(base_amt, def_val)
			total += after_def_base * (1.0 - _get_resistance_for("Physical"))

	if total > 0.0:
		# Optional post line
		if debug_damage_log:
			print("[ENEMY DMG OUT] taken=", total, " dtype=", dtype, " src=", source)
		change_hp(-total)

		if debug_damage_log:
			print("[Stats] packet taken=", total, " type=", dtype, " crit=", is_crit, " src=", source)

		emit_signal("damage_taken", total, dtype, source)
		emit_signal("damage_taken_ex", total, dtype, source, is_crit)

# --- Reconciliation helpers when stats change ---
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

# --- Public modifier APIs (backward compatible) ---
func add_modifier(modifier: Variant) -> void:
	if modifier is StatModifier:
		var incoming: StatModifier = modifier
		var runtime_mod: StatModifier = incoming.clone_for_runtime()
		var stacked: bool = false
		if String(runtime_mod.stacking_key) != "":
			var i: int = 0
			while i < modifiers.size():
				var m: Variant = modifiers[i]
				if m is StatModifier:
					var sm: StatModifier = m
					var same_stat: bool = str(sm.stat_name) == str(runtime_mod.stat_name)
					var can_stack: bool = sm.can_stack_with(runtime_mod)
					if same_stat and can_stack:
						var ok: bool = sm.add_stack_from(runtime_mod)
						if ok:
							stacked = true
							break
				i += 1
		if not stacked:
			modifiers.append(runtime_mod)
		var sname: String = str(runtime_mod.stat_name)
		if sname != "":
			emit_signal("stat_changed", sname, get_final_stat(sname))
			_reconcile_vital_if_needed(sname)
	else:
		modifiers.append(modifier)
		var s: String = ""
		if modifier is Dictionary:
			s = str(modifier.get("stat_name", ""))
		if s != "":
			emit_signal("stat_changed", s, get_final_stat(s))
			_reconcile_vital_if_needed(s)

func remove_modifiers_by_source(source_id: String) -> void:
	var filtered: Array = []
	var changed_stats: Dictionary = {}
	var i: int = 0
	while i < modifiers.size():
		var m: Variant = modifiers[i]
		var sid: String = ""
		if m is Dictionary:
			sid = str(m.get("source_id", ""))
		elif m is StatModifier:
			sid = str(m.source_id)
		else:
			sid = ""
		if sid != source_id:
			filtered.append(m)
		else:
			var sname: String = ""
			if m is Dictionary:
				sname = str(m.get("stat_name", ""))
			elif m is StatModifier:
				sname = str(m.stat_name)
			if sname != "":
				changed_stats[sname] = true
		i += 1
	modifiers = filtered
	for k in changed_stats.keys():
		var key: String = str(k)
		emit_signal("stat_changed", key, get_final_stat(key))
	_reconcile_all_vitals()

func remove_modifiers_by_key(stacking_key: StringName) -> void:
	if String(stacking_key) == "":
		return
	var filtered: Array = []
	var changed_stats: Dictionary = {}
	var i: int = 0
	while i < modifiers.size():
		var m: Variant = modifiers[i]
		var keep: bool = true
		if m is StatModifier:
			if str(m.stacking_key) == str(stacking_key):
				keep = false
				var sname: String = str(m.stat_name)
				if sname != "":
					changed_stats[sname] = true
		if keep:
			filtered.append(m)
		i += 1
	modifiers = filtered
	for k in changed_stats.keys():
		var key: String = str(k)
		emit_signal("stat_changed", key, get_final_stat(key))
	_reconcile_all_vitals()

func clear_modifiers() -> void:
	modifiers.clear()
	_reconcile_all_vitals()

func clear_expired_modifiers() -> void:
	var filtered: Array = []
	var changed_stats: Dictionary = {}
	var i: int = 0
	while i < modifiers.size():
		var m: Variant = modifiers[i]
		var keep: bool = true
		if m is StatModifier:
			if m.is_temporary() and m.expired():
				keep = false
				var sname: String = str(m.stat_name)
				if sname != "":
					changed_stats[sname] = true
		if keep:
			filtered.append(m)
		i += 1
	modifiers = filtered
	for k in changed_stats.keys():
		var key: String = str(k)
		emit_signal("stat_changed", key, get_final_stat(key))
	_reconcile_all_vitals()

# --- Processing: tick timed buffs, regen ---
func _process(delta: float) -> void:
	if auto_tick_modifiers:
		var removed: Array = []
		var i: int = 0
		while i < modifiers.size():
			var m: Variant = modifiers[i]
			if m is StatModifier and m.is_temporary():
				m.tick(delta)
				if m.expired():
					removed.append(m)
			i += 1
		var j: int = 0
		while j < removed.size():
			var rm: StatModifier = removed[j]
			modifiers.erase(rm)
			var s: String = str(rm.stat_name)
			if s != "":
				emit_signal("stat_changed", s, get_final_stat(s))
			j += 1
		if removed.size() > 0:
			_reconcile_all_vitals()

	var hp_r: float = DerivedFormulas.hp_regen_per_sec(self)
	var mp_r: float = DerivedFormulas.mp_regen_per_sec(self)
	var end_r: float = DerivedFormulas.end_regen_per_sec(self)
	if hp_r > 0.0:
		change_hp(hp_r * delta)
	if mp_r > 0.0:
		change_mp(mp_r * delta)
	if end_r > 0.0:
		change_end(end_r * delta)

# --- Utility ---
func can_allocate(stat_name: String) -> bool:
	return not (stat_name == "HP" or stat_name == "MP" or stat_name == "END")
