extends Node
class_name DebugStatsDump

@export var dump_once_on_start: bool = true
@export var auto_dump_every_sec: float = 0.0
@export var dump_on_level_up: bool = true   # NEW

var _timer_accum: float = 0.0
var _boot_dump_done: bool = false

# NEW: lightweight rescan + connection bookkeeping
var _scan_accum: float = 0.0
var _scan_interval_sec: float = 1.0
var _connected_ids: Dictionary = {}  # level_comp.instance_id() -> true

func _ready() -> void:
	set_process(true)

func _process(delta: float) -> void:
	if dump_once_on_start and not _boot_dump_done:
		_boot_dump_done = true
		call_deferred("_do_boot_dump")

	if auto_dump_every_sec > 0.0:
		_timer_accum += delta
		if _timer_accum >= auto_dump_every_sec:
			_timer_accum = 0.0
			dump_party()

	# Periodically wire up level-up signals
	if dump_on_level_up:
		_scan_accum += delta
		if _scan_accum >= _scan_interval_sec:
			_scan_accum = 0.0
			_connect_level_signals_if_needed()

func _do_boot_dump() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		await get_tree().process_frame
	dump_party()

func dump_party() -> void:
	var party: Array[Node] = _gather_party_members()
	var i: int = 0
	while i < party.size():
		var actor: Node = party[i]
		if actor != null:
			_print_actor_line(actor)
		i += 1

# -----------------------
# Level-up wiring (NEW)
# -----------------------
func _connect_level_signals_if_needed() -> void:
	var party: Array[Node] = _gather_party_members()
	var i: int = 0
	while i < party.size():
		var actor: Node = party[i]
		if actor != null:
			var level_comp: Node = _find_level_component(actor)
			if level_comp != null:
				var id: int = level_comp.get_instance_id()
				if not _connected_ids.has(id):
					_try_connect_level_signals(level_comp)
					_connected_ids[id] = true
		i += 1

func _find_level_component(n: Node) -> Node:
	if n == null:
		return null
	# Prefer a direct child named "LevelComponent"
	var direct: Node = n.get_node_or_null("LevelComponent")
	if direct != null:
		return direct
	# BFS search under the actor
	var queue: Array[Node] = []
	var kids: Array = n.get_children()
	var i: int = 0
	while i < kids.size():
		var c: Node = kids[i] as Node
		if c != null:
			queue.append(c)
		i += 1
	while queue.size() > 0:
		var cur: Node = queue.pop_front()
		if cur != null and cur.name == "LevelComponent":
			return cur
		if cur != null:
			var sub_kids: Array = cur.get_children()
			var j: int = 0
			while j < sub_kids.size():
				var sk: Node = sub_kids[j] as Node
				if sk != null:
					queue.append(sk)
				j += 1
	return null

func _try_connect_level_signals(level_comp: Node) -> void:
	# Bind the level_comp as the LAST param (bind appends),
	# then recover the actor in the handler by walking up.
	var handler: Callable = Callable(self, "_on_level_component_leveled").bind(level_comp)
	var connected_any: bool = false

	if level_comp.has_signal("leveled_up"):
		level_comp.connect("leveled_up", handler)
		connected_any = true
	if level_comp.has_signal("level_up"):
		level_comp.connect("level_up", handler)
		connected_any = true
	if level_comp.has_signal("level_changed"):
		level_comp.connect("level_changed", handler)
		connected_any = true

	if connected_any:
		pass
		# print("[DebugStatsDump] Connected level signals on ", level_comp.get_path())

# Accept up to three payload args (various signatures), plus the bound level_comp at the end.
func _on_level_component_leveled(_a: Variant = null, _b: Variant = null, _c: Variant = null, level_comp: Node = null) -> void:
	if not dump_on_level_up:
		return
	var actor: Node = _ascend_to_actor(level_comp)
	var actor_name: String = _actor_display_name(actor)
	print("[Debug] Level-up detected on: ", actor_name, " — dumping party stats.")
	dump_party()

# More robust: climb to an ancestor that either belongs to PartyMembers OR
# has a StatsComponent anywhere under it (not only as a direct child).
func _ascend_to_actor(n: Node) -> Node:
	var cur: Node = n
	while cur != null:
		if cur.is_in_group("PartyMembers"):
			return cur
		# recursive search for a StatsComponent under this parent
		var sc: Node = cur.find_child("StatsComponent", true, false)
		if sc != null:
			return cur
		cur = cur.get_parent()
	return null

func _actor_display_name(actor: Node) -> String:
	if actor == null:
		return "Unknown"
	# Prefer well-known properties if present
	if "display_name" in actor:
		var v: Variant = actor.get("display_name")
		if typeof(v) == TYPE_STRING and (v as String) != "":
			return v as String
	if "actor_name" in actor:
		var v2: Variant = actor.get("actor_name")
		if typeof(v2) == TYPE_STRING and (v2 as String) != "":
			return v2 as String
	if "enemy_name" in actor:
		var v3: Variant = actor.get("enemy_name")
		if typeof(v3) == TYPE_STRING and (v3 as String) != "":
			return v3 as String
	return actor.name

# -----------------------
# Party helpers
# -----------------------
func _gather_party_members() -> Array[Node]:
	var out: Array[Node] = []
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return out
	var nodes: Array = tree.get_nodes_in_group("PartyMembers")
	var i: int = 0
	while i < nodes.size():
		var n: Node = nodes[i] as Node
		if n != null:
			out.append(n)
		i += 1
	return out

# -----------------------
# Printing / stat helpers
# -----------------------
func _print_actor_line(actor: Node) -> void:
	var sc: Node = _find_stats_component(actor)
	var name_str: String = _actor_display_name(actor)

	var chp: float = 0.0
	var cmp: float = 0.0
	var cen: float = 0.0
	var mhp: float = 0.0
	var mmp: float = 0.0
	var men: float = 0.0

	if sc != null:
		chp = _get_current(sc, "hp")
		cmp = _get_current(sc, "mp")
		cen = _get_current(sc, "end")
		mhp = _call_float(sc, "max_hp")
		mmp = _call_float(sc, "max_mp")
		men = _call_float(sc, "max_end")

	var STR: float = _final(sc, "STR")
	var DEX: float = _final(sc, "DEX")
	var STA: float = _final(sc, "STA")
	var INT: float = _final(sc, "INT")
	var WIS: float = _final(sc, "WIS")
	var CHA: float = _final(sc, "CHA")
	var LCK: float = _final(sc, "LCK")

	var Attack: float = _final(sc, "Attack")
	var Defense: float = _final(sc, "Defense")
	var CritChance: float = _final(sc, "CritChance")

	var line: String = ""
	line += "[Party] "
	line += _pad_right(name_str, 8)
	line += " HP " + _pad_left(str(int(chp)), 5) + "/" + _pad_left(str(int(mhp)), 5)
	line += "  MP " + _pad_left(str(int(cmp)), 5) + "/" + _pad_left(str(int(mmp)), 5)
	line += "  END " + _pad_left(str(int(cen)), 5) + "/" + _pad_left(str(int(men)), 5)
	line += "  |  STR: " + _pad_left(str(int(STR)), 2)
	line += " DEX: " + _pad_left(str(int(DEX)), 2)
	line += " STA: " + _pad_left(str(int(STA)), 2)
	line += " INT: " + _pad_left(str(int(INT)), 2)
	line += " WIS: " + _pad_left(str(int(WIS)), 2)
	line += " CHA: " + _pad_left(str(int(CHA)), 2)
	line += " LCK: " + _pad_left(str(int(LCK)), 2)
	line += "  |  Attack:" + _pad_left(_fmt_one_dec(Attack), 5)
	line += " Defense:" + _pad_left(_fmt_one_dec(Defense), 5)
	# FIX: print as a percentage
	line += " CritChance:" + _fmt_one_dec(CritChance * 100.0) + "%"

	print(line)

# -----------------------
# Helpers
# -----------------------
func _find_stats_component(n: Node) -> Node:
	if n == null:
		return null
	# Try direct child first
	var s: Node = n.get_node_or_null("StatsComponent")
	if s != null:
		return s
	# Then any descendant
	return n.find_child("StatsComponent", true, false)

func _get_current(sc: Node, which: String) -> float:
	if sc == null:
		return 0.0
	if which == "hp":
		if "current_hp" in sc:
			var v: Variant = sc.get("current_hp")
			return _as_float(v)
		if sc.has_method("current_hp"):
			var r: Variant = sc.call("current_hp")
			return _as_float(r)
	elif which == "mp":
		if "current_mp" in sc:
			var v2: Variant = sc.get("current_mp")
			return _as_float(v2)
		if sc.has_method("current_mp"):
			var r2: Variant = sc.call("current_mp")
			return _as_float(r2)
	elif which == "end":
		if "current_end" in sc:
			var v3: Variant = sc.get("current_end")
			return _as_float(v3)
		if sc.has_method("current_end"):
			var r3: Variant = sc.call("current_end")
			return _as_float(r3)
	return 0.0

func _final(sc: Node, key: String) -> float:
	if sc == null:
		return 0.0
	if sc.has_method("get_final_stat"):
		var v: Variant = sc.call("get_final_stat", key)
		return _as_float(v)
	return 0.0

func _call_float(sc: Node, method: String) -> float:
	if sc == null:
		return 0.0
	if sc.has_method(method):
		var v: Variant = sc.call(method)
		return _as_float(v)
	return 0.0

func _as_float(v: Variant) -> float:
	if typeof(v) == TYPE_FLOAT:
		return float(v)
	if typeof(v) == TYPE_INT:
		return float(int(v))
	return 0.0

func _pad_left(s: String, w: int) -> String:
	var out: String = s
	while out.length() < w:
		out = " " + out
	return out

func _pad_right(s: String, w: int) -> String:
	var out: String = s
	while out.length() < w:
		out = out + " "
	return out

func _fmt_one_dec(v: float) -> String:
	return str(round(v * 10.0) / 10.0)
