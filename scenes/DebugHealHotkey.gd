extends Node

# Press F6 to force-cast "heal" on the current controlled actor (or on the first Party member).
# Prints what it tries, so we can see if the call reaches AbilitySystem + handler.

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F6:
		var as_node: Node = get_tree().get_root().get_node_or_null("AbilitySystem")
		if as_node == null:
			printerr("[DBG-HEAL] AbilitySystem autoload not found.")
			return

		# Try get the controlled/leader, else first party member, else this node’s parent.
		var target_actor: Node = null
		var pm: Node = get_tree().get_first_node_in_group("PartyManager")
		if pm != null and pm.has_method("get_controlled"):
			target_actor = pm.call("get_controlled")
		if target_actor == null:
			if pm != null and pm.has_method("get_members"):
				var members: Array = pm.call("get_members")
				if typeof(members) == TYPE_ARRAY and members.size() > 0:
					target_actor = members[0]
		if target_actor == null:
			target_actor = get_parent()

		if target_actor == null:
			printerr("[DBG-HEAL] No actor found to test heal on.")
			return

		print_rich("[DBG-HEAL] requesting heal on: ", str(target_actor))
		var ok_any: Variant = as_node.call("request_cast", target_actor, "heal", {"target": target_actor})
		if typeof(ok_any) == TYPE_BOOL and ok_any:
			print_rich("[DBG-HEAL] request_cast returned TRUE (handler accepted).")
		else:
			print_rich("[DBG-HEAL] request_cast returned FALSE (blocked or no handler).")
