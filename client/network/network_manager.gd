extends Node

const PORT := 9000
const DEFAULT_URL := "ws://localhost:9000"
const PLAYER_SCENE := preload("res://scenes/player/player.tscn")

func host() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		push_error("Failed to host: %s" % err)
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	# Host is also a player
	_add_player(multiplayer.get_unique_id())

func join(url := DEFAULT_URL) -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_error("Failed to join: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	
# --- Server-only callbacks ---

func _on_peer_connected(id: int) -> void:
	_add_player(id)

func _on_peer_disconnected(id: int) -> void:
	var players := get_node("/root/World/Players")
	if players.has_node(str(id)):
		players.get_node(str(id)).queue_free()

func _add_player(id: int) -> void:
	var player := PLAYER_SCENE.instantiate()
	player.name = str(id)
	get_node("/root/World/Players").add_child(player, true)

func _ready() -> void:
	if _is_dedicated_server():
		start_server()

func _is_dedicated_server() -> bool:
	return OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_args()

func start_server() -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		push_error("Failed to start server: %s" % err)
		return
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("Dedicated server listening on port %d" % PORT)
