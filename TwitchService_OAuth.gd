extends RefCounted
class_name TwitchService_OAuth

var twitch_service = null

var _oauth_in_process = false
var _oauth_tcpserver : TCPServer = null

# TODO: Make into an array, so we can support multiple incoming connections,
# just in case the browser tries to read our favicon or something.
var _oauth_streampeertcp : StreamPeerTCP = null
var _oauth_streampeertcp_inputbuffer : String = ""

# FIXME: Make this configurable.
var _twitch_redirect_port = 3017

var _scopes_needed : PackedStringArray = [
	"channel:read:redemptions",
	"chat:read",
	"bits:read",
	"channel:read:subscriptions",
	"moderator:read:followers",
	"bits:read",
	"user:read:chat"
]

func init(parent_twitch_service):
	twitch_service = parent_twitch_service

	# Kick off an OAuth process immediately if we don't have authorized scopes
	# we need.
	for scope in _scopes_needed:
		if not (scope in twitch_service.twitch_scopes):
			_start_oauth_process()
			break

func _stop_oauth_process():

	if _oauth_tcpserver:
		_oauth_tcpserver.stop()
		_oauth_tcpserver = null
	
	if _oauth_streampeertcp:
		_oauth_streampeertcp.disconnect_from_host()
		_oauth_streampeertcp = null

	_oauth_in_process = false
	_oauth_streampeertcp_inputbuffer = ""

func _oauth_send_page_data(peer, data):
	var http_response = "\r\n".join([
		"HTTP/1.1 200 OK",
		"Content-Type: text/html; charset=utf-8",
		"Content-Length: " + String.num_int64(len(data)),
		"Connection: close",
		"Cache-Control: max-age=0",
		"", ""])
	var full_response = http_response + data + "\n\n\n\n\n"
	var response_ascii = full_response.to_ascii_buffer()
	peer.put_data(response_ascii)
					
func _poll_oauth_server():

	if not _oauth_in_process:
		return

	# Accept incoming connections.
	if _oauth_tcpserver:
		if _oauth_tcpserver.is_connection_available():
			_oauth_streampeertcp = _oauth_tcpserver.take_connection()
	
	# Add any new incoming bytes to our input buffer.
	if _oauth_streampeertcp:
		while _oauth_streampeertcp.get_available_bytes():
			var incoming_byte = _oauth_streampeertcp.get_utf8_string(1)
			if incoming_byte != "\r":
				_oauth_streampeertcp_inputbuffer += incoming_byte

	# Only act on stuff once we have two newlines at the end of a request.	
	if _oauth_streampeertcp_inputbuffer.ends_with("\n\n"):
	
		# For each line...
		while _oauth_streampeertcp_inputbuffer.contains("\n"):
			
			# Take the line and pop it out of the buffer.
			var get_line = _oauth_streampeertcp_inputbuffer.split("\n", true)[0]
			_oauth_streampeertcp_inputbuffer = _oauth_streampeertcp_inputbuffer.substr(len(get_line) + 1)
			
			# All we care about here is the GET line.
			if get_line.begins_with("GET "):
				
				# Split "GET <path> HTTP/1.1" into "GET", <path>, and
				# "HTTP/1.1".
				var get_line_parts = get_line.split(" ")
				var http_get_path = get_line_parts[1]
				
				# If we get the root path without the arguments, then it means
				# that Twitch has stuffed the access token into the fragment
				# (after the #). Send a redirect page to read that and give it
				# to us in a GET request.
				if http_get_path == "/":	
					
					# Response page: Just a Javascript program to do a redirect
					# so we can get the access token into the a GET argument
					# instead of the fragment.
					var html_response = """
						<html><head></head><body><script>
							  var url_parts = String(window.location).split("#");
							  if(url_parts.length > 1) {
								  var redirect_url = url_parts[0] + "?" + url_parts[1];
								  window.location = redirect_url;
							  }
						</script></body></html>
					"""

					# Send webpage and disconnect.
					_oauth_send_page_data(_oauth_streampeertcp, html_response)			
					_oauth_streampeertcp.disconnect_from_host()
					_oauth_streampeertcp = null
				
				# If the path has a '?' in it at all, then it's probably our
				# redirected page.
				elif http_get_path.contains("?"):
				
					var html_response = """
						<html><head></head><body>You may now close this window.</body></html>
					"""

					# Attempt to extract the access token from the GET data.
					var path_parts  = http_get_path.split("?")
					if len(path_parts) > 1:
						var parameters = path_parts[1]
						var arg_list = parameters.split("&")
						for arg in arg_list:
							var arg_parts = arg.split("=")
							if len(arg_parts) > 1:
								if arg_parts[0] == "access_token":
									twitch_service.twitch_oauth = arg_parts[1]
									twitch_service.twitch_scopes = _scopes_needed.duplicate()

					# Send webpage and disconnect.
					_oauth_send_page_data(_oauth_streampeertcp, html_response)
					_oauth_streampeertcp.disconnect_from_host()
					_oauth_streampeertcp = null
					_stop_oauth_process()

func _start_oauth_process():
	
	_oauth_in_process = true
	
	# Kill any existing websocket server.
	if _oauth_tcpserver:
		_oauth_tcpserver.stop()
		_oauth_tcpserver = null

	# Fire up the new server.
	_oauth_tcpserver = TCPServer.new()	
	_oauth_tcpserver.listen(_twitch_redirect_port, "127.0.0.1")

	# Check client ID to make sure we aren't about to do something we'll regret.
	var ascii_twitch_id = twitch_service.twitch_client_id.to_ascii_buffer()
	for k in ascii_twitch_id:
		assert( \
			(k >= 65 and k <= 90) or \
			(k >= 97 and k <= 122) or \
			(k >= 48 and k <= 57))
	
	var scope_str = " ".join(_scopes_needed)
	scope_str = scope_str.uri_encode()

	var oauth_url = "https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=" + \
		twitch_service.twitch_client_id + \
		"&redirect_uri=http://localhost:" + \
		str(_twitch_redirect_port) + \
		"&scope=" + scope_str
		
	#"channel%3Aread%3Aredemptions%20chat%3Aread%20bits%3Aread"
	OS.shell_open(oauth_url)
