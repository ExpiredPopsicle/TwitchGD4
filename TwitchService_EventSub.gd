extends RefCounted
class_name TwitchService_EventSub

var twitch_service = null

var _client_eventsub : WebSocketPeer = WebSocketPeer.new()
var _client_eventsub_time_to_reconnect = 0.0
var _eventsub_session_id = -1
var _twitch_sub_fetch_http_client = null

var _twitch_sub_endpoint = "https://api.twitch.tv/helix/eventsub/subscriptions"
var _twitch_eventsub_url = "wss://eventsub.wss.twitch.tv/ws"

func init(parent_twitch_service):
	twitch_service = parent_twitch_service

func _client_eventsub_fail_and_restart(_error_message):
	_client_eventsub_time_to_reconnect = 10.0
	print("_client_eventsub_fail_and_restart - " + _error_message)

func _client_eventsub_handle_connection_closed(_peer_id : int):
	_client_eventsub_fail_and_restart("EventSub Connection closed")

func _client_eventsub_handle_connection_error(_was_clean = false):
	_client_eventsub_fail_and_restart("EventSub Connection closed with error")

func _sub_fetch_request_completed(_result: int, 
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray):
	
	var parsed_result = JSON.parse_string(body.get_string_from_utf8())
	var parsed_string = JSON.stringify(parsed_result)
	print("Sub Fetch - " + parsed_string)

	# If we get an authorization error, we need to re-do the oauth setup.
	if response_code == 401:
		twitch_service._start_oauth_process()
		return

func _make_sub_request(json_data):
	_twitch_sub_fetch_http_client = HTTPRequest.new()
	_twitch_sub_fetch_http_client.set_name("temp_request")
	twitch_service.add_child(_twitch_sub_fetch_http_client)
	_twitch_sub_fetch_http_client.set_name("temp_request")
	_twitch_sub_fetch_http_client.request_completed.connect(
		self._sub_fetch_request_completed)
		
	var header_params = [
		"Authorization: Bearer " + twitch_service.twitch_oauth,
		"Client-Id: " + twitch_service.twitch_client_id,
		"Content-Type: application/json"
	]
	var json_string = JSON.stringify(json_data)
	var _err = _twitch_sub_fetch_http_client.request(
		_twitch_sub_endpoint,
		header_params,
		HTTPClient.METHOD_POST,
		json_string)

func _client_eventsub_handle_connection_established(_peer_id : int):
	
	var channel_update_registration_json = {
		"type": "channel.update",
		"version": "1",
		"condition": {
			"broadcaster_user_id": str(twitch_service._twitch_user_id)
		},
		"transport": {
			"method": "websocket",
			"session_id": _eventsub_session_id,
		}
	}
	_make_sub_request(channel_update_registration_json)
	
	var follow_event_registration_json = {
		"type": "channel.follow",
		"version": "2",
		"condition": {
			"broadcaster_user_id": str(twitch_service._twitch_user_id),
			"moderator_user_id": str(twitch_service._twitch_user_id)
		},
		"transport": {
			"method": "websocket",
			"session_id": _eventsub_session_id,
		}
	}
	_make_sub_request(follow_event_registration_json)
	
	var sub_event_registration_json = {
		"type": "channel.subscribe",
		"version": "1",
		"condition": {
			"broadcaster_user_id": str(twitch_service._twitch_user_id)
		},
		"transport": {
			"method": "websocket",
			"session_id": _eventsub_session_id,
		}
	}
	_make_sub_request(sub_event_registration_json)
	
	var gift_sub_event_registration_json = {
		"type": "channel.subscription.gift",
		"version": "1",
		"condition": {
			"broadcaster_user_id": str(twitch_service._twitch_user_id)
		},
		"transport": {
			"method": "websocket",
			"session_id": _eventsub_session_id,
		}
	}
	_make_sub_request(gift_sub_event_registration_json)
	
	var resub_event_registration_json = {
		"type": "channel.subscription.message",
		"version": "1",
		"condition": {
			"broadcaster_user_id": str(twitch_service._twitch_user_id)
		},
		"transport": {
			"method": "websocket",
			"session_id": _eventsub_session_id,
		}
	}
	_make_sub_request(resub_event_registration_json)
	
	var cheer_event_registration_json = {
		"type": "channel.cheer",
		"version": "1",
		"condition": {
			"broadcaster_user_id": str(twitch_service._twitch_user_id)
		},
		"transport": {
			"method": "websocket",
			"session_id": _eventsub_session_id,
		}
	}
	_make_sub_request(cheer_event_registration_json)
	

func _client_eventsub_handle_reward_redeemed(title, username, display_name, user_input):
	# FIXME: Redundant with pubsub?
	#emit_signal("handle_channel_points_redeem",
	#	username, display_name, title, user_input)
	pass

func _client_eventsub_handle_message(type, message):

	# FIXME: This stuff still needs cleanup!

	#print("_client_eventsub_handle_message - " + str(type) + "\n" + str(message))
	match type:
		"channel.update":
			print("channel update event - " + str(message["title"]))
		"channel.follow":
			print("channel follow event - " + str(message["user_name"]))
			# FIXME: Cleanup -Kiri
			#print("channel follow event - " + str(message["user_login"]))
			#print(str(message))
			twitch_service.handle_user_followed.emit(
				message["user_login"],
				message["user_name"])
		"channel.subscribe":
			print("channel subscribe event - " + str(message["user_name"]))
		"channel.subscription.gift":
			print("channel subscription gift event - " + str(message["user_name"]) + \
			" gifted " + str(message["total"]))
		"channel.subscription.message":
			#print("channel subscription message event - " + str(message["user_name"]) + \
			#" for " + str(message["cumulative_months"]) + " months")
			print(message)
			pass
		"channel.cheer":
			print("channel cheer event - " + str(message["user_name"]) + \
			" cheered for " + str(message["bits"]) + " bits")
	
				
func _client_eventsub_handle_data_received():
	var result_str = _client_eventsub.get_packet().get_string_from_utf8()
	eventsub_inject_packet(result_str)


# Inject a packet to handle a eventsub message. This is used for both real and
# fake (testing) packets.
func eventsub_inject_packet(packet_text):
	#print(str(_eventsub_session_id) + "\n" + packet_text)
	var result_dict = JSON.parse_string(packet_text)
	var _result_indented = JSON.stringify(result_dict, "    ")
	if result_dict.has("metadata"):
		if result_dict["metadata"].has("message_type"):
			if result_dict["metadata"]["message_type"] == "session_welcome":
				_eventsub_session_id = result_dict["payload"]["session"]["id"]
				if _client_eventsub.get_ready_state() == WebSocketPeer.STATE_OPEN:
					_client_eventsub_handle_connection_established(1)
			if result_dict["metadata"]["message_type"] == "notification":
				_client_eventsub_handle_message(
					result_dict["payload"]["subscription"]["type"],
					JSON.parse_string(str(result_dict["payload"]["event"])))

func _client_eventsub_connect_to_twitch():
	
	# If you hit this assert, it's because you never filled out the Twitch
	# client ID, which is specific to your application. If you want to find out
	# what it is for your app, you can find it in your app settings here:
	#
	# https://dev.twitch.tv/console/apps
	#
	assert(twitch_service.twitch_client_id != "")
	print(_client_eventsub.get_ready_state())
	# Attempt connection.
	var err = _client_eventsub.connect_to_url(_twitch_eventsub_url)
	if err != OK:
		_client_eventsub_fail_and_restart("EventSub Connection failed: " + str(err))
		return
	
	# Wait for the connection to be fully established.
	_client_eventsub.poll()
	while _client_eventsub.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_client_eventsub.poll()
	
	# Handle failed connections.
	if _client_eventsub.get_ready_state() == WebSocketPeer.STATE_CLOSING:
		return
	if _client_eventsub.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return

	# Send subscription messages.
	_client_eventsub.poll()
	# The following was causing errors for some reason:
	#_client_eventsub_handle_connection_established(1)
	_client_eventsub.poll()

func _client_eventsub_update(delta):

	if twitch_service._twitch_user_id == -1:
		return

	_client_eventsub.poll()

	var err = _client_eventsub.get_packet_error()
	if err != OK:
		print("EventSub ERROR!!!! ", err)

	while _client_eventsub.get_available_packet_count():
		_client_eventsub_handle_data_received()
		_client_eventsub.poll()

	# See if we need to reconnect.
	if _client_eventsub.get_ready_state() == WebSocketPeer.STATE_CLOSED:

		_client_eventsub_time_to_reconnect -= delta

		if _client_eventsub_time_to_reconnect < 0.0:

			# Reconnect to Twitch websocket.
			_client_eventsub_connect_to_twitch()

			# Whatever happens, set a default reconnect delay.
			_client_eventsub_time_to_reconnect = 20.0

	_client_eventsub.poll()

