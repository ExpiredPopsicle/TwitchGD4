extends Control

func _on_lookup_button_pressed() -> void:
	var username : String = %LineEdit_Username.text

	# Fetch user data.
	var user_data = await $TwitchService.lookup_user_async(username)
	if user_data:
		# Present user data.
		%TextEdit_Userdata.text = JSON.stringify(user_data, "    ", false)
	else:
		%TextEdit_Userdata.text = "Failed to lookup " + username

	# Fetch user profile image.
	var image_path = await $TwitchService.fetch_user_profile_image_async(username)
	if image_path:
		# Preset user profile.
		var image = Image.load_from_file(image_path)
		var texture = ImageTexture.create_from_image(image)
		%TextureRect_ProfileImage.texture = texture
	else:
		%TextureRect_ProfileImage.texture = null

func _on_button_purge_caches_pressed() -> void:
	$TwitchService.purge_image_cache()
