extends Resource
class_name StatusApplySpec
# Godot 4.5 — fully typed, no ternaries.
# Describes a chance to apply a status to the resolved target of an ability.

# --------------------------------------------------
# Identity & basic application
# --------------------------------------------------
@export var status_id: StringName = &""        # e.g., &"burning", &"poisoned"
@export_range(0.0, 1.0, 0.01) var chance: float = 1.0
@export var duration_sec: float = 0.0          # <= 0.0 => infinite duration
@export var stacks: int = 1                    # >= 1

# --------------------------------------------------
# Structured payload fields (replaces generic Dictionary payload)
# These are read by the executor and forwarded to StatusConditions.apply(...)
# as a Dictionary payload it builds internally.
# --------------------------------------------------

# Optional visual hint color for status pop / UI tint (alpha 0 means "unused").
@export var color: Color = Color(0, 0, 0, 0)

# Generic numeric strength for the status. Interpretation is status-specific
# (e.g., DoT/HoT per-tick amount, buff magnitude, slow strength).
@export var magnitude: float = 0.0

# Rare escape hatch for edge cases. Avoid for normal content.
# Keys here will be shallow-merged into the payload last.
@export var extra: Dictionary = {}
