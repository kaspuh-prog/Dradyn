extends Node
class_name DebugStatDump
## Prints HP (start), STR, Attack, CritChance for party + enemies.
## Also reprints on LevelComponent.level_up.

@export var print_on_ready: bool = true

func _ready() -> void:
	if print_on_ready:
		dump_everyone()
	# Also listen for future spawns (optional): if you add enemies at runtime, call dump_everyone() again.

# ---------------------------
# Public
# ---------------------------
func dump_everyone() -> void:
	# Party leader (if present)
	var leader = get_tree().get_first_node_in_group("PartyLeader")
	if leader != null:
		_dump_actor("Party", leader)

	# Party members
	var pmems: Array = get_tree().get_nodes_in_group("PartyMembers")
	for n in pmems:
		_dump_actor("Party", n)

	# Enemies
	var enemies: Array = get_tree().get_nodes_in_group("Enemies")
	for e in enemies:
		_dump_actor("Enemy", e)

# ---------------------------
# Internals
# ---------------------------
func _dump_actor(tag: String, actor: Node) -> void:
	if actor == null or not is_instance_valid(actor):
		return

	var stats: Node = _find_stats_component(actor)
	if stats == null:
		return

	var name_str: String = actor.name

	var hp_max: float = 0.0
	if stats.has_method("max_hp"):
		hp_max = float(stats.call("max_hp"))

	var hp_cur: float = 0.0
	var hp_v: Variant = null
	# Prefer property if exposed, else a getter if you added one
	if stats.get("current_hp"):
		hp_v = stats.get("current_hp")
	elif stats.has_method("current_hp"):
		hp_v = stats.call("current_hp")
	if typeof(hp_v) == TYPE_INT or typeof(hp_v) == TYPE_FLOAT:
		hp_cur = float(hp_v)

	var str_val: float = _final_stat(stats, "STR")
	var atk_val: float = _final_stat(stats, "Attack")
	var cc_raw: float = _final_stat(stats, "CritChance")

	# Convert to percent if it looks like a 0..1 probability
	var cc_pct: float = cc_raw
	if cc_pct <= 1.0:
		cc_pct = cc_pct * 100.0

	print("[", tag, "] ", name_str,
		"  HP ", _pad_num(hp_cur, 3), "/", _pad_num(hp_max, 3),
		"  STR ", _pad_num(str_val, 2),
		"  ATK ", _pad_num(atk_val, 2),
		"  CritChance ", _fmt_pct(cc_pct))

	# If a LevelComponent exists under this actor, listen to level ups and reprint
	var lc: Node = actor.find_child("LevelComponent", true, false)
	if lc != null and lc.has_signal("level_up"):
		var cb: Callable = Callable(self, "_on_level_up_dump").bind(tag, actor)
		if not lc.level_up.is_connected(cb):
			lc.level_up.connect(cb)

func _find_stats_component(root: Node) -> Node:
	if root == null:
		return null
	var by_name: Node = root.find_child("StatsComponent", true, false)
	if by_name != null:
		return by_name
	# If you ever put the API directly on the actor:
	if root.has_method("get_final_stat") and root.has_method("max_hp"):
		return root
	return null

func _final_stat(stats: Node, name: String) -> float:
	if stats == null:
		return 0.0
	if stats.has_method("get_final_stat"):
		var v = stats.call("get_final_stat", name)
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			return float(v)
	return 0.0

func _fmt_pct(p: float) -> String:
	# Show one decimal place; clamp for safety
	var v: float = clamp(p, 0.0, 100.0)
	return str("%.1f%%" % v)

func _pad_num(v: float, width: int) -> String:
	# Just a tiny helper to keep columns tidy
	var s := ""
	# use integers for clean HP when possible
	if is_equal_approx(v, round(v)):
		s = str(int(round(v)))
	else:
		s = str("%.1f" % v)
	# left-pad to width
	while s.length() < width:
		s = " " + s
	return s

func _on_level_up_dump(_new_level: int, _levels_gained: int, tag: String, actor: Node) -> void:
	# Re-print this actor after level up
	_dump_actor(tag, actor)
