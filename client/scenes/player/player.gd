extends CharacterBody3D


const SPEED := 5.0
const JUMP_VELOCITY := 4.5
const MOUSE_SENS := 0.003

@onready var spring_arm: SpringArm3D = $SpringArm3D
@onready var camera: Camera3D = $SpringArm3D/Camera3D
@onready var input_sync: MultiplayerSynchronizer = $InputSync

# Client -> server input
@export var input_dir: Vector2 = Vector2.ZERO
@export var look_yaw: float = 0.0
@export var jump_held: bool = false

# Server-only edge detection state
var _prev_jump_held := false

func _enter_tree() -> void:
	$InputSync.set_multiplayer_authority(name.to_int())

func _is_local_player() -> bool:
	return input_sync.get_multiplayer_authority() == multiplayer.get_unique_id()

func _ready() -> void:
	if _is_local_player():
		camera.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		camera.current = false
		set_process_unhandled_input(false)

func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player():
		return
	# Browsers only grant pointer lock from a user gesture, so (re)capture on click.
	# This also handles native, where the initial capture in _ready() already ran.
	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Accumulate yaw as input; server applies it to the body
		look_yaw = wrapf(look_yaw - event.relative.x * MOUSE_SENS, -PI, PI)
		# Pitch is camera-only, keep it local
		spring_arm.rotate_x(-event.relative.y * MOUSE_SENS)
		spring_arm.rotation.x = clampf(spring_arm.rotation.x, -1.2, 0.4)
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if _is_local_player():
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		jump_held = Input.is_action_pressed("jump")
	
	# Only the server simulates
	if not multiplayer.is_server():
		return
	
	rotation.y = look_yaw
	
	# Add gravity
	if not is_on_floor():
		velocity += get_gravity() * delta
	
	# Edge detect the jump from the synced held staste
	if jump_held and not _prev_jump_held and is_on_floor():
		velocity.y = JUMP_VELOCITY
	_prev_jump_held = jump_held
	
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)

	move_and_slide()
