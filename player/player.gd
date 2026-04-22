extends CharacterBody3D

const SPEED := 1.0
const SPRINT_SPEED := 9.0
const CROUCH_SPEED := 0.5
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.002

const BLEND_LOCOMOTION := 0.2
const BLEND_JUMP := 0.15
const BLEND_LAND := 0.2
const BLEND_ROLL := 0.1
const BLEND_ROLL_OUT := 0.5  # walk/sprint fades in over this duration while roll plays out
const LAND_WALK_BLEND_START := 0.1  # fraction through Jump_Land when walk begins blending in
const BLEND_WALL_PRESS := 0.15

const HEAD_YAW_LIMIT  := PI / 3.0   # 60° left/right
const HEAD_PITCH_LIMIT := PI / 4.0  # 45° up/down
const HIP_YAW_LIMIT   := PI / 2.0  # 90° hip twist while wall-sliding
const LEDGE_CLIMB_SPEED := 2.0

@onready var camera_pivot: Node3D = $CameraPivot

var char_anim: AnimationPlayer
var skeleton: Skeleton3D
var _head_bone: int = -1
var _head_look_rot := Quaternion.IDENTITY
var _spine_bone: int = -1
var _spine_yaw := 0.0
var _smooth_wall_angle := 0.0
var _was_on_floor := true
var _pending_locomotion := ""  # locomotion anim to blend in one frame after roll starts
var _is_crouching := false
var _wall_normal := Vector3.ZERO
var _wall_pressed := false
var _ledge_detector: Area3D = null
var _ledge_reachable := false
var _ledge_grab_active := false
var _ledge_contact_point := Vector3.ZERO
var _ledge_surface_y := 0.0
var _ledge_start_y := 0.0
var _ledge_pull_t := 0.0
var _left_arm_ik: SkeletonIK3D = null
var _right_arm_ik: SkeletonIK3D = null

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	char_anim = $CharacterMesh.find_child("AnimationPlayer", true, false) as AnimationPlayer
	skeleton = $CharacterMesh.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if skeleton:
		_head_bone = skeleton.find_bone("Head")
		_spine_bone = skeleton.find_bone("Spine")
		_left_arm_ik = _make_arm_ik("LeftUpperArm", "LeftHand")
		_right_arm_ik = _make_arm_ik("RightUpperArm", "RightHand")
	char_anim.animation_finished.connect(_on_animation_finished)
	char_anim.mixer_applied.connect(_apply_head_look)
	char_anim.play("Idle", BLEND_LOCOMOTION)
	camera_pivot.top_level = true
	camera_pivot.global_position = global_position + Vector3(0, 1.5, 0)

func _on_animation_finished(anim_name: String) -> void:
	match anim_name:
		"Jump_Start":
			char_anim.play("Jump", BLEND_JUMP)
		"Jump_Land":
			_pending_locomotion = ""
			_play_locomotion()
		"Roll":
			_pending_locomotion = ""
			_play_locomotion()

func _play_locomotion() -> void:
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var target := "Sprint" if (horizontal_speed > 0.1 and Input.is_action_pressed("sprint")) else ("Walk" if horizontal_speed > 0.1 else "Idle")
	if char_anim.current_animation != target:
		char_anim.play(target, BLEND_LOCOMOTION)

func _process(_delta: float) -> void:
	camera_pivot.global_position = global_position + Vector3(0, 1.5, 0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotation.y -= event.relative.x * MOUSE_SENSITIVITY
		camera_pivot.rotation.x -= event.relative.y * MOUSE_SENSITIVITY
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -PI * 0.5, PI * 0.5)

func _physics_process(delta: float) -> void:
	if _ledge_grab_active:
		_process_ledge_grab(delta)
		return

	var on_floor := is_on_floor()

	if not on_floor:
		velocity += get_gravity() * delta

	_is_crouching = Input.is_key_pressed(KEY_CTRL) and on_floor

	if Input.is_action_just_pressed("jump") and on_floor and not Input.is_key_pressed(KEY_CTRL):
		velocity.y = JUMP_VELOCITY
		char_anim.play("Jump_Start", BLEND_JUMP)
		_wall_pressed = false
		_start_ledge_detection()

	var speed := CROUCH_SPEED if _is_crouching else (SPRINT_SPEED if Input.is_action_pressed("sprint") else SPEED)
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")

	var cam_forward := camera_pivot.global_basis.z
	cam_forward.y = 0
	cam_forward = cam_forward.normalized()
	var cam_right := -camera_pivot.global_basis.x
	cam_right.y = 0
	cam_right = cam_right.normalized()
	var direction := (cam_right * input_dir.x + cam_forward * -input_dir.y).normalized()

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
		if _wall_pressed and direction.dot(-_wall_normal) > 0.3:
			# Pushing into wall — lock back-to-wall so the character doesn't face it head-on
			rotation.y = lerp_angle(rotation.y, atan2(_wall_normal.x, _wall_normal.z), delta * 10.0)
		else:
			rotation.y = lerp_angle(rotation.y, atan2(direction.x, direction.z), delta * 8.0)
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)
		if _wall_pressed:
			rotation.y = lerp_angle(rotation.y, atan2(_wall_normal.x, _wall_normal.z), delta * 10.0)

	move_and_slide()

	# Detect wall contacts — collisions with roughly vertical surfaces
	_wall_normal = Vector3.ZERO
	for i in get_slide_collision_count():
		var col := get_slide_collision(i)
		var n := col.get_normal()
		if abs(n.y) < 0.3:
			_wall_normal = n
			break

	if _wall_normal != Vector3.ZERO:
		_smooth_wall_angle = lerp_angle(_smooth_wall_angle, atan2(_wall_normal.x, _wall_normal.z), delta * 20.0)

	# Wall press state transitions
	if _wall_pressed:
		if _wall_normal == Vector3.ZERO or not on_floor:
			_wall_pressed = false
		elif direction != Vector3.ZERO and direction.dot(_wall_normal) > 0.3:
			_wall_pressed = false  # actively moving away from wall
	elif _wall_normal != Vector3.ZERO and on_floor and direction != Vector3.ZERO:
		if direction.dot(-_wall_normal) > 0.5:  # pushing into wall
			_wall_pressed = true

	if _ledge_detector:
		if on_floor and not _was_on_floor:
			_stop_ledge_detection()
		elif not on_floor:
			_update_ledge_detector()

	_update_animation(on_floor)
	_was_on_floor = on_floor

func _start_ledge_detection() -> void:
	_ledge_reachable = false
	if _ledge_detector:
		return
	var area := Area3D.new()
	area.top_level = true  # position tracks character but orientation stays world-aligned
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.6, 0.3, 0.4)
	col.shape = box
	area.add_child(col)

	add_child(area)
	area.body_entered.connect(_on_ledge_body_entered)
	area.body_exited.connect(_on_ledge_body_exited)
	_ledge_detector = area
	_update_ledge_detector()

func _update_ledge_detector() -> void:
	_ledge_detector.global_position = global_position + Vector3(0, 1.6, 0) + global_transform.basis.z * 0.6

func _stop_ledge_detection() -> void:
	if _ledge_detector:
		_ledge_detector.queue_free()
		_ledge_detector = null
	_ledge_reachable = false

func _on_ledge_body_entered(_body: Node3D) -> void:
	_ledge_reachable = true
	if not _ledge_grab_active:
		_initiate_ledge_grab()

func _on_ledge_body_exited(_body: Node3D) -> void:
	if _ledge_detector and _ledge_detector.get_overlapping_bodies().is_empty():
		_ledge_reachable = false

func _initiate_ledge_grab() -> void:
	# Raycast through the box to find the ledge surface height
	var space := get_world_3d().direct_space_state
	var ray_from := _ledge_detector.global_position + Vector3.UP * 0.25
	var ray_to   := _ledge_detector.global_position + Vector3.DOWN * 0.25
	var query := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if not hit:
		return
	_ledge_contact_point = hit.position
	_ledge_surface_y     = hit.position.y
	_ledge_start_y       = global_position.y
	_ledge_pull_t        = 0.0
	_ledge_grab_active   = true
	_wall_pressed        = false
	velocity             = Vector3.ZERO
	char_anim.play("Crouch", 0.15, -1.0, true)  # reversed: crouch→stand reads as pull-up

func _process_ledge_grab(delta: float) -> void:
	_ledge_pull_t = minf(_ledge_pull_t + delta * LEDGE_CLIMB_SPEED, 1.0)

	# Rise toward the ledge surface
	global_position.y = lerpf(_ledge_start_y, _ledge_surface_y, _ledge_pull_t)

	# Box descends from head height to ground as character rises — visual "pull"
	_ledge_detector.global_position = (global_position
		+ Vector3(0, 1.6 * (1.0 - _ledge_pull_t), 0)
		+ global_transform.basis.z * 0.6)

	_apply_hand_ik(_ledge_pull_t)

	if _ledge_pull_t >= 1.0:
		_finish_ledge_grab()

func _finish_ledge_grab() -> void:
	_clear_hand_overrides()
	_ledge_grab_active = false
	global_position += global_transform.basis.z * 0.4  # step forward onto ledge
	_stop_ledge_detection()
	_play_locomotion()

func _make_arm_ik(root_bone: String, tip_bone: String) -> SkeletonIK3D:
	if not skeleton:
		return null
	var ik := SkeletonIK3D.new()
	ik.root_bone = root_bone
	ik.tip_bone = tip_bone
	ik.interpolation = 0.0
	skeleton.add_child(ik)
	ik.start()
	return ik

func _apply_hand_ik(t: float) -> void:
	if skeleton == null:
		return
	var weight := minf(t * 4.0, 1.0)
	var right := global_transform.basis.x
	var skel_inv := skeleton.global_transform.affine_inverse()
	if _left_arm_ik:
		var wp := _ledge_contact_point - right * 0.2
		_left_arm_ik.target = skel_inv * Transform3D(Basis.IDENTITY, wp)
		_left_arm_ik.interpolation = weight
	if _right_arm_ik:
		var wp := _ledge_contact_point + right * 0.2
		_right_arm_ik.target = skel_inv * Transform3D(Basis.IDENTITY, wp)
		_right_arm_ik.interpolation = weight

func _clear_hand_overrides() -> void:
	if _left_arm_ik:
		_left_arm_ik.interpolation = 0.0
	if _right_arm_ik:
		_right_arm_ik.interpolation = 0.0

func _apply_head_look() -> void:
	if _head_bone < 0:
		return

	var delta := get_process_delta_time()

	# Derive pitch and yaw from the camera's actual world look direction
	# to avoid Euler-angle sign ambiguity. camera_pivot.global_basis.z is
	# the direction the camera points (pivot +Z = camera look direction).
	var cam_look_world := camera_pivot.global_basis.z
	var cam_look_body  := global_transform.basis.inverse() * cam_look_world

	var yaw   := clampf(atan2(cam_look_body.x, cam_look_body.z), -HEAD_YAW_LIMIT,  HEAD_YAW_LIMIT)
	var pitch := clampf(-asin(clampf(cam_look_body.y, -1.0, 1.0)), -HEAD_PITCH_LIMIT, HEAD_PITCH_LIMIT)

	# Build rotation in parent-bone-local space (assumed roughly aligned with body)
	var target := Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch)

	# Smooth toward target
	_head_look_rot = _head_look_rot.slerp(target, delta * 8.0)

	# Apply on top of whatever the animation set this frame
	skeleton.set_bone_pose_rotation(_head_bone, _head_look_rot * skeleton.get_bone_pose_rotation(_head_bone))

	# Spine counter-rotation: upper body stays facing away from wall while hips follow movement.
	if _spine_bone >= 0:
		var target_yaw := 0.0
		if _wall_pressed and _wall_normal != Vector3.ZERO and Vector2(velocity.x, velocity.z).length() > 0.1:
			# atan2(sin,cos) gives angle difference in (-PI,PI) without any discontinuity
			var diff := atan2(sin(_smooth_wall_angle - rotation.y), cos(_smooth_wall_angle - rotation.y))
			target_yaw = clampf(diff, -HIP_YAW_LIMIT, HIP_YAW_LIMIT)
		_spine_yaw = lerpf(_spine_yaw, target_yaw, delta * 6.0)
		skeleton.set_bone_pose_rotation(_spine_bone, Quaternion(Vector3.UP, _spine_yaw))

func _update_animation(on_floor: bool) -> void:
	var current := char_anim.current_animation
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()

	# One frame after roll starts, begin blending locomotion in so they play simultaneously
	if _pending_locomotion != "" and current == "Roll":
		char_anim.play(_pending_locomotion, BLEND_ROLL_OUT)
		_pending_locomotion = ""
		return

	# Blend walk into Jump_Land once the character starts to stand back up
	if _pending_locomotion != "" and current == "Jump_Land":
		var anim_len := char_anim.current_animation_length
		if anim_len > 0.0 and char_anim.current_animation_position / anim_len >= LAND_WALK_BLEND_START:
			char_anim.play(_pending_locomotion, BLEND_ROLL_OUT)
			_pending_locomotion = ""
		return

	# Landed this frame
	if not _was_on_floor and on_floor:
		if horizontal_speed > 1.0:
			_pending_locomotion = "Sprint" if Input.is_action_pressed("sprint") else "Walk"
			char_anim.play("Roll", BLEND_ROLL)
		else:
			if horizontal_speed > 0.1:
				_pending_locomotion = "Sprint" if Input.is_action_pressed("sprint") else "Walk"
			char_anim.play("Jump_Land", BLEND_LAND)
		return

	# In air — don't override Jump_Start; it transitions via signal
	if not on_floor:
		if current not in ["Jump_Start", "Jump"]:
			char_anim.play("Jump", BLEND_JUMP)
		return

	# Don't interrupt one-shot ground animations
	if current in ["Jump_Start", "Jump_Land", "Roll"]:
		return

	# Crouch
	if _is_crouching:
		var target := "Crouch_Fwd" if horizontal_speed > 0.1 else "Crouch_Idle"
		if current != target:
			char_anim.play(target, BLEND_LOCOMOTION)
		return

	# Wall press
	if _wall_pressed:
		if horizontal_speed > 0.1:
			var target := "Sprint" if Input.is_action_pressed("sprint") else "Walk"
			if current != target:
				char_anim.play(target, BLEND_WALL_PRESS)
		elif current != "Idle":
			char_anim.play("Idle", BLEND_WALL_PRESS)
		return

	# Locomotion
	if horizontal_speed > 0.1:
		var target := "Sprint" if Input.is_action_pressed("sprint") else "Walk"
		if current != target:
			char_anim.play(target, BLEND_LOCOMOTION)
	elif current != "Idle":
		char_anim.play("Idle", BLEND_LOCOMOTION)
