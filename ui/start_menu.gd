extends Control

func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _on_play_pressed() -> void:
	get_tree().change_scene_to_file("res://node_3d.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
