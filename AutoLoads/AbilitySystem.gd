extends Node
class_name AbilitySystem

## Signals
signal cooldown_started(user: Node, ability_id: String, duration_ms: int, until_msec: int)
signal ability_cast(user: Node, ability_id: String, ok: bool)
signal gcd_started(user: Node, duration_ms: int, until_msec: int)

## Constants
const LOG_PREFIX: String = "[ABILITY] "
const ABILITY_HEAL: String = "heal"
const ABILITY_ATTACK: String = "attack"
const ABILITY_REVIVE: String = "revive"

## Inspector
@export var default_gcd_ms: int = 600
@export var default_cooldown_ms: int = 600
@export var debug_log: bool = true

# ----------------------------------------------------------------------------- #
# DEPRECATED – legacy spell resource hooks (kept only for editor/back-compat).
# No longer used anywhere in execution flow.
# ----------------------------------------------------------------------------- #
@export var heal_spell_resource_path: String = "res://Data/Abilities/HealingWhisper.tres" # DEPRECATED/UNUSED
@export var heal_spell_resource: Resource # DEPRECATED/UNUSED
@export var revive_spell_resource_path: String = "res://Data/Abilities/BlessingofLife.tres" # DEPRECATED/UNUSED
@export var revive_spell_resource: Resource # DEPRECATED/UNUSED

# (Kept for compatibility; no longer used to instantiate a script handler)
@export var revive_handler_path: String = "res://Data/Abilities/Handlers/AbilityReviveHandler.gd" # DEPRECATED/UNUSED

# Executor/def registry (generic). Values can be:
# - AbilityDef (Resource)
# - Path to AbilityDef .tres/.res
# - Other Resource/Object with perform() (legacy). We will no longer pass "spell_res".
var _handlers: Dictionary = {}

# Timers
var _gcd_until: Dictionary = {}          # user_key -> until_msec
var _cd_until: Dictionary = {}           # user_key -> { ability_id: until_msec }

# ----------------------------------------------------------------------------- #
# AbilityDef caches and icon cache (used by Hotbar/HUD)
# ----------------------------------------------------------------------------- #
var _def_icon_cache: Dictionary = {}     # ability_id -> Texture2D
var _def_by_id_cache: Dictionary = {}    # ability_id -> AbilityDef
var _defs_scanned: bool = false

# ----------------------------------------------------------------------------- #
# Tracer (autoload name: HealFlowTrace)
# ----------------------------------------------------------------------------- #
var _heal_tracer_cached: Node = null

# ----------------------------------------------------------------------------- #
# Autoloads
# ----------------------------------------------------------------------------- #
var AbilityExec: Node = null

func _ready() -> void:
	# Resolve executor autoload (per project rule #16)
	AbilityExec = get_node_or_null("/root/AbilityExec")

	# Warm legacy resources if inspector paths are set (DEPRECATED/UNUSED).
	# Retained to avoid editor warnings / missing resources in existing scenes.
	if heal_spell_resource == null and heal_spell_resource_path != "" and ResourceLoader.exists(heal_spell_resource_path):
		heal_spell_resource = ResourceLoader.load(heal_spell_resource_path)
	if revive_spell_resource == null and revive_spell_resource_path != "" and ResourceLoader.exists(revive_spell_resource_path):
		revive_spell_resource = ResourceLoader.load(revive_spell_resource_path)

# ----------------------------------------------------------------------------- #
# Public API
# ----------------------------------------------------------------------------- #
func register_handler(ability_id: String, handler_like: Variant) -> void:
	if ability_id == "":
		return
	_handlers[ability_id] = handler_like
	_try_cache_from_handler_entry(ability_id, handler_like)

func register_handler_path(ability_id: String, resource_path: String) -> void:
	if ability_id == "" or resource_path == "":
		return
	_handlers[ability_id] = resource_path
	_try_cache_def_from_path(ability_id, resource_path)

func request_cast(user: Node, ability_id: String, context: Dictionary = {}) -> bool:
	if user == null or not is_instance_valid(user):
		return false
	if ability_id == null or ability_id == "":
		return false

	# TRACE: request start
	var __tr: Node = _get_heal_tracer()
	if __tr and ability_id == ABILITY_HEAL and __tr.has_method("trace_request_start"):
		__tr.call("trace_request_start", user, ability_id, context)

	if debug_log:
		print_rich(LOG_PREFIX, "request by ", _uname(user), " ability=", ability_id)

	# Eligibility gate (class/brain/known list)
	if not _user_has_ability(user, ability_id):
		if __tr and ability_id == ABILITY_HEAL and __tr.has_method("trace_request_result"):
			__tr.call("trace_request_result", user, ability_id, false, "not_eligible")
		if debug_log:
			push_warning(LOG_PREFIX + "user not eligible for ability_id=" + ability_id + " user=" + _uname(user))
		emit_signal("ability_cast", user, ability_id, false)
		return false

	var user_key: String = _user_key(user)
	var gcd_blocked: bool = _is_on_gcd(user_key)
	var cd_blocked: bool = _is_on_cooldown(user_key, ability_id)

	# TRACE: can_cast snapshot (reads only)
	if __tr and ability_id == ABILITY_HEAL and __tr.has_method("trace_can_cast"):
		var extra: Dictionary = {
			"ctx_has_manual_target": context.has("manual_target"),
			"ctx_source": String(context.get("source", "unknown"))
		}
		__tr.call("trace_can_cast", user, ability_id, true, not gcd_blocked, not cd_blocked, extra)

	# Global cooldown
	if gcd_blocked:
		if __tr and ability_id == ABILITY_HEAL and __tr.has_method("trace_request_result"):
			__tr.call("trace_request_result", user, ability_id, false, "gcd_blocked")
		if debug_log:
			print_rich(LOG_PREFIX, "blocked by GCD for ", _uname(user), " ability=", ability_id)
		emit_signal("ability_cast", user, ability_id, false)
		return false

	# Per-ability cooldown
	if cd_blocked:
		if __tr and ability_id == ABILITY_HEAL and __tr.has_method("trace_request_result"):
			__tr.call("trace_request_result", user, ability_id, false, "cooldown_blocked")
		if debug_log:
			print_rich(LOG_PREFIX, "blocked by CD for ", _uname(user), " ability=", ability_id)
		emit_signal("ability_cast", user, ability_id, false)
		return false

	# ---- Resolve execution inputs (AbilityDef only) ----
	var ability_def: Resource = _resolve_ability_def(ability_id)
	if ability_def == null:
		var reg_def: Resource = _resolve_registered_ability_def(ability_id)
		if reg_def != null:
			ability_def = reg_def

	# ---- Execute via AbilityExec (single unified executor) ----
	var ok: bool = false
	if AbilityExec != null and AbilityExec.has_method("execute"):
		# IMPORTANT: No more spell_res being passed.
		var res_any: Variant = AbilityExec.call("execute", user, ability_def, context)
		if typeof(res_any) == TYPE_BOOL:
			ok = bool(res_any)
	else:
		# Safety net: if AbilityExec isn't present, try legacy object with perform()
		var legacy_obj: Object = _resolve_registered_object_with_perform(ability_id)
		if legacy_obj != null and legacy_obj.has_method("perform"):
			var ok_any: Variant = legacy_obj.call("perform", user, context)
			if typeof(ok_any) == TYPE_BOOL:
				ok = bool(ok_any)

	# ---- Timers: from AbilityDef/context ----
	var gcd_ms: int = 0
	var cd_ms: int = 0
	if ok:
		gcd_ms = _gcd_for_def(ability_def, user, context)
		cd_ms = _cooldown_for_def(ability_def, user, context)
		if gcd_ms > 0:
			_start_gcd(user_key, gcd_ms, user)
		if cd_ms > 0:
			_start_cooldown(user_key, ability_id, cd_ms, user)
		if debug_log:
			print_rich(LOG_PREFIX, "cast ok ", _uname(user), " id=", ability_id, " gcd_ms=", gcd_ms, " cd_ms=", cd_ms)
	else:
		if debug_log:
			print_rich(LOG_PREFIX, "cast FAILED ", _uname(user), " id=", ability_id)

	# TRACE: final result
	if __tr and ability_id == ABILITY_HEAL and __tr.has_method("trace_request_result"):
		if ok:
			__tr.call("trace_request_result", user, ability_id, true, "ok")
		else:
			__tr.call("trace_request_result", user, ability_id, false, "perform_failed")

	emit_signal("ability_cast", user, ability_id, ok)
	return ok

func can_cast(user: Node, ability_id: String) -> bool:
	if user == null or not is_instance_valid(user):
		return false
	if not _user_has_ability(user, ability_id):
		return false
	var user_key: String = _user_key(user)
	if _is_on_gcd(user_key):
		return false
	if _is_on_cooldown(user_key, ability_id):
		return false
	return true

# ----------------------------------------------------------------------------- #
# AbilityDef resolution & caches
# ----------------------------------------------------------------------------- #
func get_ability_icon(ability_id: String) -> Texture2D:
	if _def_icon_cache.has(ability_id):
		var v: Variant = _def_icon_cache[ability_id]
		if v is Texture2D:
			return v as Texture2D
	_scan_ability_defs()
	if _def_icon_cache.has(ability_id):
		var v2: Variant = _def_icon_cache[ability_id]
		if v2 is Texture2D:
			return v2 as Texture2D
	return null

func _resolve_ability_def(ability_id: String) -> Resource:
	if ability_id == "":
		return null
	if _def_by_id_cache.has(ability_id):
		var v: Variant = _def_by_id_cache[ability_id]
		if v is Resource:
			return v as Resource
	var reg_def: Resource = _resolve_registered_ability_def(ability_id)
	if reg_def != null:
		_def_by_id_cache[ability_id] = reg_def
		_try_cache_icon_from_def(ability_id, reg_def)
		return reg_def
	_scan_ability_defs()
	if _def_by_id_cache.has(ability_id):
		var v2: Variant = _def_by_id_cache[ability_id]
		if v2 is Resource:
			return v2 as Resource
	return null

func _resolve_registered_ability_def(ability_id: String) -> Resource:
	if not (ability_id in _handlers):
		return null
	var entry: Variant = _handlers[ability_id]
	if typeof(entry) == TYPE_OBJECT and entry is Resource:
		return entry as Resource
	if typeof(entry) == TYPE_STRING:
		var p: String = entry
		if p.ends_with(".tres") or p.ends_with(".res"):
			if ResourceLoader.exists(p):
				var res_any: Resource = ResourceLoader.load(p)
				return res_any
	return null

# Legacy spell fetcher is retained but UNUSED after this update.
# Keeping it avoids breaking editor state and future scripted migrations.
func _resolve_registered_spell(_ability_id: String) -> Resource:
	return null

func _resolve_registered_object_with_perform(ability_id: String) -> Object:
	if not (ability_id in _handlers):
		return null
	var entry: Variant = _handlers[ability_id]
	if typeof(entry) == TYPE_OBJECT and entry is Object:
		var obj: Object = entry as Object
		if obj.has_method("perform"):
			return obj
	if typeof(entry) == TYPE_STRING and ResourceLoader.exists(String(entry)):
		var res: Resource = ResourceLoader.load(String(entry))
		if res is Script:
			var inst: Object = (res as Script).new()
			if inst.has_method("perform"):
				return inst
		if res is Object and (res as Object).has_method("perform"):
			return res as Object
	return null

# --- Recursive scan helpers ----------------------------------------------------
func _scan_ability_defs() -> void:
	if _defs_scanned:
		return
	var root_dir: String = "res://Data/Abilities/Defs"
	_scan_dir_recursive(root_dir)
	_defs_scanned = true

func _scan_dir_recursive(dir_path: String) -> void:
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return
	da.list_dir_begin()
	while true:
		var fname: String = da.get_next()
		if fname == "":
			break
		if da.current_is_dir():
			if fname == "." or fname == "..":
				continue
			_scan_dir_recursive(dir_path.rstrip("/") + "/" + fname)
			continue
		if not fname.ends_with(".tres") and not fname.ends_with(".res"):
			continue
		var res_path: String = dir_path.rstrip("/") + "/" + fname
		var any_res: Variant = ResourceLoader.load(res_path)
		if any_res is Resource and (any_res as Resource).has_method("get"):
			var def: Resource = any_res as Resource
			var ability_id_val: Variant = def.get("ability_id")
			if typeof(ability_id_val) == TYPE_STRING:
				var id_str: String = String(ability_id_val)
				if id_str != "":
					_def_by_id_cache[id_str] = def
					_try_cache_icon_from_def(id_str, def)

# --- Cache helpers for register_* paths ---------------------------------------
func _try_cache_from_handler_entry(ability_id: String, entry: Variant) -> void:
	if typeof(entry) == TYPE_OBJECT and entry is Resource:
		_try_cache_icon_from_def(ability_id, entry as Resource)
	elif typeof(entry) == TYPE_STRING:
		var p: String = String(entry)
		_try_cache_def_from_path(ability_id, p)

func _try_cache_def_from_path(ability_id: String, resource_path: String) -> void:
	if resource_path == "":
		return
	if not (resource_path.ends_with(".tres") or resource_path.ends_with(".res")):
		return
	if not ResourceLoader.exists(resource_path):
		return
	var res_any: Variant = ResourceLoader.load(resource_path)
	if res_any is Resource:
		var def_res: Resource = res_any as Resource
		if def_res.has_method("get"):
			var id_v: Variant = def_res.get("ability_id")
			if typeof(id_v) == TYPE_STRING:
				_def_by_id_cache[ability_id] = def_res
				_try_cache_icon_from_def(ability_id, def_res)

func _try_cache_icon_from_def(ability_id: String, def_res: Resource) -> void:
	if def_res == null:
		return
	if not def_res.has_method("get"):
		return
	var icon_any: Variant = def_res.get("icon")
	if icon_any is Texture2D:
		_def_icon_cache[ability_id] = icon_any as Texture2D

# ----------------------------------------------------------------------------- #
# DEPRECATED – Legacy spell fallbacks (unused)
# ----------------------------------------------------------------------------- #
func _resolve_spell_resource_fallbacks(_ability_id: String) -> Resource:
	return null

# ----------------------------------------------------------------------------- #
# Eligibility helpers (unchanged)
# ----------------------------------------------------------------------------- #
func _user_has_ability(user: Object, ability_id: String) -> bool:
	if user == null or not is_instance_valid(user):
		return false
	if user is Object and (user as Object).has_method("has_ability"):
		var ok_any: Variant = (user as Object).call("has_ability", ability_id)
		if typeof(ok_any) == TYPE_BOOL and bool(ok_any):
			return true
	if user is Object and "known_abilities" in user:
		var arr_any: Variant = (user as Object).get("known_abilities")
		if typeof(arr_any) == TYPE_ARRAY:
			var arr: Array = arr_any
			if arr.has(ability_id):
				return true
	var kac: KnownAbilitiesComponent = _find_known_abilities_component(user)
	if kac != null:
		if kac.has_ability(ability_id):
			return true
	return false

func _find_known_abilities_component(user: Object) -> KnownAbilitiesComponent:
	if user == null or not is_instance_valid(user):
		return null
	if not (user is Node):
		return null
	var n: Node = user as Node
	var cand: Node = n.get_node_or_null("KnownAbilities")
	if cand != null and cand is KnownAbilitiesComponent:
		return cand as KnownAbilitiesComponent
	var found: Node = n.find_child("KnownAbilities", true, false)
	if found != null and found is KnownAbilitiesComponent:
		return found as KnownAbilitiesComponent
	return null

# ----------------------------------------------------------------------------- #
# Cooldowns (GCD/CD) — sourced from AbilityDef or context
# ----------------------------------------------------------------------------- #
func _is_on_gcd(user_key: String) -> bool:
	if not (user_key in _gcd_until):
		return false
	var now: int = Time.get_ticks_msec()
	return now < int(_gcd_until[user_key])

func _start_gcd(user_key: String, duration_ms: int, user: Node) -> void:
	var now: int = Time.get_ticks_msec()
	var dur: int = max(0, duration_ms)
	var until: int = now + dur
	_gcd_until[user_key] = until
	emit_signal("gcd_started", user, duration_ms, until)

func _is_on_cooldown(user_key: String, ability_id: String) -> bool:
	if not (user_key in _cd_until):
		return false
	var map: Dictionary = _cd_until[user_key]
	if not (ability_id in map):
		return false
	var now: int = Time.get_ticks_msec()
	return now < int(map[ability_id])

func _start_cooldown(user_key: String, ability_id: String, duration_ms: int, user: Node) -> void:
	var now: int = Time.get_ticks_msec()
	var dur: int = max(0, duration_ms)
	var until: int = now + dur
	if not (user_key in _cd_until):
		_cd_until[user_key] = {}
	var map: Dictionary = _cd_until[user_key]
	map[ability_id] = until
	emit_signal("cooldown_started", user, ability_id, duration_ms, until)

func _gcd_for_def(def: Resource, user: Object, context: Dictionary) -> int:
	if def != null and def.has_method("get"):
		var v: Variant = def.get("gcd_sec")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			var sec_f: float = float(v)
			if sec_f > 0.0:
				return int(roundi(sec_f * 1000.0))
	if context.has("gcd"):
		var sec_ctx: Variant = context["gcd"]
		if typeof(sec_ctx) == TYPE_FLOAT or typeof(sec_ctx) == TYPE_INT:
			var sec_ctx_f: float = float(sec_ctx)
			if sec_ctx_f > 0.0:
				return int(roundi(sec_ctx_f * 1000.0))
	return default_gcd_ms

func _cooldown_for_def(def: Resource, user: Object, context: Dictionary) -> int:
	if def != null and def.has_method("get"):
		var v: Variant = def.get("cooldown_sec")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			var sec_f: float = float(v)
			if sec_f > 0.0:
				return int(roundi(sec_f * 1000.0))
	if context.has("cooldown"):
		var sec_ctx: Variant = context["cooldown"]
		if typeof(sec_ctx) == TYPE_FLOAT or typeof(sec_ctx) == TYPE_INT:
			var sec_ctx_f: float = float(sec_ctx)
			if sec_ctx_f > 0.0:
				return int(roundi(sec_ctx_f * 1000.0))
	return default_cooldown_ms

# ----------------------------------------------------------------------------- #
# Utils
# ----------------------------------------------------------------------------- #
func _get_heal_tracer() -> Node:
	if _heal_tracer_cached == null:
		_heal_tracer_cached = get_node_or_null("/root/HealFlowTrace")
	return _heal_tracer_cached

func _user_key(user: Object) -> String:
	return str(user.get_instance_id())

func _uname(user: Object) -> String:
	if user == null or not is_instance_valid(user):
		return "null"
	if user is Node:
		var nd: Node = user as Node
		return nd.name + "(" + str(nd.get_instance_id()) + ")"
	return "obj(" + str(user.get_instance_id()) + ")"
