extends Node
class_name TwitchService

# -----------------------------------------------------------------------------
# Settings

## Client ID for the twitch application. Found here:
##
##   https://dev.twitch.tv/console/apps
##
@export var twitch_client_id : String = ""

## NOTE: Whatever setting you put here will be clobbered by whatever is in the
## saved configuration file, so if you're modifying it directly (through the
## editor) instead of relying on saved credentials, you'll have to make sure the
## saved credentials file gets cleared out when you need a new token.
@export var twitch_oauth : String = ""

## To be filled out per-user.
@export var twitch_username : String = ""

## Scopes that have been authorized.
@export var twitch_scopes : PackedStringArray = []

## Location to store config once it's set, so you don't have to go through the
## token generation flow all the time.
@export var twitch_config_path : String = "user://twitch_config.ini"

## Automatically save credentials on startup and any time set_twitch_credentials
## is called.
@export var auto_save_credentials : bool = true

## Automatically load credentials when starting.
@export var auto_load_credentials : bool = true

## Path to save downloaded images to.
@export var images_cache_path : String = "user://_twitch_images"

# -----------------------------------------------------------------------------
# Signals

## Emitted when a user uses bits to cheer.
signal handle_channel_chat_message(
	cheerer_username, cheerer_display_name, message, bits_count)

# FIXME: Name this better.
## Handle chat messages. This goes through EventSub instead of IRC, and contains
## fragment data with emotes.
signal handle_channel_chat_message_v2(
	chatter_username : String,
	chatter_display_name : String,
	message : String,
	fragment_list : Array,
	bits_count : int)

## Emitted when a user redeems a channel point redeem.
signal handle_channel_points_redeem(
	redeemer_username, redeemer_display_name, redeem_title, user_input)

## Emitted when another user raids your channel.
signal handle_channel_raid(
	raider_username, raider_display_name, raid_user_count)

## Emitted when another user follows your channel.
signal handle_user_followed(
	follower_username, follower_display_name)

# -----------------------------------------------------------------------------
# Individual services

var _twitch_service_oauth = TwitchService_OAuth.new()
var _twitch_service_pubsub = TwitchService_PubSub.new()
var _twitch_service_irc = TwitchService_IRC.new()
var _twitch_service_eventsub = TwitchService_EventSub.new()
var _twitch_service_users = TwitchService_Users.new()

# -----------------------------------------------------------------------------
# Constants

# Twitch user data endpoint. We'll use this to fetch a user ID based on the
# username.
var _twitch_users_endpoint : String = "https://api.twitch.tv/helix/users"

var _image_extensions_recognized : PackedStringArray = \
	[ ".png", ".jpg", ".gif" ]

# -----------------------------------------------------------------------------
# User ID fetch

var _twitch_user_id = -1
var _twitch_user_id_fetch_time_to_retry = 0.0
var _twitch_user_id_fetch_http_client = null

func _user_id_request_completed(
	_result: int, response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray):
	
	var parsed_result = JSON.parse_string(
		body.get_string_from_utf8())

	# If we get an authorization error, we need to re-do the oauth setup.
	if response_code == 401:
		_twitch_service_oauth._start_oauth_process()
		if _twitch_user_id_fetch_http_client:
			_twitch_user_id_fetch_http_client.queue_free()
			_twitch_user_id_fetch_http_client = null
		return

	# Get the user ID and login from the incoming Twitch data.
	_twitch_user_id = -1
	for user in parsed_result["data"]:
		_twitch_user_id = int(user["id"])
		set_twitch_credentials(user["login"], twitch_oauth, twitch_scopes)
		break

	# Clean up.
	if _twitch_user_id_fetch_http_client:
		_twitch_user_id_fetch_http_client.queue_free()
		_twitch_user_id_fetch_http_client = null

	_twitch_user_id_fetch_time_to_retry = 5.0

# Determine the user ID of the user who's authorized this.
func _fetch_user_id():

	if _twitch_user_id_fetch_http_client:
		# Request already in-flight.
		return

	_twitch_user_id_fetch_http_client = HTTPRequest.new()
	_twitch_user_id_fetch_http_client.set_name("temp_request_fetch_user_id_2")
	add_child(_twitch_user_id_fetch_http_client)
	_twitch_user_id_fetch_http_client.request_completed.connect(
		self._user_id_request_completed)

	var header_params = [
		"Authorization: Bearer " + twitch_oauth,
		"Client-Id: " + twitch_client_id
	]

	var err = _twitch_user_id_fetch_http_client.request(
		_twitch_users_endpoint,
		header_params)
		
	if err != OK:
		_twitch_user_id_fetch_http_client.queue_free()
		_twitch_user_id_fetch_http_client = null

	_twitch_user_id_fetch_time_to_retry = 5.0

func _update_user_id(delta):

	if _twitch_service_oauth._oauth_in_process:
		return

	# Check user ID. See if we need to fetch that. If we do, then we can't do
	# anything else until that's ready.
	if _twitch_user_id == -1:
		_twitch_user_id_fetch_time_to_retry -= delta
		if _twitch_user_id_fetch_time_to_retry < 0.0:
			_twitch_user_id_fetch_time_to_retry = 5.0 # Try every 5 seconds.
			_fetch_user_id()

# -----------------------------------------------------------------------------
# Config Management

func load_config():

	if twitch_config_path == "":
		return

	var config = ConfigFile.new()
	var err = config.load(twitch_config_path)
	if err != OK:
		return

	# Load the values, but default to whatever was there (export values that may
	# have been set in the editor.)
	if config.has_section_key("twitch", "twitch_username"):
		twitch_username = config.get_value("twitch", "twitch_username", twitch_username)

	if config.has_section_key("twitch", "twitch_oauth_token"):
		twitch_oauth = config.get_value("twitch", "twitch_oauth_token", twitch_oauth)

	if config.has_section_key("twitch", "twitch_scopes"):
		twitch_scopes = config.get_value("twitch", "twitch_scopes", twitch_scopes).split(",")

func save_config():

	if twitch_config_path == "":
		return

	var config = ConfigFile.new()
	config.set_value("twitch", "twitch_username", twitch_username)
	config.set_value("twitch", "twitch_oauth_token", twitch_oauth)
	config.set_value("twitch", "twitch_scopes", ",".join(twitch_scopes))
	config.save(twitch_config_path)

func set_twitch_credentials(username, oauth_token, scopes):

	if username and username != "":
		twitch_username = username
	if oauth_token and oauth_token != "":
		twitch_oauth = oauth_token
	if scopes and len(scopes):
		twitch_scopes = scopes

	if auto_save_credentials:
		save_config()

# -----------------------------------------------------------------------------
# Normal Node entry points

func _ready():
	
	if auto_load_credentials:
		load_config()

	if auto_save_credentials:
		save_config()
		
	_twitch_service_users.init(self)
	_twitch_service_oauth.init(self)
	_twitch_service_pubsub.init(self)
	_twitch_service_irc.init(self)
	_twitch_service_eventsub.init(self)

# FIXME: Make this toggleable. Maybe we don't want to fire off auth requests and
# stuff immediately upon instantiating the node.
func _process(delta):

	# Check user ID.
	_update_user_id(delta)

	# Update Pubsub.
	_twitch_service_pubsub._client_pubsub_update(delta)

	# Update IRC.
	_twitch_service_irc._client_irc_update(delta)
	
	_twitch_service_eventsub._client_eventsub_update(delta)

	# Poll oauth.
	_twitch_service_oauth._poll_oauth_server()

	_twitch_service_users.update(delta)

func _sanitize_string(s : String) -> String:

	# FIXME: Verify that this covers all valid characters in usernames.

	var new_s = "" + s # FIXME: Do we have to do this to make a unique copy?
	for i in range(0, len(s)):
		var u = s.unicode_at(i)
		if u >= 0x41 and u <= 0x5A: # A-Z
			continue
		if u >= 0x61 and u <= 0x7A: # a-z
			continue
		if u == 0x5f || u == 0x2D: # _, -
			continue
		if u >= 0x30 and u <= 0x39: # 0-9
			continue

		# Not any of the allowed characters. Replace with underscore.
		new_s[i] = "_"
	return new_s

## Delete all cached images. Do this now and then so you can reflect avatar
## updates by removing stale, outdated images. Or just free up disk space.
func purge_image_cache():
	var dir : DirAccess = DirAccess.open(images_cache_path)

	if not dir:
		# Directory doesn't even exist?
		return

	# Iterate through files and find everything matching an image type.
	dir.list_dir_begin()
	var file_name : String = dir.get_next()
	var deletion_list : PackedStringArray = []
	while file_name != "":
		if not dir.current_is_dir():
			for image_extension : String in _image_extensions_recognized:
				if file_name.ends_with(image_extension):
					deletion_list.append(file_name)
					break
		file_name = dir.get_next()

	# Delete them.
	for file_to_delete in deletion_list:
		dir.remove(file_to_delete)

## Download an emote asynchronously or lookup a cached emote.
func fetch_emote_async(emote_id : String):
	var emote_id_san : String = _sanitize_string(emote_id)
	var url : String = "https://static-cdn.jtvnw.net/emoticons/v2/" + emote_id_san + "/default/light/3.0"
	return await fetch_image_async("emote_" + emote_id_san, url)

## Download an emote asynchronously or lookup a cached emote.
func fetch_user_profile_image_async(user_login : String):
	var user_login_san : String = _sanitize_string(user_login)
	var user_data : Dictionary = await lookup_user_async(user_login_san)
	if user_data:
		return await fetch_image_async(
			"profile_" + user_login_san, user_data["profile_image_url"])
	return null

## Download an image asynchronously. Returns immediately if the image is already
## the image cache.
func fetch_image_async(cache_id : String, image_url : String):

	# Check for existing file before firing off a request.
	for extension in _image_extensions_recognized:
		var path_to_test = images_cache_path.path_join(cache_id + extension)
		if FileAccess.file_exists(path_to_test):
			return path_to_test

	var http_request = HTTPRequest.new()
	add_child(http_request)

	# Perform a GET request. The URL below returns JSON as of writing.
	var error = http_request.request(
		image_url)
	if error != OK:
		push_error(
			"Failed to fetch Twitch image: ", image_url,
			"\nReason: ", error_string(error))
		return null

	var results = await http_request.request_completed

	if results[0] != HTTPRequest.RESULT_SUCCESS:
		push_error(
			"Failed to fetch Twitch image: ", image_url,
			"\nReason: ", results[0])
		return null

	if results[1] != 200:
		push_error(
			"Failed to fetch Twitch image: ", image_url,
			"\nResponse: ", results[1])
		return null

	var extension : String = ""

	# Check PNG magic number.
	if results[3].slice(0, 8) == PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10]):
		extension = ".png"

	# Check GIF magic number ("GIF8")
	if results[3].slice(0, 4) == "GIF8".to_ascii_buffer():
		extension = ".gif"

	# Check JPG magic number.
	if results[3].slice(0, 8) == PackedByteArray([0xff, 0xd8, 0xff]):
		extension = ".jpg"

	var image_output_path : String = images_cache_path.path_join(cache_id + extension)

	DirAccess.make_dir_absolute(images_cache_path)

	var out_file : FileAccess = FileAccess.open(image_output_path, FileAccess.WRITE)
	out_file.store_buffer(results[3])
	out_file.close()

	http_request.queue_free()

	return image_output_path

## Lookup a user. Using coroutines, will aynchronously wait and return a user
## data structure when the request finishes. For when you don't want to juggle
## callbacks for stream-related triggers.
##
## May still return immediately if a cached lookup is present.
##
## Wrapper around TwitchService_Users::lookup_user_async for the public API.
func lookup_user_async(user_login : String):
	return await _twitch_service_users.lookup_user_async(user_login)
