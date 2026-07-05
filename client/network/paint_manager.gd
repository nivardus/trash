extends Node
## Autoload `Paint`: relays brush strokes between peers and keeps a server-side
## master image per paintable surface for late-joiner snapshots.
##
## Clients paint into a GPU DrawableTexture2D for display. The server (dedicated
## or listen-host) keeps a CPU Image per surface as the source of truth that new
## players pull on connect. We only ever send stroke *events* over the wire, plus
## a one-time PNG snapshot when a peer joins.

# Canonical brush resolution. Stamps are scaled from this into the target rect.
const BRUSH_SIZE := 128
# Stamp spacing along a stroke segment, as a fraction of brush diameter.
const SPACING := 0.25

# surface_id: StringName -> {
#   "tex_size": int,
#   "base_color": Color,
#   "drawable": DrawableTexture2D or null (present where rendering is available),
#   "image": Image or null (present on the server only),
# }
var _surfaces := {}

# White radial brush, used as the blit source (GPU) and the alpha mask (CPU).
var _brush_image: Image
var _brush_tex: ImageTexture

func _ready() -> void:
	_build_brush()
	# On join, ask the server for a snapshot of every surface's current state.
	# Fires on clients only; the host already holds the master images.
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func _on_connected_to_server() -> void:
	request_snapshots.rpc_id(1)

# --- Surface registration (called by paintable_surface.gd) ---

func register_surface(id: StringName, drawable: DrawableTexture2D, tex_size: int, base_color: Color) -> void:
	var entry: Dictionary = _surfaces.get(id, {})
	entry["tex_size"] = tex_size
	entry["base_color"] = base_color
	entry["drawable"] = drawable
	# Preserve any existing master image (e.g. if the server was set up first).
	if not entry.has("image"):
		entry["image"] = null
	_surfaces[id] = entry
	# If we're already the server when a surface registers, give it a master image.
	if multiplayer.has_multiplayer_peer() and multiplayer.is_server():
		_ensure_master_image(id)

func unregister_surface(id: StringName) -> void:
	_surfaces.erase(id)

# Allocate blank master images for every surface. Called when this peer becomes
# the server (see Net.host()/start_server()).
func become_server() -> void:
	for id in _surfaces.keys():
		_ensure_master_image(id)

func _ensure_master_image(id: StringName) -> void:
	if not _surfaces.has(id):
		return
	var entry: Dictionary = _surfaces[id]
	if entry.get("image") == null:
		var t: int = entry["tex_size"]
		var img := Image.create(t, t, false, Image.FORMAT_RGBA8)
		img.fill(entry.get("base_color", Color(0.9, 0.9, 0.9, 1.0)))
		entry["image"] = img

# --- Painting entry point (called by the local PaintTool) ---

# Apply a stroke segment locally (prediction) and route it to the rest of the
# session. `from_uv`/`to_uv` are in 0..1 surface UV space.
func paint(id: StringName, from_uv: Vector2, to_uv: Vector2, color: Color, size_px: int, opacity: float) -> void:
	_stamp_drawable(id, from_uv, to_uv, color, size_px, opacity)
	if not multiplayer.has_multiplayer_peer():
		return
	if multiplayer.is_server():
		_server_ingest(id, from_uv, to_uv, color, size_px, opacity, multiplayer.get_unique_id())
	else:
		submit_stroke.rpc_id(1, id, from_uv, to_uv, color, size_px, opacity)

# --- RPCs ---

@rpc("any_peer", "call_remote", "unreliable_ordered")
func submit_stroke(id: StringName, from_uv: Vector2, to_uv: Vector2, color: Color, size_px: int, opacity: float) -> void:
	# Server-only: fold into the master image and fan out to the other clients.
	if not multiplayer.is_server():
		return
	_server_ingest(id, from_uv, to_uv, color, size_px, opacity, multiplayer.get_remote_sender_id())

@rpc("authority", "call_remote", "unreliable_ordered")
func apply_stroke(id: StringName, from_uv: Vector2, to_uv: Vector2, color: Color, size_px: int, opacity: float) -> void:
	# Client-only: replay a stroke another peer made.
	_stamp_drawable(id, from_uv, to_uv, color, size_px, opacity)

@rpc("any_peer", "call_remote", "reliable")
func request_snapshots() -> void:
	if not multiplayer.is_server():
		return
	var peer := multiplayer.get_remote_sender_id()
	for id in _surfaces.keys():
		var img: Image = _surfaces[id].get("image")
		if img == null:
			continue
		receive_snapshot.rpc_id(peer, id, img.save_png_to_buffer())

@rpc("authority", "call_remote", "reliable")
func receive_snapshot(id: StringName, png: PackedByteArray) -> void:
	if not _surfaces.has(id):
		return
	var entry: Dictionary = _surfaces[id]
	if entry.get("drawable") == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(png) != OK:
		return
	var t: int = entry["tex_size"]
	# A late joiner's canvas is blank, so blitting the snapshot over it reproduces
	# the server's state.
	var snap := ImageTexture.create_from_image(img)
	entry["drawable"].blit_rect(Rect2i(0, 0, t, t), snap, Color(1, 1, 1, 1))

# --- Stroke application ---

func _server_ingest(id: StringName, from_uv: Vector2, to_uv: Vector2, color: Color, size_px: int, opacity: float, origin: int) -> void:
	_stamp_image(id, from_uv, to_uv, color, size_px, opacity)
	# On a listen-host, update the host's own visible canvas for remote strokes.
	# The host's own strokes are already predicted locally in paint(), so skip
	# those to avoid double-stamping. (No-op on a headless dedicated server.)
	if origin != multiplayer.get_unique_id():
		_stamp_drawable(id, from_uv, to_uv, color, size_px, opacity)
	for peer in multiplayer.get_peers():
		if peer != origin:
			apply_stroke.rpc_id(peer, id, from_uv, to_uv, color, size_px, opacity)

func _stamp_drawable(id: StringName, from_uv: Vector2, to_uv: Vector2, color: Color, size_px: int, opacity: float) -> void:
	if not _surfaces.has(id):
		return
	var entry: Dictionary = _surfaces[id]
	var drawable: DrawableTexture2D = entry.get("drawable")
	if drawable == null:
		return
	var tint := Color(color.r, color.g, color.b, opacity)
	for p in _segment_points(entry["tex_size"], from_uv, to_uv, size_px):
		var r := Rect2i(int(round(p.x)) - size_px / 2, int(round(p.y)) - size_px / 2, size_px, size_px)
		drawable.blit_rect(r, _brush_tex, tint)

func _stamp_image(id: StringName, from_uv: Vector2, to_uv: Vector2, color: Color, size_px: int, opacity: float) -> void:
	if not _surfaces.has(id):
		return
	var entry: Dictionary = _surfaces[id]
	var img: Image = entry.get("image")
	if img == null:
		return
	var stamp := _colored_stamp(size_px, color, opacity)
	var src_rect := Rect2i(0, 0, size_px, size_px)
	for p in _segment_points(entry["tex_size"], from_uv, to_uv, size_px):
		var dst := Vector2i(int(round(p.x)) - size_px / 2, int(round(p.y)) - size_px / 2)
		img.blend_rect(stamp, src_rect, dst)

# Evenly spaced stamp centres (in pixels) along a UV segment.
func _segment_points(tex_size: int, from_uv: Vector2, to_uv: Vector2, size_px: int) -> PackedVector2Array:
	var p0 := from_uv * float(tex_size)
	var p1 := to_uv * float(tex_size)
	var points := PackedVector2Array()
	var dist := p0.distance_to(p1)
	var step := maxf(1.0, float(size_px) * SPACING)
	var n := int(dist / step)
	for i in range(n + 1):
		points.append(p0.lerp(p1, float(i) / float(maxi(n, 1))))
	return points

# --- Brush construction ---

func _build_brush() -> void:
	_brush_image = Image.create(BRUSH_SIZE, BRUSH_SIZE, false, Image.FORMAT_RGBA8)
	var c := Vector2(BRUSH_SIZE, BRUSH_SIZE) * 0.5
	var radius := float(BRUSH_SIZE) * 0.5
	for y in range(BRUSH_SIZE):
		for x in range(BRUSH_SIZE):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / radius
			# Soft round brush: alpha falls off toward the edge.
			var a := clampf(1.0 - smoothstep(0.7, 1.0, d), 0.0, 1.0)
			_brush_image.set_pixel(x, y, Color(1, 1, 1, a))
	_brush_tex = ImageTexture.create_from_image(_brush_image)

# A brush stamp resized to `size_px`, tinted `color`, scaled by `opacity`. Used
# for CPU blending into the server's master image.
func _colored_stamp(size_px: int, color: Color, opacity: float) -> Image:
	var mask := _brush_image.duplicate() as Image
	mask.resize(size_px, size_px, Image.INTERPOLATE_BILINEAR)
	var out := Image.create(size_px, size_px, false, Image.FORMAT_RGBA8)
	for y in range(size_px):
		for x in range(size_px):
			var a := mask.get_pixel(x, y).a * opacity
			out.set_pixel(x, y, Color(color.r, color.g, color.b, a))
	return out
