import 'dart:io';

import 'package:anyps5_desktop/core/libmpv.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/posts.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/clip_player.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/ui_support.dart';

/// A clip player that plays nothing: what it was asked to open, play or pause and move to.
class FakeClipPlayback implements ClipPlayback {
  final List<String> opened = [];
  final List<Duration> seeks = [];
  int toggles = 0;
  bool disposed = false;
  final ValueNotifier<ClipState> _state = ValueNotifier(const ClipState());

  @override
  ValueListenable<ClipState> get state => _state;

  set now(ClipState state) => _state.value = state;

  @override
  Future<void> open(String source) async => opened.add(source);

  @override
  Future<void> playOrPause() async {
    toggles++;
    _state.value = _state.value.copyWith(playing: !_state.value.playing);
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Widget view(BuildContext context) => const ColoredBox(key: ValueKey('fake-video'), color: Colors.black);

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  group('the gallery plays a clip in the launcher, as on the Mac', () {
    late Fixture fixture;
    late AppModel model;
    late List<FakeClipPlayback> players;
    late String shot;
    late String clip;

    setUp(() {
      players = [];
      fixture = makeFixture(clipPlayback: () => FakeClipPlayback()..let(players.add));
      model = fixture.model;
      shot = p.join(fixture.temp.path, 'PPSA01001-20261026-115900.png');
      clip = p.join(fixture.temp.path, 'PPSA01001-clip-20261026-120000.mp4');
      File(shot).writeAsBytesSync(png(16, 9, (x, y) => 0x3366FFFF));
      File(clip).writeAsBytesSync(List.filled(64, 1));
      model.selected = model.games.indexWhere((game) => game.titleId == 'PPSA01001');
      model.open(Layer.gallery);
      model.galleryShots = [shot, clip];
      model.galleryIndex = 1;
    });

    tearDown(() {
      T.language = Language.english;
      fixture.dispose();
    });

    test('✕ on a clip shows it over the whole screen and never hands it to the system player', () {
      model.handle(Command.select);
      expect(model.galleryViewing, isTrue);
      expect(model.galleryIndex, 1);
      expect(fixture.opened, isEmpty);
      // ← and → move through the gallery as they do on a picture; ○ goes back to the grid.
      model.handle(Command.left);
      expect(model.galleryIndex, 0);
      model.handle(Command.right);
      expect(model.galleryIndex, 1);
      model.handle(Command.back);
      expect(model.galleryViewing, isFalse);
      expect(model.overlay, Layer.gallery);
      expect(fixture.opened, isEmpty);
    });

    test('openClip and a click on a clip open the viewer on it, not the system player', () {
      model.galleryIndex = 0;
      model.openClip(clip);
      expect(model.galleryViewing, isTrue);
      expect(model.galleryIndex, 1);
      model.galleryViewing = false;
      model.tapShot(1);
      expect(model.galleryViewing, isTrue);
      expect(fixture.opened, isEmpty);
    });

    test('a clip the player could not open goes to the system player: a file as a file, a link as it is', () {
      model.playClipOutside(clip);
      model.playClipOutside('https://media.example/clip.mp4?sig=1');
      expect(fixture.opened, [Uri.file(clip), Uri.parse('https://media.example/clip.mp4?sig=1')]);
    });

    testWidgets('the viewer plays the clip from the start, the next one when → moves to it, and lets it go', (
      tester,
    ) async {
      final second = p.join(fixture.temp.path, 'PPSA01001-clip-20261026-120100.mp4');
      File(second).writeAsBytesSync(List.filled(64, 1));
      model.galleryShots = [shot, clip, second];
      model.galleryIndex = 1;
      model.galleryViewing = true;
      model.refresh();
      await pumpLauncher(tester, model);
      expect(players, hasLength(1));
      expect(players.single.opened, [clip]);
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(model.galleryIndex, 2);
      expect(players.single.opened, [clip, second], reason: 'one player, the next clip in it');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(model.galleryIndex, 1);
      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(model.galleryIndex, 0);
      expect(players.single.disposed, isTrue, reason: 'a picture needs no player');
      expect(find.byKey(const ValueKey('fake-video')), findsNothing);
      expect(fixture.opened, isEmpty);
    });

    testWidgets('a clip that cannot be opened goes to the system player once', (tester) async {
      model.galleryViewing = true;
      model.refresh();
      await pumpLauncher(tester, model);
      players.single.now = const ClipState(failed: true);
      await settle(tester);
      players.single.now = const ClipState(failed: true, position: Duration(seconds: 1));
      await settle(tester);
      expect(fixture.opened, [Uri.file(clip)]);
      expect(find.byKey(const ValueKey('fake-video')), findsNothing);
    });

    testWidgets('without a player the clip shows its picture, as before', (tester) async {
      final plain = makeFixture();
      addTearDown(plain.dispose);
      final other = plain.model;
      other.selected = other.games.indexWhere((game) => game.titleId == 'PPSA01001');
      other.open(Layer.gallery);
      other.galleryShots = [clip];
      other.galleryIndex = 0;
      other.galleryViewing = true;
      other.refresh();
      await pumpLauncher(tester, other);
      expect(find.byKey(const ValueKey('clip-badge')), findsOneWidget);
      expect(plain.opened, isEmpty);
    });
  });

  group('the bar over a clip', () {
    Future<FakeClipPlayback> pump(WidgetTester tester, {ClipState? state}) async {
      final playback = FakeClipPlayback();
      if (state != null) playback.now = state;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 800,
              height: 450,
              child: ClipPlayerView(
                source: '/v/clip.mp4',
                create: () => playback,
                onFailed: (_) {},
                accent: Colors.blue,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return playback;
    }

    testWidgets('paused, it shows: the track moves through the clip and ▶ plays it', (tester) async {
      final semantics = tester.ensureSemantics();
      final playback = await pump(tester, state: const ClipState(duration: Duration(seconds: 40)));
      expect(playback.opened, ['/v/clip.mp4']);
      expect(find.byKey(const ValueKey('clip-bar')), findsOneWidget);
      expect(find.text('0:00 / 0:40'), findsOneWidget);
      expect(find.bySemanticsLabel('Play'), findsOneWidget);
      // A click halfway along the track goes to the middle.
      final track = tester.getRect(find.byKey(const ValueKey('clip-track')));
      await tester.tapAt(track.center);
      expect(playback.seeks.single.inMilliseconds, closeTo(20000, 50));
      await tester.tap(find.byKey(const ValueKey('clip-play')));
      await tester.pump();
      expect(playback.toggles, 1);
      expect(playback.state.value.playing, isTrue);
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('playing, it waits for the pointer and goes after a moment of stillness', (tester) async {
      final playback = await pump(tester, state: const ClipState(playing: true, duration: Duration(seconds: 40)));
      final bar = find.byKey(const ValueKey('clip-bar'));
      double opacity() =>
          tester.widget<AnimatedOpacity>(find.ancestor(of: bar, matching: find.byType(AnimatedOpacity)).first).opacity;
      expect(opacity(), 0);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.byType(ClipPlayerView)));
      await mouse.moveBy(const Offset(4, 4));
      await tester.pump();
      expect(opacity(), 1);
      await tester.pump(const Duration(seconds: 3));
      expect(opacity(), 0);
      await mouse.removePointer();
      expect(playback.disposed, isFalse);
    });

    test('the clock and how far in', () {
      expect(ClipState.clock(const Duration(seconds: 7)), '0:07');
      expect(ClipState.clock(const Duration(seconds: 90)), '1:30');
      expect(const ClipState(position: Duration(seconds: 10), duration: Duration(seconds: 40)).progress, 0.25);
      expect(const ClipState().progress, 0);
    });

    test('the libmpv the plugin linked is the one media_kit opens (Linux)', () {
      expect(
        MediaKitClipPlayback.libmpvIn([
          '7f00-7f10 r--p 00000000 08:01 1 /opt/anyps5-desktop/lib/libflutter_linux_gtk.so',
          '7f20-7f30 r-xp 00000000 08:01 2 /opt/anyps5-desktop/lib/libmpv.so.1',
          '7f40-7f50 rw-p 00000000 00:00 0 [heap]',
        ]),
        '/opt/anyps5-desktop/lib/libmpv.so.1',
      );
      expect(MediaKitClipPlayback.libmpvIn(['7f40-7f50 rw-p 00000000 00:00 0 [heap]']), isNull);
    });
  });

  group('Linux without libmpv: the clip says how to install it', () {
    Future<List<String>> pump(WidgetTester tester, List<String> commands) async {
      final handed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 960,
              height: 540,
              child: ClipPlayerView(
                source: '/v/clip.mp4',
                create: () => throw LibmpvMissing(commands),
                onFailed: handed.add,
                accent: Colors.blue,
                poster: const ColoredBox(key: ValueKey('poster'), color: Colors.teal),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return handed;
    }

    testWidgets('the picture stays, with what is missing and the command for this system', (tester) async {
      final handed = await pump(tester, ['sudo apt install libmpv2']);
      expect(find.byKey(const ValueKey('poster')), findsOneWidget);
      expect(find.byKey(const ValueKey('libmpv-missing')), findsOneWidget);
      expect(find.text('Clips need libmpv'), findsOneWidget);
      expect(find.textContaining("your system's libmpv"), findsOneWidget);
      expect(find.text('sudo apt install libmpv2'), findsOneWidget);
      expect(find.byKey(const ValueKey('clip-bar')), findsNothing);
      // Not handed to the system's player by itself: only when asked.
      expect(handed, isEmpty);
      await tester.tap(find.byKey(const ValueKey('libmpv-elsewhere')));
      await tester.pump();
      expect(handed, ['/v/clip.mp4']);
    });

    testWidgets('a distribution it does not know: a line for each family', (tester) async {
      await pump(tester, SystemLibmpv.all);
      for (final command in SystemLibmpv.all) {
        expect(find.text(command), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the copy button copies the command', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pump(tester, ['sudo pacman -S mpv']);
      expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('libmpv-copy-sudo pacman -S mpv')));
      await tester.pump();
      expect(copied, 'sudo pacman -S mpv');
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(Icons.content_copy_rounded), findsOneWidget);
    });

    testWidgets('in Turkish', (tester) async {
      T.language = Language.byCode('tr');
      addTearDown(() => T.language = Language.english);
      await pump(tester, ['sudo apt install libmpv1']);
      expect(find.text('Klipler için libmpv gerekli'), findsOneWidget);
      expect(find.text('Başka bir oynatıcıda aç'), findsOneWidget);
    });
  });

  group('Captures and chats play their clips in the launcher, as on the Mac', () {
    late Fixture fixture;
    late AppModel model;

    setUp(() {
      fixture = makeFixture(clipPlayback: FakeClipPlayback.new);
      model = fixture.model;
    });

    tearDown(() {
      T.language = Language.english;
      fixture.dispose();
    });

    test('a clip post opens in the viewer, not the system player', () {
      final post = Post.fromJson({
        'id': '01',
        'author': {'userId': 'ana', 'handle': 'ana', 'displayName': 'Ana'},
        'media': [
          {'id': 'a', 'kind': 'clip', 'url': 'https://x/a.mp4', 'poster': 'https://x/a.jpg', 'durationMs': 12000},
        ],
        'createdAt': '2026-11-07T10:00:00Z',
      });
      model.together.viewCapture(post);
      expect(model.together.captures.viewing?.clip, isTrue);
      expect(model.together.captures.viewing?.url, 'https://x/a.mp4');
      expect(fixture.opened, isEmpty);
      model.together.capturesCommand(Command.back);
      expect(model.together.captures.viewing, isNull);
    });

    test('a clip or photo sent in a chat opens over the whole screen; ✕, ○ or △ close it', () {
      final together = model.together;
      together.viewChatMedia(
        const MediaLink(id: 'm1', kind: 'clip', url: 'https://x/m1.mp4', poster: 'https://x/m1.jpg'),
      );
      expect(together.chatViewing?.clip, 'https://x/m1.mp4');
      expect(together.chatViewing?.poster, 'https://x/m1.jpg');
      expect(fixture.opened, isEmpty);
      together.messagesCommand(Command.back);
      expect(together.chatViewing, isNull);
      together.viewChatMedia(const MediaLink(id: 'm2', kind: 'image', url: 'https://x/m2.png'));
      expect(together.chatViewing?.isClip, isFalse);
      expect(together.chatViewing?.link, 'https://x/m2.png');
      together.messagesCommand(Command.options);
      expect(together.chatViewing, isNull);
      // One taken away opens nothing.
      together.viewChatMedia(const MediaLink(id: 'm3', kind: 'clip', url: 'https://x/m3.mp4', gone: true));
      expect(together.chatViewing, isNull);
      expect(fixture.opened, isEmpty);
    });
  });
}

extension<V> on V {
  V let(void Function(V value) use) {
    use(this);
    return this;
  }
}
