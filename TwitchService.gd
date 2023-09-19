extends Node
class_name TwitchService

# -----------------------------------------------------------------------------
# Settings

# Client ID for the twitch application. Found here:
#
#   https://dev.twitch.tv/console/apps
#
@export var twitch_client_id : String = ""

# NOTE: Whatever setting you put here will be clobbered by whatever is in the
# saved configuration file, so if you're modifying it directly (through the
# editor) instead of relying on saved credentials, you'll have to make sure the
# saved credentials file gets cleared out when you need a new token.
@export var twitch_oauth : String = ""

# To be filled out per-user.
@export var twitch_username : String = ""

# Location to store config once it's set, so you don't have to go through the
# token generation flow all the time.
@export var twitch_config_path : String = "user://twitch_config.ini"

# Automatically save credentials on startup and any time set_twitch_credentials
# is called.
@export var auto_save_credentials : bool = true

# Automatically load credentials when starting.
@export var auto_load_credentials : bool = true

# -----------------------------------------------------------------------------
# Signals

# Emitted when a user uses bits to cheer.
signal handle_channel_chat_message(
	cheerer_username, cheerer_display_name, message, bits_count)

# Emitted when a user redeems a channel point redeem.
signal handle_channel_points_redeem(
	redeemer_username, redeemer_display_name, redeem_title, user_input)

# Emitted when another user raids your channel.
signal handle_channel_raid(
	raider_username, raider_display_name, raid_user_count)

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
var _twitch_users_endpoint = "https://api.twitch.tv/helix/users"


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
		set_twitch_credentials(user["login"], twitch_oauth)
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
	_twitch_user_id_fetch_http_client.set_name("temp_request")
	add_child(_twitch_user_id_fetch_http_client)
	_twitch_user_id_fetch_http_client.set_name("temp_request")
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

func save_config():

	if twitch_config_path == "":
		return

	var config = ConfigFile.new()
	config.set_value("twitch", "twitch_username", twitch_username)
	config.set_value("twitch", "twitch_oauth_token", twitch_oauth)
	config.save(twitch_config_path)

func set_twitch_credentials(username, oauth_token):

	if username and username != "":
		twitch_username = username
	if oauth_token and oauth_token != "":
		twitch_oauth = oauth_token

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


