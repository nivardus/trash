extends CanvasLayer

func _on_host_pressed() -> void:
	Net.host()
	hide()

func _on_join_pressed() -> void:
	Net.join("ws://localhost:9000")   # or wss://yourserver for production
	hide()

func _ready() -> void:
	if OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_args():
		queue_free()
