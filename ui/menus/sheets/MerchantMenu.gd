extends Control
class_name MerchantMenu

signal transaction_confirmed(mode: int, item: ItemDef, quantity: int, unit_price: int)
signal transaction_cancelled(mode: int, item: ItemDef, quantity: int, unit_price: int)
signal mode_changed(mode: int)

enum Mode {
	BUY,
	SELL,
	SPECIAL
}

# -------------------------
# State
# -------------------------
var _mode: int = Mode.BUY
var _current_item: ItemDef = null
var _current_stock: int = 0
var _unit_price: int = 0
var _quantity: int = 1

var _confirm_default_text: String = ""
var _cancel_default_text: String = ""

# -------------------------
# Node refs (wired to your layout)
# -------------------------
@onready var _tabs_row: Control = $BG/TabsRow
@onready var _tab_buy: BaseButton = $BG/TabsRow/Tab_Buy
@onready var _tab_sell: BaseButton = $BG/TabsRow/Tab_Sell
@onready var _tab_extra: BaseButton = $BG/TabsRow/Tab_Extra
@onready var _extra_label: Label = $BG/TabsRow/Tab_Extra/Extra_Label

@onready var _grid: MerchantGridView = $BG/MerchantGrid

@onready var _item_name: Label = $BG/DescriptionPane/ItemName
@onready var _stock_qty: Label = $BG/DescriptionPane/StockQty
@onready var _item_desc: RichTextLabel = $BG/DescriptionPane/ItemDescription
@onready var _purchase_prompt: Label = $BG/DescriptionPane/PurchasePrompt

@onready var _qty_up: BaseButton = $BG/BottomControls/QtyUp
@onready var _qty_down: BaseButton = $BG/BottomControls/QtyDown
@onready var _qty_label: Label = $BG/BottomControls/QtyField/QtyLabel
@onready var _confirm_button: BaseButton = $BG/BottomControls/ConfirmButton
@onready var _cancel_button: BaseButton = $BG/BottomControls/CancelButton
@onready var _confirm_label: Label = $BG/BottomControls/ConfirmButton/ConfirmLabel
@onready var _cancel_label: Label = $BG/BottomControls/CancelButton/ConfirmLabel

@onready var _gold_label: Label = $BG/CurrencyBar/GoldLabel


func _ready() -> void:
	_wire_tabs()
	_wire_quantity_buttons()
	_wire_confirm_cancel()
	_configure_prompt_label()
	_cache_default_button_texts()
	_clear_ui()
	_update_button_labels()


# -------------------------
# Public API
# -------------------------

func get_grid() -> MerchantGridView:
	return _grid

func get_mode() -> int:
	return _mode

func get_current_item() -> ItemDef:
	return _current_item

func set_mode(mode: int) -> void:
	_mode = mode
	_update_tab_states()
	_update_button_labels()
	_update_prompt_text()
	mode_changed.emit(_mode)

func clear_selection() -> void:
	_current_item = null
	_current_stock = 0
	_unit_price = 0
	_quantity = 1
	_clear_ui()

func show_item(item: ItemDef, current_stock: int, unit_price: int, quantity: int = 1) -> void:
	_current_item = item

	if current_stock < 0:
		_current_stock = 0
	else:
		_current_stock = current_stock

	if unit_price < 0:
		_unit_price = 0
	else:
		_unit_price = unit_price

	if quantity < 1:
		_quantity = 1
	else:
		_quantity = quantity

	_update_ui()

func set_quantity(quantity: int) -> void:
	if quantity < 1:
		quantity = 1
	_quantity = quantity
	_update_quantity_ui()
	_update_prompt_text()

func set_gold_amount(amount: int) -> void:
	if _gold_label != null:
		_gold_label.text = str(amount) + "g"

## SPECIAL / Alchemy helpers

func set_special_prompt(text: String) -> void:
	# Used by MerchantController in SPECIAL mode for the alchemy requirements text.
	if _purchase_prompt != null:
		_purchase_prompt.text = text

func set_special_tab_label(text: String) -> void:
	# Allows the controller to rename the 3rd tab (e.g. "Extra" -> "Alchemy").
	if _extra_label != null:
		_extra_label.text = text


# -------------------------
# Internal wiring
# -------------------------

func _wire_tabs() -> void:
	if _tab_buy != null:
		_tab_buy.pressed.connect(_on_tab_buy_pressed)
	if _tab_sell != null:
		_tab_sell.pressed.connect(_on_tab_sell_pressed)
	if _tab_extra != null:
		_tab_extra.pressed.connect(_on_tab_extra_pressed)

func _wire_quantity_buttons() -> void:
	if _qty_up != null:
		_qty_up.pressed.connect(_on_qty_up_pressed)
	if _qty_down != null:
		_qty_down.pressed.connect(_on_qty_down_pressed)

func _wire_confirm_cancel() -> void:
	if _confirm_button != null:
		_confirm_button.pressed.connect(_on_confirm_pressed)
	if _cancel_button != null:
		_cancel_button.pressed.connect(_on_cancel_pressed)

func _configure_prompt_label() -> void:
	# Keep requirements/prompt text inside the DescBG and wrap nicely.
	if _purchase_prompt != null:
		_purchase_prompt.autowrap_mode = TextServer.AUTOWRAP_WORD
		_purchase_prompt.clip_text = true

func _cache_default_button_texts() -> void:
	if _confirm_label != null:
		_confirm_default_text = _confirm_label.text
	if _cancel_label != null:
		_cancel_default_text = _cancel_label.text

func _update_button_labels() -> void:
	if _confirm_label != null:
		if _mode == Mode.SPECIAL:
			_confirm_label.text = "Unlock"
		else:
			_confirm_label.text = _confirm_default_text

	if _cancel_label != null:
		if _mode == Mode.SPECIAL:
			_cancel_label.text = "Exit"
		else:
			_cancel_label.text = _cancel_default_text


# -------------------------
# UI updates
# -------------------------

func _clear_ui() -> void:
	if _item_name != null:
		_item_name.text = ""
	if _stock_qty != null:
		_stock_qty.text = ""
	if _item_desc != null:
		_item_desc.text = ""
	if _purchase_prompt != null:
		_purchase_prompt.text = ""
	if _qty_label != null:
		_qty_label.text = "1"

func _update_ui() -> void:
	if _current_item == null:
		_clear_ui()
		return

	_update_name_and_stock()
	_update_description()
	_update_quantity_ui()
	_update_prompt_text()

func _update_name_and_stock() -> void:
	if _item_name != null:
		var name_text: String = ""
		if _current_item.display_name != "":
			name_text = _current_item.display_name
		else:
			name_text = String(_current_item.id)
		_item_name.text = name_text

	if _stock_qty != null:
		var stock_text: String = "Current: " + str(_current_stock)
		_stock_qty.text = stock_text

func _update_description() -> void:
	if _item_desc == null:
		return

	if _current_item == null:
		_item_desc.text = ""
		return

	var desc_text: String = _current_item.description
	_item_desc.text = desc_text

func _update_quantity_ui() -> void:
	if _qty_label != null:
		_qty_label.text = str(_quantity)

func _update_prompt_text() -> void:
	if _purchase_prompt == null:
		return

	if _current_item == null:
		_purchase_prompt.text = ""
		return

	if _mode == Mode.SPECIAL:
		# In SPECIAL mode (alchemy), the controller will push a custom multi-line
		# requirements string via set_special_prompt(), so we do not overwrite it here.
		return

	var total_price: int = _unit_price * _quantity
	var base_text: String = ""

	if _mode == Mode.BUY:
		base_text = "That will be " + str(total_price) + "g. Buy it?"
	elif _mode == Mode.SELL:
		base_text = "I can give you " + str(total_price) + "g. Sell it?"
	else:
		base_text = ""

	_purchase_prompt.text = base_text

func _update_tab_states() -> void:
	if _tab_buy != null:
		_tab_buy.set_pressed_no_signal(_mode == Mode.BUY)
	if _tab_sell != null:
		_tab_sell.set_pressed_no_signal(_mode == Mode.SELL)
	if _tab_extra != null:
		_tab_extra.set_pressed_no_signal(_mode == Mode.SPECIAL)


# -------------------------
# Button callbacks
# -------------------------

func _on_tab_buy_pressed() -> void:
	set_mode(Mode.BUY)

func _on_tab_sell_pressed() -> void:
	set_mode(Mode.SELL)

func _on_tab_extra_pressed() -> void:
	set_mode(Mode.SPECIAL)

func _on_qty_up_pressed() -> void:
	var new_quantity: int = _quantity + 1
	set_quantity(new_quantity)

func _on_qty_down_pressed() -> void:
	var new_quantity: int = _quantity - 1
	if new_quantity < 1:
		new_quantity = 1
	set_quantity(new_quantity)

func _on_confirm_pressed() -> void:
	if _current_item == null:
		return
	transaction_confirmed.emit(_mode, _current_item, _quantity, _unit_price)

func _on_cancel_pressed() -> void:
	if _current_item == null:
		return
	transaction_cancelled.emit(_mode, _current_item, _quantity, _unit_price)
