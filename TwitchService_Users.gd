extends RefCounted
class_name TwitchService_Users

# Twitch user data endpoint. We'll use this to fetch a user ID based on the
# username.
var _twitch_users_endpoint = "https://api.twitch.tv/helix/users"

var twitch_service = null

var _twitch_user_id = -1
var _twitch_user_id_fetch_time_to_retry = 0.0
var _twitch_user_id_fetch_http_client : HTTPRequest = null

var _user_request_queue = []

var _cached_user_data = {}

## Emitted when a user lookup has completed. Either successfully or not. If
## unsuccessful due to connection error, lookup error, or otherwise, user_data
## will be null.
signal user_request_completed(login : String, user_data : Dictionary)

func init(parent_twitch_service):
	twitch_service = parent_twitch_service

func _user_id_request_completed(
	_result: int, response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	original_request_login : String):

	var found_original_request : bool = false
	var completed_entries : Array = []

	if response_code == 200 and _result == HTTPRequest.RESULT_SUCCESS:

		var parsed_result = JSON.parse_string(
			body.get_string_from_utf8())

		for entry in parsed_result["data"]:
			if entry["login"] == original_request_login:
				found_original_request = true
			_cached_user_data[entry["login"]] = entry
			completed_entries.append(entry)

	# Clean up.
	if _twitch_user_id_fetch_http_client:
		_twitch_user_id_fetch_http_client.queue_free()
		_twitch_user_id_fetch_http_client = null

	_twitch_user_id_fetch_time_to_retry = 5.0

	# Fire off signals.
	for entry : Dictionary in completed_entries:
		user_request_completed.emit(entry["login"], entry)

	# If we never found the original request (probably due to an error) we still
	# need to fire off the signal so that coroutines can handle the error and
	# cleanup.
	if not found_original_request:
		user_request_completed.emit(original_request_login, null)

# Determine the user ID of the user who's authorized this.
func _fetch_user_id(user_login : String = "", user_id : int = -1):

	if _twitch_user_id_fetch_http_client:
		# Request already in-flight.
		return

	_twitch_user_id_fetch_http_client = HTTPRequest.new()
	_twitch_user_id_fetch_http_client.set_name("temp_request_fetch_user_id")
	twitch_service.add_child(_twitch_user_id_fetch_http_client)
	_twitch_user_id_fetch_http_client.request_completed.connect(
		self._user_id_request_completed.bind(user_login))

	var header_params = [
		"Authorization: Bearer " + twitch_service.twitch_oauth,
		"Client-Id: " + twitch_service.twitch_client_id
	]

	var params_string = ""
	if user_login != "":
		params_string += "login=" + user_login.uri_encode()
	if user_id != -1:
		if len(params_string):
			params_string += "&"
		params_string += "id=" + str(user_id)

	var err = _twitch_user_id_fetch_http_client.request(
		_twitch_users_endpoint + "?" + params_string,
		header_params)
		
	if err != OK:
		_twitch_user_id_fetch_http_client.queue_free()
		_twitch_user_id_fetch_http_client = null

	_twitch_user_id_fetch_time_to_retry = 5.0

func add_lookup_request(user_login):
	_user_request_queue.append(user_login)

## Lookup a user. Using coroutines, will aynchronously wait and return a user
## data structure when the request finishes. For when you don't want to juggle
## callbacks for stream-related triggers.
##
## May still return immediately if a cached lookup is present.
func lookup_user_async(user_login : String):

	if _cached_user_data.has(user_login):
		return _cached_user_data[user_login]

	add_lookup_request(user_login)

	# Now we need to filter out the response signals down to just the one we
	# originally requested.
	while true:
		var request_results = await user_request_completed
		if request_results[0] == user_login:
			return request_results[1]

func update(delta):
	
	if _twitch_user_id_fetch_http_client:
		return
		
	if len(_user_request_queue):
		var next_user = _user_request_queue.pop_front()
		if not next_user in _cached_user_data:
			_fetch_user_id(next_user)

func check_cached_user_data(user_login):
	if user_login in _cached_user_data:
		return _cached_user_data[user_login]
	return null
