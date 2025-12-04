extends Node
class_name EnemyAbilityAI

# Tick & retry cadence (mirrors Companion)
@export var think_hz: float = 6.0
@export var min_retry_ms: int = 150

# Fallback basic attack (only used if no MELEE ability is available in KnownAbilities)
@export var fallback_attack_id: String = "attack"
@export var use_gcd_for_fallback_attack: bool = false

# Melee heuristics like Companion
@export var default_melee_range_px: float = 56.0
@export var default_arc_deg: float = 70.0

# INVERTED groups (from an enemy AI’s POV)
@export var enemy_groups: PackedStringArray = ["PartyMembers"]       # things we damage
@export var ally_groups: PackedStringArray = ["Enemies", "Enemy"]    # things we heal/rez

# Tunables (mirrors Companion defaults)
@export var debug_enemy_ai: bool = false
@export var heal_threshold_ratio: float = 0.55
@export var pursue_melee: bool = true
@export var max_target_radius_px: float = 220.0
@export var prefer_ranged_outside_melee: bool = true

# State
var _think_accum: float = 0.0
var _last_try_msec: int = 0
var _active: bool = true

var _actor_root: Node2D = null
var _owner_body: Node2D = null

var _kac: Node = null                            # KnownAbilitiesComponent (or compatible)
var _known_ids: PackedStringArray = []
var _type_cache: Dictionary = {}                 # ability_id -> UPPER type string cache

func _ready() -> void:
	_actor_root = _resolve_actor_root()
	_owner_body = _actor_root
	_kac = _resolve_known_abilities()
	_sync_known_abilities_from_component()
	_connect_kac_signals()
	set_process(true)

	# One-time visibility if the autoload is misnamed/missing
	var asys: Node = _ability_system()
	if asys == null:
		push_warning("[EnemyAbilityAI] Ability system not found at /root/AbilitySys or /root/AbilitySystem.")

func set_active(active: bool) -> void:
	_active = active
	set_process(_active)
	if debug_enemy_ai:
		var who: String = "null"
		if _actor_root != null and is_instance_valid(_actor_root):
			who = _actor_root.name
		print_rich("[EAI] set_active(", active, ") for ", who)

func _process(delta: float) -> void:
	if not _active:
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
	# Late-resolve KAC in case scene spawns it later
	if _kac == null or not is_instance_valid(_kac):
		_kac = _resolve_known_abilities()
		if _kac != null and is_instance_valid(_kac):
			_connect_kac_signals()
			_sync_known_abilities_from_component()
			if debug_enemy_ai:
				print_rich("[EAI] Found KnownAbilities component late and connected.")

	if _is_dead():
		_halt_motion()
		return
	if _movement_blocked():
		return

	# throttle re-try
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_try_msec < min_retry_ms:
		return
	_last_try_msec = now_msec

	var choice: Dictionary = _choose_best_ability()
	if choice.is_empty():
		return

	var ability_id: String = ""
	if "ability_id" in choice:
		var a_any: Variant = choice["ability_id"]
		if typeof(a_any) == TYPE_STRING:
			ability_id = String(a_any)
	if ability_id == "":
		return

	var ctx: Dictionary = {}
	if "context" in choice:
		var c_any: Variant = choice["context"]
		if typeof(c_any) == TYPE_DICTIONARY:
			ctx = c_any as Dictionary

	# Ensure an aim_dir is present and up-to-date; AnimationBridge will use this to pick _down/_up/_left/_right/_side.
	# Prefer aiming directly at the explicit target if one is present.
	if ctx.has("target"):
		var t_any: Variant = ctx["target"]
		var t2d: Node2D = t_any as Node2D
		if t2d != null and is_instance_valid(t2d):
			ctx["aim_dir"] = _aim_towards(t2d)
	elif not ctx.has("aim_dir"):
		ctx["aim_dir"] = _aim_towards_target_in_ctx(ctx)

	# Fire through AbilitySystem (same call shape as Companion)
	var asys: Node = _ability_system()
	if asys == null:
		return

	var ok_any: Variant = asys.call("request_cast", _owner_body, ability_id, ctx)
	var ok: bool = false
	if typeof(ok_any) == TYPE_BOOL:
		ok = bool(ok_any)

	if debug_enemy_ai:
		var tn: String = ""
		if ctx.has("target"):
			var t: Node = ctx["target"] as Node
			if t != null and is_instance_valid(t):
				tn = t.name
		var who: String = "null"
		if _actor_root != null and is_instance_valid(_actor_root):
			who = _actor_root.name
		print_rich("[EAI] cast user=", who, " ability=", ability_id, " ok=", ok, " target=", tn, " ctx=", ctx, " known=", _known_ids)

	if ok:
		_halt_motion()
	else:
		# If melee-ish but failed (CD/GCD/etc.), try to close the gap a bit
		if _is_melee_like(ability_id):
			_try_gap_close_for_melee_attack()

# ---------------- Choosing abilities (mirrors Companion) ---------------- #

func _choose_best_ability() -> Dictionary:
	_sync_known_abilities_from_component()

	if _known_ids.is_empty() and debug_enemy_ai:
		print_rich("[EAI] No known abilities on enemy (seed KnownAbilitiesComponent.known_abilities).")

	# Situation reads
	var lowest_ally: Node2D = _find_lowest_hp_ally(heal_threshold_ratio)
	var dead_ally: Node2D = _find_dead_ally()
	var enemy: Node2D = _current_enemy_target()
	if enemy == null or not is_instance_valid(enemy):
		enemy = _pick_enemy_target(max_target_radius_px)

	# Bucket known abilities by type (via AbilitySystem/AbilityDef just like Companion)
	var revive_ids: Array[String] = []
	var heal_ids: Array[String] = []
	var melee_ids: Array[String] = []
	var ranged_ids: Array[String] = []
	var buffish_ids: Array[String] = []
	var summon_ids: Array[String] = []

	var i: int = 0
	while i < _known_ids.size():
		var aid: String = _known_ids[i]
		var atype: String = _ability_type_for(aid)
		match atype:
			"REVIVE_SPELL":
				revive_ids.append(aid)
			"HEAL_SPELL", "HOT_SPELL", "CURE_SPELL":
				heal_ids.append(aid)
			"MELEE":
				melee_ids.append(aid)
			"PROJECTILE", "DAMAGE_SPELL", "DOT_SPELL", "DEBUFF":
				ranged_ids.append(aid)
			"BUFF":
				buffish_ids.append(aid)
			"SUMMON_SPELL":
				summon_ids.append(aid)
			_:
				pass
		i += 1

	# 1) REVIVE
	if dead_ally != null and is_instance_valid(dead_ally) and revive_ids.size() > 0:
		var id_revive: String = revive_ids[0]
		if _can_cast(id_revive):
			return {"ability_id": id_revive, "context": {"target": dead_ally}}

	# 2) HEAL/HOT/CURE on lowest HP ally (includes self if ally groups contain this actor)
	if lowest_ally != null and is_instance_valid(lowest_ally) and heal_ids.size() > 0:
		var id_heal: String = heal_ids[0]
		if _can_cast(id_heal):
			return {"ability_id": id_heal, "context": {"target": lowest_ally}}

	# 3A) Ranged-first if far (casters or mixed kits)
	if enemy != null and is_instance_valid(enemy) and prefer_ranged_outside_melee and ranged_ids.size() > 0:
		var far_from_melee: bool = true
		if _owner_body != null and is_instance_valid(_owner_body):
			var d2: float = (enemy.global_position - _owner_body.global_position).length_squared()
			var melee_r: float = default_melee_range_px
			if d2 <= (melee_r * melee_r):
				far_from_melee = false
		if far_from_melee:
			var j: int = 0
			while j < ranged_ids.size():
				var rid: String = ranged_ids[j]
				if _can_cast(rid):
					return {"ability_id": rid, "context": {"target": enemy, "aim_dir": _aim_towards(enemy)}}
				j += 1

	# 3B) Melee if close (or if pursuing melee) – now per-ability range
	if pursue_melee and enemy != null and is_instance_valid(enemy) and melee_ids.size() > 0:
		var any_close: bool = false
		var m: int = 0
		while m < melee_ids.size():
			var mid: String = melee_ids[m]
			var range_px: float = _melee_range_for(mid)
			if _in_melee_range(enemy, range_px):
				any_close = true
				if _can_cast(mid):
					return {"ability_id": mid, "context": {"target": enemy, "aim_dir": _aim_towards(enemy)}}
			m += 1
		if not any_close:
			_try_gap_close_for_melee_attack()

		# 4) Any remaining enemy damage (ranged)
	if enemy != null and is_instance_valid(enemy) and ranged_ids.size() > 0:
		var k: int = 0
		while k < ranged_ids.size():
			var rd: String = ranged_ids[k]
			if _can_cast(rd):
				return {"ability_id": rd, "context": {"target": enemy, "aim_dir": _aim_towards(enemy)}}
			k += 1

	# 5) As a last resort, try fallback attack — BUT:
	#    - Only use it for kits that do NOT already have a MELEE ability.
	#    - If the fallback itself is MELEE, still respect melee range.
	if enemy != null and is_instance_valid(enemy) and fallback_attack_id != "":
		var fb_type: String = _ability_type_for(fallback_attack_id)

		# If we *already* have explicit MELEE abilities, do NOT spam the fallback.
		if fb_type == "MELEE":
			if melee_ids.size() == 0:
				var fb_range: float = _melee_range_for(fallback_attack_id)
				if _in_melee_range(enemy, fb_range) and _can_cast(fallback_attack_id):
					return {
						"ability_id": fallback_attack_id,
						"context": {"target": enemy, "aim_dir": _aim_towards(enemy)}
					}
		else:
			# Non-melee fallback (e.g., simple projectile) can still be used when there’s no
			# better ranged option, without extra range gating here.
			if ranged_ids.size() == 0 and _can_cast(fallback_attack_id):
				return {
					"ability_id": fallback_attack_id,
					"context": {"target": enemy, "aim_dir": _aim_towards(enemy)}
				}

	return {}


# ---------------- Ability typing & utils (like Companion) ---------------- #

func _ability_type_for(ability_id: String) -> String:
	if ability_id == "":
		return ""
	if _type_cache.has(ability_id):
		return String(_type_cache[ability_id])

	var asys: Node = _ability_system()
	var t: String = ""
	if asys != null:
		# Companion uses AbilitySystem’s internal resolver to read AbilityDef. Do the same.
		if asys.has_method("_resolve_ability_def"):
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

func _melee_range_for(ability_id: String) -> float:
	if ability_id == "":
		return default_melee_range_px
	var asys: Node = _ability_system()
	if asys != null and asys.has_method("_resolve_ability_def"):
		var def_any: Variant = asys.call("_resolve_ability_def", ability_id)
		if def_any is Resource:
			var r: Resource = def_any
			if "melee_range_px" in r:
				var v: Variant = r.get("melee_range_px")
				if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
					var f: float = float(v)
					if f > 0.0:
						return f
	return default_melee_range_px

func _can_cast(ability_id: String) -> bool:
	var asys: Node = _ability_system()
	if asys == null:
		return false
	if asys.has_method("can_cast"):
		var ok_any: Variant = asys.call("can_cast", _owner_body, ability_id)
		if typeof(ok_any) == TYPE_BOOL:
			return bool(ok_any)
	return true

func _is_melee_like(ability_id: String) -> bool:
	return _ability_type_for(ability_id) == "MELEE" or ability_id == "attack"

# ---------------- Motion helpers --------------------------- #

func _halt_motion() -> void:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return
	if _owner_body.has_method("set_move_dir"):
		_owner_body.call("set_move_dir", Vector2.ZERO)
	if _owner_body is CharacterBody2D:
		var cb: CharacterBody2D = _owner_body as CharacterBody2D
		cb.velocity = Vector2.ZERO

func _try_gap_close_for_melee_attack() -> void:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return
	var enemy: Node2D = _current_enemy_target()
	if enemy == null or not is_instance_valid(enemy):
		return
	_close_gap_towards(enemy)

# ---------------- KnownAbilities (mirrors Companion) -------- #

func _resolve_known_abilities() -> Node:
	if _actor_root == null or not is_instance_valid(_actor_root):
		return null
	var cand: Node = _actor_root.get_node_or_null("KnownAbilities")
	if cand != null:
		return cand
	cand = _actor_root.get_node_or_null("KnownAbilitiesComponent")
	if cand != null:
		return cand
	cand = _actor_root.get_node_or_null("KnownAbilitiesCmponent") # legacy typo support
	if cand != null:
		return cand

	# Deep capability search
	var q: Array = [_actor_root]
	while not q.is_empty():
		var cur: Node = q.pop_front()
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
		if not _kac.is_connected("abilities_changed", Callable(self, "_on_kac_abilities_changed")):
			_kac.connect("abilities_changed", Callable(self, "_on_kac_abilities_changed"))

func _on_kac_abilities_changed(current: PackedStringArray) -> void:
	_known_ids = current.duplicate()
	# Clear cached types for removed ids
	var keys: Array = _type_cache.keys()
	var idx: int = 0
	while idx < keys.size():
		var key: Variant = keys[idx]
		if key is String:
			var sid: String = key
			if not _known_ids.has(sid):
				_type_cache.erase(sid)
		idx += 1
	if debug_enemy_ai:
		print_rich("[EAI] abilities_changed -> ", _known_ids)

func _sync_known_abilities_from_component() -> void:
	if _kac != null and is_instance_valid(_kac):
		if "known_abilities" in _kac:
			var any_arr: Variant = _kac.get("known_abilities")
			if typeof(any_arr) == TYPE_PACKED_STRING_ARRAY:
				_known_ids = (any_arr as PackedStringArray).duplicate()

# ---------------- Allies / Enemies / Targets ---------------- #

func _find_lowest_hp_ally(threshold_ratio: float) -> Node2D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var best: Node2D = null
	var best_ratio: float = threshold_ratio
	var i: int = 0
	while i < ally_groups.size():
		var g: String = ally_groups[i]
		var nodes: Array = tree.get_nodes_in_group(g)
		var j: int = 0
		while j < nodes.size():
			var n: Node = nodes[j]
			if n is Node2D and is_instance_valid(n) and not _target_is_dead(n as Node2D):
				var n2d: Node2D = n as Node2D
				# ensure this "ally" is not flagged as an enemy too
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
				if _target_is_dead(n2d):
					return n2d
			j += 1
		i += 1
	return null

func _current_enemy_target() -> Node2D:
	return _pick_enemy_target(max_target_radius_px)

func _pick_enemy_target(max_radius_px: float) -> Node2D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var me: Node2D = _owner_body
	if me == null or not is_instance_valid(me):
		return null
	var best: Node2D = null
	var best_d2: float = max_radius_px * max_radius_px
	var i: int = 0
	while i < enemy_groups.size():
		var g: String = enemy_groups[i]
		var nodes: Array = tree.get_nodes_in_group(g)
		var j: int = 0
		while j < nodes.size():
			var n: Node = nodes[j]
			if n is Node2D and is_instance_valid(n):
				var n2d: Node2D = n as Node2D
				# require damage-addressable and alive, and not an ally
				if _node_in_any_group(n2d, ally_groups):
					j += 1
					continue
				if not _is_damage_addressable(n2d):
					j += 1
					continue
				if _target_is_dead(n2d):
					j += 1
					continue
				var d2: float = (n2d.global_position - me.global_position).length_squared()
				if d2 < best_d2:
					best_d2 = d2
					best = n2d
			j += 1
		i += 1
	return best

# ---------------- Common helpers (mirrors Companion) ---------------- #

func _resolve_actor_root() -> Node2D:
	if owner is Node2D:
		return owner as Node2D
	if self.get_parent() is Node2D:
		return self.get_parent() as Node2D
	return null

func _ability_system() -> Node:
	# Mirror CompanionAbilityAI: try AbilitySys, then AbilitySystem
	var root: Viewport = get_tree().root
	if root == null:
		return null
	var n: Node = root.get_node_or_null("AbilitySys")
	if n != null:
		return n
	return root.get_node_or_null("AbilitySystem")

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

func _movement_blocked() -> bool:
	if _owner_body == null or not is_instance_valid(_owner_body):
		return true

	# Respect the owner’s action lock so we do not attempt ability casts
	# while the base enemy attack / cast animation is still in progress.
	if _owner_body.has_method("is_action_locked"):
		var locked_any: Variant = _owner_body.call("is_action_locked")
		if typeof(locked_any) == TYPE_BOOL:
			if bool(locked_any):
				return true

	return false

func _in_melee_range(targ: Node2D, range_px: float) -> bool:
	if _owner_body == null or not is_instance_valid(_owner_body) or targ == null or not is_instance_valid(targ):
		return false
	var d2: float = (targ.global_position - _owner_body.global_position).length_squared()
	return d2 <= (range_px * range_px)

func _close_gap_towards(targ: Node2D) -> void:
	if _owner_body == null or not is_instance_valid(_owner_body) or targ == null or not is_instance_valid(targ):
		return
	if _owner_body.has_method("set_move_dir"):
		var dir: Vector2 = _aim_towards(targ)
		_owner_body.call("set_move_dir", dir)

# ---------- DEAD / HP helpers (UPDATED to honor StatusConditions) ---------- #

func _target_is_dead(n: Node2D) -> bool:
	var root: Node = n
	if root == null or not is_instance_valid(root):
		return true

	# 1) StatusConditions (canonical), deep search first
	var sc: Node = null
	if root.has_node("StatusConditions"):
		sc = root.get_node("StatusConditions")
	else:
		sc = root.find_child("StatusConditions", true, false)
		if sc == null:
			# Some actors might name it "Status"
			sc = root.find_child("Status", true, false)

	if sc != null and sc.has_method("is_dead"):
		var sv: Variant = sc.call("is_dead")
		if typeof(sv) == TYPE_BOOL and bool(sv):
			return true

	# 2) Stats-based HP check (fallback – also deep)
	var stats: Node = root.get_node_or_null("StatsComponent")
	if stats == null:
		stats = root.find_child("StatsComponent", true, false)
	if stats != null:
		if "current_hp" in stats:
			var ch: Variant = stats.get("current_hp")
			if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
				return true
		if stats.has_method("get_hp"):
			var gh: Variant = stats.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true

	# 3) Direct method on the actor (if exposed)
	if root.has_method("is_dead"):
		var dv: Variant = root.call("is_dead")
		if typeof(dv) == TYPE_BOOL and bool(dv):
			return true

	# 4) Legacy “dead” property on the root node
	if "dead" in root:
		var df: Variant = root.get("dead")
		if typeof(df) == TYPE_BOOL and bool(df):
			return true

	return false

func _hp_ratio_for(n: Node2D) -> float:
	var root: Node = n
	if root == null or not is_instance_valid(root):
		return 1.0
	var stats: Node = root.get_node_or_null("StatsComponent")
	if stats == null:
		stats = root.find_child("StatsComponent", true, false)
	if stats != null:
		var ch: float = 0.0
		var mh: float = 0.0
		if "current_hp" in stats:
			var v1: Variant = stats.get("current_hp")
			if typeof(v1) == TYPE_FLOAT or typeof(v1) == TYPE_INT:
				ch = float(v1)
		if "max_hp" in stats:
			var v2: Variant = stats.get("max_hp")
			if typeof(v2) == TYPE_FLOAT or typeof(v2) == TYPE_INT:
				mh = float(v2)
		if mh > 0.0:
			return ch / mh
	return 1.0

func _node_in_any_group(n: Node2D, groups: PackedStringArray) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	var i: int = 0
	while i < groups.size():
		if n.is_in_group(groups[i]):
			return true
		i += 1
	return false

func _is_dead() -> bool:
	var root: Node2D = _actor_root
	if root == null or not is_instance_valid(root):
		return true
	# Reuse the same logic we use for targets – StatusConditions first
	return _target_is_dead(root)

# ---------- NEW: Damage-addressable checks (skip ghosts/stat-less) ---------- #

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var sc: Node = null
	if root.has_node("StatsComponent"):
		sc = root.get_node("StatsComponent")
	else:
		sc = root.find_child("StatsComponent", true, false)
	if sc != null:
		return sc
	if root.has_method("apply_damage_packet"):
		return root
	return null

func _is_damage_addressable(n: Node2D) -> bool:
	var r: Node = n
	if r == null or not is_instance_valid(r):
		return false
	var st: Node = _find_stats_component(r)
	if st == null:
		return false
	return true
