extends RefCounted
class_name TwitchService_IRC

var twitch_service = null

# IRC (over websocket) connection target.
var _twicth_irc_url = "wss://irc-ws.chat.twitch.tv"

var _client_irc : WebSocketPeer = WebSocketPeer.new()
var _client_irc_time_to_reconnect = 0.0

func init(parent_twitch_service):
	twitch_service = parent_twitch_service

func _client_irc_fail_and_restart(_error_message):
	_client_irc_time_to_reconnect = 10.0

func _client_irc_handle_connection_closed(_was_clean = false):
	_client_irc_fail_and_restart("Connection closed")

func _client_irc_handle_connection_error(_was_clean = false):
	_client_irc_fail_and_restart("Connection closed with error")

func _client_irc_send(message):
	_client_irc.send_text(message)

func _client_irc_handle_connection_established(_proto = ""):

	# Send IRC handshaking messages.
	_client_irc_send("CAP REQ :twitch.tv/membership twitch.tv/tags twitch.tv/commands") # twitch.tv/tags twitch.tv/commands
	_client_irc_send("PASS oauth:" + twitch_service.twitch_oauth)
	_client_irc_send("NICK " + twitch_service.twitch_username)
	_client_irc_send("JOIN #" + twitch_service.twitch_username)
	
func _parse_irc_message(message):
	
	var split_message
	var output = {}
	output["tags"]    = {}
	output["prefix"]  = ""
	output["command"] = ""
	output["params"]  = []

	# Parse tags.
	if message.length() > 0:
		if message[0] == "@":
			split_message = message.split(" ", false, 1)
			var tags_str = split_message[0].substr(1)
			if split_message.size() > 1:
				message = split_message[1]
			else:
				message = ""
			var tags_pair_strs = tags_str.split(";")
			for tag_pair in tags_pair_strs:
				var tag_parts = tag_pair.split("=")
				output["tags"][tag_parts[0]] = tag_parts[1]

	# Parse prefix, and chop it off from the message if it's there.
	if message.length() > 0:
		if message[0] == ":":
			split_message = message.split(" ", false, 1)
			output["prefix"] = split_message[0].substr(1)
			if split_message.size() > 1:
				message = split_message[1]
			else:
				message = ""

	if output["prefix"].length() > 0:

		# Here are what I think are the three forms of prefix we might be
		# dealing with here:
		# - nick!user@host
		# - user@host (maybe?)
		# - host
		
		# Split on "!" to separate the nick from everything else. We might not
		# have a nick, but that's okay. We'll just leave the field blank.
		var prefix_nick_user = output["prefix"].split("!", true, 1)
		var nick
		var prefix_user_host
		if prefix_nick_user.size() > 1:
			nick = prefix_nick_user[0]
			prefix_user_host = prefix_nick_user[1]
		else:
			nick = ""
			prefix_user_host = prefix_nick_user[0]

		# Split the user@host by "@" to get a user and host. It may also just
		# be a host, so if we only have one result from this, assume it's a host
		# with no user (message directly from server, etc).
		var prefix_user_host_split = prefix_user_host.split("@", true, 1)
		var user
		var host
		if prefix_user_host_split.size() > 1:
			user = prefix_user_host_split[0]
			host = prefix_user_host_split[1]
		else:
			user = ""
			host = prefix_user_host_split[0]
			
		output["prefix_nick"] = nick
		output["prefix_host"] = host
		output["prefix_user"] = user

	# Parse command, and chop it off from the message if it's there.
	if message.length() > 0:
		split_message = message.split(" ", false, 1)
		output["command"] = split_message[0]
		if split_message.size() > 1:
			message = split_message[1]
		else:
			message = ""

	# Parse the parameters to the command.
	while message.length() > 0:
		if message[0] == ":":
			output["params"].append(message.substr(1))
			message = ""
		else:
			split_message = message.split(" ", false, 1)
			output["params"].append(split_message[0])
			if split_message.size() > 1:
				message = split_message[1]
			else:
				message = ""

	return output

func _client_irc_handle_data_received():
	var packet_text = _client_irc.get_packet().get_string_from_utf8()
	irc_inject_packet(packet_text)

func irc_inject_packet(packet_text):

	# This might be multiple messages, separated by CRLF, so split it up.
	var irc_messages = packet_text.split("\r\n")

	for message in irc_messages:
		if message.length():
#			print("IRC: " + message)
			var parsed_message = _parse_irc_message(message)

			# Just respond to pings right here.
			if parsed_message["command"].to_lower() == "ping":
				_client_irc_send("PONG :" + parsed_message["params"][0])

			# Raids and other stuff that comes in by USERNOTICE.
			if parsed_message["command"].to_lower() == "usernotice":
				if "msg-id" in parsed_message["tags"]:
#					print("Message ID: ", parsed_message["tags"]["msg-id"])
					if parsed_message["tags"]["msg-id"] == "raid":

						# Looks like we got an actual raid! Fire off the signal.
						twitch_service.emit_signal(
							"handle_channel_raid",
							parsed_message["tags"]["msg-param-login"],
							parsed_message["tags"]["msg-param-displayName"],
							parsed_message["tags"]["msg-param-viewerCount"])

			# Handle incoming messages, including bit cheers.
			if parsed_message["command"].to_lower() == "privmsg":

				var message_text = ""
				if parsed_message["params"].size() > 1:
					message_text = parsed_message["params"][1]

				# Make sure this is meant for us (for the channel).
				if parsed_message["params"].size() > 0:
					if parsed_message["params"][0] == "#" + twitch_service.twitch_username:

						# Bit cheer message?
						if "bits" in parsed_message["tags"]:
							twitch_service.emit_signal(
								"handle_channel_chat_message",
								parsed_message["prefix_user"], # FIXME: User or nick?
								parsed_message["tags"]["display-name"],
								message_text,
								int(parsed_message["tags"]["bits"]))
						else:
							twitch_service.emit_signal(
								"handle_channel_chat_message",
								parsed_message["prefix_user"], # FIXME: User or nick?
								parsed_message["tags"]["display-name"],
								message_text,
								0)

func _client_irc_connect_to_twitch():
	
	# If you hit this assert, it's because you never filled out the Twitch
	# client ID, which is specific to your application. If you want to find out
	# what it is for your app, you can find it in your app settings here:
	#
	# https://dev.twitch.tv/console/apps
	#
	assert(twitch_service.twitch_client_id != "")
	
	var err = _client_irc.connect_to_url(_twicth_irc_url)
	if err != OK:
		_client_irc_fail_and_restart("Connection failed: " + str(err))

	_client_irc.poll()
	while _client_irc.get_ready_state() == WebSocketPeer.STATE_CONNECTING:
		_client_irc.poll()

	if _client_irc.get_ready_state() == WebSocketPeer.STATE_CLOSED || \
		_client_irc.get_ready_state() == WebSocketPeer.STATE_CLOSING:
		
		return
	
	_client_irc_handle_connection_established("")

func _client_irc_update(delta):

	if twitch_service._twitch_user_id == -1:
		return

	_client_irc.poll()
	while _client_irc.get_available_packet_count():
		_client_irc_handle_data_received()
		_client_irc.poll()

	# See if we need to reconnect.
	if _client_irc.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		
		_client_irc_time_to_reconnect -= delta

		if _client_irc_time_to_reconnect < 0.0:

			# Reconnect to Twitch websocket.
			_client_irc_connect_to_twitch()

			# Whatever happens, set a default reconnect delay.
			_client_irc_time_to_reconnect = 20.0
