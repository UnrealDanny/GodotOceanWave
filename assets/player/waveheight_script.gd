@tool
extends MeshInstance3D

@export var water : Node3D

func _physics_process(_delta: float) -> void:
	# 1. SAFETY: Stop if no water node is assigned in the Inspector
	if not water:
		return
		
	# 2. SAFETY: Stop if the assigned node doesn't have the height function
	if not water.has_method("get_height"):
		return

	# 3. Apply the height
	global_position.y = water.get_height(global_position)
