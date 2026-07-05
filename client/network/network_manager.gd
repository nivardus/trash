extends Node

const PORT := 9000
const DEFAULT_URL := "ws://localhost:9000"
# The web client is served from https://trash.place, which forbids plain ws://
# (mixed content). Caddy routes the /ws path on that same host to the game
# server, so browser builds connect over TLS via wss://.
const PROD_URL := "wss://trash.place/ws"
const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

# Heartbeat: the server pings every connected client on an interval and drops
# any peer that hasn't checked in within the timeout. This reclaims players
# whose connection died without a clean WebSocket close (crashed tab, lost
# network, force-quit) — cases TCP alone can take minutes, or forever, to
# notice. The timeout is several intervals so brief blips don't kick anyone.
const HEARTBEAT_INTERVAL := 5.0
const CLIENT_TIMEOUT := 20.0

# peer id -> last time (ms) we heard from it. Server-only.
var _last_seen := {}
var _heartbeat_timer: Timer

# URL the client should connect to by default: the public wss:// endpoint for
# browser builds, and a local ws:// server for desktop/dev runs.
func default_join_url() -> String:
	if OS.has_feature("web"):
		return PROD_URL
	return DEFAULT_URL

func host() -> void:
	if not _start_server():
		return
	# The listen-server host is also a player.
	_add_player(multiplayer.get_unique_id())

func join(url := DEFAULT_URL) -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_error("Failed to join: %s" % err)
		return
	multiplayer.multiplayer_peer = peer

func start_server() -> void:
	if _start_server():
		print("Dedicated server listening on port %d" % PORT)

func _ready() -> void:
	if _is_dedicated_server():
		start_server()

func _is_dedicated_server() -> bool:
	return OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_args()

# --- Server setup ---

func _start_server() -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		push_error("Failed to start server: %s" % err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	# Give the paint system its authoritative per-surface master images.
	Paint.become_server()
	_heartbeat_timer = Timer.new()
	_heartbeat_timer.wait_time = HEARTBEAT_INTERVAL
	_heartbeat_timer.autostart = true
	_heartbeat_timer.timeout.connect(_on_heartbeat)
	add_child(_heartbeat_timer)
	return true

func _on_heartbeat() -> void:
	# Ask every client to check in...
	_heartbeat_ping.rpc()
	# ...then drop anyone we haven't heard from in a while. keys() returns a
	# copy, so erasing inside the loop is safe.
	var now := Time.get_ticks_msec()
	var timeout_ms := int(CLIENT_TIMEOUT * 1000.0)
	for id in _last_seen.keys():
		if now - int(_last_seen[id]) > timeout_ms:
			push_warning("Peer %d timed out; disconnecting" % id)
			_drop_peer(id)

func _drop_peer(id: int) -> void:
	_last_seen.erase(id)
	var peer := multiplayer.multiplayer_peer
	if peer is WebSocketMultiplayerPeer:
		peer.disconnect_peer(id)
	_remove_player(id)

# --- Peer lifecycle (server-only) ---

func _on_peer_connected(id: int) -> void:
	_last_seen[id] = Time.get_ticks_msec()
	_add_player(id)

func _on_peer_disconnected(id: int) -> void:
	_last_seen.erase(id)
	_remove_player(id)

func _add_player(id: int) -> void:
	var players := get_node_or_null("/root/World/Players")
	if players == null or players.has_node(str(id)):
		return
	var player := PLAYER_SCENE.instantiate()
	player.name = str(id)
	players.add_child(player, true)

func _remove_player(id: int) -> void:
	var players := get_node_or_null("/root/World/Players")
	if players != null and players.has_node(str(id)):
		players.get_node(str(id)).queue_free()

# --- Heartbeat RPCs ---

@rpc("authority", "call_remote", "unreliable")
func _heartbeat_ping() -> void:
	# Runs on clients; reply to the server (peer id 1).
	_heartbeat_pong.rpc_id(1)

@rpc("any_peer", "call_remote", "unreliable")
func _heartbeat_pong() -> void:
	# Runs on the server.
	var id := multiplayer.get_remote_sender_id()
	if _last_seen.has(id):
		_last_seen[id] = Time.get_ticks_msec()
