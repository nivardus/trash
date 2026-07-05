extends Node3D
## Local-player painting: while the left mouse button is held, raycast from the
## camera, resolve the hit to a surface UV, and feed stroke segments to Paint
## (which predicts locally and syncs to the rest of the session).

const REACH := 100.0
const BRUSH_PX := 24
const OPACITY := 0.9

var _active := false
var _camera: Camera3D
var _player: PhysicsBody3D
var _color := Color.WHITE
var _cursor: MeshInstance3D

var _painting := false
var _last_uv := Vector2(-1, -1)
var _last_surface: StringName = &""

# Enable painting for the local player only, wiring up the camera to cast from.
func activate(camera: Camera3D) -> void:
	_active = true
	_camera = camera
	_player = get_parent() as PhysicsBody3D
	_color = _color_for_peer(multiplayer.get_unique_id())
	_build_cursor()

func _physics_process(_delta: float) -> void:
	if not _active or _camera == null:
		return
	var hit := _raycast()
	var paintable: Node = null
	if not hit.is_empty():
		paintable = _find_paintable(hit.collider)
	# Keep the preview on whatever paintable surface we're aiming at.
	if paintable != null:
		_show_cursor(hit.position, hit.normal, paintable)
	else:
		_cursor.visible = false

	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_painting = false
		return
	if paintable == null:
		return
	var uv: Vector2 = paintable.resolve_uv(hit.position, hit.get("face_index", -1))
	if uv.x < 0.0:
		return
	var id: StringName = paintable.get_surface_id()
	# Connect to the previous sample only within a continuous stroke on the same
	# surface; otherwise lay down a single dab.
	var from_uv := uv
	if _painting and id == _last_surface:
		from_uv = _last_uv
	Paint.paint(id, from_uv, uv, _color, BRUSH_PX, OPACITY)
	_painting = true
	_last_uv = uv
	_last_surface = id

func _raycast() -> Dictionary:
	var space := get_world_3d().direct_space_state
	var from := _camera.global_position
	var to := from + (-_camera.global_transform.basis.z) * REACH
	var query := PhysicsRayQueryParameters3D.create(from, to)
	if _player != null:
		query.exclude = [_player.get_rid()]
	return space.intersect_ray(query)

# A flat ring shown on the surface at the aim point, tinted the paint colour.
func _build_cursor() -> void:
	_cursor = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.85
	ring.outer_radius = 1.0
	_cursor.mesh = ring
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = _color
	# Draw over geometry so the ring is never hidden by the surface it sits on.
	mat.no_depth_test = true
	_cursor.material_override = mat
	_cursor.top_level = true
	_cursor.visible = false
	add_child(_cursor)

func _show_cursor(pos: Vector3, normal: Vector3, paintable: Node) -> void:
	var n := normal.normalized()
	# Build an orthonormal basis whose Y axis is the surface normal (the torus
	# lies in its local XZ plane).
	var tangent := Vector3.RIGHT
	if absf(n.dot(tangent)) > 0.9:
		tangent = Vector3.FORWARD
	var x := tangent.cross(n).normalized()
	var z := n.cross(x).normalized()
	var r: float = maxf(paintable.world_radius_for_pixels(BRUSH_PX), 0.02)
	var basis := Basis(x, n, z).scaled(Vector3(r, r, r))
	_cursor.global_transform = Transform3D(basis, pos + n * 0.02)
	_cursor.visible = true

func _find_paintable(node: Node) -> Node:
	while node != null:
		if node.is_in_group(&"paintable"):
			return node
		node = node.get_parent()
	return null

# Distinct, stable colour per peer so it's obvious who painted what.
func _color_for_peer(id: int) -> Color:
	var hue := fmod(float(id) * 0.61803398875, 1.0)
	return Color.from_hsv(hue, 0.8, 0.95)
