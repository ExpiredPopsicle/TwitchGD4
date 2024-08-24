# Twitch PubSub handling.
#
# This file is mostly deprecated now, given that we have EventSub support. It's
# staying here for now just in case there's something we really need PubSub over
# EventSub for.

extends RefCounted
class_name TwitchService_PubSub

var twitch_service = null

# Pubsub connection target.
var _twitch_service_url = "wss://pubsub-edge.twitch.tv"

var _client_pubsub : WebSocketPeer = WebSocketPeer.new()
var _client_pubsub_time_to_reconnect = 0.0
var _client_pubsub_time_to_ping = 30.0

func init(parent_twitch_service):
	twitch_service = parent_twitch_service

func _client_pubsub_fail_and_restart(_error_message):
	_client_pubsub_time_to_reconnect = 10.0

func _client_pubsub_handle_connection_closed(_peer_id : int):
	_client_pubsub_fail_and_restart("Connection closed")

func _client_pubsub_handle_connection_error(_was_clean = false):
	_client_pubsub_fail_and_restart("Connection closed with error")

func _client_pubsub_send_ping():

	# Send a ping! For funsies or something.
	var ping_json = {
		"type" : "PING",
	}
	var ping_data = JSON.stringify(ping_json)
	_client_pubsub.send_text(ping_data)
	
	print("pubsub ping!")

func _client_pubsub_handle_connection_established(_peer_id : int):

	# Send a ping! For funsies or something.
	_client_pubsub_send_ping()

	# Register for channel point redeems.
	var event_registration_json = {
		"type" : "LISTEN",
		"nonce" : "ChannelPoints",
		"data" : {
			"topics" : [
				# TODO: Add any extra subscription types we don't want to handle
				# through EventSub here.
				"channel-points-channel-v1." + str(twitch_service._twitch_user_id),
				"channel-bits-events-v1." + str(twitch_service._twitch_user_id)
			],
			"auth_token" : twitch_service.twitch_oauth
		}
	}	
	var event_registration_data = JSON.stringify(event_registration_json)
	_client_pubsub.send_text(event_registration_data)

func _client_pubsub_handle_message(_topic, message):
	# TODO: Fill in any events here that we don't want to handle through
	# EventSub, for whatever reason.

	if "type" in message.keys():
		# TODO: Check type, eg "reward-redeemed".
		pass

func _client_pubsub_handle_data_received():
	var result_str = _client_pubsub.get_packet().get_string_from_utf8()
	pubsub_inject_packet(result_str)

# Inject a packet to handle a pubsub message. This is used for both real and
# fake (testing) packets.
func pubsub_inject_packet(packet_text):
	var result_dict = JSON.parse_string(packet_text)
	var _result_indented = JSON.stringify(result_dict, "    ")

	if result_dict["type"] == "MESSAGE":
		_client_pubsub_handle_message(
			result_dict["data"]["topic"],
			JSON.parse_string(result_dict["data"]["message"]))

func _client_pubsub_connect_to_twitch():
	
	# If you hit this assert, it's because you never filled out the Twitch
	# client ID, which is specific to your application. If you want to find out
	# what it is for your app, you can find it in your app settings here:
	#
	# https://dev.twitch.tv/console/apps
	#
	assert(twitch_service.twitch_client_id != "")
	
	# Attempt connection.
	var err = _client_pubsub.connect_to_url(_twitch_service_url)
	if err != OK:
		_client_pubsub_fail_and_restart("Connection failed: " + str(err))
		return
	
	# Wait for the connection to be fully established.
	_client_pubsub.poll()
	while _client_pubsub.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_client_pubsub.poll()
	
	# Handle failed connections.
	if _client_pubsub.get_ready_state() == WebSocketPeer.STATE_CLOSING:
		return
	if _client_pubsub.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		return

	# Send subscription messages.
	_client_pubsub.poll()
	_client_pubsub_handle_connection_established(1)
	_client_pubsub.poll()

func _client_pubsub_update(delta):

	if twitch_service._twitch_user_id == -1:
		return

	_client_pubsub.poll()

	var err = _client_pubsub.get_packet_error()
	if err != OK:
		push_error("PubSub client error: ", error_string(err))

	while _client_pubsub.get_available_packet_count():
		_client_pubsub_handle_data_received()

	# See if we need to reconnect.
	if _client_pubsub.get_ready_state() == WebSocketPeer.STATE_CLOSED:

		_client_pubsub_time_to_reconnect -= delta

		if _client_pubsub_time_to_reconnect < 0.0:

			# Reconnect to Twitch websocket.
			_client_pubsub_connect_to_twitch()

			# Whatever happens, set a default reconnect delay.
			_client_pubsub_time_to_reconnect = 20.0

	else:
		
		_client_pubsub_time_to_ping -= delta
		if _client_pubsub_time_to_ping < 0.0:
			_client_pubsub_time_to_ping = 30.0
			_client_pubsub_send_ping()

	_client_pubsub.poll()
