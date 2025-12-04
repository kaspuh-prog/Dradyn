extends Node
class_name SheetController

@export var bag_tabs_row_path: NodePath = ^"../BagTabsRow"
@export var grid_path: NodePath = ^"../Grid"
@export var desc_name_path: NodePath = ^"../DescriptionPane/ItemName"
@export var desc_qty_path: NodePath = ^"../DescriptionPane/Qty"
@export var desc_text_path: NodePath = ^"../DescriptionPane/ItemDescription" # fixed default

# Parent that contains the equipment slots (e.g., "../PortraitCluster")
@export var portrait_cluster_path: NodePath = ^"../PortraitCluster"

@export var debug_override_unlocked: int = -1

# -------- Scrollbar appearance & behavior (ItemDescription only) --------
enum ScrollMode { AUTO, ALWAYS_OFF, ALWAYS_ON }

@export var desc_scroll_mode: ScrollMode = ScrollMode.AUTO
@export var desc_scroll_width: int = 8
@export var desc_scroll_track_color: Color = Color(0.0, 0.0, 0.0, 0.18)
@export var desc_scroll_grabber_color: Color = Color(0.49, 0.36, 0.23, 0.95)
@export var desc_scroll_corner_radius: int = 6
# -----------------------------------------------------------------------

var _tabs: BagTabsRow
var _grid: InventoryGridView
var _desc_name: Label
var _desc_qty: Label
var _desc_text: RichTextLabel

# Unlocked counts per tab; editor sets a default on the node in TabbedMenu.tscn
@export var unlocked_by_tab: PackedInt32Array = [12, 0, 0, 0, 0, 48]

var _inv: Node = null
var _party: Node = null
var _portrait_cluster: Node = null

# ---------- Stat label mapping / normalization ----------

const _STAT_LABELS: Dictionary = {
	"WeaponWeight": "Weight",
	"weapon_weight": "Weight",
	"weight": "Weight",
	"Attack": "Attack",
	"attack": "Attack",
	"Defense": "Defense",
	"defense": "Defense",
	"MaxHP": "Max HP",
	"max_hp": "Max HP",
	"MaxMP": "Max MP",
	"max_mp": "Max MP",
	"MaxEND": "Max END",
	"max_end": "Max END",
	"CritChance": "Crit Chance",
	"crit_chance": "Crit Chance",
	"CritDamage": "Crit Damage",
	"crit_damage": "Crit Damage",
	"Strength": "STR",
	"strength": "STR",
	"dexterity": "DEX",
	"stamina": "STA",
	"intelligence": "INT",
	"wisdom": "WIS",
	"charisma": "CHA",
	"luck": "LCK"
}

func _fallback_stat_label(key: String) -> String:
	if key == "":
		return "Stat"
	var lower: String = key.replace("_", " ").to_lower()
	var words: PackedStringArray = lower.split(" ", false)
	var out_words: Array[String] = []
	var i: int = 0
	while i < words.size():
		var w: String = words[i]
		if w.length() > 0:
			var cap: String = w.substr(0, 1).to_upper() + w.substr(1, w.length() - 1)
			out_words.append(cap)
		i += 1
	return " ".join(out_words)

func _clean_number_string(s: String) -> String:
	# Accept "+2", "-3", "2.0", "2", "2.50", "0.05", "5%"
	if s.ends_with("%"):
		return s

	var sign: String = ""
	if s.begins_with("+") or s.begins_with("-"):
		sign = s.substr(0, 1)
		s = s.substr(1, s.length() - 1)

	var parsed: bool = false
	var val: float = 0.0
	if s.is_valid_float():
		val = s.to_float()
		parsed = true
	elif s.is_valid_int():
		val = float(s.to_int())
		parsed = true

	if parsed:
		if is_equal_approx(val, round(val)):
			return sign + str(int(round(val)))
		else:
			return sign + String.num(val, 2).rstrip("0").rstrip(".")
	else:
		return sign + s

func _normalize_stat_line(raw_line: String) -> String:
	# Handles "WeaponWeight = 2.0" -> "• Weight 2"
	# Leaves lines like "+2 Attack" as-is (apart from key mapping if we detect it).
	var eq_index: int = raw_line.find("=")
	if eq_index >= 0:
		var key: String = raw_line.substr(0, eq_index).strip_edges()
		var val: String = raw_line.substr(eq_index + 1, raw_line.length() - eq_index - 1).strip_edges()
		var label: String = _STAT_LABELS.get(key, _fallback_stat_label(key))
		var clean_val: String = _clean_number_string(val)
		return "• " + label + " " + clean_val

	# Try to catch "Key Value" or "+2 Attack" forms and map known keys.
	# If it begins with + or -, assume already human-friendly; just return with bullet.
	if raw_line.begins_with("+") or raw_line.begins_with("-"):
		return "• " + raw_line.strip_edges()

	# Otherwise, split to see if first token is a key.
	var parts: PackedStringArray = raw_line.split(" ", false)
	if parts.size() >= 2:
		var first: String = parts[0].strip_edges()
		var rest: String = raw_line.substr(first.length()).strip_edges()
		if _STAT_LABELS.has(first):
			var label2: String = _STAT_LABELS[first]
			return "• " + label2 + " " + rest

	# Fallback: just bullet the original
	return "• " + raw_line.strip_edges()

# -------------------------------------------------------

func _ready() -> void:
	_tabs = get_node_or_null(bag_tabs_row_path) as BagTabsRow
	_grid = get_node_or_null(grid_path) as InventoryGridView
	_desc_name = get_node_or_null(desc_name_path) as Label
	_desc_qty = get_node_or_null(desc_qty_path) as Label
	_desc_text = get_node_or_null(desc_text_path) as RichTextLabel
	_portrait_cluster = get_node_or_null(portrait_cluster_path)

	# Self-heal: older scenes may still have ../DescriptionPane/ItemDesc
	if _desc_text == null:
		var try_path: NodePath = ^"../DescriptionPane/ItemDesc"
		var n: Node = get_node_or_null(try_path)
		if n is RichTextLabel:
			_desc_text = n as RichTextLabel

	# Make sure the text fills the pane nicely (prevents center scrollbar)
	if _desc_text != null:
		_desc_text.set_anchors_preset(Control.PRESET_FULL_RECT)
		_desc_text.offset_left = 8.0
		_desc_text.offset_top = 18.0
		_desc_text.offset_right = -8.0
		_desc_text.offset_bottom = -8.0
		_desc_text.selection_enabled = false
		_desc_text.bbcode_enabled = false
		_desc_text.fit_content = false
		_desc_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

		# Style the scrollbar once; visibility handled by _update_desc_scrollbar()
		_apply_desc_scroll_style()
		# Track resizes so Auto mode stays correct when the panel size changes
		if not _desc_text.resized.is_connected(_on_desc_resized):
			_desc_text.resized.connect(_on_desc_resized)

	_resolve_inventory_singleton()
	_resolve_party_singleton()

	if _tabs != null:
		if not _tabs.bag_changed.is_connected(_on_bag_changed):
			_tabs.bag_changed.connect(_on_bag_changed)
		if not _tabs.tab_pressed_locked.is_connected(_on_tab_locked_pressed):
			_tabs.tab_pressed_locked.connect(_on_tab_locked_pressed)

	if _grid != null:
		# Selection changes always update description.
		if not _grid.selection_changed.is_connected(_on_grid_selection_changed):
			_grid.selection_changed.connect(_on_grid_selection_changed)
		# CLICK = VIEW ONLY
		if not _grid.activated.is_connected(_on_grid_activated):
			_grid.activated.connect(_on_grid_activated)
		_grid.set_selected_index(0)

	# Hook equipment slots so clicks on equipped items update the description pane.
	_connect_equipment_slots()

	# Refresh when inventory changes.
	if _inv != null and _inv.has_signal("inventory_changed"):
		(_inv as Node).connect("inventory_changed", Callable(self, "_on_inventory_changed"))

	var active_index: int = 0
	if _tabs != null:
		active_index = _tabs.get_active()

	_refresh_tab(active_index)
	_update_description_for_slot(active_index, 0)

func _resolve_inventory_singleton() -> void:
	var n: Node = get_node_or_null("/root/InventorySystem")
	if n == null:
		n = get_node_or_null("/root/InventorySys")
	_inv = n

func _resolve_party_singleton() -> void:
	var pm: Node = get_node_or_null("/root/PartyManager")
	if pm == null:
		pm = get_tree().get_first_node_in_group("PartyManager")
	_party = pm

func _connect_equipment_slots() -> void:
	if _portrait_cluster == null:
		return
	var stack: Array[Node] = [_portrait_cluster]
	while stack.size() > 0:
		var n: Node = stack.pop_back()
		for child in n.get_children():
			stack.push_back(child)
		if n is EquipmentSlot:
			var es: EquipmentSlot = n as EquipmentSlot
			if not es.slot_selected.is_connected(_on_equipment_slot_selected):
				es.slot_selected.connect(_on_equipment_slot_selected)

func _on_equipment_slot_selected(slot_name: String, item: ItemDef) -> void:
	_update_description_for_equipped(slot_name, item)

func _on_inventory_changed() -> void:
	var active_index: int = 0
	if _tabs != null:
		active_index = _tabs.get_active()
	_refresh_tab(active_index)
	var sel: int = 0
	if _grid != null:
		sel = _grid.get_selected_index()
	_update_description_for_slot(active_index, sel)

func _on_bag_changed(tab_index: int) -> void:
	_refresh_tab(tab_index)
	if _grid != null:
		_grid.set_selected_index(0)
	_update_description_for_slot(tab_index, 0)

func _on_tab_locked_pressed(index: int) -> void:
	_update_locked_description(index)

func _on_grid_selection_changed(index: int) -> void:
	var active_index: int = 0
	if _tabs != null:
		active_index = _tabs.get_active()
	_update_description_for_slot(active_index, index)

func _on_grid_activated(index: int) -> void:
	# CLICK = VIEW ONLY
	var active_index: int = 0
	if _tabs != null:
		active_index = _tabs.get_active()
	_update_description_for_slot(active_index, index)

func _get_controlled_actor() -> Node:
	if _party != null and _party.has_method("get_controlled"):
		var v: Variant = _party.call("get_controlled")
		if v is Node:
			return v
	return self

func _refresh_tab(tab_index: int) -> void:
	if _grid == null:
		return

	var grid_total_slots: int = _grid.cols * _grid.rows
	var sys_total: int = grid_total_slots
	var sys_unlocked: int = 0

	if debug_override_unlocked >= 0:
		sys_unlocked = clampi(debug_override_unlocked, 0, grid_total_slots)
	else:
		if tab_index >= 0 and tab_index < unlocked_by_tab.size():
			sys_unlocked = clampi(unlocked_by_tab[tab_index], 0, grid_total_slots)
		else:
			sys_unlocked = 0

	_grid.set_capacity(sys_unlocked, sys_total)

func _update_locked_description(tab_index: int) -> void:
	var label: String = "Bag " + str(tab_index + 1)
	if tab_index == 5:
		label = "Key Items"
	if _desc_name != null:
		_desc_name.text = "(Locked)"
	if _desc_qty != null:
		_desc_qty.text = ""
	if _desc_text != null:
		_desc_text.text = label + " — Locked"
	_update_desc_scrollbar()

func _update_description_for_slot(tab_index: int, slot_index: int) -> void:
	var grid_total: int = 0
	if _grid != null:
		grid_total = _grid.cols * _grid.rows
	var unlocked: int = 0
	if tab_index >= 0 and tab_index < unlocked_by_tab.size():
		unlocked = clampi(unlocked_by_tab[tab_index], 0, grid_total)

	var bag_label: String = "Bag " + str(tab_index + 1)
	if tab_index == 5:
		bag_label = "Key Items"

	if slot_index < 0 or slot_index >= unlocked:
		if _desc_name != null:
			_desc_name.text = "(Locked)"
		if _desc_qty != null:
			_desc_qty.text = ""
		if _desc_text != null:
			_desc_text.text = bag_label + " — Locked"
		_update_desc_scrollbar()
		return

	if _inv == null or not _inv.has_method("get_item_summary_for_slot"):
		if _desc_name != null:
			_desc_name.text = "(Empty Slot)"
		if _desc_qty != null:
			_desc_qty.text = ""
		if _desc_text != null:
			_desc_text.text = bag_label + " — Empty"
		_update_desc_scrollbar()
		return

	var d_v: Variant = _inv.call("get_item_summary_for_slot", slot_index)

	var has_item: bool = false
	var item_name: String = ""
	var qty: int = 0
	var item_desc: String = ""
	var stat_lines: Array[String] = []

	if typeof(d_v) == TYPE_DICTIONARY:
		var d: Dictionary = d_v
		has_item = bool(d.get("has_item", false))
		item_name = String(d.get("name", ""))
		qty = int(d.get("qty", 0))
		item_desc = String(d.get("desc", ""))  # InventorySys may now pass ItemDef.description here
		if d.has("stats"):
			var raw_stats: Array = d["stats"]
			var i: int = 0
			while i < raw_stats.size():
				stat_lines.append(String(raw_stats[i]))
				i += 1

	if has_item:
		_show_item_description_with_stats(item_name, qty, item_desc, bag_label, stat_lines)
	else:
		if _desc_name != null:
			_desc_name.text = "(Empty Slot)"
		if _desc_qty != null:
			_desc_qty.text = ""
		if _desc_text != null:
			_desc_text.text = bag_label + " — Empty"
		_update_desc_scrollbar()

func _show_item_description(item_name: String, qty: int, item_desc: String, bag_label: String) -> void:
	if _desc_name != null:
		_desc_name.text = item_name
	if _desc_qty != null:
		if qty > 1:
			_desc_qty.text = "x" + str(qty)
		else:
			_desc_qty.text = ""
	if _desc_text != null:
		# Only show the bag header if there IS a description to pair with it.
		if item_desc != "":
			_desc_text.text = item_desc
		else:
			_desc_text.text = ""  # intentionally blank when no description
	_update_desc_scrollbar()

func _show_item_description_with_stats(item_name: String, qty: int, item_desc: String, header_label: String, stat_lines: Array[String]) -> void:
	if _desc_name != null:
		_desc_name.text = item_name
	if _desc_qty != null:
		if qty > 1:
			_desc_qty.text = "x" + str(qty)
		else:
			_desc_qty.text = ""
	if _desc_text != null:
		var body_lines: Array[String] = []

		# If there is a description, put it first. If not, skip the old "Bag — (No description)" line.
		if item_desc != "":
			body_lines.append(item_desc.strip_edges())

		# Append normalized stat lines
		if stat_lines.size() > 0:
			var i: int = 0
			while i < stat_lines.size():
				var pretty: String = _normalize_stat_line(String(stat_lines[i]))
				body_lines.append(pretty)
				i += 1

		_desc_text.text = "\n".join(body_lines)
	_update_desc_scrollbar()

# --- Equipment description path ---

func _update_description_for_equipped(slot_name: String, item: ItemDef) -> void:
	var label: String = "Equipped — " + String(slot_name).capitalize()
	if item == null:
		if _desc_name != null:
			_desc_name.text = "(Nothing Equipped)"
		if _desc_qty != null:
			_desc_qty.text = ""
		if _desc_text != null:
			_desc_text.text = label + " — Empty"
		_update_desc_scrollbar()
		return

	var item_name: String = ""
	var item_desc: String = ""
	if "display_name" in item:
		item_name = String(item.display_name)
	elif "name" in item:
		item_name = String(item.name)
	else:
		item_name = String(item.get_class())

	# Prefer ItemDef.description if present
	if "description" in item and String(item.description) != "":
		item_desc = String(item.description)

	var stats: Array[String] = []
	if item.has_method("get_stat_modifiers"):
		var mods: Array = item.call("get_stat_modifiers")
		var i: int = 0
		while i < mods.size():
			var m_v: Variant = mods[i]
			var line: String = ""
			if m_v is StatModifier:
				var m: StatModifier = m_v
				if m.apply_override:
					line = String(m.stat_name) + " = " + str(m.override_value)
				else:
					var parts: Array[String] = []
					if abs(m.add_value) > 0.0:
						var sign: String = "+"
						if m.add_value < 0.0:
							sign = ""
						parts.append(sign + str(int(m.add_value)) + " " + String(m.stat_name))
					if abs(m.mul_value - 1.0) > 0.0001:
						var mult_val: float = round(m.mul_value * 100.0) / 100.0
						parts.append("×" + str(mult_val) + " " + String(m.stat_name))
					line = ", ".join(parts)
			elif typeof(m_v) == TYPE_DICTIONARY:
				var d2: Dictionary = m_v
				var sname: String = String(d2.get("stat_name", ""))
				var addv: float = float(d2.get("add_value", 0.0))
				var mulv: float = float(d2.get("mul_value", 1.0))
				var ovrd: bool = bool(d2.get("apply_override", false))
				var ovv: float = float(d2.get("override_value", 0.0))
				if ovrd:
					line = sname + " = " + str(ovv)
				else:
					var parts2: Array[String] = []
					if abs(addv) > 0.0:
						var sign2: String = "+"
						if addv < 0.0:
							sign2 = ""
						parts2.append(sign2 + str(int(addv)) + " " + sname)
					if abs(mulv - 1.0) > 0.0001:
						var mult_val2: float = round(mulv * 100.0) / 100.0
						parts2.append("×" + str(mult_val2) + " " + sname)
					line = ", ".join(parts2)
			if String(line) != "":
				stats.append(line)
			i += 1

	_show_item_description_with_stats(item_name, 1, item_desc, label, stats)

# ----------- Scrollbar logic & styling (ItemDescription) -----------

func _on_desc_resized() -> void:
	_update_desc_scrollbar()

func _update_desc_scrollbar() -> void:
	if _desc_text == null:
		return

	if desc_scroll_mode == ScrollMode.ALWAYS_OFF:
		_desc_text.scroll_active = false
		return

	if desc_scroll_mode == ScrollMode.ALWAYS_ON:
		_desc_text.scroll_active = true
		return

	# AUTO: enable only when content exceeds the visible height
	var content_h: float = float(_desc_text.get_content_height())
	var visible_h: float = _desc_text.size.y
	if content_h > visible_h + 1.0:
		_desc_text.scroll_active = true
	else:
		_desc_text.scroll_active = false

func _apply_desc_scroll_style() -> void:
	var vscroll: VScrollBar = _get_desc_vscroll()
	if vscroll == null:
		return

	# Width / size
	vscroll.custom_minimum_size = Vector2(float(desc_scroll_width), 0.0)

	# Track (background rail)
	var track: StyleBoxFlat = StyleBoxFlat.new()
	track.bg_color = desc_scroll_track_color
	_set_round_corners(track, desc_scroll_corner_radius)
	vscroll.add_theme_stylebox_override("scroll", track)

	# Grabber (handle)
	var grab: StyleBoxFlat = StyleBoxFlat.new()
	grab.bg_color = desc_scroll_grabber_color
	grab.border_color = desc_scroll_grabber_color.darkened(0.25)
	grab.border_width_all = 1
	_set_round_corners(grab, desc_scroll_corner_radius)
	vscroll.add_theme_stylebox_override("grabber", grab)

	var grab_h: StyleBoxFlat = grab.duplicate() as StyleBoxFlat
	grab_h.bg_color = desc_scroll_grabber_color.lightened(0.15)
	vscroll.add_theme_stylebox_override("grabber_highlight", grab_h)

	var grab_p: StyleBoxFlat = grab.duplicate() as StyleBoxFlat
	grab_p.bg_color = desc_scroll_grabber_color.darkened(0.15)
	vscroll.add_theme_stylebox_override("grabber_pressed", grab_p)

	# Keep the handle usable on long texts
	vscroll.add_theme_constant_override("minimum_grab_size", 10)

func _get_desc_vscroll() -> VScrollBar:
	if _desc_text == null:
		return null
	if _desc_text.has_method("get_v_scroll"):
		var vs: Variant = _desc_text.call("get_v_scroll")
		if vs is VScrollBar:
			return vs as VScrollBar
	return null

func _set_round_corners(sb: StyleBoxFlat, r: int) -> void:
	sb.corner_radius_top_left = r
	sb.corner_radius_top_right = r
	sb.corner_radius_bottom_left = r
	sb.corner_radius_bottom_right = r
