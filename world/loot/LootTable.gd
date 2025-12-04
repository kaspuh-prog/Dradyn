extends Resource
class_name LootTable

@export var rolls: int = 1
@export var allow_duplicates: bool = true
@export var entries: Array[LootEntry] = []

# NEW — table-level currency settings
@export_range(0.0, 100.0, 0.1) var currency_percent_chance: float = 0.0
@export var currency_min: int = 0
@export var currency_max: int = 0

@export var verbose_debug: bool = false

func pick(rng: RandomNumberGenerator) -> Array[Dictionary]:
	var results: Array[Dictionary] = []

	# ---- Item rolls ----
	if entries.is_empty():
		if verbose_debug:
			print_debug("[LootTable] No item entries.")
	else:
		var pool: Array[LootEntry] = entries.duplicate()
		var r: int = 0
		while r < rolls and not pool.is_empty():
			var choice: LootEntry = _pick_one(rng, pool)
			if choice == null:
				if verbose_debug:
					print_debug("[LootTable] Roll ", str(r), ": no candidate passed gate.")
				break

			if choice.is_valid_item_entry():
				var qty: int = choice.get_random_qty(rng)
				if qty > 0:
					var item: Dictionary = {
						"type": "item",
						"id": choice.id,
						"item_def": choice.item_def,
						"quantity": qty
					}
					results.append(item)
					if verbose_debug:
						print_debug("[LootTable] Picked ITEM id=", choice.id, " qty=", str(qty), " def=", str(choice.item_def))
			else:
				if verbose_debug:
					print_debug("[LootTable] Picked entry invalid. id=", choice.id)

			if not allow_duplicates:
				pool.erase(choice)
			r += 1

	# ---- Currency roll (once per chest) ----
	var will_try_currency: bool = currency_percent_chance > 0.0
	if will_try_currency:
		var roll_val: float = rng.randf() * 100.0
		var pass_roll: bool = roll_val < currency_percent_chance
		if verbose_debug:
			print_debug(
				"[LootTable] Currency gate roll=", _fmt2(roll_val), "%  chance=",
				_fmt2(currency_percent_chance), "%  pass=", str(pass_roll)
			)
		if pass_roll:
			var amount: int = _roll_currency_amount(rng)
			if amount > 0:
				results.append({
					"type": "currency",
					"amount": amount
				})
				if verbose_debug:
					print_debug("[LootTable] Currency awarded amount=", str(amount))

	return results

func _roll_currency_amount(rng: RandomNumberGenerator) -> int:
	var lo: int = currency_min
	var hi: int = currency_max
	if hi < lo:
		hi = lo
	if hi <= 0 and lo <= 0:
		return 0
	return rng.randi_range(lo, hi)

func _pick_one(rng: RandomNumberGenerator, pool: Array[LootEntry]) -> LootEntry:
	# Gate by percent_chance (100.0 means always pass)
	var candidates: Array[LootEntry] = []
	var i: int = 0
	while i < pool.size():
		var e: LootEntry = pool[i]
		var roll_val: float = rng.randf() * 100.0
		var pass_roll: bool = roll_val < e.percent_chance
		if pass_roll:
			candidates.append(e)
		if verbose_debug:
			print_debug(
				"[LootTable] Gate id=", e.id,
				" roll=", _fmt2(roll_val), "% ",
				"chance=", _fmt2(e.percent_chance), "% ",
				"pass=", str(pass_roll)
			)
		i += 1

	if candidates.is_empty():
		return null

	# Weighted choice
	var total_weight: float = 0.0
	var j: int = 0
	while j < candidates.size():
		var w: float = candidates[j].weight
		if w < 0.0:
			w = 0.0
		total_weight += w
		j += 1

	if total_weight <= 0.0:
		if verbose_debug:
			print_debug("[LootTable] All candidate weights <= 0.")
		return null

	var target: float = rng.randf() * total_weight
	var accum: float = 0.0
	var k: int = 0
	while k < candidates.size():
		var w2: float = candidates[k].weight
		if w2 < 0.0:
			w2 = 0.0
		accum += w2
		if target <= accum:
			if verbose_debug:
				print_debug(
					"[LootTable] target=", _fmt3(target),
					" / total=", _fmt3(total_weight),
					" → PICK id=", candidates[k].id
				)
			return candidates[k]
		k += 1

	# Extremely rare float overshoot: clamp to last
	if verbose_debug:
		print_debug("[LootTable] target overshoot; clamping to last candidate.")
	return candidates.back()

# -----------------
# Helpers
# -----------------
func _fmt2(v: float) -> String:
	var rounded: float = round(v * 100.0) / 100.0
	return str(rounded)

func _fmt3(v: float) -> String:
	var rounded: float = round(v * 1000.0) / 1000.0
	return str(rounded)
