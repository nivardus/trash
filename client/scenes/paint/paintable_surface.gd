extends MeshInstance3D
## Marks a mesh as paintable. On peers that render, it owns a DrawableTexture2D
## shown as the mesh's albedo; the server keeps a matching CPU master image (via
## Paint). It also builds a trimesh collider so raycasts return a `face_index`,
## and resolves world-space hits to surface UVs.

## Stable network id shared across peers (must be unique per surface).
@export var surface_id: StringName = &""
## Square canvas resolution in pixels.
@export var tex_size: int = 512
## Opaque base colour the canvas starts as (the "paper").
@export var base_color: Color = Color(0.9, 0.9, 0.9, 1.0)

# Expanded per-triangle data in mesh-local space (3 entries per triangle),
# ordered to match the trimesh collider's face indices.
var _tri_verts := PackedVector3Array()
var _tri_uvs := PackedVector2Array()

var _drawable: DrawableTexture2D

func _ready() -> void:
	assert(surface_id != &"", "paintable_surface needs a surface_id")
	_cache_mesh_arrays()
	_build_collider()
	add_to_group(&"paintable")
	if _can_render():
		_setup_drawable()
	Paint.register_surface(surface_id, _drawable, tex_size, base_color)

func get_surface_id() -> StringName:
	return surface_id

func _can_render() -> bool:
	return DisplayServer.get_name() != "headless"

func _setup_drawable() -> void:
	_drawable = DrawableTexture2D.new()
	_drawable.setup(tex_size, tex_size, DrawableTexture2D.DRAWABLE_FORMAT_RGBA8, base_color)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _drawable
	set_surface_override_material(0, mat)

func _build_collider() -> void:
	# create_trimesh_collision() adds a StaticBody3D child with a
	# ConcavePolygonShape3D, which is what makes intersect_ray return a face_index.
	create_trimesh_collision()

func _cache_mesh_arrays() -> void:
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uvs == null or uvs.is_empty():
		push_warning("paintable_surface %s: mesh has no UVs, cannot paint" % surface_id)
		return
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices != null and not indices.is_empty():
		for i in indices:
			_tri_verts.append(verts[i])
			_tri_uvs.append(uvs[i])
	else:
		_tri_verts = verts
		_tri_uvs = uvs

# Approximate world radius (in metres) covered by a brush of `px` pixels, so the
# cursor preview can match the actual stamp footprint. Assumes an affine UV map.
func world_radius_for_pixels(px: int) -> float:
	return _world_units_per_uv() * (float(px) * 0.5 / float(tex_size))

func _world_units_per_uv() -> float:
	if _tri_verts.size() < 3 or _tri_uvs.size() < 3:
		return 1.0
	var gb := global_transform.basis
	var duv1 := _tri_uvs[1] - _tri_uvs[0]
	var duv2 := _tri_uvs[2] - _tri_uvs[0]
	var total := 0.0
	var n := 0
	if duv1.length() > 0.0001:
		total += (gb * (_tri_verts[1] - _tri_verts[0])).length() / duv1.length()
		n += 1
	if duv2.length() > 0.0001:
		total += (gb * (_tri_verts[2] - _tri_verts[0])).length() / duv2.length()
		n += 1
	return total / float(n) if n > 0 else 1.0

# Resolve a world-space hit point (plus the ray's face_index) to a UV in 0..1.
# Returns Vector2(-1, -1) if the surface can't be painted.
func resolve_uv(world_pos: Vector3, face_index: int) -> Vector2:
	if _tri_uvs.is_empty():
		return Vector2(-1, -1)
	var base := face_index * 3
	# Fall back to the first triangle when the index is missing or out of range.
	# For planar surfaces the UV mapping is affine, so any triangle on the plane
	# yields the same interpolated UV regardless of which one we pick.
	if face_index < 0 or base + 2 >= _tri_verts.size():
		base = 0
	var local := global_transform.affine_inverse() * world_pos
	return _barycentric_uv(local, base)

func _barycentric_uv(p: Vector3, base: int) -> Vector2:
	var a := _tri_verts[base]
	var b := _tri_verts[base + 1]
	var c := _tri_verts[base + 2]
	var v0 := b - a
	var v1 := c - a
	var v2 := p - a
	var d00 := v0.dot(v0)
	var d01 := v0.dot(v1)
	var d11 := v1.dot(v1)
	var d20 := v2.dot(v0)
	var d21 := v2.dot(v1)
	var denom := d00 * d11 - d01 * d01
	if is_zero_approx(denom):
		return Vector2(-1, -1)
	var v := (d11 * d20 - d01 * d21) / denom
	var w := (d00 * d21 - d01 * d20) / denom
	var u := 1.0 - v - w
	return _tri_uvs[base] * u + _tri_uvs[base + 1] * v + _tri_uvs[base + 2] * w
