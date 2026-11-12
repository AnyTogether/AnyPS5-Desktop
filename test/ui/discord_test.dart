import 'package:anyps5_desktop/core/discord_presence.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_process.dart';
import 'package:anyps5_desktop/core/together/socket.dart';
import 'package:anyps5_desktop/core/together/parties.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../core/discord_presence_test.dart' show FakePipe;
import '../support/fake_process.dart';
import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Settings › Behaviour › Show the game you play on Discord, and what the launcher tells
/// Discord: the party ("In a party"), the Join button with its code, and nothing once the
/// setting goes off.
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late List<(int, Map<String, dynamic>)> frames;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  Map<String, dynamic>? lastActivity() {
    final sets = frames.where((frame) => frame.$1 == 1).toList();
    if (sets.isEmpty) return null;
    return (sets.last.$2['args'] as Map)['activity'] as Map<String, dynamic>?;
  }

  setUp(() async {
    server = await FakeTogether.start();
    frames = [];
    fixture = makeFixture(
      together: server.base,
      discord: () => DiscordPresence(applicationId: 'app', connect: () async => FakePipe(frames)),
    );
    model = fixture.model;
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  List<PanelRow> general() {
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'general'));
    return model.panelCategories()[model.panelCategory].rows;
  }

  test('the two rows follow Show Hidden Trophies, on by default', () {
    final ids = general().map((row) => row.id).toList();
    expect(ids.indexOf('discord'), ids.indexOf('hiddenTrophies') + 1);
    expect(ids.indexOf('discordJoin'), ids.indexOf('discord') + 1);
    final row = general().firstWhere((row) => row.id == 'discord');
    expect(row.title, 'Show the game you play on Discord');
    expect((row.kind as ToggleRow).value, isTrue);
    expect(model.preferences.toJson()['discordPresence'], isTrue);
  });

  test('a party shows with its size and the Join button; the setting off clears it', () async {
    server.inParty([FakeTogether.card('u-ana', 'ana', 'Ana')], leader: 'u-me');
    await model.together.hub.parties.refresh();
    // The leader has no code: one is made for the button. The fake's code is already out of
    // time, so it is not asked for again and no button shows.
    await until(() => server.callsTo('parties/${model.together.hub.parties.party!.id}/code').isNotEmpty);
    await until(() => lastActivity() != null);
    final activity = lastActivity()!;
    expect(activity['details'], 'In a party');
    expect(activity['state'], 'AnyPS5 · Linux');
    expect(activity['party'], {
      'id': model.together.hub.parties.party!.id,
      'size': [2, 8],
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.callsTo('parties/${model.together.hub.parties.party!.id}/code'), hasLength(1));

    // A code that works: the button opens its page.
    final party = model.together.hub.parties.party!;
    model.together.hub.parties.party = party.copyWith(
      joinCode: () => JoinCode(
        code: 'H8NZ4WRB',
        url: Uri.parse('https://anytogether.net/join/H8NZ4WRB'),
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
      ),
    );
    model.discord.update();
    await until(() => lastActivity()?['buttons'] != null);
    expect(lastActivity()!['buttons'], [
      {'label': 'Join on AnyTogether', 'url': 'https://anytogether.net/join/H8NZ4WRB'},
    ]);

    final toggle = general().firstWhere((row) => row.id == 'discord').kind as ToggleRow;
    toggle.set(false);
    await until(() => frames.last.$1 == 1 && (frames.last.$2['args'] as Map)['activity'] == null);
    expect(model.preferences.discordPresence, isFalse);
    expect(model.discord.shown, isNull);
  });

  test('an emulator game reaches neither Discord nor AnyTogether presence', () async {
    final process = FakeGameProcess();
    addTearDown(process.quit);
    final disc = Game(
      folder: 'retro',
      titleId: 'retro-ps1-0123456789',
      name: 'Crash Team Racing (USA).cue',
      names: const {},
      defaultLanguage: 'en-US',
      version: '',
      executable: ExecutableKind.disc,
      retro: (platform: RetroPlatform.ps1, path: 'Crash Team Racing (USA).cue'),
    );
    for (var tries = 0; tries < 300 && !model.together.connected; tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    model.running = (disc, RunningGame(process, process.exitCode, DateTime.now()));
    model.together.gameChanged();
    model.discord.update();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(model.together.hub.socket.presence, isA<PresenceOnline>());
    expect(frames.where((frame) => '${frame.$2}'.contains('Crash Team Racing')), isEmpty);
    expect(model.discord.shown, isNull);
  });

  test('a code the user stopped is not made again for the button', () async {
    server.inParty(const [], leader: 'u-me');
    await model.together.hub.parties.refresh();
    final id = model.together.hub.parties.party!.id;
    await until(() => server.callsTo('parties/$id/code').isNotEmpty);
    await model.together.stopJoinCode();
    expect(model.discord.codeStopped, contains(id));
    model.discord.update();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.callsTo('parties/$id/code').where((call) => call.method == 'POST'), hasLength(1));
  });
}
