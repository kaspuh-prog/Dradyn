extends Node
class_name AbilitySuiteBootstrap

func _ready() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	var root := tree.get_root()
	if root == null:
		return
	var suite_node: Node = root.get_node_or_null("Suite")
	if suite_node != null and suite_node.has_method("is_suite_enabled"):
		var on_any: Variant = suite_node.call("is_suite_enabled")
		var on_flag: bool = false
		if typeof(on_any) == TYPE_BOOL:
			on_flag = bool(on_any)
		print("[Bootstrap] Suite.enabled=", on_flag)
