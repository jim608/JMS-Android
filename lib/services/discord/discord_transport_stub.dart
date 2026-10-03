import 'discord_presence_client.dart';
import 'discord_transport_types.dart';

bool get discordDesktopSupported => false;
int get discordProcessId => 0;

Future<DiscordIpcTransport> openDiscordIpcTransport(Duration timeout) async {
  throw const DiscordIpcException(DiscordIpcFailure.unsupported);
}
