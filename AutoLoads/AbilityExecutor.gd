extends Node
class_name AbilityExecutor
# Godot 4.5 — fully typed where practical, no ternaries.

# --- Autoloads ---
var TargetingSys: Node
var Party: Node
var VFXBridge: Node

# Preload formulas once
const DF: Script = preload("res://scripts/stats/DerivedFormulas.gd")

# --- Types ---
enum AbilityType {
	UNKNOWN,
	MELEE,
	PROJECTILE,
	DAMAGE_SPELL,
	DOT_SPELL,
	HOT_SPELL,
	HEAL_SPELL,
	CURE_SPELL,
	REVIVE_SPELL,
	BUFF,
	DEBUFF,
	SUMMON_SPELL,
	PASSIVE
}

# --- MELEE defaults ---
const DEF_MELEE_RANGE_PX: float = 28.0
const DEF_MELEE_ARC_DEG: float = 70.0
const DEF_MELEE_FORWARD_PX: float = 10.0
const DEF_MELEE_HIT_FRAME: int = 2
const DEF_MELEE_FALLBACK_FPS: float = 12.0
const DEF_MELEE_ANIM_PREFIX: String = "attack1"
const DEF_MELEE_SWING_THICKNESS_PX: float = 12.0
const DEF_MELEE_LOCK_MS: int = 400
const DEF_MELEE_VARIANCE_PCT: float = 0.10
const MELEE_DEBUG: bool = true
const STATUS_DEBUG: bool = true

var melee_default_range_px: float = DEF_MELEE_RANGE_PX
var melee_default_arc_deg: float = DEF_MELEE_ARC_DEG
var melee_forward_offset_px: float = DEF_MELEE_FORWARD_PX
var melee_default_hit_frame: int = DEF_MELEE_HIT_FRAME
var melee_default_fallback_fps: float = DEF_MELEE_FALLBACK_FPS
var melee_anim_prefix: String = DEF_MELEE_ANIM_PREFIX
var melee_swing_thickness_px: float = DEF_MELEE_SWING_THICKNESS_PX
var melee_lock_ms: int = DEF_MELEE_LOCK_MS
var melee_variance_pct: float = DEF_MELEE_VARIANCE_PCT


func _ready() -> void:
	TargetingSys = get_node_or_null("/root/TargetingSys")
	Party = get_node_or_null("/root/Party")
	VFXBridge = get_node_or_null("/root/VFXBridge")

# ============================================================================ #
# Public entry
# ============================================================================ #
func execute(user: Node, def: Resource, ctx: Dictionary) -> bool:
	if user == null or not is_instance_valid(user):
		_log_fail("no_user", "", "")
		return false
	if def == null:
		_log_fail("no_def", "", "")
		return false

	var ability_id: String = _get_string(def, "ability_id")
	var display_name: String = _get_string(def, "display_name")
	var cast_anim_str: String = _get_string(def, "cast_anim")
	var cast_anim: StringName = StringName(cast_anim_str)
	var vfx_hint: StringName = StringName(_get_string(def, "vfx_hint"))
	var sfx_event: StringName = StringName(_get_string(def, "sfx_event"))
	var mp_cost: float = _get_float(def, "mp_cost")
	var end_cost: float = _get_float(def, "end_cost")
	var ability_type_name: String = _get_string(def, "ability_type")
	var requires_target: bool = _get_bool(def, "requires_target")
	var target_rule: StringName = StringName(_get_string(def, "target_rule"))
	var ability_type: int = _coerce_ability_type(ability_type_name)

	# Targets
	var targets: Array = []
	if requires_target:
		targets = _resolve_targets(user, target_rule, ctx)
	else:
		targets = _resolve_self_or_context(user, target_rule, ctx)

	# Filter out dead / alive based on ability type
	targets = _filter_targets_for_ability(targets, ability_type)

	# If we require a target and none survive filtering, bail.
	if targets.is_empty() and requires_target:
		_log_fail("no_targets", ability_id, display_name, {"rule": String(target_rule)})
		return false

	# Safety for revive: there must be at least one dead target left
	if ability_type == AbilityType.REVIVE_SPELL:
		var dead_ok: bool = false
		var i0: int = 0
		while i0 < targets.size():
			var st0: Node = _find_status_component(targets[i0])
			if _is_dead(st0):
				dead_ok = true
				break
			i0 += 1
		if not dead_ok:
			_log_fail("revive_no_dead_target", ability_id, display_name)
			return false

	# Costs
	if not _try_consume_mp(user, mp_cost):
		_log_fail("mp_fail", ability_id, display_name)
		return false
	if not _try_consume_end(user, end_cost):
		_log_fail("end_fail", ability_id, display_name)
		return false

	# Context for VFX (target-side only)
	var vis_ctx: Dictionary = _vfx_ctx(def, ctx)

	# Caster cues
	_play_cast_anim(user, cast_anim)

	# If sfx_cues exist, they take over SFX authoring for this ability.
	# (Author frame=0 cues for cast-start sounds.)
	var has_sfx_cues: bool = _has_sfx_cues(def)
	if has_sfx_cues:
		_emit_sfx_cues_at_frame(def, user, 0)
	else:
		_emit_sfx(sfx_event, user)

	if ability_type != AbilityType.MELEE:
		_maybe_play_bridge_lock_from_cast(user, cast_anim_str, ctx)

	# Dispatch
	var ok: bool = false
	match ability_type:
		AbilityType.MELEE:
			ok = _do_melee(user, def, ctx, cast_anim_str, vfx_hint, vis_ctx)
		AbilityType.PROJECTILE:
			ok = _do_projectile(user, def, ctx, vis_ctx, targets)
		AbilityType.DAMAGE_SPELL:
			ok = _do_damage_spell(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.DOT_SPELL:
			ok = _do_dot_spell(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.HOT_SPELL:
			ok = _do_hot_spell(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.HEAL_SPELL:
			ok = _do_heal_spell(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.CURE_SPELL:
			ok = _do_cure_spell(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.REVIVE_SPELL:
			ok = _do_revive_spell(user, def, ctx, targets, ability_id, vfx_hint, vis_ctx)
		AbilityType.BUFF:
			ok = _do_buff(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.DEBUFF:
			ok = _do_debuff(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.SUMMON_SPELL:
			ok = _do_summon(user, def, ctx, targets, vfx_hint, vis_ctx)
		AbilityType.PASSIVE:
			ok = _do_passive(user, def, ctx)
		_:
			_log_fail("unknown_type", ability_id, display_name, {"type": ability_type_name})
			ok = false

	if not ok:
		_log_fail("type_handler_false", ability_id, display_name, {"type": ability_type_name})
	return ok

# ============================================================================ #
# KNOCKBACK (AbilityDef-driven, opt-in)
# ============================================================================ #
func _kb_speed(def: Resource) -> float:
	# Primary field
	var s: float = _get_float(def, "knockback_speed_px_s")
	if s > 0.0:
		return s
	# Optional legacy alias if you ever used it
	s = _get_float(def, "knockback_speed")
	if s > 0.0:
		return s
	return 0.0


func _kb_duration(def: Resource) -> float:
	var d: float = _get_float(def, "knockback_duration_s")
	if d > 0.0:
		return d
	# Optional legacy alias
	d = _get_float(def, "knockback_duration")
	if d > 0.0:
		return d
	return 0.0


func _kb_mode(def: Resource) -> String:
	var m: String = _get_string(def, "knockback_dir_mode")
	if m == "":
		return "AWAY_FROM_CASTER"
	return m.strip_edges().to_upper()


func _kb_origin_from_ctx(ctx: Dictionary, fallback: Vector2) -> Vector2:
	# Support several common keys without forcing any one convention.
	var keys: PackedStringArray = PackedStringArray([
		"impact_origin",
		"aoe_origin",
		"origin",
		"center",
		"blast_center"
	])
	var i: int = 0
	while i < keys.size():
		var k: String = keys[i]
		if ctx.has(k):
			var v: Variant = ctx[k]
			if typeof(v) == TYPE_VECTOR2:
				return v
		i += 1
	return fallback


func _find_knockback_receiver(target: Node) -> Node:
	if target == null:
		return null
	if not is_instance_valid(target):
		return null

	# Prefer the node itself
	if target.has_method("apply_knockback"):
		return target

	# Some targets might have the knockback API on their parent/root
	var p: Node = target.get_parent()
	if p != null and is_instance_valid(p) and p.has_method("apply_knockback"):
		return p

	return null


func _try_apply_knockback(user: Node, target: Node, def: Resource, ctx: Dictionary, aim_dir: Vector2) -> bool:
	if user == null or not is_instance_valid(user):
		return false
	if target == null or not is_instance_valid(target):
		return false
	if def == null:
		return false

	var speed: float = _kb_speed(def)
	var dur: float = _kb_duration(def)
	if speed <= 0.0 or dur <= 0.0:
		return false

	var recv: Node = _find_knockback_receiver(target)
	if recv == null:
		return false

	var user2d: Node2D = user as Node2D
	var tgt2d: Node2D = target as Node2D
	if user2d == null or tgt2d == null:
		return false

	var mode: String = _kb_mode(def)
	var dir: Vector2 = Vector2.ZERO

	if mode == "ALONG_AIM":
		if aim_dir != Vector2.ZERO:
			dir = aim_dir.normalized()
		else:
			# Fallback: if caller already put an impact_dir in ctx (eg projectile), use it.
			if ctx.has("impact_dir"):
				var v: Variant = ctx["impact_dir"]
				if typeof(v) == TYPE_VECTOR2:
					var d0: Vector2 = v
					if d0 != Vector2.ZERO:
						dir = d0.normalized()
		if dir == Vector2.ZERO:
			# Last fallback: away from caster
			dir = (tgt2d.global_position - user2d.global_position)

	elif mode == "FROM_POINT":
		var origin: Vector2 = _kb_origin_from_ctx(ctx, user2d.global_position)
		dir = (tgt2d.global_position - origin)

	else:
		# Default: AWAY_FROM_CASTER
		dir = (tgt2d.global_position - user2d.global_position)

	if dir.length_squared() <= 0.000001:
		return false

	dir = dir.normalized()
	recv.call("apply_knockback", dir, speed, dur)
	return true


func _attach_projectile_knockback_metadata(projectile_node: Node, user: Node, def: Resource, aim_dir: Vector2, ctx: Dictionary) -> void:
	# Projectiles own their own hit/damage logic; we just attach opt-in metadata.
	if projectile_node == null or not is_instance_valid(projectile_node):
		return
	if user == null or not is_instance_valid(user):
		return
	if def == null:
		return

	var speed: float = _kb_speed(def)
	var dur: float = _kb_duration(def)
	if speed <= 0.0 or dur <= 0.0:
		return

	var mode: String = _kb_mode(def)

	# If the projectile provides an explicit API, use it (safe no-op otherwise).
	if projectile_node.has_method("set_knockback"):
		projectile_node.call("set_knockback", speed, dur, mode)
		return

	# Or if it exposes properties, set them only if present.
	if "knockback_speed_px_s" in projectile_node:
		projectile_node.set("knockback_speed_px_s", speed)
	if "knockback_duration_s" in projectile_node:
		projectile_node.set("knockback_duration_s", dur)
	if "knockback_dir_mode" in projectile_node:
		projectile_node.set("knockback_dir_mode", mode)

	# Always provide a meta blob as a universal fallback.
	var meta: Dictionary = {
		"speed_px_s": speed,
		"duration_s": dur,
		"dir_mode": mode,
		"aim_dir": aim_dir,
		"source_node": user
	}
	projectile_node.set_meta("ability_knockback", meta)

# ============================================================================ #
# TYPE EXECUTION
# ============================================================================ #
func _do_projectile(user: Node, def: Resource, ctx: Dictionary, vis_ctx: Dictionary, _targets: Array) -> bool:
	var actor: Node2D = user as Node2D
	if actor == null:
		return false

	var aim_dir: Vector2 = _resolve_melee_aim(actor, ctx)
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2.DOWN
	else:
		aim_dir = aim_dir.normalized()

	var origin: Vector2 = _resolve_cast_origin(actor, def, ctx)
	var fwd_px: float = _def_or_default_f(def, "projectile_forward_offset_px", melee_forward_offset_px)
	var spawn_pos: Vector2 = origin + aim_dir * fwd_px

	var base_power: float = _get_float(def, "power")
	if base_power <= 0.0:
		base_power = _melee_attack_amount_from(_get_stats(actor))

	var proj_scene_any: Variant = null
	if def.has_method("get"):
		proj_scene_any = def.get("projectile_scene")
	if proj_scene_any == null or typeof(proj_scene_any) != TYPE_OBJECT:
		_log_fail("no_projectile_scene", _get_string(def, "ability_id"), _get_string(def, "display_name"))
		return false
	var proj_scene: PackedScene = proj_scene_any as PackedScene
	if proj_scene == null:
		_log_fail("bad_projectile_scene", _get_string(def, "ability_id"), _get_string(def, "display_name"))
		return false

	var projectile_node: Node = proj_scene.instantiate()
	if projectile_node == null:
		return false

	var parent_node: Node = actor.get_parent()
	if parent_node == null:
		parent_node = actor
	parent_node.add_child(projectile_node)

	var as_node2d: Node2D = projectile_node as Node2D
	if as_node2d != null:
		as_node2d.global_position = spawn_pos

	# Optional AbilityDef overrides (safe no-ops if missing)
	if def.has_method("get"):
		var mask_any: Variant = def.get("projectile_collision_mask")
		if typeof(mask_any) == TYPE_INT:
			if "collision_mask" in projectile_node:
				projectile_node.set("collision_mask", int(mask_any))
		var layer_any: Variant = def.get("projectile_collision_layer")
		if typeof(layer_any) == TYPE_INT:
			if "collision_layer" in projectile_node:
				projectile_node.set("collision_layer", int(layer_any))
		var groups_any: Variant = def.get("projectile_hit_groups")
		if typeof(groups_any) == TYPE_PACKED_STRING_ARRAY:
			if "hit_groups" in projectile_node:
				projectile_node.set("hit_groups", groups_any)
		var ignore_any: Variant = def.get("projectile_ignore_group")
		if typeof(ignore_any) == TYPE_STRING:
			if "ignore_group" in projectile_node:
				projectile_node.set("ignore_group", String(ignore_any))

	var ability_id: String = _get_string(def, "ability_id")
	if projectile_node.has_method("setup"):
		projectile_node.call("setup", user, ability_id, aim_dir, base_power)
	else:
		if projectile_node.has_method("set_direction"):
			projectile_node.call("set_direction", aim_dir)
		if as_node2d != null:
			as_node2d.rotation = atan2(aim_dir.y, aim_dir.x)
	if projectile_node.has_method("orient_from_dir"):
		projectile_node.call("orient_from_dir", aim_dir)

	# NEW: attach opt-in knockback metadata for projectile scripts to consume on hit.
	_attach_projectile_knockback_metadata(projectile_node, user, def, aim_dir, ctx)

	var impact_hint: StringName = StringName(_get_string(def, "vfx_hint"))
	var impact_ctx: Dictionary = ctx.duplicate()
	impact_ctx.merge(vis_ctx)
	impact_ctx["impact_dir"] = aim_dir

	if projectile_node.has_signal("hit"):
		var c: Callable = Callable(self, "_on_projectile_hit").bind(impact_hint, impact_ctx)
		if not projectile_node.is_connected("hit", c):
			projectile_node.connect("hit", c)

	return true


func _do_damage_spell(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var base_power: float = _get_float(def, "power")
	var any: bool = false
	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		_apply_damage(user, t, base_power, def, ctx)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)

		# NEW: opt-in knockback (ability-data driven)
		_try_apply_knockback(user, t, def, ctx, Vector2.ZERO)

		any = true
	return any


func _do_dot_spell(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var duration: float = _get_float(def, "duration_sec")
	var interval: float = _get_float(def, "tick_interval_sec")
	if duration <= 0.0 or interval <= 0.0:
		return _dot_tick_once(user, def, ctx, targets, vfx_hint, vis_ctx)
	var total_ticks: int = int(floor(duration / interval))
	if total_ticks < 1:
		total_ticks = 1

	_schedule_periodic_ticks(targets, interval, total_ticks, func(t: Node) -> void:
		if t == null:
			return
		if not is_instance_valid(t):
			return
		if _is_effect_target_dead(t):
			return
		var amt: float = _get_float(def, "power")
		_apply_damage(user, t, amt, def, ctx)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
	)
	return true


func _dot_tick_once(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var any: bool = false
	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		_apply_damage(user, t, _get_float(def, "power"), def, ctx)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
		any = true
	return any


func _do_hot_spell(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var duration: float = _get_float(def, "duration_sec")
	var interval: float = _get_float(def, "tick_interval_sec")

	# Ability metadata for HOT_SPELL threat
	var ability_id: String = _get_string(def, "ability_id")
	var ability_type_name: String = _get_string(def, "ability_type")
	if ability_type_name == "":
		ability_type_name = "HOT_SPELL"

	if duration <= 0.0 or interval <= 0.0:
		return _hot_tick_once(user, def, ctx, targets, vfx_hint, vis_ctx, ability_id, ability_type_name)
	var total_ticks: int = int(floor(duration / interval))
	if total_ticks < 1:
		total_ticks = 1

	_schedule_periodic_ticks(targets, interval, total_ticks, func(t: Node) -> void:
		if t == null:
			return
		if not is_instance_valid(t):
			return
		if _is_effect_target_dead(t):
			return
		var amt: float = _resolve_heal_amount(user, t, def)
		_apply_heal(user, t, amt, def, ctx, ability_id, ability_type_name)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
	)
	return true


func _hot_tick_once(
	user: Node,
	def: Resource,
	ctx: Dictionary,
	targets: Array,
	vfx_hint: StringName,
	vis_ctx: Dictionary,
	ability_id: String,
	ability_type_name: String
) -> bool:
	var any: bool = false
	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		var amt: float = _resolve_heal_amount(user, t, def)
		_apply_heal(user, t, amt, def, ctx, ability_id, ability_type_name)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
		any = true
	return any


func _do_heal_spell(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var healed: bool = false

	# Ability metadata for HEAL_SPELL threat
	var ability_id: String = _get_string(def, "ability_id")
	var ability_type_name: String = _get_string(def, "ability_type")
	if ability_type_name == "":
		ability_type_name = "HEAL_SPELL"

	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		var amount: float = _resolve_heal_amount(user, t, def)
		_apply_heal(user, t, amount, def, ctx, ability_id, ability_type_name)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
		healed = true
	return healed


func _do_cure_spell(_user: Node, def: Resource, _ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var cured_any: bool = false
	var status_ids: PackedStringArray = PackedStringArray()
	var src_ids: PackedStringArray = PackedStringArray()
	var stack_keys: PackedStringArray = PackedStringArray()

	if def.has_method("get"):
		var sids: Variant = def.get("cure_status_ids")
		if typeof(sids) == TYPE_PACKED_STRING_ARRAY:
			status_ids = sids
		var srcs: Variant = def.get("cure_modifier_sources")
		if typeof(srcs) == TYPE_PACKED_STRING_ARRAY:
			src_ids = srcs
		var skeys: Variant = def.get("cure_stacking_keys")
		if typeof(skeys) == TYPE_PACKED_STRING_ARRAY:
			stack_keys = skeys

	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue

		var did: bool = false

		var sc: Node = _find_status_component(t)
		if sc != null:
			var j: int = 0
			while j < status_ids.size():
				var sid: String = status_ids[j]
				if sid != "":
					if sc.has_method("remove"):
						sc.call("remove", StringName(sid))
						did = true
				j += 1

		var stats: Node = _get_stats(t)
		if stats != null:
			var k: int = 0
			while k < src_ids.size():
				var src: String = src_ids[k]
				if src != "" and stats.has_method("remove_modifiers_by_source"):
					stats.call("remove_modifiers_by_source", src)
					did = true
				k += 1
			var m: int = 0
			while m < stack_keys.size():
				var sk: String = stack_keys[m]
				if sk != "" and stats.has_method("remove_modifiers_by_key"):
					stats.call("remove_modifiers_by_key", StringName(sk))
					did = true
				m += 1

		if did:
			cured_any = true
			if vfx_hint != StringName(""):
				_emit_target_vfx(t, vfx_hint, vis_ctx)

	return cured_any


func _do_revive_spell(user: Node, def: Resource, ctx: Dictionary, targets: Array, ability_id: String, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var target: Node = null
	var status: Node = null
	var i: int = 0
	while i < targets.size():
		var st: Node = _find_status_component(targets[i])
		if _is_dead(st):
			target = targets[i]
			status = st
			break
		i += 1
	if target == null or status == null:
		_log_fail("revive_no_dead_target_late", ability_id, _get_string(def, "display_name"))
		return false

	var stats: Node = _get_stats(target)
	if stats == null:
		_log_fail("revive_no_stats", ability_id, _get_string(def, "display_name"))
		return false

	var fixed_hp: int = _def_or_default_i(def, "revive_fixed_hp", 0)
	var use_heal_formula: bool = _get_bool(def, "revive_use_heal_formula")
	var pct_max: float = _get_float(def, "revive_percent_max_hp")
	var cap_max: int = _def_or_default_i(def, "revive_max_hp", 0)
	var invuln_secs: float = _get_float(def, "revive_invuln_seconds")
	if invuln_secs <= 0.0:
		invuln_secs = 2.0

	var restore_amt: int = 0
	if fixed_hp > 0:
		restore_amt = fixed_hp
	else:
		if use_heal_formula:
			var caster_stats: Node = _get_stats(user)
			if DF != null:
				var df: Object = DF.new()
				if df != null and df.has_method("calc_heal"):
					var v: Variant = df.call("calc_heal", caster_stats, _get_float(def, "power"), _get_string(def, "scale_stat"), false)
					if typeof(v) == TYPE_INT:
						restore_amt = int(v)
					elif typeof(v) == TYPE_FLOAT:
						restore_amt = int(round(float(v)))
		if restore_amt <= 0 and pct_max > 0.0:
			var max_hp_val: float = 0.0
			if stats.has_method("max_hp"):
				var mh: Variant = stats.call("max_hp")
				if typeof(mh) == TYPE_FLOAT or typeof(mh) == TYPE_INT:
					max_hp_val = float(mh)
			restore_amt = int(round(max_hp_val * pct_max))

	if cap_max > 0 and restore_amt > cap_max:
		restore_amt = cap_max
	if restore_amt < 1:
		restore_amt = 1

	if status.has_method("clear_dead_with_invuln"):
		status.call("clear_dead_with_invuln", invuln_secs, null, {})
	elif status.has_method("clear_dead"):
		status.call("clear_dead")

	var restored: int = 0
	var revive_type_name: String = _get_string(def, "ability_type")
	if revive_type_name == "":
		revive_type_name = "REVIVE_SPELL"

	if stats.has_method("apply_heal"):
		var healed_any: Variant = stats.call(
			"apply_heal",
			float(restore_amt),
			_ability_source_string(def, ctx),
			false,
			user,
			ability_id,
			revive_type_name
		)
		if typeof(healed_any) == TYPE_INT:
			restored = int(healed_any)
	if restored <= 0 and stats.has_method("change_hp"):
		var before: int = 0
		if "current_hp" in stats:
			var ch: Variant = stats.get("current_hp")
			if typeof(ch) == TYPE_INT or typeof(ch) == TYPE_FLOAT:
				before = int(ch)
		stats.call("change_hp", float(restore_amt))
		var after: int = before
		if "current_hp" in stats:
			var ch2: Variant = stats.get("current_hp")
			if typeof(ch2) == TYPE_INT or typeof(ch2) == TYPE_FLOAT:
				after = int(ch2)
		restored = max(0, after - before)

	if restored > 0:
		if vfx_hint != StringName(""):
			_emit_target_vfx(target, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, target)
		return true

	_log_fail("revive_restore_failed", ability_id, _get_string(def, "display_name"))
	return false


func _do_buff(_user: Node, def: Resource, _ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var mods: Array = []
	if def.has_method("get"):
		var any: Variant = def.get("buff_mods")
		if typeof(any) == TYPE_ARRAY:
			mods = any
	# If there are no StatModifier-based buff mods, fall back to status application only.
	if mods.is_empty():
		return _maybe_apply_statuses_multi(_user, def, targets, vfx_hint, vis_ctx)

	# This source_id is already used for the modifiers we add.
	var src_default: String = "ability:" + _get_string(def, "ability_id")
	var applied_any: bool = false

	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue

		var stats: Node = _get_stats(t)
		if stats != null:
			# NEW: ensure this ability only ever has one “stack” per target.
			# If the buff is already present, remove its old modifiers so
			# re-casting refreshes it instead of double-stacking.
			if stats.has_method("remove_modifiers_by_source"):
				stats.call("remove_modifiers_by_source", src_default)

			var j: int = 0
			while j < mods.size():
				var m: Variant = mods[j]
				if m is StatModifier:
					var tmpl: StatModifier = (m as StatModifier).duplicate(true) as StatModifier
					if tmpl == null:
						tmpl = m
					if String(tmpl.source_id) == "":
						tmpl.source_id = src_default
					if stats.has_method("add_modifier"):
						stats.call("add_modifier", tmpl)
						applied_any = true
				j += 1

		# Still allow BUFF abilities to also apply StatusConditions if configured.
		_maybe_apply_statuses(_user, def, t)

		if vfx_hint != StringName("") and applied_any:
			_emit_target_vfx(t, vfx_hint, vis_ctx)

	return applied_any


func _do_debuff(_user: Node, def: Resource, _ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var mods: Array = []
	if def.has_method("get"):
		var any: Variant = def.get("debuff_mods")
		if typeof(any) == TYPE_ARRAY:
			mods = any

	var src_default: String = "ability:" + _get_string(def, "ability_id")
	var applied_any: bool = false

	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue

		var stats: Node = _get_stats(t)
		if stats != null and not mods.is_empty():
			var j: int = 0
			while j < mods.size():
				var m: Variant = mods[j]
				if m is StatModifier:
					var tmpl: StatModifier = (m as StatModifier).duplicate(true) as StatModifier
					if tmpl == null:
						tmpl = m
					if String(tmpl.source_id) == "":
						tmpl.source_id = src_default
					if stats.has_method("add_modifier"):
						stats.call("add_modifier", tmpl)
						applied_any = true
				j += 1
		var did_status: bool = _maybe_apply_statuses(_user, def, t)
		if vfx_hint != StringName("") and (applied_any or did_status):
			_emit_target_vfx(t, vfx_hint, vis_ctx)

	return applied_any

# ============================================================================ #
# SUMMON (NEW IMPLEMENTATION)
# ============================================================================ #
func _do_summon(user: Node, def: Resource, ctx: Dictionary, _targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var actor: Node2D = user as Node2D
	if actor == null:
		return false

	# AbilityDef: summon_scene
	var summon_scene_any: Variant = null
	if def.has_method("get"):
		summon_scene_any = def.get("summon_scene")
	if summon_scene_any == null or typeof(summon_scene_any) != TYPE_OBJECT:
		_log_fail("no_summon_scene", _get_string(def, "ability_id"), _get_string(def, "display_name"))
		return false

	var summon_scene: PackedScene = summon_scene_any as PackedScene
	if summon_scene == null:
		_log_fail("bad_summon_scene", _get_string(def, "ability_id"), _get_string(def, "display_name"))
		return false

	# Spawn offset (front of summoner)
	var spawn_offset_px: float = _get_float(def, "summon_spawn_offset_px")
	if spawn_offset_px <= 0.0:
		spawn_offset_px = 16.0

	var aim_dir: Vector2 = _resolve_melee_aim(actor, ctx)
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2.DOWN
	else:
		aim_dir = aim_dir.normalized()

	var spawn_pos: Vector2 = actor.global_position + aim_dir * spawn_offset_px

	# Instantiate
	var pet: Node = summon_scene.instantiate()
	if pet == null:
		return false

	# Parent under same parent as the caster (world node)
	var parent_node: Node = actor.get_parent()
	if parent_node == null:
		parent_node = actor
	parent_node.add_child(pet)

	var pet2d: Node2D = pet as Node2D
	if pet2d != null:
		pet2d.global_position = spawn_pos

	# Ownership: minimal + flexible (pet scene can choose how to consume it later)
	if pet.has_method("set_owner"):
		pet.call("set_owner", user)
	elif pet.has_method("set_summon_owner"):
		pet.call("set_summon_owner", user)
	else:
		pet.set_meta("summon_owner", user)

	# Register with summoner roster (enforces FIFO cap internally)
	var pets_comp: SummonedPetsComponent = _find_summoned_pets_component(user)
	if pets_comp != null:
		pets_comp.register_pet(pet)

	# Apply current mode immediately if pet supports it (safe no-ops)
	if pets_comp != null:
		var mode: int = pets_comp.get_pet_mode()
		if pet.has_method("on_owner_pet_mode_changed"):
			pet.call("on_owner_pet_mode_changed", mode)
		elif pet.has_method("set_pet_mode"):
			pet.call("set_pet_mode", mode)

	# Summon VFX: use AbilityDef.vfx_hint already passed through the dispatcher.
	if vfx_hint != StringName(""):
		_emit_target_vfx(pet, vfx_hint, vis_ctx)

	# Lifetime (0 = infinite)
	var lifetime_sec: float = _get_float(def, "summon_lifetime_sec")
	if lifetime_sec > 0.0:
		var tree: SceneTree = get_tree()
		if tree != null:
			var tmr: SceneTreeTimer = tree.create_timer(lifetime_sec)
			tmr.timeout.connect(func() -> void:
				if pet == null:
					return
				if not is_instance_valid(pet):
					return
				if pet.has_method("request_despawn"):
					pet.call("request_despawn")
				elif pet.has_method("despawn"):
					pet.call("despawn")
				else:
					pet.queue_free()
			)

	return true


func _do_passive(_user: Node, _def: Resource, _ctx: Dictionary) -> bool:
	return true

# ============================================================================ #
# MELEE (core + status/VFX on hit)
# ============================================================================ #
func _do_melee(
	user: Node,
	def: Resource,
	ctx: Dictionary,
	cast_anim_prefix: String,
	vfx_hint: StringName,
	vis_ctx: Dictionary
) -> bool:
	var actor: Node2D = user as Node2D
	if actor == null:
		return false

	# Respect action lock (used by player + enemies)
	if user.has_method("is_action_locked"):
		var locked_any: Variant = user.call("is_action_locked")
		if typeof(locked_any) == TYPE_BOOL:
			var is_locked: bool = bool(locked_any)
			if is_locked:
				return false

	# Resolve aim direction
	var aim_dir: Vector2 = _resolve_melee_aim(actor, ctx)
	if aim_dir == Vector2.ZERO:
		aim_dir = Vector2.DOWN
	else:
		aim_dir = aim_dir.normalized()

	# Core melee geometry from AbilityDef or defaults
	var range_px: float = _def_or_default_f(def, "melee_range_px", melee_default_range_px)
	var arc_deg: float = _def_or_default_f(def, "melee_arc_deg", melee_default_arc_deg)

	# Let each ability control its own arc. Basic Attack can stay at the default.
	# Guard against zero/negative values.
	if arc_deg <= 0.0:
		arc_deg = melee_default_arc_deg

	var fwd_px: float = _def_or_default_f(def, "melee_forward_offset_px", melee_forward_offset_px)
	var legacy_hit_frame: int = _def_or_default_i(def, "melee_hit_frame", melee_default_hit_frame)
	var swing_thickness: float = _def_or_default_f(def, "melee_swing_thickness_px", melee_swing_thickness_px)
	var anim_prefix: String = _def_or_default_s(def, "melee_anim_prefix", melee_anim_prefix)

	# If the cast_anim_prefix is already an "attack" string, prefer that as our anim prefix
	if cast_anim_prefix.begins_with("attack"):
		anim_prefix = cast_anim_prefix

	# Multi-hit support:
	# - Prefer AbilityDef.melee_hit_frames when present/non-empty.
	# - Otherwise, fall back to legacy melee_hit_frame.
	var hit_frames: PackedInt32Array = _resolve_melee_hit_frames(def, legacy_hit_frame)
	var primary_hit_frame: int = legacy_hit_frame
	if hit_frames.size() > 0:
		primary_hit_frame = hit_frames[0]

	# Origin of the swing in world space (used for early checks only; recomputed at hit time)
	var origin: Vector2 = actor.global_position + aim_dir * fwd_px

	# Team-aware candidate collection (Enemies → Party, Party → Enemies)
	var candidates: Array = _collect_melee_candidates_for(actor)
	candidates = _maybe_constrain_melee_to_primary_target(def, ctx, candidates)

	# This callback actually applies hits when the animation reaches a hit frame.
	# IMPORTANT: recompute origin/aim at hit time so moving actors don't miss by stale geometry.
	var do_hit: Callable = func() -> void:
		if actor == null:
			return
		if not is_instance_valid(actor):
			return

		var hit_aim: Vector2 = _resolve_melee_aim(actor, ctx)
		if hit_aim == Vector2.ZERO:
			hit_aim = aim_dir
		else:
			hit_aim = hit_aim.normalized()

		var hit_origin: Vector2 = actor.global_position + hit_aim * fwd_px

		_apply_melee_hits(
			actor,
			hit_origin,
			hit_aim,
			arc_deg,
			range_px,
			swing_thickness,
			candidates,
			def,
			vfx_hint,
			vis_ctx,
			ctx
		)

	# Lock the actor while the swing plays so movement/other actions do not interrupt
	if user.has_method("lock_action_for"):
		user.call("lock_action_for", melee_lock_ms)

	# Drive melee swings only via the ability-defined prefix.
	var bridge: Node = _find_animation_bridge(actor)

	var used_bridge: bool = false
	if bridge != null and bridge.has_method("play_attack_with_prefix"):
		bridge.call("play_attack_with_prefix", anim_prefix, aim_dir, primary_hit_frame, do_hit)
		used_bridge = true
	else:
		# No AnimationBridge; try direct sprite-based fallback with the SAME prefix.
		_play_melee_anim_fallback(actor, aim_dir, anim_prefix)

	# Timing basis for additional hits + timed SFX
	var fps: float = _anim_fps(actor, anim_prefix)
	if fps <= 1.0:
		fps = melee_default_fallback_fps

	var tree: SceneTree = actor.get_tree()
	if tree == null:
		return true

	# Schedule additional melee hits:
	# - If bridge is used, it will call the primary hit itself at primary_hit_frame.
	# - We schedule the remaining frames.
	# - If bridge is NOT used, we schedule ALL hit frames ourselves.
	var schedule_hit_frames: PackedInt32Array = PackedInt32Array()
	var hf_i: int = 0
	while hf_i < hit_frames.size():
		schedule_hit_frames.append(hit_frames[hf_i])
		hf_i += 1

	if used_bridge:
		if schedule_hit_frames.size() > 0:
			# Remove primary (first after sorting)
			schedule_hit_frames.remove_at(0)

	var hi: int = 0
	while hi < schedule_hit_frames.size():
		var frame_val: int = schedule_hit_frames[hi]
		hi += 1

		var hit_sec: float = float(frame_val) / fps
		if hit_sec <= 0.0:
			do_hit.call()
		else:
			var tmr: SceneTreeTimer = tree.create_timer(hit_sec)
			tmr.timeout.connect(func() -> void:
				do_hit.call()
			)

	# Schedule frame-based SFX cues for melee (frames > 0).
	# Frame 0 cues are handled at cast start in execute().
	var cue_frames: PackedInt32Array = _collect_sfx_cue_frames(def, 1)
	var ci: int = 0
	while ci < cue_frames.size():
		var cue_frame: int = cue_frames[ci]
		ci += 1

		var cue_sec: float = float(cue_frame) / fps
		if cue_sec <= 0.0:
			_emit_sfx_cues_at_frame(def, actor, cue_frame)
		else:
			var tmr2: SceneTreeTimer = tree.create_timer(cue_sec)
			tmr2.timeout.connect(func() -> void:
				if actor == null:
					return
				if not is_instance_valid(actor):
					return
				_emit_sfx_cues_at_frame(def, actor, cue_frame)
			)

	return true


func _apply_melee_hits(
	attacker: Node2D,
	origin: Vector2,
	aim_dir: Vector2,
	arc_deg: float,
	range_px: float,
	swing_thickness: float,
	candidates: Array,
	def: Resource,
	vfx_hint: StringName,
	vis_ctx: Dictionary,
	ctx: Dictionary
) -> void:
	if attacker == null:
		return
	if not is_instance_valid(attacker):
		return

	var aim_n: Vector2 = aim_dir.normalized()
	var half_rad: float = deg_to_rad(arc_deg * 0.5)

	var total_hits: int = 0

	if MELEE_DEBUG:
		print(
			"[MELEE] debug attacker=", attacker.name,
			" origin=", origin,
			" aim=", aim_n,
			" range=", range_px,
			" arc=", arc_deg,
			" cand_count=", candidates.size()
		)

	var i: int = 0
	while i < candidates.size():
		var c_any: Variant = candidates[i]
		i += 1

		if c_any == null:
			continue
		if not is_instance_valid(c_any):
			continue
		if not (c_any is Node2D):
			continue

		var tgt: Node2D = c_any as Node2D

		if tgt == attacker:
			if MELEE_DEBUG:
				print("[MELEE] skip self target=", tgt.name)
			continue
		if tgt.is_queued_for_deletion():
			if MELEE_DEBUG:
				print("[MELEE] skip queued_for_deletion target=", tgt.name)
			continue
		if _is_effect_target_dead(tgt):
			if MELEE_DEBUG:
				print("[MELEE] skip dead target=", tgt.name)
			continue

		var to: Vector2 = tgt.global_position - origin
		var to_len: float = to.length()

		# 1) Distance gate – must be within melee range
		if to_len > range_px:
			if MELEE_DEBUG:
				print(
					"[MELEE] skip by range attacker=", attacker.name,
					" target=", tgt.name,
					" dist=", to_len,
					" max_range=", range_px
				)
			continue

		# 2) Angle gate – must be inside the front arc
		var ang_arc: float = 0.0
		if to_len > 0.001:
			var dir: Vector2 = to / maxf(to_len, 0.001)
			ang_arc = absf(aim_n.angle_to(dir))

		if ang_arc > half_rad:
			if MELEE_DEBUG:
				print(
					"[MELEE] skip by angle attacker=", attacker.name,
					" target=", tgt.name,
					" ang_deg=", rad_to_deg(ang_arc),
					" half_arc_deg=", rad_to_deg(half_rad)
				)
			continue

		var t_stats: Node = _get_stats(tgt)
		if t_stats == null:
			if MELEE_DEBUG:
				print("[MELEE] skip no stats target=", tgt.name)
			continue

		var amount: float = _melee_attack_amount_from(_get_stats(attacker))

		# Scale melee damage by AbilityDef.power when present.
		# Basic attack: power = 0.0  -> just uses base attack rating.
		# Abilities:    power > 0.0 -> base attack * power.
		var base_power: float = _get_float(def, "power")
		if base_power > 0.0:
			amount = amount * base_power

		if MELEE_DEBUG:
			print(
				"[MELEE] hit target=", tgt.name,
				" dist=", to_len,
				" ang_deg=", rad_to_deg(ang_arc),
				" amount=", amount
			)

		# IMPORTANT: funnel melee damage through the threat-aware packet path.
		_apply_damage(attacker, tgt, amount, def, ctx)

		if vfx_hint != StringName(""):
			_emit_target_vfx(tgt, vfx_hint, vis_ctx)

		_maybe_apply_statuses(attacker, def, tgt)

		# NEW: opt-in knockback (ability-data driven)
		_try_apply_knockback(attacker, tgt, def, ctx, aim_n)

		total_hits += 1

	if MELEE_DEBUG:
		print("[MELEE] total_hits=", total_hits)

# --- Melee helpers ---
func _collect_melee_candidates_for(attacker: Node) -> Array:
	var out: Array = []
	var tree: SceneTree = get_tree()
	if tree == null:
		return out

	var want_groups: PackedStringArray = PackedStringArray()
	if attacker != null and attacker.is_in_group("PartyMembers"):
		want_groups.append("Enemies")
		want_groups.append("Enemy")
	elif attacker != null and attacker.is_in_group("Enemies"):
		want_groups.append("PartyMembers")
	else:
		want_groups.append("Enemies")
		want_groups.append("Enemy")
		want_groups.append("PartyMembers")

	var gi: int = 0
	while gi < want_groups.size():
		var gname: String = want_groups[gi]
		var nodes: Array = tree.get_nodes_in_group(gname)
		var i: int = 0
		while i < nodes.size():
			out.append(nodes[i])
			i += 1
		gi += 1

	return out


func _maybe_constrain_melee_to_primary_target(
	def: Resource,
	ctx: Dictionary,
	candidates: Array
) -> Array:
	var out: Array = candidates
	if def == null:
		return out
	if not def.has_method("get"):
		return out

	# Only special-case melee abilities that explicitly require a target.
	var requires_target: bool = _get_bool(def, "requires_target")
	if not requires_target:
		return out

	var rule: String = _get_string(def, "target_rule")
	if rule == "":
		return out
	# Treat single-target rules as "hit just that one thing".
	if rule != "ENEMY_SINGLE" and rule != "ALLY_SINGLE":
		return out

	var primary: Node2D = null

	if ctx.has("target"):
		var any_target: Variant = ctx["target"]
		if any_target is Node2D:
			primary = any_target

	if primary == null and ctx.has("targets"):
		var arr_any: Variant = ctx["targets"]
		if typeof(arr_any) == TYPE_ARRAY:
			var arr: Array = arr_any
			var i: int = 0
			while i < arr.size():
				if arr[i] is Node2D:
					primary = arr[i]
					break
				i += 1

	if primary == null:
		return out
	if not is_instance_valid(primary):
		return out

	var filtered: Array = []
	var j: int = 0
	while j < candidates.size():
		if candidates[j] == primary:
			filtered.append(primary)
			break
		j += 1

	if filtered.is_empty():
		return out

	return filtered


func _melee_any_in_range(
	origin: Vector2,
	aim_dir: Vector2,
	arc_deg: float,
	range_px: float,
	_swing_thickness: float,
	candidates: Array
) -> bool:
	var aim_n: Vector2 = aim_dir.normalized()
	var half_rad: float = deg_to_rad(arc_deg * 0.5)

	var i: int = 0
	while i < candidates.size():
		var c_any: Variant = candidates[i]
		i += 1

		if c_any == null:
			continue
		if not is_instance_valid(c_any):
			continue
		if not (c_any is Node2D):
			continue

		var tgt: Node2D = c_any as Node2D

		var to: Vector2 = tgt.global_position - origin
		var to_len: float = to.length()

		if to_len > range_px:
			continue

		var ang_arc: float = 0.0
		if to_len > 0.001:
			var dir: Vector2 = to / maxf(to_len, 0.001)
			ang_arc = absf(aim_n.angle_to(dir))

		if ang_arc > half_rad:
			continue

		return true

	return false


func _is_ai_driven_for_melee(actor: Node) -> bool:
	if actor.is_in_group("Enemies"):
		return true
	if actor.is_in_group("PartyMembers"):
		var controlled: Node = _party_current_controlled()
		if controlled != null and actor == controlled:
			return false
		if actor.is_in_group("PartyLeader"):
			return false
		return true
	return false


func _party_current_controlled() -> Node:
	var mgr: Node = null
	var list: Array = get_tree().get_nodes_in_group("PartyManager")
	if list.size() > 0:
		var maybe: Variant = list[0]
		if maybe is Node:
			mgr = maybe
	if mgr != null and mgr.has_method("get_controlled"):
		var v: Variant = mgr.call("get_controlled")
		if v is Node:
			return v
	return null

# ============================================================================ #
# TARGETING / PRESENTATION / STATS HELPERS
# ============================================================================ #
func _resolve_targets(user: Node, rule: StringName, ctx: Dictionary) -> Array:
	if TargetingSys == null:
		return []

	if TargetingSys.has_method("get_targets"):
		var res: Variant = TargetingSys.call("get_targets", user, rule, ctx)
		if typeof(res) == TYPE_ARRAY:
			return res

	var rule_s: String = String(rule)

	# If caller supplied an explicit target, validate it (can be freed).
	if ctx.has("target"):
		var tv: Variant = ctx["target"]
		if tv is Object:
			var tv_obj: Object = tv as Object
			if is_instance_valid(tv_obj):
				if tv_obj is Node:
					return [tv_obj as Node]

	if rule_s == "ALLY_SINGLE":
		var ally: Node = null
		if TargetingSys.has_method("current_ally_target"):
			var raw_ally: Variant = TargetingSys.call("current_ally_target")
			if raw_ally is Object:
				var obj_ally: Object = raw_ally as Object
				if is_instance_valid(obj_ally):
					if obj_ally is Node:
						ally = obj_ally as Node
		if ally != null:
			return [ally]
		return [user]

	if rule_s == "ENEMY_SINGLE":
		var foe: Node = null
		if TargetingSys.has_method("current_enemy_target"):
			var raw_foe: Variant = TargetingSys.call("current_enemy_target")
			if raw_foe is Object:
				var obj_foe: Object = raw_foe as Object
				if is_instance_valid(obj_foe):
					if obj_foe is Node:
						foe = obj_foe as Node
		if foe != null:
			return [foe]
		return []

	if rule_s == "ALLY_OR_SELF":
		var a2: Node = null
		if TargetingSys.has_method("current_ally_target"):
			var raw_a2: Variant = TargetingSys.call("current_ally_target")
			if raw_a2 is Object:
				var obj_a2: Object = raw_a2 as Object
				if is_instance_valid(obj_a2):
					if obj_a2 is Node:
						a2 = obj_a2 as Node
		if a2 != null:
			return [a2]
		return [user]

	if rule_s == "ALLY_PARTY" or rule_s == "ALLY_ALL":
		var arr: Array = []
		var nodes: Array = get_tree().get_nodes_in_group("PartyMembers")
		var i2: int = 0
		while i2 < nodes.size():
			arr.append(nodes[i2])
			i2 += 1
		if arr.is_empty():
			arr.append(user)
		return arr

	return []

	return []


func _resolve_self_or_context(user: Node, _rule: StringName, ctx: Dictionary) -> Array:
	var prefer: String = ""
	if ctx.has("prefer"):
		var v: Variant = ctx["prefer"]
		if typeof(v) == TYPE_STRING:
			prefer = v
	if prefer == "target" and ctx.has("target"):
		var t: Variant = ctx["target"]
		if t is Node:
			return [t]
	return [user]


func _play_cast_anim(user: Node, anim: StringName) -> void:
	if anim == StringName(""):
		return
	var ap: AnimationPlayer = _find_anim_player(user)
	if ap == null:
		return
	if ap.has_animation(String(anim)):
		ap.play(String(anim))


func _maybe_play_bridge_lock_from_cast(user: Node, cast_anim_str: String, ctx: Dictionary) -> void:
	if cast_anim_str == "":
		return
	var actor2d: Node2D = user as Node2D
	if actor2d == null:
		return
	var bridge: Node = _find_animation_bridge(actor2d)

	var aim: Vector2 = Vector2.ZERO
	if ctx.has("aim_dir"):
		var v: Variant = ctx["aim_dir"]
		if typeof(v) == TYPE_VECTOR2:
			var d: Vector2 = v
			if d != Vector2.ZERO:
				aim = d.normalized()
	if aim == Vector2.ZERO and actor2d is CharacterBody2D:
		var body: CharacterBody2D = actor2d as CharacterBody2D
		if body.velocity.length() > 0.01:
			aim = body.velocity.normalized()
	if aim == Vector2.ZERO:
		var lm_any: Variant = actor2d.get("_last_move_dir")
		if typeof(lm_any) == TYPE_VECTOR2:
			var lm: Vector2 = lm_any
			if lm != Vector2.ZERO:
				aim = lm.normalized()
	if aim == Vector2.ZERO:
		aim = Vector2.DOWN

	var lock_sec: float = 0.25

	if bridge != null:
		if bridge.has_method("set_facing"):
			bridge.call("set_facing", aim)

		if cast_anim_str.begins_with("cast"):
			if bridge.has_method("play_cast_with_prefix"):
				bridge.call("play_cast_with_prefix", cast_anim_str, lock_sec)
				return
		if cast_anim_str.begins_with("buff"):
			if bridge.has_method("play_buff_with_prefix"):
				bridge.call("play_buff_with_prefix", cast_anim_str, lock_sec)
				return
		if cast_anim_str.begins_with("projectile"):
			if bridge.has_method("play_projectile_with_prefix"):
				bridge.call("play_projectile_with_prefix", cast_anim_str, lock_sec)
				_try_direct_sprite_projectile(actor2d, cast_anim_str, aim)
				return

	_try_direct_sprite_projectile(actor2d, cast_anim_str, aim)


func _emit_target_vfx(target: Node, hint: StringName, ctx: Dictionary) -> void:
	if hint == StringName(""):
		return
	if target == null:
		return
	if VFXBridge != null and VFXBridge.has_method("emit_for_node"):
		VFXBridge.call("emit_for_node", hint, target, ctx)
		return
	if target.has_method("emit_vfx_hint"):
		target.call("emit_vfx_hint", hint, ctx)


func _emit_sfx(event: StringName, user: Node) -> void:
	if event == StringName(""):
		return

	# Prefer caster position if they are spatial (Node2D).
	var pos: Vector2 = Vector2.INF
	var as2d: Node2D = user as Node2D
	if as2d != null:
		pos = as2d.global_position

	# Play through AudioSys directly (autoload name).
	AudioSys.play_sfx_event(event, pos)

	# Optional legacy bridge: if some actors still implement emit_sfx_event, keep it.
	# (This preserves existing behavior while you migrate.)
	if user != null and user.has_method("emit_sfx_event"):
		user.call("emit_sfx_event", event)

# ============================================================================ #
# SFX CUES (AbilityDef.sfx_cues) + MELEE MULTI-HIT FRAMES (AbilityDef.melee_hit_frames)
# ============================================================================ #
func _has_sfx_cues(def: Resource) -> bool:
	if def == null:
		return false
	if not def.has_method("get"):
		return false
	var any: Variant = def.get("sfx_cues")
	if typeof(any) != TYPE_ARRAY:
		return false
	var arr: Array = any
	if arr.is_empty():
		return false
	return true


func _get_sfx_cues(def: Resource) -> Array[AbilitySfxCue]:
	var out: Array[AbilitySfxCue] = []
	if def == null:
		return out
	if not def.has_method("get"):
		return out

	var any: Variant = def.get("sfx_cues")
	if typeof(any) != TYPE_ARRAY:
		return out

	var arr: Array = any
	var i: int = 0
	while i < arr.size():
		var v: Variant = arr[i]
		if v is AbilitySfxCue:
			out.append(v as AbilitySfxCue)
		i += 1

	return out


func _emit_sfx_cues_at_frame(def: Resource, user: Node, frame: int) -> bool:
	var cues: Array[AbilitySfxCue] = _get_sfx_cues(def)
	if cues.is_empty():
		return false

	var played_any: bool = false
	var i: int = 0
	while i < cues.size():
		var cue: AbilitySfxCue = cues[i]
		i += 1
		if cue == null:
			continue
		if cue.frame != frame:
			continue
		var ev: String = String(cue.event).strip_edges()
		if ev.is_empty():
			continue
		_play_sfx_cue(cue, user)
		played_any = true

	return played_any


func _collect_sfx_cue_frames(def: Resource, min_frame: int) -> PackedInt32Array:
	var cues: Array[AbilitySfxCue] = _get_sfx_cues(def)
	var set: Dictionary = {}

	var i: int = 0
	while i < cues.size():
		var cue: AbilitySfxCue = cues[i]
		i += 1
		if cue == null:
			continue
		var f: int = cue.frame
		if f < min_frame:
			continue
		var ev: String = String(cue.event).strip_edges()
		if ev.is_empty():
			continue
		set[f] = true

	var keys: Array = set.keys()
	keys.sort()

	var out: PackedInt32Array = PackedInt32Array()
	var k: int = 0
	while k < keys.size():
		var v: Variant = keys[k]
		if typeof(v) == TYPE_INT:
			out.append(int(v))
		elif typeof(v) == TYPE_FLOAT:
			out.append(int(v))
		k += 1

	return out


func _resolve_melee_hit_frames(def: Resource, fallback_hit_frame: int) -> PackedInt32Array:
	var frames: PackedInt32Array = PackedInt32Array()

	if def != null and def.has_method("get"):
		var any: Variant = def.get("melee_hit_frames")
		if typeof(any) == TYPE_PACKED_INT32_ARRAY:
			frames = any
		elif typeof(any) == TYPE_ARRAY:
			var arr: Array = any
			var i: int = 0
			while i < arr.size():
				var v: Variant = arr[i]
				if typeof(v) == TYPE_INT:
					frames.append(int(v))
				elif typeof(v) == TYPE_FLOAT:
					frames.append(int(v))
				i += 1

	if frames.size() == 0:
		frames.append(fallback_hit_frame)

	return _unique_sorted_int32(frames)


func _unique_sorted_int32(input: PackedInt32Array) -> PackedInt32Array:
	var set: Dictionary = {}
	var i: int = 0
	while i < input.size():
		var v: int = input[i]
		if v >= 0:
			set[v] = true
		i += 1

	var keys: Array = set.keys()
	keys.sort()

	var out: PackedInt32Array = PackedInt32Array()
	var k: int = 0
	while k < keys.size():
		var kv: Variant = keys[k]
		if typeof(kv) == TYPE_INT:
			out.append(int(kv))
		elif typeof(kv) == TYPE_FLOAT:
			out.append(int(kv))
		k += 1

	return out


func _play_sfx_cue(cue: AbilitySfxCue, user: Node) -> void:
	if cue == null:
		return

	var stream: AudioStream = cue.resolve_stream()
	if stream == null:
		# Fallback: treat cue.event as an AudioSys registered event.
		var pos_fallback: Vector2 = Vector2.INF
		var as2d_fb: Node2D = user as Node2D
		if as2d_fb != null:
			pos_fallback = as2d_fb.global_position
		AudioSys.play_sfx_event(cue.event, pos_fallback, cue.volume_db)
		return

	var final_stream: AudioStream = stream
	if cue.play_once:
		final_stream = _force_stream_no_loop(stream)

	# Prefer AudioSys playback helpers if present (keeps bus + pooling behavior consistent).
	var pos: Vector2 = Vector2.INF
	var as2d: Node2D = user as Node2D
	if as2d != null:
		pos = as2d.global_position

	if pos != Vector2.INF:
		if AudioSys != null and AudioSys.has_method("_play_sfx_at_position"):
			AudioSys.call("_play_sfx_at_position", final_stream, pos, cue.volume_db)
			return
	else:
		if AudioSys != null and AudioSys.has_method("_play_sfx_global"):
			AudioSys.call("_play_sfx_global", final_stream, cue.volume_db)
			return

	# Last resort: play directly.
	_play_sfx_stream_direct(final_stream, pos, cue.volume_db)


func _play_sfx_stream_direct(stream: AudioStream, world_position: Vector2, volume_db: float) -> void:
	if stream == null:
		return

	if world_position != Vector2.INF:
		var p2d: AudioStreamPlayer2D = AudioStreamPlayer2D.new()
		p2d.stream = stream
		p2d.volume_db = volume_db
		p2d.finished.connect(Callable(p2d, "queue_free"))
		add_child(p2d)
		p2d.global_position = world_position
		p2d.play()
		return

	var p: AudioStreamPlayer = AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = volume_db
	p.finished.connect(Callable(p, "queue_free"))
	add_child(p)
	p.play()


func _force_stream_no_loop(stream: AudioStream) -> AudioStream:
	if stream == null:
		return null

	var dup_res: Resource = stream.duplicate(true)
	var dup: AudioStream = stream
	if dup_res is AudioStream:
		dup = dup_res as AudioStream

	if dup is AudioStreamWAV:
		var w: AudioStreamWAV = dup as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_DISABLED
	elif dup is AudioStreamOggVorbis:
		var o: AudioStreamOggVorbis = dup as AudioStreamOggVorbis
		o.loop = false
	elif dup is AudioStreamMP3:
		var m: AudioStreamMP3 = dup as AudioStreamMP3
		m.loop = false

	return dup


func _try_consume_mp(user: Node, mp_cost: float) -> bool:
	if mp_cost <= 0.0:
		return true
	var stats: Node = _get_stats(user)
	if stats == null:
		return true
	if stats.has_method("spend_mp"):
		var v: Variant = stats.call("spend_mp", mp_cost)
		if typeof(v) == TYPE_BOOL:
			return bool(v)
		return true
	return true


func _try_consume_end(user: Node, end_cost: float) -> bool:
	if end_cost <= 0.0:
		return true
	var stats: Node = _get_stats(user)
	if stats == null:
		return true
	if stats.has_method("spend_end"):
		var v: Variant = stats.call("spend_end", end_cost)
		if typeof(v) == TYPE_BOOL:
			return bool(v)
		return true
	return true


func _apply_heal(
	user: Node,
	target: Node,
	amount: float,
	def: Resource,
	ctx: Dictionary,
	ability_id: String,
	ability_type: String
) -> void:
	if _is_effect_target_dead(target):
		return
	var stats: Node = _get_stats(target)
	if stats == null:
		return
	var source_str: String = _ability_source_string(def, ctx)
	var is_crit: bool = false
	if ctx.has("is_crit"):
		var v: Variant = ctx["is_crit"]
		if typeof(v) == TYPE_BOOL:
			is_crit = bool(v)
	if stats.has_method("apply_heal"):
		stats.call("apply_heal", amount, source_str, is_crit, user, ability_id, ability_type)
	elif stats.has_method("heal"):
		stats.call("heal", amount)
	elif stats.has_method("change_hp"):
		stats.call("change_hp", amount)


func _apply_damage(user: Node, target: Node, amount: float, def: Resource, ctx: Dictionary) -> void:
	if _is_effect_target_dead(target):
		return
	var stats: Node = _get_stats(target)
	if stats == null:
		return

	var source_str: String = _ability_source_string(def, ctx)
	var dmg_type: String = "Physical"

	var is_crit: bool = false
	if ctx.has("is_crit"):
		var crit_any: Variant = ctx["is_crit"]
		if typeof(crit_any) == TYPE_BOOL:
			is_crit = bool(crit_any)

	# ----------------------------
	# NEW: Attacker Accuracy
	# (StatsComponent will consume this when we wire the miss logic.)
	# ----------------------------
	var attacker_accuracy: float = 0.0
	var attacker_stats: Node = _get_stats(user)
	if attacker_stats != null and attacker_stats.has_method("get_final_stat"):
		var acc_any: Variant = attacker_stats.call("get_final_stat", "Accuracy")
		if typeof(acc_any) == TYPE_FLOAT or typeof(acc_any) == TYPE_INT:
			attacker_accuracy = float(acc_any)

	# Build a threat-aware damage packet for StatsComponent.apply_damage_packet.
	var packet: Dictionary = {
		"amount": amount,
		"source": source_str,
		"is_crit": is_crit,

		# NEW: Accuracy value (0..1 expected, but we do not clamp here).
		"accuracy": attacker_accuracy
	}

	# Include typed damage so StatsComponent can use resistances.
	var types: Dictionary = {}
	types[dmg_type] = 1.0
	packet["types"] = types

	# Threat metadata: who dealt the damage.
	if user != null and is_instance_valid(user):
		packet["source_node"] = user

	# Threat metadata: which ability and type caused this damage.
	if def != null and def.has_method("get"):
		var ability_id: String = _get_string(def, "ability_id")
		if ability_id != "":
			packet["ability_id"] = ability_id
		var ability_type_name: String = _get_string(def, "ability_type")
		if ability_type_name != "":
			packet["ability_type"] = ability_type_name

	# Prefer the packet path (emits damage_threat) but keep old behavior as fallback.
	if stats.has_method("apply_damage_packet"):
		stats.call("apply_damage_packet", packet)
	elif stats.has_method("apply_damage"):
		stats.call("apply_damage", amount, dmg_type, source_str)
	elif stats.has_method("take_damage"):
		stats.call("take_damage", amount, user)


func _resolve_heal_amount(user: Node, _target: Node, def: Resource) -> float:
	var base_power: float = _get_float(def, "power")
	if base_power < 0.0:
		base_power = 0.0
	var caster_stats: Node = _get_stats(user)
	var is_crit: bool = false
	if DF != null:
		var df_obj: Object = DF.new()
		if df_obj != null:
			if caster_stats != null and df_obj.has_method("crit_heal_chance"):
				var chance_any: Variant = df_obj.call("crit_heal_chance", caster_stats)
				var chance: float = 0.0
				if typeof(chance_any) == TYPE_FLOAT or typeof(chance_any) == TYPE_INT:
					chance = float(chance_any)
					if chance > 0.0:
						var roll: float = randf()
						if roll < chance:
							is_crit = true
	var scale_stat: String = "WIS"
	if def != null and def.has_method("get"):
		var v: Variant = def.get("scale_stat")
		if typeof(v) == TYPE_STRING:
			var s: String = v
			if s != "":
				scale_stat = s
	var amount: int = 0
	if DF != null:
		var df2: Object = DF.new()
		if df2 != null and df2.has_method("calc_heal"):
			var v2: Variant = df2.call("calc_heal", caster_stats, base_power, scale_stat, is_crit)
			if typeof(v2) == TYPE_INT:
				amount = int(v2)
			elif typeof(v2) == TYPE_FLOAT:
				amount = int(round(float(v2)))
	if amount < 1:
		amount = 1
	return float(amount)


func _melee_attack_amount_from(user_stats: Node) -> float:
	if user_stats == null:
		return 5.0
	var atk: float = 5.0
	if DF != null:
		var df_obj: Object = DF.new()
		if df_obj != null and df_obj.has_method("attack_rating"):
			var v: Variant = df_obj.call("attack_rating", user_stats)
			if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
				atk = float(v)
				if atk <= 0.0:
					atk = 5.0
	if melee_variance_pct > 0.0:
		var low: float = 1.0 - melee_variance_pct
		var high: float = 1.0 + melee_variance_pct
		var roll: float = randf_range(low, high)
		atk *= roll
	return atk

# ============================================================================ #
# STATUS APPLICATION
# ============================================================================ #
func _maybe_apply_statuses(_user: Node, def: Resource, target: Node) -> bool:
	if def == null or target == null:
		return false
	if not def.has_method("get"):
		return false
	if _is_effect_target_dead(target):
		return false
		
		

	var arr_any: Variant = def.get("applies_status")
	if typeof(arr_any) != TYPE_ARRAY:
		return false
	var arr: Array = arr_any

	var sc: Node = _find_status_component(target)
	if sc == null:
		return false
	var any_applied: bool = false

	var i: int = 0
	while i < arr.size():
		var spec: Variant = arr[i]
		i += 1
		if spec == null:
			continue
		var sid: StringName = _get_status_spec_id(spec)
		if sid == StringName(""):
			continue
		var chance: float = _get_status_spec_chance(spec)
		var dur: float = _get_status_spec_duration(spec)
		var stacks: int = _get_status_spec_stacks(spec)
		var payload: Dictionary = _get_status_spec_payload(spec)

		var roll: float = randf()
		if roll <= chance:
			var opts: Dictionary = {
				"duration": dur,
				"stacks": stacks,
				"source": _user,
				"payload": payload
			}

			if STATUS_DEBUG:
				# Log BEFORE applying, using the real StatusConditions API from the project.
				var pre_has: bool = false
				var pre_is_slowed: bool = false
				var pre_attack_mul: float = 1.0
				if sc.has_method("has"):
					var v_has: Variant = sc.call("has", sid)
					if typeof(v_has) == TYPE_BOOL:
						pre_has = bool(v_has)
				if sc.has_method("is_slowed"):
					var v_sl: Variant = sc.call("is_slowed")
					if typeof(v_sl) == TYPE_BOOL:
						pre_is_slowed = bool(v_sl)
				if sc.has_method("get_attack_speed_multiplier"):
					var v_mul: Variant = sc.call("get_attack_speed_multiplier")
					if typeof(v_mul) == TYPE_FLOAT or typeof(v_mul) == TYPE_INT:
						pre_attack_mul = float(v_mul)

				var abil_id_dbg: String = _get_string(def, "ability_id")
				var caster_dbg: String = ""
				if _user != null and is_instance_valid(_user):
					caster_dbg = _user.name
				print(
					"[STATUSDBG] pre",
					" ability=", abil_id_dbg,
					" caster=", caster_dbg,
					" target=", target.name,
					" sid=", String(sid),
					" roll=", roll,
					" chance=", chance,
					" pre_has=", pre_has,
					" pre_is_slowed=", pre_is_slowed,
					" pre_attack_mul=", pre_attack_mul,
					" dur=", dur,
					" stacks=", stacks,
					" payload=", payload
				)

			if sc.has_method("apply"):
				sc.call("apply", sid, opts)
				any_applied = true

				if STATUS_DEBUG:
					# Log AFTER applying.
					var post_has: bool = false
					var post_is_slowed: bool = false
					var post_attack_mul: float = 1.0
					if sc.has_method("has"):
						var v2_has: Variant = sc.call("has", sid)
						if typeof(v2_has) == TYPE_BOOL:
							post_has = bool(v2_has)
					if sc.has_method("is_slowed"):
						var v2_sl: Variant = sc.call("is_slowed")
						if typeof(v2_sl) == TYPE_BOOL:
							post_is_slowed = bool(v2_sl)
					if sc.has_method("get_attack_speed_multiplier"):
						var v2_mul: Variant = sc.call("get_attack_speed_multiplier")
						if typeof(v2_mul) == TYPE_FLOAT or typeof(v2_mul) == TYPE_INT:
							post_attack_mul = float(v2_mul)

					print(
						"[STATUSDBG] post",
						" target=", target.name,
						" sid=", String(sid),
						" post_has=", post_has,
						" post_is_slowed=", post_is_slowed,
						" post_attack_mul=", post_attack_mul
					)
	return any_applied


func _maybe_apply_statuses_multi(user: Node, def: Resource, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var any_applied: bool = false
	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		if _maybe_apply_statuses(user, def, t):
			any_applied = true
			if vfx_hint != StringName(""):
				_emit_target_vfx(t, vfx_hint, vis_ctx)
	return any_applied

# --- Status spec readers ---
func _get_status_spec_id(spec: Variant) -> StringName:
	if spec is Object and (spec as Object).has_method("get"):
		var v: Variant = (spec as Object).get("status_id")
		if typeof(v) == TYPE_STRING_NAME:
			return v
		if typeof(v) == TYPE_STRING:
			return StringName(String(v))
	return StringName("")


func _get_status_spec_chance(spec: Variant) -> float:
	if spec is Object and (spec as Object).has_method("get"):
		var v: Variant = (spec as Object).get("chance")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return clampf(float(v), 0.0, 1.0)
	return 0.0


func _get_status_spec_duration(spec: Variant) -> float:
	if spec is Object and (spec as Object).has_method("get"):
		var v: Variant = (spec as Object).get("duration_sec")
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			return max(0.0, float(v))
	return 0.0


func _get_status_spec_stacks(spec: Variant) -> int:
	if spec is Object and (spec as Object).has_method("get"):
		var v: Variant = (spec as Object).get("stacks")
		if typeof(v) == TYPE_INT:
			return max(1, int(v))
		if typeof(v) == TYPE_FLOAT:
			return max(1, int(v))
	return 1


func _get_status_spec_payload(spec: Variant) -> Dictionary:
	var out: Dictionary = {}
	if spec is Object and (spec as Object).has_method("get"):
		var col_any: Variant = (spec as Object).get("color")
		if typeof(col_any) == TYPE_COLOR:
			var col: Color = col_any
			if col.a > 0.0:
				out["color"] = col

		var mag_any: Variant = (spec as Object).get("magnitude")
		if typeof(mag_any) == TYPE_FLOAT or typeof(mag_any) == TYPE_INT:
			var mag: float = float(mag_any)
			if mag != 0.0:
				out["magnitude"] = mag

		var extra_any: Variant = (spec as Object).get("extra")
		if typeof(extra_any) == TYPE_DICTIONARY:
			var ex: Dictionary = extra_any
			for k in ex.keys():
				out[k] = ex[k]

		if out.is_empty():
			var legacy: Variant = (spec as Object).get("payload")
			if typeof(legacy) == TYPE_DICTIONARY:
				return legacy
	return out

# ============================================================================ #
# HELPERS
# ============================================================================ #
func _ability_source_string(def: Resource, ctx: Dictionary) -> String:
	var s: String = _get_string(def, "display_name")
	if s == "":
		s = _get_string(def, "ability_id")
	if s == "":
		if ctx.has("display_name"):
			var v: Variant = ctx["display_name"]
			if typeof(v) == TYPE_STRING:
				s = String(v)
	if s == "":
		s = "Ability"
	return s


func _get_stats(node: Node) -> Node:
	if node == null:
		return null
	if node.has_method("get_stats"):
		var s: Variant = node.call("get_stats")
		if s is Node:
			return s
	if node.has_node("StatsComponent"):
		return node.get_node("StatsComponent")
	return null


func _find_status_component(root: Node) -> Node:
	if root == null:
		return null
	if root.has_node("StatusConditions"):
		return root.get_node("StatusConditions")
	var i: int = 0
	while i < root.get_child_count():
		var ch: Node = root.get_child(i)
		if ch != null and (ch.name == "StatusConditions" or ch.name == "Status"):
			return ch
		i += 1
	return null


func _is_dead(status: Node) -> bool:
	if status == null:
		return false
	if status.has_method("is_dead"):
		var v: Variant = status.call("is_dead")
		if typeof(v) == TYPE_BOOL:
			return bool(v)
	return false


func _is_effect_target_dead(target: Node) -> bool:
	if target == null:
		return true
	if not is_instance_valid(target):
		return true
	var status: Node = _find_status_component(target)
	return _is_dead(status)


func _filter_targets_for_ability(targets: Array, ability_type: int) -> Array:
	var out: Array = []
	var i: int = 0
	while i < targets.size():
		var any: Variant = targets[i]
		i += 1
		if not (any is Node):
			continue
		var n: Node = any as Node
		var dead: bool = _is_effect_target_dead(n)
		if ability_type == AbilityType.REVIVE_SPELL:
			if dead:
				out.append(n)
		else:
			if not dead:
				out.append(n)
	return out


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	if node is AnimationPlayer:
		return node
	if node.has_node("AnimationPlayer"):
		var ap: Node = node.get_node("AnimationPlayer")
		if ap is AnimationPlayer:
			return ap
	return null


func _find_animation_bridge(actor: Node2D) -> Node:
	var n: Node = actor.get_node_or_null("AnimationBridge")
	if n != null:
		return n
	var i: int = 0
	while i < actor.get_child_count():
		var ch: Node = actor.get_child(i)
		if ch != null and ch.get_class() == "AnimationBridge":
			return ch
		i += 1
	return null


func _try_direct_sprite_projectile(actor: Node2D, prefix: String, aim: Vector2) -> void:
	if actor == null:
		return
	var spr: AnimatedSprite2D = actor.get_node_or_null("Anim") as AnimatedSprite2D
	if spr == null:
		return
	if spr.sprite_frames == null:
		return

	var use_side: bool = spr.sprite_frames.has_animation(prefix + "_side")
	var anim_name: String = prefix + "_down"

	if use_side:
		if absf(aim.x) >= absf(aim.y):
			anim_name = prefix + "_side"
			spr.flip_h = (aim.x < 0.0)
		else:
			if aim.y >= 0.0:
				anim_name = prefix + "_down"
				spr.flip_h = false
			else:
				anim_name = prefix + "_up"
				spr.flip_h = false
	else:
		if absf(aim.x) > absf(aim.y):
			if spr.sprite_frames.has_animation(prefix + "_right") and aim.x > 0.0:
				anim_name = prefix + "_right"
			elif spr.sprite_frames.has_animation(prefix + "_left") and aim.x < 0.0:
				anim_name = prefix + "_left"
			elif aim.y < 0.0:
				anim_name = prefix + "_up"
			else:
				anim_name = prefix + "_down"
			spr.flip_h = false
		else:
			if aim.y < 0.0:
				anim_name = prefix + "_up"
			else:
				anim_name = prefix + "_down"
			spr.flip_h = false

	if spr.sprite_frames.has_animation(anim_name):
		spr.sprite_frames.set_animation_loop(anim_name, false)
		spr.frame = 0
		spr.play(anim_name)


func _play_melee_anim_fallback(actor: Node2D, aim: Vector2, prefix: String) -> void:
	var spr: AnimatedSprite2D = null
	var direct: Node = actor.get_node_or_null("AnimatedSprite2D")
	if direct != null and direct is AnimatedSprite2D:
		spr = direct as AnimatedSprite2D
	if spr == null:
		var i: int = 0
		while i < actor.get_child_count():
			var as2: AnimatedSprite2D = actor.get_child(i) as AnimatedSprite2D
			if as2 != null:
				spr = as2
				break
			i += 1
	if spr == null:
		return

	var use_side: bool = false
	if spr.sprite_frames != null and spr.sprite_frames.has_animation(prefix + "_side"):
		use_side = true

	var name: String = prefix + "_down"
	if use_side:
		if absf(aim.x) >= absf(aim.y):
			name = prefix + "_side"
			spr.flip_h = (aim.x < 0.0)
		else:
			if aim.y >= 0.0:
				name = prefix + "_down"
			else:
				name = prefix + "_up"
			spr.flip_h = false
	else:
		if absf(aim.x) > absf(aim.y):
			if aim.x > 0.0:
				name = prefix + "_right"
			else:
				name = prefix + "_left"
		else:
			if aim.y >= 0.0:
				name = prefix + "_down"
			else:
				name = prefix + "_up"

	if spr.sprite_frames != null and spr.sprite_frames.has_animation(name):
		spr.sprite_frames.set_animation_loop(name, false)
	spr.frame = 0
	spr.play(name)


func _anim_fps(actor: Node2D, prefix: String) -> float:
	var spr: AnimatedSprite2D = actor.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if spr == null or spr.sprite_frames == null:
		return melee_default_fallback_fps
	var anim: String = spr.animation
	if anim == "":
		anim = prefix + "_down"
	var fps: float = spr.sprite_frames.get_animation_speed(anim)
	if fps <= 0.0:
		return melee_default_fallback_fps
	return fps


func _resolve_melee_aim(actor: Node2D, ctx: Dictionary) -> Vector2:
	if ctx.has("aim_dir"):
		var v: Variant = ctx["aim_dir"]
		if typeof(v) == TYPE_VECTOR2:
			var d: Vector2 = v
			if d != Vector2.ZERO:
				return d.normalized()
	if actor is CharacterBody2D:
		var body: CharacterBody2D = actor as CharacterBody2D
		if body.velocity.length() > 1.0:
			return body.velocity.normalized()
	var lm_any: Variant = actor.get("_last_move_dir")
	if typeof(lm_any) == TYPE_VECTOR2:
		var lm: Vector2 = lm_any
		if lm != Vector2.ZERO:
			return lm.normalized()
	return Vector2.ZERO


func _def_or_default_f(def: Resource, prop: String, fallback: float) -> float:
	var v: float = _get_float(def, prop)
	if v == 0.0:
		return fallback
	return v


func _def_or_default_i(def: Resource, prop: String, fallback: int) -> int:
	if def == null or not def.has_method("get"):
		return fallback
	var any: Variant = def.get(prop)
	if typeof(any) == TYPE_INT:
		return int(any)
	return fallback


func _def_or_default_s(def: Resource, prop: String, fallback: String) -> String:
	if def == null or not def.has_method("get"):
		return fallback
	var any: Variant = def.get(prop)
	if typeof(any) == TYPE_STRING:
		var s: String = any
		if s != "":
			return s
	return fallback


func _get_string(obj: Object, prop: String) -> String:
	if obj == null:
		return ""
	if not obj.has_method("get"):
		return ""
	var v: Variant = obj.get(prop)
	if typeof(v) == TYPE_STRING:
		return String(v)
	return ""


func _get_float(obj: Object, prop: String) -> float:
	if obj == null:
		return 0.0
	if not obj.has_method("get"):
		return 0.0
	var v: Variant = obj.get(prop)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return 0.0


func _get_bool(obj: Object, prop: String) -> bool:
	if obj == null:
		return false
	if not obj.has_method("get"):
		return false
	var v: Variant = obj.get(prop)
	if typeof(v) == TYPE_BOOL:
		return bool(v)
	return false


func _coerce_ability_type(name: String) -> int:
	if name == "MELEE":
		return AbilityType.MELEE
	if name == "PROJECTILE":
		return AbilityType.PROJECTILE
	if name == "DAMAGE_SPELL":
		return AbilityType.DAMAGE_SPELL
	if name == "DOT_SPELL":
		return AbilityType.DOT_SPELL
	if name == "HOT_SPELL":
		return AbilityType.HOT_SPELL
	if name == "HEAL_SPELL":
		return AbilityType.HEAL_SPELL
	if name == "CURE_SPELL":
		return AbilityType.CURE_SPELL
	if name == "REVIVE_SPELL":
		return AbilityType.REVIVE_SPELL
	if name == "BUFF":
		return AbilityType.BUFF
	if name == "DEBUFF":
		return AbilityType.DEBUFF
	if name == "SUMMON_SPELL":
		return AbilityType.SUMMON_SPELL
	if name == "PASSIVE":
		return AbilityType.PASSIVE
	return AbilityType.UNKNOWN


func _vfx_ctx(def: Resource, base_ctx: Dictionary) -> Dictionary:
	var out: Dictionary = base_ctx.duplicate()
	var ability_id: String = _get_string(def, "ability_id")
	var display_name: String = _get_string(def, "display_name")
	if ability_id != "":
		out["ability_id"] = ability_id
	if display_name != "":
		out["display_name"] = display_name
	if def.has_method("get"):
		var any_vfx: Variant = def.get("vfx_name")
		if typeof(any_vfx) == TYPE_STRING:
			var s: String = any_vfx
			if s != "":
				out["vfx_name"] = s
	return out


func _log_fail(kind: String, ability_id: String, display_name: String, extra: Dictionary = {}) -> void:
	var id_str: String = ability_id
	var name_str: String = display_name
	var msg: String = "[ABILITY] FAIL kind=%s id=%s name=%s" % [kind, id_str, name_str]
	for k in extra.keys():
		msg += " %s=%s" % [String(k), String(extra[k])]
	print(msg)


func _on_projectile_hit(target: Node, impact_hint: StringName, impact_ctx: Dictionary) -> void:
	if target == null:
		return
	if _is_effect_target_dead(target):
		return
	_emit_target_vfx(target, impact_hint, impact_ctx)


func _resolve_cast_origin(actor: Node2D, def: Resource, _ctx: Dictionary) -> Vector2:
	if def != null and def.has_method("get"):
		var any_path: Variant = def.get("spawn_node")
		if typeof(any_path) == TYPE_STRING:
			var rel: String = any_path
			if rel != "":
				if actor.has_node(rel):
					var n1: Node = actor.get_node(rel)
					if n1 is Node2D:
						return (n1 as Node2D).global_position

	var socket_names: PackedStringArray = [
		"CastOrigin",
		"ProjectileOrigin",
		"Muzzle",
		"RightHandSocket",
		"SpellSocket"
	]
	var i: int = 0
	while i < socket_names.size():
		var nm: String = socket_names[i]
		if actor.has_node(nm):
			var n2: Node = actor.get_node(nm)
			if n2 is Node2D:
				return (n2 as Node2D).global_position
		i += 1

	return actor.global_position

# ============================================================================ #
# SummonedPetsComponent helper (NEW)
# ============================================================================ #
func _find_summoned_pets_component(user: Node) -> SummonedPetsComponent:
	if user == null:
		return null

	# Preferred: direct child node name
	var direct: Node = user.get_node_or_null("SummonedPetsComponent")
	var direct_comp: SummonedPetsComponent = direct as SummonedPetsComponent
	if direct_comp != null:
		return direct_comp

	# Fallback: BFS search for SummonedPetsComponent class
	var q: Array[Node] = [user]
	while q.size() > 0:
		var cur: Node = q.pop_front()
		var as_comp: SummonedPetsComponent = cur as SummonedPetsComponent
		if as_comp != null:
			return as_comp
		for c in cur.get_children():
			if c is Node:
				q.push_back(c)

	return null

# ============================================================================ #
# Periodic scheduler
# ============================================================================ #
func _schedule_periodic_ticks(targets: Array, interval: float, total_ticks: int, on_tick: Callable) -> void:
	if interval <= 0.0:
		return
	if total_ticks < 1:
		return
	var tree: SceneTree = get_tree()
	if tree == null:
		return

	var t: int = 0
	while t < total_ticks:
		var delay: float = float(t + 1) * interval
		var timer: SceneTreeTimer = tree.create_timer(delay)
		var weak_targets: Array = []
		var i: int = 0
		while i < targets.size():
			var n: Node = targets[i]
			weak_targets.append(weakref(n))
			i += 1

		timer.timeout.connect(func() -> void:
			var j: int = 0
			while j < weak_targets.size():
				var w: WeakRef = weak_targets[j]
				var node_ref: Object = w.get_ref()
				if node_ref != null and node_ref is Node:
					on_tick.call(node_ref)
				j += 1
		)

		t += 1
