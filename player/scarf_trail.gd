extends MeshInstance3D

## World-space length the scarf traces behind the character.
@export_range(0.5, 20.0, 0.1) var trail_distance: float = 5.0
## Ribbon width at the base (near the character).
@export_range(0.01, 0.5, 0.01) var trail_width: float = 0.15
## Maximum stored sample points — higher is smoother but costs more.
@export_range(4, 128) var max_points: int = 64
## Minimum world distance between consecutive samples.
@export_range(0.005, 0.3, 0.005) var min_step: float = 0.04
## Drag the Skeleton3D here and set bone_name to track a bone directly.
@export var bone_skeleton: Skeleton3D
@export var bone_name: StringName = &""
## Fallback: any Node3D to follow. Used when skeleton/bone_name are not set.
## Defaults to parent if also unset.
@export var target: Node3D

const _SHADER := preload("res://player/scarf_trail.gdshader")

var _pts: Array[Vector3] = []
var _arr_mesh := ArrayMesh.new()

func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _arr_mesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if not bone_skeleton and not target:
		target = get_parent() as Node3D
	var mat := ShaderMaterial.new()
	mat.shader = _SHADER
	material_override = mat

## Call this on teleport / respawn to avoid a visual streak.
func clear_trail() -> void:
	_pts.clear()
	_arr_mesh.clear_surfaces()

func _process(_delta: float) -> void:
	global_transform = Transform3D.IDENTITY

	var head: Vector3
	if bone_skeleton and bone_name:
		var bi := bone_skeleton.find_bone(bone_name)
		if bi < 0:
			return
		head = (bone_skeleton.global_transform * bone_skeleton.get_bone_global_pose(bi)).origin
	elif is_instance_valid(target):
		head = target.global_position
	else:
		return
	if _pts.is_empty() or head.distance_to(_pts.back()) >= min_step:
		_pts.append(head)

	_trim()
	_rebuild()

func _trim() -> void:
	while _pts.size() > max_points:
		_pts.pop_front()
	if _pts.size() < 2:
		return
	# Remove oldest points that push the total length past trail_distance.
	var total := _arc_len()
	while total > trail_distance and _pts.size() > 2:
		total -= _pts[0].distance_to(_pts[1])
		_pts.pop_front()

func _arc_len() -> float:
	var d := 0.0
	for i in range(1, _pts.size()):
		d += _pts[i - 1].distance_to(_pts[i])
	return d

func _rebuild() -> void:
	_arr_mesh.clear_surfaces()
	var n := _pts.size()
	if n < 2:
		return

	# Cumulative arc-length from _pts[0] (tip / oldest) to _pts[n-1] (base / newest).
	var cum := PackedFloat32Array()
	cum.resize(n)
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + _pts[i - 1].distance_to(_pts[i])
	var total: float = cum[n - 1]
	if total < 1e-5:
		return

	var verts := PackedVector3Array()
	var uvs   := PackedVector2Array()
	var norms  := PackedVector3Array()
	var idxs   := PackedInt32Array()

	for i in range(n):
		# UV.x: 0 at base (newest, attached to character), 1 at tip (oldest, free end).
		var t := 1.0 - cum[i] / total

		# Tangent along the trail at this sample.
		var tang: Vector3
		if i == 0:
			tang = (_pts[1] - _pts[0]).normalized()
		elif i == n - 1:
			tang = (_pts[n - 1] - _pts[n - 2]).normalized()
		else:
			tang = (_pts[i + 1] - _pts[i - 1]).normalized()
		if tang.length_squared() < 1e-6:
			tang = Vector3.FORWARD

		# Stable ribbon frame: right perpendicular to the trail in the horizontal plane.
		var world_up := Vector3.UP
		if abs(tang.dot(world_up)) > 0.9:
			world_up = Vector3.BACK
		var right  := tang.cross(world_up).normalized()
		# Normal points "up" out of the ribbon surface.
		var normal := tang.cross(right)

		var half := trail_width * 0.5

		verts.append(_pts[i] + right * half)
		verts.append(_pts[i] - right * half)
		uvs.append(Vector2(t, 0.0))
		uvs.append(Vector2(t, 1.0))
		norms.append(normal)
		norms.append(normal)

		if i < n - 1:
			var b := i * 2
			idxs.append_array([b, b + 2, b + 1, b + 1, b + 2, b + 3])

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX]  = idxs
	_arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
