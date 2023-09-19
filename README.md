# Kiri's Twitch Integration for Godot 4

Hiya! This is the Twitch integration I (Kiri) use for my VTuber avatar
renderer.

It started off in Godot 3 as a bare minimum way for me to get my
VTuber softare talking to Twitch, and then it got ported over to Godot
4 and became a little more fleshed out. But as a result, it's only
really got the "throw things at my face in response to Twitch redeems
and bit cheers" use case in mind, so it may need to be extended to be
more useful.

## Setup

It should be pretty simple to set up. Here's the rundown:

  1. Make a Twitch app in the dev console.
  2. Add a **Redirect URL** to http://localhost:3017 (localhost, port
	 3017, http NOT https).
  3. Create a **TwitchService** node in your application.
  4. Copy the **Client ID** from the Twitch console for the app to the
	 **twitch_client_id** exported variable.

![Screenshot of the dev console emphasizing the above
information.](dev_console_example.png)

If everything is set up correctly and nothing else has been touched,
this should automatically trigger an attempt to authenticate on
startup.

User credentials are, by default, stored in
"user://twitch_config.ini". It will automatically load and attempt to
use these credentials on subsequent startups. This path can be changed
with **twitch_config_path** and the functionality can be disabled by
setting **auto_save_credentials** and **auto_load_credentials**.

## Reacting to Twitch Events

The TwitchService node has three signals:

  1. **handle_channel_chat_message**: Connect something to this to
	 react to chat messages, *including bit cheers*.
  2. **handle_channel_points_redeem**: Connect tis to handle point
	 redeems. The redeem name is on of the parameters, so filter
	 redeem events on the receiving end.
  3. **handle_channel_raid**: Connect this to handle a raid.

Hopefully the arguments these take should be self-explanatory.

## Extending It

Right now the service only selects a limited number of scopes:

  1. **channel:read:redemptions**: Needed for point redeems.
  2. **chat:read**: Needed for reading chat (and raids?).
  3. **bits:read**: Needed for reacting to bit donations.

See **_start_oauth_process** to adjust the generated URL to modify the
scopes used.

### PubSub

See **_client_pubsub_handle_connection_established** for pubsub events
that it subscribes to.

See **_client_pubsub_handle_message** for the code that recognizes and
reacts to PubSub events.

See the [Twitch documentation about
PubSub](https://dev.twitch.tv/docs/pubsub/) for a list of topics to
subscribe to.

See the [Twitch documentation about
scopes](https://dev.twitch.tv/docs/authentication/scopes/) for a list
of scopes to use when requesting the token.

### IRC

See **irc_inject_packet** for code that reacts to incoming IRC data
and emits signals.

