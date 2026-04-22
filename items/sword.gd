extends Node3D

var _pickup_enabled := true

func _ready() -> void:
	_build_visuals()
	_setup_pickup_area()

func _build_visuals() -> void:
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.82, 0.86, 0.92)
	metal.metallic = 0.9
	metal.roughness = 0.12

	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.75, 0.58, 0.18)
	gold.metallic = 0.85
	gold.roughness = 0.25

	var blade := MeshInstance3D.new()
	var blade_mesh := BoxMesh.new()
	blade_mesh.size = Vector3(0.04, 0.68, 0.012)
	blade.mesh = blade_mesh
	blade.position = Vector3(0.0, 0.34, 0.0)
	blade.set_surface_override_material(0, metal)
	add_child(blade)

	var guard := MeshInstance3D.new()
	var guard_mesh := BoxMesh.new()
	guard_mesh.size = Vector3(0.22, 0.035, 0.035)
	guard.mesh = guard_mesh
	guard.set_surface_override_material(0, gold)
	add_child(guard)

	var handle := MeshInstance3D.new()
	var handle_mesh := BoxMesh.new()
	handle_mesh.size = Vector3(0.03, 0.20, 0.03)
	handle.mesh = handle_mesh
	handle.position = Vector3(0.0, -0.13, 0.0)
	handle.set_surface_override_material(0, gold)
	add_child(handle)

func _setup_pickup_area() -> void:
	var area := Area3D.new()
	area.name = "PickupArea"
	var col := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.9
	col.shape = sphere
	area.add_child(col)
	area.body_entered.connect(_on_body_entered)
	add_child(area)

func _on_body_entered(body: Node3D) -> void:
	if _pickup_enabled and body.has_method("try_pickup"):
		body.try_pickup(self)

func disable_pickup() -> void:
	_pickup_enabled = false
	var area := get_node_or_null("PickupArea")
	if area:
		area.monitoring = false
		area.monitorable = false
