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
	if duration <= 0.0 or interval <= 0.0:
		return _hot_tick_once(user, def, ctx, targets, vfx_hint, vis_ctx)
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
		_apply_heal(user, t, amt, def, ctx)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
	)
	return true

func _hot_tick_once(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var any: bool = false
	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		var amt: float = _resolve_heal_amount(user, t, def)
		_apply_heal(user, t, amt, def, ctx)
		if vfx_hint != StringName(""):
			_emit_target_vfx(t, vfx_hint, vis_ctx)
		_maybe_apply_statuses(user, def, t)
		any = true
	return any

func _do_heal_spell(user: Node, def: Resource, ctx: Dictionary, targets: Array, vfx_hint: StringName, vis_ctx: Dictionary) -> bool:
	var healed: bool = false
	var i: int = 0
	while i < targets.size():
		var t: Node = targets[i]
		i += 1
		if _is_effect_target_dead(t):
			continue
		var amount: float = _resolve_heal_amount(user, t, def)
		_apply_heal(user, t, amount, def, ctx)
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
	if stats.has_method("apply_heal"):
		var healed_any: Variant = stats.call("apply_heal", float(restore_amt), _ability_source_string(def, ctx), false)
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
	if mods.is_empty():
		return _maybe_apply_statuses_multi(_user, def, targets, vfx_hint, vis_ctx)

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

func _do_summon(_user: Node, _def: Resource, _ctx: Dictionary, _targets: Array, _vfx_hint: StringName, _vis_ctx: Dictionary) -> bool:
	return false

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

	# Let each ability control its own arc. Basic Attack can stay at the default
	# melee_default_arc_deg, while WideSwing (and others) override in their AbilityDef.
	# We only guard against zero/negative values here.
	if arc_deg <= 0.0:
		arc_deg = melee_default_arc_deg

	var fwd_px: float = _def_or_default_f(def, "melee_forward_offset_px", melee_forward_offset_px)
	var hit_frame: int = _def_or_default_i(def, "melee_hit_frame", melee_default_hit_frame)
	var swing_thickness: float = _def_or_default_f(def, "melee_swing_thickness_px", melee_swing_thickness_px)
	var anim_prefix: String = _def_or_default_s(def, "melee_anim_prefix", melee_anim_prefix)

	# If the cast_anim_prefix is already an "attack" string, prefer that as our anim prefix
	if cast_anim_prefix.begins_with("attack"):
		anim_prefix = cast_anim_prefix

	# Origin of the swing in world space
	var origin: Vector2 = actor.global_position + aim_dir * fwd_px

	# Team-aware candidate collection (Enemies → Party, Party → Enemies)
	var candidates: Array = _collect_melee_candidates_for(actor)

	# This callback actually applies hits when the animation reaches its hit frame
	var on_hit: Callable = func() -> void:
		_apply_melee_hits(
			actor,
			origin,
			aim_dir,
			arc_deg,
			range_px,
			swing_thickness,
			candidates,
			def,
			vfx_hint,
			vis_ctx
		)

	# Lock the actor while the swing plays so movement/other actions do not interrupt
	if user.has_method("lock_action_for"):
		user.call("lock_action_for", melee_lock_ms)

	# Drive melee swings only via the ability-defined prefix.
	# We no longer call legacy "play_melee_attack" / "play_melee_attack_anim" on the actor,
	# and we never fall back to a registry default (attack1) for abilities.
	var bridge: Node = _find_animation_bridge(actor)

	var used_bridge: bool = false
	if bridge != null and bridge.has_method("play_attack_with_prefix"):
		bridge.call("play_attack_with_prefix", anim_prefix, aim_dir, hit_frame, on_hit)
		used_bridge = true
	else:
		# No AnimationBridge; try direct sprite-based fallback with the SAME prefix.
		_play_melee_anim_fallback(actor, aim_dir, anim_prefix)

	# Hit timing:
	# - If we used AnimationBridge, it already knows the real hit frame and will
	#   invoke on_hit itself based on the animation frame.
	# - If we used the simple sprite fallback, we approximate hit timing from FPS.
	if not used_bridge:
		var fps: float = _anim_fps(actor, anim_prefix)
		if fps <= 1.0:
			fps = melee_default_fallback_fps
		var hit_sec: float = float(hit_frame) / fps

		if hit_sec <= 0.0:
			on_hit.call()
		else:
			var tmr: SceneTreeTimer = actor.get_tree().create_timer(hit_sec)
			tmr.timeout.connect(on_hit)

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
	vis_ctx: Dictionary
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
					"[MELEE] skip by range target=", tgt.name,
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
					"[MELEE] skip by angle target=", tgt.name,
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

		if t_stats.has_method("apply_damage"):
			t_stats.call("apply_damage", amount, "Physical", "Melee")
		elif t_stats.has_method("apply_damage_packet"):
			var packet: Dictionary = {
				"amount": amount,
				"type": "Physical",
				"source": "Melee",
				"is_crit": false
			}
			t_stats.call("apply_damage_packet", packet)

		if vfx_hint != StringName(""):
			_emit_target_vfx(tgt, vfx_hint, vis_ctx)

		_maybe_apply_statuses(attacker, def, tgt)

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

	if ctx.has("target"):
		var tv: Variant = ctx["target"]
		if tv is Node:
			return [tv]

	if rule_s == "ALLY_SINGLE":
		var ally: Node = null
		if TargetingSys.has_method("current_ally_target"):
			ally = TargetingSys.call("current_ally_target")
		if ally is Node:
			return [ally]
		return [user]

	if rule_s == "ENEMY_SINGLE":
		var foe: Node = null
		if TargetingSys.has_method("current_enemy_target"):
			foe = TargetingSys.call("current_enemy_target")
		if foe is Node:
			return [foe]
		return []

	if rule_s == "ALLY_OR_SELF":
		var a2: Node = null
		if TargetingSys.has_method("current_ally_target"):
			a2 = TargetingSys.call("current_ally_target")
		if a2 is Node:
			return [a2]
		return [user]

	if rule_s == "SELF" or rule_s == "SELF_ONLY":
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
	if user != null and user.has_method("emit_sfx_event"):
		user.call("emit_sfx_event", event)

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

func _apply_heal(user: Node, target: Node, amount: float, def: Resource, ctx: Dictionary) -> void:
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
		stats.call("apply_heal", amount, source_str, is_crit)
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
	if stats.has_method("apply_damage"):
		stats.call("apply_damage", amount, dmg_type, source_str)
	elif stats.has_method("apply_damage_packet"):
		var packet: Dictionary = {
			"amount": amount,
			"type": dmg_type,
			"source": source_str,
			"is_crit": false
		}
		stats.call("apply_damage_packet", packet)
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
			if sc.has_method("apply"):
				sc.call("apply", sid, opts)
				any_applied = true
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
