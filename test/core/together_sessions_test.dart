import 'package:anyps5_desktop/core/together/game_sessions.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:test/test.dart';

void main() {
  test('engine builds and game versions as the server takes them', () {
    expect(GameSession.cleanEngineBuild(' 0.2.13 (abc)/x '), '0.2.13--abc--x');
    expect(GameSession.cleanEngineBuild(''), 'unknown');
    expect(GameSession.cleanEngineBuild('a' * 80), hasLength(64));
    expect(GameSession.cleanGameVersion('01.000.000'), '01.000.000');
    expect(GameSession.cleanGameVersion('9' * 40), hasLength(32));
  });

  test('a session says why another copy cannot join', () {
    final session = GameSession.fromJson({
      'id': 's1',
      'host': {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
      'titleId': 'PPSA01001',
      'gameVersion': '01.000.000',
      'engineBuild': 'toolkit-1',
      'capacity': 4,
      'joinable': true,
      'players': [
        {'userId': 'u-ana', 'handle': 'ana', 'displayName': 'Ana'},
      ],
      'members': [
        {
          'userId': 'u-ana',
          'device': 'd1',
          'properties': {'port': 3074},
        },
      ],
    });
    expect(session.mismatch(gameVersion: '01.000.000', engineBuild: 'toolkit-1'), isNull);
    expect(session.mismatch(gameVersion: '01.001.000', engineBuild: 'toolkit-1'), SessionMismatch.gameVersion);
    expect(session.mismatch(gameVersion: '01.000.000', engineBuild: 'toolkit-2'), SessionMismatch.engineBuild);
    expect((session.json['members'] as List).single, containsPair('properties', {'port': 3074}));
  });

  test('names in the language asked, else English, else any', () {
    expect(pickName({'tr': 'Yörünge', 'en': 'Orbit'}, 'tr'), 'Yörünge');
    expect(pickName({'tr': 'Yörünge', 'en': 'Orbit'}, 'de'), 'Orbit');
    expect(pickName({'ja': 'A', 'fr': 'B'}, 'de'), 'B');
    expect(pickName({}, 'en'), isNull);
    expect(Profiles.path('@ana b'), 'ana%20b');
  });
}
