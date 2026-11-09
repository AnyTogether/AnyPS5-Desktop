import 'package:anyps5_desktop/core/together/levels.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/core/together/profiles.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_audio.dart';
import '../support/fake_together.dart';
import '../support/ui_support.dart';

/// Trophy levels, the showcase, comparing trophies and appearing offline in the launcher, against
/// the fake AnyTogether. (Their screens are in together_levels_interface_test.dart.)
void main() {
  late FakeTogether server;
  late Fixture fixture;
  late AppModel model;
  late FakeAudio audio;

  Future<void> until(bool Function() condition) async {
    for (var tries = 0; tries < 300 && !condition(); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  List<PanelRow> rows() => model.panelCategories()[model.panelCategory].rows;
  PanelRow row(String id) => rows().firstWhere((row) => row.id == id);

  Map<String, dynamic> trophyLevel(int level, {int progress = 40}) => {
    ...{'level': level, 'tier': LevelBadge.of(level).tier.name, 'frame': LevelBadge.of(level).frame},
    'points': 700,
    'levelPoints': 660,
    'nextLevelPoints': 720,
    'progress': progress,
  };

  setUp(() async {
    server = await FakeTogether.start();
    server
      ..friend('u-ana', 'ana', 'Ana', presence: {'state': 'online'})
      ..friend('u-bora', 'bora', 'Bora', presence: {'state': 'in_game', 'titleId': 'PPSA02002'});
    server.friends.first['level'] = {'level': 140, 'tier': 'silver', 'frame': 2};
    server.me['trophyLevel'] = trophyLevel(11);
    server.profiles['bora'] = {
      'userId': 'u-bora',
      'handle': 'bora',
      'displayName': 'Bora',
      'friendship': 'friends',
      'trophyLevel': trophyLevel(42),
    };
    server.showcases['bora'] = {
      'trophies': [
        {
          'titleId': 'PPSA02002',
          'gameNames': {'en': 'Neon Alley'},
          'trophyId': 3,
          'grade': 'gold',
          'hidden': false,
          'texts': {
            'en': {'name': 'Night Owl'},
          },
          'earnedAt': '2026-10-20T21:00:00Z',
          'rarity': 0.08,
          'rarityLabel': 'very_rare',
        },
      ],
      'games': null,
    };
    server.compareLists['bora'] = [
      {
        'titleId': 'PPSA02002',
        'names': {'en': 'Neon Alley'},
        'iconUrl': null,
        'mine': {'earned': 2, 'total': 42, 'progress': 4, 'points': 30},
        'theirs': {'earned': 18, 'total': 42, 'progress': 43, 'points': 690},
      },
      {
        'titleId': 'PPSA07007',
        'names': {'en': 'Harbor Lights'},
        'iconUrl': null,
        'mine': null,
        'theirs': {'earned': 3, 'total': 10, 'progress': 30, 'points': 45},
      },
    ];
    server.compareViews['bora/PPSA02002'] = {
      'titleId': 'PPSA02002',
      'game': {
        'names': {'en': 'Neon Alley'},
        'iconUrl': null,
      },
      'setHash': 'abc',
      'me': {
        'userId': 'u-me',
        'handle': 'utku',
        'displayName': 'Utku',
        'avatar': null,
        'level': {'level': 11, 'tier': 'bronze', 'frame': 1},
      },
      'them': {
        'userId': 'u-bora',
        'handle': 'bora',
        'displayName': 'Bora',
        'avatar': null,
        'level': {'level': 42, 'tier': 'bronze', 'frame': 1},
      },
      'trophies': [
        {
          'id': 0,
          'grade': 'bronze',
          'hidden': false,
          'texts': {
            'en': {'name': 'First Steps'},
          },
          'rarity': 0.8,
          'rarityLabel': 'common',
          'mine': '2026-10-21T20:00:00Z',
          'theirs': '2026-10-19T20:00:00Z',
        },
        {
          'id': 1,
          'grade': 'gold',
          'hidden': false,
          'texts': {
            'en': {'name': 'Night Owl'},
          },
          'rarity': 0.08,
          'rarityLabel': 'very_rare',
          'mine': null,
          'theirs': '2026-10-20T21:00:00Z',
        },
      ],
      'totals': {'mine': 1, 'theirs': 2, 'both': 1, 'total': 2},
    };
    audio = FakeAudio();
    fixture = makeFixture(together: server.base, audio: audio);
    model = fixture.model;
    await model.startAudio();
    model.together.email = 'utku@example.com';
    await model.together.sendCode();
    model.together.code = '123456';
    await model.together.verify();
    await until(() => model.together.hub.friends.loaded && model.together.hub.self.loaded);
  });

  tearDown(() async {
    model.dispose();
    await server.close();
    T.language = Language.english;
    fixture.dispose();
  });

  group('trophy levels', () {
    test('my level beside my name; friends with theirs, none where it is kept from me', () {
      expect(model.together.hub.self.level?.level, 11);
      model.open(Layer.friends);
      expect(row('friends-me').level?.level, 11);
      expect(row('friend-u-ana').level, LevelBadge.of(140));
      expect(row('friend-u-bora').level, isNull);
      model.together.openSettings();
      expect(row('together-user').level?.level, 11);
    });

    test('a level reached: the toast with its badge and the trophy sound; a friend\'s changes their row', () async {
      server.me['trophyLevel'] = trophyLevel(12, progress: 5);
      server.push('level.up', {
        'userId': 'u-me',
        'handle': 'utku',
        'displayName': 'Utku',
        'level': 12,
        'tier': 'bronze',
        'frame': 1,
      });
      await until(() => model.toast == 'Trophy level 12');
      expect(model.toastLevel, LevelBadge.of(12));
      expect(audio.cues.last, 'unlocked');
      await until(() => model.together.hub.self.level?.progress == 5);

      server.push('level.up', {
        'userId': 'u-bora',
        'handle': 'bora',
        'displayName': 'Bora',
        'level': 43,
        'tier': 'bronze',
        'frame': 1,
      });
      await until(() => model.together.hub.friends.byId('u-bora')?.level?.level == 43);
      // A friend's level: a word while the launcher is in front and no game runs, as on the Mac.
      await until(() => model.toast == 'Bora reached trophy level 43');
      model.open(Layer.friends);
      expect(row('friend-u-bora').level?.level, 43);
    });

    test('in Turkish', () async {
      T.language = Language.byCode('tr');
      server.push('level.up', {'userId': 'u-me', 'level': 12, 'tier': 'bronze', 'frame': 1});
      await until(() => model.toast == 'Kupa seviyesi 12');
    });
  });

  group('showcase and comparing', () {
    test("a friend's profile: their level, showcase and Compare trophies first", () async {
      await model.together.openProfile('bora');
      final page = model.together.profile!;
      expect(page.profile.trophyLevel?.level, 42);
      expect(page.showcase.value!.trophies!.single.name('en'), 'Night Owl');
      expect(page.showcase.value!.games, isNull);
      expect(model.together.canCompare, isTrue);
      expect(model.together.profileIndex, 0);
      model.handle(launcher.Command.select);
      expect(model.overlay, Layer.compare);
      await until(() => model.together.compareGames != null);
      expect(model.together.compareWith?.handle, 'bora');
      expect(model.together.compareGames!.value!.map((game) => game.titleId), ['PPSA02002', 'PPSA07007']);
    });

    test('the games, one game side by side, back to the games, back to the profile', () async {
      await model.together.openProfile('bora');
      model.handle(launcher.Command.select);
      await until(() => model.together.compareGames != null);
      model.handle(launcher.Command.down);
      expect(model.together.compareIndex, 1);
      model.handle(launcher.Command.up);
      model.handle(launcher.Command.select);
      expect(model.together.compareTitleId, 'PPSA02002');
      await until(() => model.together.comparison != null);
      final view = model.together.comparison!.value!;
      expect(view.trophies.map((trophy) => trophy.name('en')), ['First Steps', 'Night Owl']);
      expect((view.mine, view.theirs, view.both), (1, 2, 1));
      model.handle(launcher.Command.down);
      expect(model.together.comparisonIndex, 1);
      model.handle(launcher.Command.back);
      expect(model.together.compareTitleId, isNull);
      expect(model.overlay, Layer.compare);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.profile);
      expect(model.together.profile?.profile.handle, 'bora', reason: 'the profile is still there');
    });

    test('my own profile has nothing to compare; a friend\'s options offer it', () async {
      await model.together.openMyProfile();
      expect(model.together.canCompare, isFalse);
      model.handle(launcher.Command.back);
      model.open(Layer.friends);
      (row('friend-u-ana').kind as ActionRow).run();
      expect(rows().map((row) => row.id), contains('friend-compare'));
      (row('friend-compare').kind as ActionRow).run();
      expect(model.overlay, Layer.compare);
      await until(() => model.together.compareGames != null);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.friendOptions);
    });

    test('trophies kept private: the comparison says so', () async {
      server.privateParts['bora'] = {'compare'};
      await model.together.openProfile('bora');
      model.handle(launcher.Command.select);
      await until(() => model.together.compareGames != null);
      expect(model.together.compareGames, isA<SectionPrivate<List<ComparedGame>>>());
      model.handle(launcher.Command.select);
      expect(model.together.compareTitleId, isNull, reason: 'nothing to open');
    });
  });

  group('appearing offline', () {
    test('the setting: Online, Idle, Do not disturb or Invisible, sent to the server, shown on my name', () async {
      model.together.openSettings();
      final ids = rows().map((row) => row.id).toList();
      expect(ids.indexOf('together-presence'), ids.indexOf('together-online') + 1);
      final presence = row('together-presence');
      expect(presence.title, 'Show me as');
      expect(presence.detail, 'Friends see you online and what you play.');
      final choice = presence.kind as ChoiceRow;
      expect(choice.options, ['Online', 'Idle', 'Do not disturb', 'Invisible']);
      expect(choice.selected, 0);
      choice.set(3);
      await until(() => server.callsTo('me/presence', method: 'PATCH').isNotEmpty);
      expect(server.callsTo('me/presence', method: 'PATCH').single.body, {
        'appearOffline': true,
        'status': 'invisible',
      });
      expect((row('together-presence').kind as ChoiceRow).selected, 3);
      expect(
        row('together-presence').detail,
        'Friends see you as offline. Messages, parties and cloud saves keep working.',
      );
      expect(row('together-user').detail, 'Utku · Appearing offline');
      expect(row('together-user').person?.status, PersonStatus.offline);
      model.open(Layer.friends);
      expect(row('friends-me').detail, contains('Appearing offline'));
    });

    test('Do not disturb and Idle on a server that has them: a red dot and a moon on my name', () async {
      server.presenceStatuses = true;
      model.together.openSettings();
      (row('together-presence').kind as ChoiceRow).set(2);
      await until(() => model.together.myStatus == PresenceStatus.dnd && server.me['status'] == 'dnd');
      expect(server.callsTo('me/presence', method: 'PATCH').single.body, {'appearOffline': false, 'status': 'dnd'});
      expect((row('together-presence').kind as ChoiceRow).selected, 2);
      expect(row('together-presence').detail, 'Friends see that you do not want to be disturbed.');
      expect(row('together-user').detail, 'Utku · Do not disturb');
      expect(row('together-user').person?.status, PersonStatus.dnd);
      (row('together-presence').kind as ChoiceRow).set(1);
      await until(() => server.me['status'] == 'idle');
      expect(row('together-user').person?.status, PersonStatus.idle);
      expect(row('together-presence').detail, 'Friends see you as away.');
    });

    test('Idle on a server before statuses: back to Online, with a short note', () async {
      model.together.openSettings();
      (row('together-presence').kind as ChoiceRow).set(1);
      await until(() => model.toast == 'Idle and do not disturb are not available on this server yet');
      expect(model.together.myStatus, PresenceStatus.online);
      expect((row('together-presence').kind as ChoiceRow).selected, 0);
    });

    test("friends' idle and do not disturb: their dots and words; invisible and a missing status as today", () {
      final together = model.together;
      expect(TogetherModel.status(Presence.fromJson({'state': 'online', 'status': 'idle'})), PersonStatus.idle);
      expect(TogetherModel.status(Presence.fromJson({'state': 'online', 'status': 'dnd'})), PersonStatus.dnd);
      expect(
        TogetherModel.status(Presence.fromJson({'state': 'in_game', 'titleId': 'PPSA01001', 'status': 'dnd'})),
        PersonStatus.dnd,
      );
      expect(TogetherModel.status(Presence.fromJson({'state': 'online', 'status': 'invisible'})), PersonStatus.offline);
      expect(TogetherModel.status(Presence.fromJson({'state': 'online'})), PersonStatus.online);
      expect(TogetherModel.status(Presence.fromJson({'state': 'away'})), PersonStatus.away);
      expect(together.presenceText(Presence.fromJson({'state': 'online', 'status': 'idle'})), 'Idle');
      expect(together.presenceText(Presence.fromJson({'state': 'online', 'status': 'dnd'})), 'Do not disturb');
      expect(together.presenceText(Presence.fromJson({'state': 'online', 'status': 'invisible'})), 'Offline');
      expect(together.presenceText(Presence.fromJson({'state': 'online'})), 'Online');
    });

    test('another device turns it on and off; the next start reads it from /me', () async {
      server.push('presence.mode', {'appearOffline': true});
      await until(() => model.together.hub.self.appearOffline);
      model.together.openSettings();
      expect((row('together-presence').kind as ChoiceRow).selected, 3);
      server.push('presence.mode', {'appearOffline': false});
      await until(() => !model.together.hub.self.appearOffline);

      server.me['appearOffline'] = true;
      await model.together.hub.self.refresh();
      expect(model.together.hub.self.appearOffline, isTrue);
    });

    test('a server without it: turned back, with a short note', () async {
      server.answers['PATCH me/presence'] = FakeTogether.problem(404, 'not_found');
      model.together.openSettings();
      (row('together-presence').kind as ChoiceRow).set(3);
      await until(() => model.toast == 'Appearing offline is not available on this server yet');
      expect(model.together.hub.self.appearOffline, isFalse);
      expect((row('together-presence').kind as ChoiceRow).selected, 0);
    });
  });

  group('back from a profile', () {
    test('Settings › AnyTogether › My Profile: Back lands on AnyTogether, on the row', () async {
      model.together.openSettings();
      model.panelRow = rows().indexWhere((row) => row.id == 'together-profile');
      (row('together-profile').kind as ActionRow).run();
      expect(model.overlay, Layer.profile);
      await until(() => model.together.profile != null || model.together.profileFailed);
      model.mouseBack();
      expect(model.overlay, Layer.settings);
      expect(model.panelCategories()[model.panelCategory].id, 'together');
      expect(rows()[model.panelRow].id, 'together-profile');
    });

    test('the feed and a leaderboard go back to the section they were opened from', () async {
      model.together.openSettings();
      model.together.openFeed();
      expect(model.overlay, Layer.feed);
      model.handle(launcher.Command.back);
      expect(model.overlay, Layer.settings);
      expect(model.panelCategories()[model.panelCategory].id, 'together');
    });
  });
}
