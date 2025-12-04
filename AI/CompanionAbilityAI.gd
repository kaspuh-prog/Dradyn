extends Node
class_name CompanionAbilityAI

@export var think_hz: float = 6.0
@export var min_retry_ms: int = 150

# Kept for scene compatibility; no hardcoded fallback anymore.
@export var fallback_attack_id: String = "attack"
@export var use_gcd_for_fallback_attack: bool = false

@export var default_melee_range_px: float = 56.0
@export var default_arc_deg: float = 70.0

@export var enemy_groups: PackedStringArray = ["Enemies", "Enemy"]
@export var ally_groups: PackedStringArray = ["PartyMembers"]

@export var debug_companion_ai: bool = false

# Decision tuning
@export var heal_threshold_ratio: float = 0.55
@export var pursue_melee: bool = true
@export var max_target_radius_px: float = 220.0
@export var prefer_ranged_outside_melee: bool = true

var _owner_body: Node2D = null
var _actor_root: Node2D = null
var _think_accum: float = 0.0
var _last_attempt_msec: int = 0
var _active: bool = true

# Movement suppression cache
var _cf_node: Node = null

# Known Abilities component (may spawn later)
var _kac: Node = null
var _known_ids: PackedStringArray = []

# Ability type cache: ability_id -> String ("MELEE", "PROJECTILE", ...)
var _type_cache: Dictionary = {}

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
		var who: String = "null"
		if _actor_root != null and is_instance_valid(_actor_root):
			who = _actor_root.name
		print_rich("[CAI] set_active(", active, ") for ", who)

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
				print_rich("[CAI] Found KnownAbilities component late and connected.")

	if _is_dead():
		_halt_motion()
		return

	var now: int = Time.get_ticks_msec()
	if now - _last_attempt_msec < min_retry_ms:
		return
	_last_attempt_msec = now

	var choice: Dictionary = _choose_best_ability()
	if choice.is_empty():
		_try_gap_close_for_melee_attack()
		return

	var ability_id: String = String(choice.get("ability_id", ""))
	var ctx: Dictionary = choice.get("context", {})
	if ability_id == "":
		_try_gap_close_for_melee_attack()
		return

	if not ctx.has("aim_dir"):
		ctx["aim_dir"] = _aim_towards_target_in_ctx(ctx)

	if _is_dead():
		_halt_motion()
		return

	var asys: Node = _ability_system()
	if asys == null:
		return

	var ok_any: Variant = asys.call("request_cast", _owner_body, ability_id, ctx)
	var ok: bool = (typeof(ok_any) == TYPE_BOOL and bool(ok_any))

	if debug_companion_ai:
		var tn: String = ""
		if ctx.has("target"):
			var t: Node = ctx["target"] as Node
			if t != null and is_instance_valid(t):
				tn = t.name
		var who: String = "null"
		if _actor_root != null and is_instance_valid(_actor_root):
			who = _actor_root.name
		print_rich("[CAI] cast user=", who, " ability=", ability_id, " ok=", ok, " target=", tn, " ctx=", ctx, " known=", _known_ids)

	if ok:
		_halt_motion()
	else:
		if _is_melee_like(ability_id):
			_try_gap_close_for_melee_attack()

# ------------------------------------------------------------------ #
# Ability selection via AbilityDef.ability_type
# Priority: REVIVE → HEAL/HOT/CURE → RANGED(DAMAGE/PROJECTILE/DOT/DEBUFF) if far → MELEE(attack/other) → remaining ranged
# ------------------------------------------------------------------ #
func _choose_best_ability() -> Dictionary:
	_sync_known_abilities_from_component()

	if _known_ids.is_empty() and debug_companion_ai:
		print_rich("[CAI] No known abilities yet (waiting for purchases/hotbar).")

	# Situation reads
	var lowest_ally: Node2D = _find_lowest_hp_ally(heal_threshold_ratio)
	var dead_ally: Node2D = _find_dead_ally()
	var enemy: Node2D = _current_enemy_target()
	if enemy == null or not is_instance_valid(enemy):
		enemy = _pick_enemy_target(max_target_radius_px)

	# Bucket known abilities by type
	var revive_ids: Array[String] = []
	var heal_ids: Array[String] = []
	var melee_ids: Array[String] = []
	var ranged_ids: Array[String] = []
	var other_enemy_damage_ids: Array[String] = []
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

	# 2) HEAL/HOT/CURE (only if ally truly below threshold)
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
			far_from_melee = d2 > (melee_r * melee_r)
		if far_from_melee:
			var j: int = 0
			while j < ranged_ids.size():
				var rid: String = ranged_ids[j]
				if _can_cast(rid):
					return {"ability_id": rid, "context": {"target": enemy, "aim_dir": _aim_towards(enemy)}}
				j += 1

	# 3B) MELEE “attack” (or any melee) if unlocked
	if enemy != null and is_instance_valid(enemy) and melee_ids.size() > 0:
		var mid: String = _prefer_attack_id(melee_ids)
		if _can_cast(mid):
			return {
				"ability_id": mid,
				"context": {
					"target": enemy,
					"aim_dir": _aim_towards(enemy),
					"range": default_melee_range_px,
					"arc_deg": default_arc_deg,
					"prefer": "target"
				}
			}

	# 4) Any remaining enemy damage (ranged) if close or melee not available
	if enemy != null and is_instance_valid(enemy) and ranged_ids.size() > 0:
		var k: int = 0
		while k < ranged_ids.size():
			var rd: String = ranged_ids[k]
			if _can_cast(rd):
				return {"ability_id": rd, "context": {"target": enemy, "aim_dir": _aim_towards(enemy)}}
			k += 1

	return {}

# ---------------- Ability typing & utils -------------------- #
func _ability_type_for(ability_id: String) -> String:
	if ability_id == "":
		return ""
	if _type_cache.has(ability_id):
		return String(_type_cache[ability_id])

	var asys: Node = _ability_system()
	var t: String = ""
	if asys != null:
		# Preferred public helpers if you add them later; otherwise fall back to def.
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
	if not pursue_melee:
		return
	# only chase if we actually have a melee ability
	var has_melee: bool = false
	var i: int = 0
	while i < _known_ids.size():
		if _ability_type_for(_known_ids[i]) == "MELEE":
			has_melee = true
			break
		i += 1
	if not has_melee:
		return

	var targ: Node2D = _current_enemy_target()
	if targ == null or not is_instance_valid(targ):
		targ = _pick_enemy_target(max_target_radius_px)
		if targ == null or not is_instance_valid(targ):
			if debug_companion_ai:
				print_rich("[CAI] No enemy target to pursue.")
			return
	if not _in_melee_range(targ, default_melee_range_px):
		if _movement_blocked():
			if debug_companion_ai:
				print_rich("[CAI] Movement blocked; cannot pursue melee.")
			_halt_motion()
			return
		_close_gap_towards(targ)

# ---------------- KnownAbilities integration ---------------- #
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
	if debug_companion_ai:
		print_rich("[CAI] abilities_changed -> ", _known_ids)
	# clear cached types for removed ids
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

# ---------------- Allies / Enemies / Targets ---------------- #
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

	# READ PROPERTY first (StatsComponent exposes current_hp as a property)
	if "current_hp" in stats:
		var chv: Variant = stats.get("current_hp")
		if typeof(chv) == TYPE_INT or typeof(chv) == TYPE_FLOAT:
			cur = float(chv)

	# If a method exists (older scripts), allow it too.
	if cur <= 0.0 and stats.has_method("get_hp"):
		var gh: Variant = stats.call("get_hp")
		if typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT:
			cur = float(gh)

	# max_hp is a method in your StatsComponent
	if stats.has_method("max_hp"):
		var mh: Variant = stats.call("max_hp")
		if typeof(mh) == TYPE_INT or typeof(mh) == TYPE_FLOAT:
			maxv = max(1.0, float(mh))

	if maxv <= 0.0:
		maxv = 1.0
	return clamp(cur / maxv, 0.0, 1.0)

func _current_enemy_target() -> Node2D:
	var ts: Node = _targeting_system()
	if ts != null and ts.has_method("current_enemy_target"):
		var v: Variant = ts.call("current_enemy_target")
		var t: Node2D = v as Node2D
		if t != null and is_instance_valid(t):
			return t
	return null

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

# ---------------- Utility / Integration -------------------- #
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
	return d <= (range_px - 2.0)

func _close_gap_towards(targ: Node2D) -> void:
	if _owner_body == null or targ == null:
		return
	if _movement_blocked():
		if debug_companion_ai:
			print_rich("[CAI] _close_gap_towards blocked.")
		_halt_motion()
		return
	if _owner_body.has_method("set_move_dir"):
		var dir: Vector2 = (targ.global_position - _owner_body.global_position).normalized()
		_owner_body.call("set_move_dir", dir)

func _target_is_dead(n: Node2D) -> bool:
	if n == null or not is_instance_valid(n):
		return true

	# 1) Direct method on the node (actors that expose is_dead())
	if n.has_method("is_dead"):
		var dead_direct_raw: Variant = n.call("is_dead")
		if typeof(dead_direct_raw) == TYPE_BOOL and bool(dead_direct_raw):
			return true

	# 2) StatusConditions child (canonical “dead” flag)
	var sc: Node = n.get_node_or_null("StatusConditions")
	if sc != null and sc.has_method("is_dead"):
		var sv: Variant = sc.call("is_dead")
		if typeof(sv) == TYPE_BOOL and bool(sv):
			return true

	# 3) Stats-based HP check as a fallback
	var stats: Node = n.find_child("StatsComponent", true, false)
	if stats != null:
		# Prefer property
		if "current_hp" in stats:
			var hp_raw: Variant = stats.get("current_hp")
			if (typeof(hp_raw) == TYPE_INT or typeof(hp_raw) == TYPE_FLOAT) and float(hp_raw) <= 0.0:
				return true
		# Legacy method fallback
		if stats.has_method("get_hp"):
			var gh: Variant = stats.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true

	# 4) Legacy “dead” property on the node itself
	if "dead" in n:
		var dead_raw: Variant = n.get("dead")
		if typeof(dead_raw) == TYPE_BOOL and bool(dead_raw):
			return true

	return false
	

# ============================ DEAD DETECTION ======================
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
		# Prefer property
		if "current_hp" in stats:
			var ch: Variant = stats.get("current_hp")
			if (typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT) and float(ch) <= 0.0:
				return true
		# Legacy method fallback
		if stats.has_method("get_hp"):
			var gh: Variant = stats.call("get_hp")
			if (typeof(gh) == TYPE_INT or typeof(gh) == TYPE_FLOAT) and float(gh) <= 0.0:
				return true

	return false
