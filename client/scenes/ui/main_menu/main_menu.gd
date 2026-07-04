extends CanvasLayer

func _on_host_pressed() -> void:
	Net.host()
	hide()

func _on_join_pressed() -> void:
	Net.join(Net.default_join_url())
	hide()

func _ready() -> void:
	if OS.has_feature("dedicated_server") or "--server" in OS.get_cmdline_args():
		queue_free()
		return
	# Browser builds are the public client: skip the menu and connect straight
	# to the hosted server. Desktop builds keep the Host/Join choice.
	if OS.has_feature("web"):
		_on_join_pressed()
