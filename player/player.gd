extends CharacterBody3D

const SPEED := 1.0
const SPRINT_SPEED := 9.0
const CROUCH_SPEED := 0.75
const ACCELERATION := 6.0
const DECELERATION := 8.0
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.002

const LAND_WALK_BLEND_START := 0.1
const ATTACK_WALK_BLEND_START := 0.5
const ATTACK_LUNGE_SPEED := 10.0
const ATTACK_LUNGE_DECAY := 8.0
const ATTACK_LUNGE_START := 0.2  # fraction through anim before lunge kicks in
const HOLSTER_POSITION := Vector3(0.135, 0.1, 0.03)
const HOLSTER_ROTATION := Vector3(0.52, 5.14, 2.35)
const SWORD_PENDULUM_FORCE := 2.0
const SWORD_PENDULUM_GRAVITY := 12.0
const SWORD_PENDULUM_DAMPING := 5.0
const SWORD_PENDULUM_MAX_ANGLE := 0.4

const ROLL_SPEED_THRESHOLD   := 2.5
const ROLL_SPRINT_CUTOFF     := 0.91
const ROLL_CROUCH_CUTOFF     := 0.8
const ROLL_DAMPEN_START_FRAC := 0.3   # last 70% of the roll gets dampened

const HEAD_YAW_LIMIT  := PI / 3.0   # 60° left/right
const HEAD_PITCH_LIMIT := PI / 4.0  # 45° up/down
const HIP_YAW_LIMIT   := PI / 2.0  # 90° hip twist while wall-sliding
const LEDGE_CLIMB_SPEED := 2.0

@onready var camera_pivot: Node3D = $CameraPivot
@export var wall_shadow: Node

const ATTACK_STATES := ["Sword_Attack", "Punch_Jab", "Punch_Cross"]

var char_anim: AnimationPlayer  # kept for get_animation() and ledge-grab reversed play
var anim_tree: AnimationTree
var anim_playback: AnimationNodeStateMachinePlayback
var jump_playback: AnimationNodeStateMachinePlayback
var skeleton: Skeleton3D
var _head_bone: int = -1
var _head_look_rot := Quaternion.IDENTITY
var _spine_bone: int = -1
var _spine_yaw := 0.0
var _smooth_wall_angle := 0.0
var _was_on_floor := true
var _ctrl_held_prev := false
var _pending_return := false
var _pending_land := false
var _pending_locomotion := false
var _pending_crouch := false
var _is_crouching := false
var _equipped_item: Node3D = null
var _hand_attach: BoneAttachment3D = null
var _hip_attach: BoneAttachment3D = null
var _item_holstered := false
var _is_attacking := false
var _attack_lunge_vel := Vector3.ZERO
var _pending_lunge_vel := Vector3.ZERO
var _last_punch := ""
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
var _left_hand_target: Node3D = null
var _right_hand_target: Node3D = null
var _sword_swing := Vector2.ZERO
var _sword_swing_vel := Vector2.ZERO
var _prev_horizontal_vel := Vector3.ZERO

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	char_anim = $CharacterMesh.find_child("AnimationPlayer", true, false) as AnimationPlayer
	anim_tree = $CharacterMesh.find_child("AnimationTree", true, false) as AnimationTree
	anim_playback = anim_tree.get("parameters/playback") as AnimationNodeStateMachinePlayback
	jump_playback = anim_tree.get("parameters/Jump/playback") as AnimationNodeStateMachinePlayback
	skeleton = $CharacterMesh.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if skeleton:
		_head_bone = skeleton.find_bone("Head")
		_spine_bone = skeleton.find_bone("Spine")
		_left_arm_ik = _make_arm_ik("LeftUpperArm", "LeftHand")
		_right_arm_ik = _make_arm_ik("RightUpperArm", "RightHand")
		_left_hand_target = Node3D.new()
		_right_hand_target = Node3D.new()
		add_child(_left_hand_target)
		add_child(_right_hand_target)
		_left_arm_ik.target_node = _left_hand_target.get_path()
		_right_arm_ik.target_node = _right_hand_target.get_path()
		_hand_attach = BoneAttachment3D.new()
		_hand_attach.bone_name = "RightHand"
		skeleton.add_child(_hand_attach)
		_hip_attach = BoneAttachment3D.new()
		_hip_attach.bone_name = "Hips"
		skeleton.add_child(_hip_attach)
	anim_tree.animation_finished.connect(_on_animation_finished)
	anim_tree.mixer_applied.connect(_apply_head_look)
	camera_pivot.top_level = true
	camera_pivot.global_position = global_position + Vector3(0, 1.5, 0)

func try_pickup(item: Node3D) -> void:
	if _equipped_item:
		return
	item.disable_pickup()
	call_deferred("_finish_pickup", item)

func _finish_pickup(item: Node3D) -> void:
	if _equipped_item or not is_instance_valid(item):
		return
	item.reparent(_hand_attach)
	item.position = Vector3(0.1, 0.1, 0.02)
	item.rotation = Vector3(0.0, 0.0, -PI / 2)
	_equipped_item = item

func _holster_item() -> void:
	_equipped_item.reparent(_hip_attach)
	_equipped_item.position = HOLSTER_POSITION
	_equipped_item.rotation = HOLSTER_ROTATION
	_sword_swing = Vector2.ZERO
	_sword_swing_vel = Vector2.ZERO
	_prev_horizontal_vel = Vector3(velocity.x, 0.0, velocity.z)
	_item_holstered = true

func _draw_item() -> void:
	_equipped_item.reparent(_hand_attach)
	_equipped_item.position = Vector3(0.1, 0.1, 0.02)
	_equipped_item.rotation = Vector3(0.0, 0.0, -PI / 2)
	_sword_swing = Vector2.ZERO
	_sword_swing_vel = Vector2.ZERO
	_item_holstered = false

func _update_sword_pendulum(delta: float) -> void:
	var cur_vel := Vector3(velocity.x, 0.0, velocity.z)
	var accel := (cur_vel - _prev_horizontal_vel) / delta
	_prev_horizontal_vel = cur_vel
	var local_accel := global_transform.basis.inverse() * accel
	_sword_swing_vel.x -= local_accel.x * SWORD_PENDULUM_FORCE * delta
	_sword_swing_vel.y -= local_accel.z * SWORD_PENDULUM_FORCE * delta
	_sword_swing_vel -= _sword_swing * SWORD_PENDULUM_GRAVITY * delta
	_sword_swing_vel *= maxf(0.0, 1.0 - SWORD_PENDULUM_DAMPING * delta)
	_sword_swing += _sword_swing_vel * delta
	_sword_swing = _sword_swing.clamp(Vector2.ONE * -SWORD_PENDULUM_MAX_ANGLE, Vector2.ONE * SWORD_PENDULUM_MAX_ANGLE)
	_equipped_item.rotation = HOLSTER_ROTATION + Vector3(_sword_swing.y, 0.0, _sword_swing.x)

func _on_animation_finished(anim_name: String) -> void:
	match anim_name:
		"Jump_Land":
			_pending_return = false
			_pending_locomotion = true
		"Roll":
			_pending_return = false
			if _is_crouching:
				_pending_crouch = true
			else:
				_pending_locomotion = true
		"Sword_Attack", "Punch_Cross", "Punch_Jab":
			_pending_return = false
			_is_attacking = false
			velocity.x = 0.0
			velocity.z = 0.0
			_pending_locomotion = true

func _start_attack(anim_name: String) -> void:
	var anim := char_anim.get_animation(anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_NONE
	_is_attacking = true
	_attack_lunge_vel = Vector3.ZERO
	_pending_lunge_vel = Vector3.ZERO if anim_name in ["Punch_Jab", "Punch_Cross"] else global_transform.basis.z * ATTACK_LUNGE_SPEED
	velocity.x = 0.0
	velocity.z = 0.0
	if Vector2(velocity.x, velocity.z).length() > 0.1:
		_pending_return = true
	_pending_locomotion = false
	anim_tree["parameters/conditions/do_locomotion"] = false
	anim_playback.travel(anim_name)

func _next_punch() -> String:
	_last_punch = "Punch_Jab" if _last_punch == "Punch_Cross" else "Punch_Cross"
	return _last_punch

func _play_locomotion() -> void:
	anim_tree.set("parameters/Locomotion/blend_position", Vector2(velocity.x, velocity.z).length())
	anim_tree["parameters/conditions/do_locomotion"] = true

func _reset_conditions() -> void:
	anim_tree["parameters/conditions/do_jump"] = false
	anim_tree["parameters/conditions/do_roll"] = false
	anim_tree["parameters/conditions/do_locomotion"] = false
	anim_tree["parameters/conditions/do_crouch"] = false
	anim_tree["parameters/Jump/conditions/do_land"] = false

func _process(_delta: float) -> void:
	camera_pivot.global_position = global_position + Vector3(0, 1.5, 0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_pivot.rotation.y -= event.relative.x * MOUSE_SENSITIVITY
		camera_pivot.rotation.x -= event.relative.y * MOUSE_SENSITIVITY
		camera_pivot.rotation.x = clampf(camera_pivot.rotation.x, -PI * 0.5, PI * 0.5)
	if event is InputEventKey and event.keycode == KEY_X and event.pressed and not event.echo:
		if _equipped_item and not _item_holstered:
			_holster_item()
		elif _equipped_item and _item_holstered:
			_draw_item()
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if not _is_attacking:
			var cur := anim_playback.get_current_node()
			if cur not in ["Jump", "Roll"]:
				_start_attack("Sword_Attack" if (_equipped_item and not _item_holstered) else _next_punch())

func _physics_process(delta: float) -> void:
	_reset_conditions()
	if _ledge_grab_active:
		_process_ledge_grab(delta)
		return

	var on_floor := is_on_floor()

	if not on_floor:
		velocity += get_gravity() * delta

	var ctrl_held := Input.is_key_pressed(KEY_CTRL)
	var ctrl_just := ctrl_held and not _ctrl_held_prev
	_ctrl_held_prev = ctrl_held
	_is_crouching = ctrl_held and on_floor

	var h_spd := Vector2(velocity.x, velocity.z).length()
	if ctrl_just and on_floor and h_spd >= ROLL_SPEED_THRESHOLD and not _is_attacking:
		var cur := anim_playback.get_current_node()
		if cur != "Roll" and cur != "Jump" and cur not in ATTACK_STATES:
			anim_tree["parameters/conditions/do_roll"] = true
			_is_crouching = false

	if Input.is_action_just_pressed("jump") and on_floor and not Input.is_key_pressed(KEY_CTRL):
		_is_attacking = false
		velocity.y = JUMP_VELOCITY
		anim_tree["parameters/conditions/do_jump"] = true
		_wall_pressed = false
		_start_ledge_detection()

	var direction := Vector3.ZERO
	if _is_attacking:
		if _pending_lunge_vel != Vector3.ZERO:
			var anim_len := anim_playback.get_current_length()
			if anim_len > 0.0 and anim_playback.get_current_play_position() / anim_len >= ATTACK_LUNGE_START:
				_attack_lunge_vel = _pending_lunge_vel
				_pending_lunge_vel = Vector3.ZERO
		velocity.x = lerpf(velocity.x, _attack_lunge_vel.x, delta * ATTACK_LUNGE_DECAY)
		velocity.z = lerpf(velocity.z, _attack_lunge_vel.z, delta * ATTACK_LUNGE_DECAY)
		_attack_lunge_vel = _attack_lunge_vel.lerp(Vector3.ZERO, delta * ATTACK_LUNGE_DECAY)
	else:
		var speed := CROUCH_SPEED if _is_crouching else (SPRINT_SPEED if Input.is_action_pressed("sprint") else SPEED)
		var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")

		var cam_forward := camera_pivot.global_basis.z
		cam_forward.y = 0
		cam_forward = cam_forward.normalized()
		var cam_right := -camera_pivot.global_basis.x
		cam_right.y = 0
		cam_right = cam_right.normalized()
		direction = (cam_right * input_dir.x + cam_forward * -input_dir.y).normalized()

		if anim_playback.get_current_node() == "Roll":
			var rpos := anim_playback.get_current_play_position()
			var cutoff := ROLL_CROUCH_CUTOFF if _is_crouching else ROLL_SPRINT_CUTOFF
			var t := clampf((rpos / cutoff - ROLL_DAMPEN_START_FRAC) / (1.0 - ROLL_DAMPEN_START_FRAC), 0.0, 1.0)
			var exit_speed := CROUCH_SPEED if _is_crouching else SPEED
			speed = lerpf(SPRINT_SPEED, exit_speed, t * t * t)
		if direction:
			velocity.x = lerpf(velocity.x, direction.x * speed, delta * ACCELERATION)
			velocity.z = lerpf(velocity.z, direction.z * speed, delta * ACCELERATION)
			rotation.y = lerp_angle(rotation.y, atan2(direction.x, direction.z), delta * 8.0)
		else:
			velocity.x = lerpf(velocity.x, 0.0, delta * DECELERATION)
			velocity.z = lerpf(velocity.z, 0.0, delta * DECELERATION)

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

	if _wall_pressed:
		if _wall_normal == Vector3.ZERO or not on_floor:
			_wall_pressed = false
		elif direction != Vector3.ZERO and direction.dot(_wall_normal) > 0.3:
			_wall_pressed = false  # actively moving away from wall
	elif _wall_normal != Vector3.ZERO and on_floor and direction != Vector3.ZERO:
		if direction.dot(-_wall_normal) > 0.5:  # pushing into wall
			_wall_pressed = true

	if is_instance_valid(wall_shadow):
		if _wall_pressed:
			wall_shadow.activate(global_position, _wall_normal)
		else:
			wall_shadow.deactivate()

	if _ledge_detector:
		if on_floor and not _was_on_floor:
			_stop_ledge_detection()
		elif not on_floor:
			_update_ledge_detector()

	_update_animation(on_floor)
	_was_on_floor = on_floor

	if _item_holstered and _equipped_item:
		_update_sword_pendulum(delta)

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
	# Plays the Crouch animation backwards (stand→crouch reversed = pull-up).
	# The AnimationTree state machine needs a "Ledge_Climb" state with Crouch playing backward,
	# or keep this direct AnimationPlayer call while disabling the tree temporarily.
	anim_tree.active = false
	char_anim.play("Crouch", 0.15, -1.0, true)
	char_anim.animation_finished.connect(_on_ledge_anim_finished, CONNECT_ONE_SHOT)

func _process_ledge_grab(delta: float) -> void:
	_ledge_pull_t = minf(_ledge_pull_t + delta * LEDGE_CLIMB_SPEED, 1.0)

	# Rise toward the ledge surface
	global_position.y = lerpf(_ledge_start_y, _ledge_surface_y, _ledge_pull_t)

	# Press chest against wall — project the character's center to capsule-radius distance
	# from the ledge surface so the body slides flush against the wall as it rises.
	var fwd := global_transform.basis.z
	var wall_d := _ledge_contact_point.dot(fwd) - 0.4
	global_position += fwd * (wall_d - global_position.dot(fwd))

	# Box descends from head height to ground as character rises — visual "pull"
	_ledge_detector.global_position = (global_position
		+ Vector3(0, 1.6 * (1.0 - _ledge_pull_t), 0)
		+ global_transform.basis.z * 0.6)

	_apply_hand_ik(_ledge_pull_t)

	if _ledge_pull_t >= 1.0:
		_finish_ledge_grab()

func _on_ledge_anim_finished(_anim_name: String) -> void:
	anim_tree.active = true

func _finish_ledge_grab() -> void:
	_clear_hand_overrides()
	_ledge_grab_active = false
	global_position += global_transform.basis.z * 0.4  # step forward onto ledge
	_stop_ledge_detection()
	anim_tree.active = true
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
	# Fade in, hold through mid-climb, fade out before the character clears the ledge
	# so the IK doesn't drag the hands downward once the character has risen above the contact point.
	var weight := smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.6, 0.85, t))
	var skel_xform := skeleton.global_transform
	var skel_inv   := skel_xform.affine_inverse()
	# Derive the true lateral axis from the skeleton itself — basis.x is unreliable
	# because the character mesh may have been imported with a different facing convention.
	var l_shoulder := (skel_xform * skeleton.get_bone_global_pose(skeleton.find_bone("LeftUpperArm"))).origin
	var r_shoulder := (skel_xform * skeleton.get_bone_global_pose(skeleton.find_bone("RightUpperArm"))).origin
	var to_right   := (r_shoulder - l_shoulder).normalized()
	var half_span  := (r_shoulder - l_shoulder).length() * 1.5
	var hand_offset := Vector3.DOWN * 0.06
	if _left_hand_target and _left_arm_ik:
		_left_hand_target.global_position = _ledge_contact_point - to_right * half_span + hand_offset
		_left_arm_ik.magnet   = skel_inv * (l_shoulder - to_right * 0.3)
		_left_arm_ik.interpolation = weight
	if _right_hand_target and _right_arm_ik:
		_right_hand_target.global_position = _ledge_contact_point + to_right * half_span + hand_offset
		_right_arm_ik.magnet   = skel_inv * (r_shoulder + to_right * 0.3)
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

	_head_look_rot = _head_look_rot.slerp(target, delta * 8.0)
	# multiply with anim pose so head look stacks on top of the current frame
	skeleton.set_bone_pose_rotation(_head_bone, _head_look_rot * skeleton.get_bone_pose_rotation(_head_bone))


func _update_animation(on_floor: bool) -> void:
	if _pending_locomotion:
		var _in_jump := anim_playback.get_current_node() == "Jump"
		if not _in_jump or jump_playback.get_current_node() == "Jump_Land":
			anim_tree.set("parameters/Locomotion/blend_position", Vector2(velocity.x, velocity.z).length())
			anim_tree["parameters/conditions/do_locomotion"] = true
		_pending_locomotion = false

	if _pending_crouch:
		anim_tree["parameters/conditions/do_crouch"] = true
		_pending_crouch = false
		return

	var root_node := anim_playback.get_current_node()
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()

	anim_tree.set("parameters/Locomotion/blend_position", horizontal_speed)
	anim_tree.set("parameters/Crouch/blend_position", horizontal_speed)

	if _is_attacking and root_node not in ATTACK_STATES:
		_pending_return = false
		_is_attacking = false
		_attack_lunge_vel = Vector3.ZERO
		_pending_lunge_vel = Vector3.ZERO

	# Begin blend-in as Roll exits — go to Crouch if ctrl is still held
	if _pending_return and root_node == "Roll":
		if _is_crouching:
			anim_tree["parameters/conditions/do_crouch"] = true
		else:
			anim_tree["parameters/conditions/do_locomotion"] = true
		_pending_return = false
		return

	if root_node == "Jump":
		var sub_node := jump_playback.get_current_node()
		# Player jumped again before Jump_Land finished — skip the rest of the landing anim.
		if sub_node == "Jump_Land" and velocity.y > 0.1:
			jump_playback.start("Jump_Start")
			_pending_land = false
			_pending_return = false
			return
		# Landing must be detected inside the Jump block — we return early here
		if not _was_on_floor and on_floor:
			if horizontal_speed > 0.1:
				_pending_return = true
			_pending_land = true
			return
		if _pending_land:
			if sub_node == "Jump":
				anim_tree["parameters/Jump/conditions/do_land"] = true
			elif sub_node == "Jump_Land":
				_pending_land = false
		if _pending_return and sub_node == "Jump_Land":
			var anim_len := jump_playback.get_current_length()
			if anim_len > 0.0 and jump_playback.get_current_play_position() / anim_len >= LAND_WALK_BLEND_START:
				anim_tree["parameters/conditions/do_locomotion"] = true
				_pending_return = false
		return

	if _pending_return and root_node in ATTACK_STATES:
		var anim_len := anim_playback.get_current_length()
		if anim_len > 0.0 and anim_playback.get_current_play_position() / anim_len >= ATTACK_WALK_BLEND_START:
			anim_tree["parameters/conditions/do_locomotion"] = true
			_pending_return = false
		return

	if not _was_on_floor and on_floor:
		if horizontal_speed > 0.1:
			_pending_return = true
		anim_tree["parameters/conditions/do_jump"] = true
		_pending_land = true
		return

	if not on_floor:
		if root_node != "Jump":
			anim_tree["parameters/conditions/do_jump"] = true
		return

	if root_node == "Roll":
		var pos := anim_playback.get_current_play_position()
		if _is_crouching and pos >= ROLL_CROUCH_CUTOFF:
			anim_tree["parameters/conditions/do_crouch"] = true
		elif not _is_crouching and pos >= ROLL_SPRINT_CUTOFF:
			anim_tree["parameters/conditions/do_locomotion"] = true
		return

	# Don't interrupt one-shot states
	if root_node == "Jump" or root_node in ATTACK_STATES:
		return

	if _is_crouching:
		if root_node != "Crouch":
			anim_tree["parameters/conditions/do_crouch"] = true
		return

	if root_node != "Locomotion":
		anim_tree["parameters/conditions/do_locomotion"] = true
