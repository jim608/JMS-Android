import 'discord_transport_stub.dart'
    if (dart.library.io) 'discord_transport_io.dart' as platform;
import 'discord_transport_types.dart';

export 'discord_transport_types.dart';

bool get discordDesktopSupported => platform.discordDesktopSupported;
int get discordProcessId => platform.discordProcessId;

Future<DiscordIpcTransport> openDiscordIpcTransport(Duration timeout) =>
    platform.openDiscordIpcTransport(timeout);
