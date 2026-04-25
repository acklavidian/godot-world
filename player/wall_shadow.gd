extends Node3D
## Projects a pose-accurate silhouette of the character onto the wall while wall-pressed,
## and dissolves the player mesh in/out with a smoky burn effect.

# ── tunables ──────────────────────────────────────────────────────────────
const DISSOLVE_SPEED := 1.6
const DISSOLVE_MAX   := 1.1   # slightly past 1 to guarantee full discard

const ORTHO_SIZE := 2.2       # orthographic camera view height (metres)
const CAM_Z_DIST := 3.0       # camera offset behind the silhouette in viewport world
const CAM_Y      := 0.9       # camera vertical centre (feet=0, head≈1.8)

const QUAD_W   := 1.89   # scaled with viewport width (384 px) to preserve character proportions
const QUAD_H   := 2.16
const WALL_GAP := 0.03   # offset in front of wall surface to prevent z-fighting

const _DISSOLVE_SHADER := preload("res://player/dissolve.gdshader")
const _SHADOW_SHADER   := preload("res://player/wall_shadow_proj.gdshader")

# ── state machine ─────────────────────────────────────────────────────────
enum _S { IDLE, ENTERING, PRESSED, EXITING }
var _state := _S.IDLE

var _dissolve     := 0.0
var _shadow_alpha := 0.0

# ── scene nodes ───────────────────────────────────────────────────────────
var _viewport:  SubViewport
var _sil_cam:   Camera3D
var _wall_quad: MeshInstance3D
var _wall_mat:  ShaderMaterial

# ── character refs ────────────────────────────────────────────────────────
var _player:         CharacterBody3D
var _orig_skeleton:  Skeleton3D        # the live skeleton in the main scene
var _sil_skeleton:   Skeleton3D        # duplicate in the viewport world
var _meshes:         Array[MeshInstance3D] = []
var _sil_meshes:     Array[MeshInstance3D] = []
var _dissolve_mats:   Array[ShaderMaterial] = []
var _saved_overrides: Dictionary = {}
var _cur_wall_normal: Vector3 = Vector3.ZERO


func _ready() -> void:
	top_level = true
	_player = get_parent() as CharacterBody3D
	_build_viewport()
	_build_wall_quad()
	call_deferred("_find_meshes")


# ── setup ─────────────────────────────────────────────────────────────────

func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(384, 512)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.own_world_3d = true
	add_child(_viewport)

	# Black background so the white silhouette reads as r=1, bg as r=0.
	var wenv := WorldEnvironment.new()
	var env  := Environment.new()
	env.background_mode        = Environment.BG_COLOR
	env.background_color       = Color(0.0, 0.0, 0.0, 1.0)
	env.ambient_light_source   = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color    = Color.BLACK
	env.ambient_light_energy   = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	wenv.environment = env
	_viewport.add_child(wenv)

	_sil_cam = Camera3D.new()
	_sil_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_sil_cam.size       = ORTHO_SIZE
	_sil_cam.near       = 0.01
	_sil_cam.far        = 20.0
	_sil_cam.position   = Vector3(0.0, CAM_Y, CAM_Z_DIST)
	# Default orientation looks in -Z — character will be placed at Z ≈ 0.
	_viewport.add_child(_sil_cam)


func _build_wall_quad() -> void:
	_wall_quad = MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(QUAD_W, QUAD_H)
	_wall_quad.mesh = q
	_wall_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wall_quad.visible = false

	_wall_mat = ShaderMaterial.new()
	_wall_mat.shader = _SHADOW_SHADER
	_wall_mat.set_shader_parameter("shadow_alpha", 0.0)
	_wall_quad.material_override = _wall_mat
	add_child(_wall_quad)
	call_deferred("_link_viewport_texture")


func _link_viewport_texture() -> void:
	_wall_mat.set_shader_parameter("silhouette_tex", _viewport.get_texture())


func _find_meshes() -> void:
	if not is_instance_valid(_player):
		return
	var char_mesh := _player.get_node_or_null("CharacterMesh")
	if not char_mesh:
		return
	_orig_skeleton = char_mesh.find_child("GeneralSkeleton", true, false) as Skeleton3D
	_collect(char_mesh, _meshes)
	_create_silhouette_rig()
	_prepare_dissolve_materials()


func _collect(node: Node, result: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect(child, result)


func _create_silhouette_rig() -> void:
	# ── duplicate skeleton ──────────────────────────────────────────────
	if _orig_skeleton:
		_sil_skeleton = _orig_skeleton.duplicate() as Skeleton3D
		_sil_skeleton.name = "GeneralSkeleton"
		_viewport.add_child(_sil_skeleton)

	# ── create white unlit mesh copies ──────────────────────────────────
	var sil_mat := StandardMaterial3D.new()
	sil_mat.albedo_color = Color.WHITE
	sil_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sil_mat.cull_mode    = BaseMaterial3D.CULL_BACK

	for m in _meshes:
		if not m.mesh:
			continue
		var dup := MeshInstance3D.new()
		dup.mesh              = m.mesh
		dup.skin              = m.skin        # same bind-pose data as original
		dup.material_override = sil_mat
		_viewport.add_child(dup)
		_sil_meshes.append(dup)

	# Wire skeleton paths after all nodes are in the tree.
	if _sil_skeleton:
		for dup in _sil_meshes:
			dup.skeleton = NodePath("../GeneralSkeleton")


func _prepare_dissolve_materials() -> void:
	for m in _meshes:
		var dm := ShaderMaterial.new()
		dm.shader = _DISSOLVE_SHADER
		dm.set_shader_parameter("dissolve",     0.0)
		dm.set_shader_parameter("burn_width",   0.08)
		dm.set_shader_parameter("smoke_speed",  0.5)
		dm.set_shader_parameter("smoke_scale",  4.0)
		dm.set_shader_parameter("albedo_color", Color.WHITE)

		var orig := m.get_active_material(0)
		if orig is StandardMaterial3D:
			var sm := orig as StandardMaterial3D
			dm.set_shader_parameter("albedo_color", sm.albedo_color)
			if sm.albedo_texture:
				dm.set_shader_parameter("albedo_tex", sm.albedo_texture)
		_dissolve_mats.append(dm)


# ── public API ────────────────────────────────────────────────────────────

func activate(player_pos: Vector3, wall_normal: Vector3) -> void:
	_cur_wall_normal = wall_normal
	_place_quad(player_pos, wall_normal)
	_refresh_meshes()

	var smoke_dir := -wall_normal
	for dm in _dissolve_mats:
		dm.set_shader_parameter("smoke_dir", smoke_dir)

	match _state:
		_S.IDLE, _S.EXITING:
			_state = _S.ENTERING
			_wall_quad.visible = true
			_apply_dissolve_mats()


func deactivate() -> void:
	match _state:
		_S.ENTERING, _S.PRESSED:
			_state = _S.EXITING


# ── internals ─────────────────────────────────────────────────────────────

func _place_quad(player_pos: Vector3, wall_normal: Vector3) -> void:
	var pos := player_pos - wall_normal * (0.4 - WALL_GAP)
	pos.y = player_pos.y + QUAD_H * 0.45  # 0.5 = centre; was 0.4 (down 10 %), now 0.45 (down 5 %)
	_wall_quad.global_position = pos
	_wall_quad.global_basis = Basis.looking_at(-wall_normal, Vector3.UP)


func _refresh_meshes() -> void:
	var char_mesh := _player.get_node_or_null("CharacterMesh")
	if not char_mesh:
		return
	var current: Array[MeshInstance3D] = []
	_collect(char_mesh, current)
	var sil_mat := StandardMaterial3D.new()
	sil_mat.albedo_color = Color.WHITE
	sil_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sil_mat.cull_mode    = BaseMaterial3D.CULL_BACK
	for m in current:
		if _meshes.has(m) or not m.mesh:
			continue
		_meshes.append(m)
		var dm := ShaderMaterial.new()
		dm.shader = _DISSOLVE_SHADER
		dm.set_shader_parameter("dissolve",    0.0)
		dm.set_shader_parameter("burn_width",  0.08)
		dm.set_shader_parameter("smoke_speed", 0.5)
		dm.set_shader_parameter("smoke_scale", 4.0)
		dm.set_shader_parameter("albedo_color", Color.WHITE)
		var orig := m.get_active_material(0)
		if orig is StandardMaterial3D:
			var sm := orig as StandardMaterial3D
			dm.set_shader_parameter("albedo_color", sm.albedo_color)
			if sm.albedo_texture:
				dm.set_shader_parameter("albedo_tex", sm.albedo_texture)
		_dissolve_mats.append(dm)
		var dup := MeshInstance3D.new()
		dup.mesh              = m.mesh
		dup.skin              = m.skin
		dup.material_override = sil_mat
		_viewport.add_child(dup)
		if _sil_skeleton:
			dup.skeleton = NodePath("../GeneralSkeleton")
		_sil_meshes.append(dup)


func _apply_dissolve_mats() -> void:
	for i in _meshes.size():
		var m := _meshes[i]
		if not _saved_overrides.has(m):
			_saved_overrides[m] = m.material_override
		if i < _dissolve_mats.size():
			m.material_override = _dissolve_mats[i]


func _restore_mats() -> void:
	for m in _meshes:
		m.material_override = _saved_overrides.get(m, null)
	_saved_overrides.clear()


func _update_sil_rig() -> void:
	if not is_instance_valid(_player):
		return
	var player_inv := _player.global_transform.affine_inverse()

	# Rotate the viewport rig so the character's wall-facing side points at the
	# camera (-Z in viewport world).  wall_normal points FROM wall TOWARD player,
	# so -wall_normal is the wall direction; rotating it to +Z (in front of cam)
	# shows the profile that would cast a shadow on the wall.
	var profile_rot := Basis.IDENTITY
	if _cur_wall_normal != Vector3.ZERO:
		var wn_local := player_inv.basis * _cur_wall_normal
		wn_local.y = 0.0
		if wn_local.length_squared() > 0.001:
			wn_local = wn_local.normalized()
			# Angle from +Z to wall_normal_local in XZ plane.
			# Rotating by -angle brings wall_normal_local to +Z → camera sees wall side.
			var angle := atan2(wn_local.x, wn_local.z)
			profile_rot = Basis(Vector3.UP, -angle)

	if _sil_skeleton and _orig_skeleton:
		var rel := player_inv * _orig_skeleton.global_transform
		rel.basis = profile_rot * rel.basis
		_sil_skeleton.transform = rel

		var bone_count := _orig_skeleton.get_bone_count()
		for i in bone_count:
			_sil_skeleton.set_bone_pose_position(i, _orig_skeleton.get_bone_pose_position(i))
			_sil_skeleton.set_bone_pose_rotation(i, _orig_skeleton.get_bone_pose_rotation(i))
			_sil_skeleton.set_bone_pose_scale(i,    _orig_skeleton.get_bone_pose_scale(i))

	for i in min(_meshes.size(), _sil_meshes.size()):
		var rel := player_inv * _meshes[i].global_transform
		# Skinned meshes are driven by the skeleton (which has profile_rot on its basis already);
		# rotating their origin too would desync them from the skeleton. Non-skinned props like
		# the sword need origin rotated so they sit in the correct profile position.
		if not _meshes[i].skin:
			rel.origin = profile_rot * rel.origin
		rel.basis = profile_rot * rel.basis
		_sil_meshes[i].transform = rel


# ── tick ──────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _state != _S.IDLE:
		_update_sil_rig()

	match _state:
		_S.IDLE:
			return

		_S.ENTERING:
			_dissolve = minf(_dissolve + delta * DISSOLVE_SPEED, DISSOLVE_MAX)
			_shadow_alpha = minf(_dissolve, 1.0)
			if _dissolve >= DISSOLVE_MAX:
				_state = _S.PRESSED

		_S.PRESSED:
			_dissolve     = DISSOLVE_MAX
			_shadow_alpha = 1.0

		_S.EXITING:
			_dissolve = maxf(_dissolve - delta * DISSOLVE_SPEED, 0.0)
			_shadow_alpha = minf(_dissolve, 1.0)
			if _dissolve <= 0.0:
				_state = _S.IDLE
				_wall_quad.visible = false
				_restore_mats()
				return

	for dm in _dissolve_mats:
		dm.set_shader_parameter("dissolve", _dissolve)
	_wall_mat.set_shader_parameter("shadow_alpha", _shadow_alpha)
