import 'dart:typed_data';

import 'package:anyps5_desktop/core/desktop/desktop.dart';
import 'package:anyps5_desktop/core/desktop/layer_overlay.dart';
import 'package:anyps5_desktop/core/desktop/linux_desktop.dart';
import 'package:test/test.dart';

/// What the launcher asked of the runner's layer-shell surfaces.
class FakeLayerOverlay implements LayerOverlay {
  final calls = <String>[];
  final shown = <(String, LayerAnchor, int, int, double, double)>[];
  final updates = <(double, int)>[];
  bool works = true;

  @override
  Future<bool> show(
    String name,
    RgbaImage image, {
    required LayerAnchor anchor,
    int left = 0,
    int top = 0,
    double scale = 1,
    double opacity = 1,
  }) async {
    calls.add('show $name');
    shown.add((name, anchor, left, top, scale, opacity));
    return works;
  }

  @override
  Future<bool> update(String name, {required double opacity, required int top}) async {
    if (calls.last != 'update $name') calls.add('update $name');
    updates.add((opacity, top));
    return works;
  }

  @override
  Future<bool> hide(String name) async {
    calls.add('hide $name');
    return true;
  }
}

/// Cards and the LIVE badge over the game on Linux: X11's own windows, Wayland's layer shell where
/// the compositor has it, the system notification where it does not (GNOME).
void main() {
  final card = RgbaImage(2, 1, Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 128]));

  group('the way a card goes over the game', () {
    test('X11 draws its own window once Xlib loads', () {
      expect(linuxCardWay(session: LinuxSession.x11, xlib: true, layerShell: false), LinuxCardWay.x11Window);
      expect(linuxCardWay(session: LinuxSession.x11, xlib: false, layerShell: true), LinuxCardWay.notification);
    });

    test('Wayland takes layer shell where the runner found it, the notification elsewhere', () {
      expect(linuxCardWay(session: LinuxSession.wayland, xlib: false, layerShell: true), LinuxCardWay.layerShell);
      expect(linuxCardWay(session: LinuxSession.wayland, xlib: true, layerShell: false), LinuxCardWay.notification);
      expect(linuxCardWay(session: LinuxSession.none, xlib: false, layerShell: true), LinuxCardWay.notification);
    });

    test('the badge stays out of the picture: the window alone on X11, always under Wayland', () {
      expect(linuxBadgeReach(LinuxCardWay.x11Window), BadgeReach.windowRecordingOnly);
      expect(linuxBadgeReach(LinuxCardWay.layerShell), BadgeReach.excluded);
      expect(linuxBadgeReach(LinuxCardWay.notification), BadgeReach.none);
    });

    test('the runner says layer shell is there with the monitor\'s scale', () {
      expect(layerShellScale({'ANYPS5_LAYER_SHELL': '2'}), 2);
      expect(layerShellScale({'ANYPS5_LAYER_SHELL': '1'}), 1);
      expect(layerShellScale({'ANYPS5_LAYER_SHELL': '0'}), isNull);
      expect(layerShellScale({'ANYPS5_LAYER_SHELL': 'yes'}), isNull);
      expect(layerShellScale({}), isNull);
    });
  });

  group('under Wayland', () {
    const wayland = {'XDG_SESSION_TYPE': 'wayland', 'WAYLAND_DISPLAY': 'wayland-0'};

    test('with layer shell a card comes in at the top, fades and goes, never above the edge', () async {
      final layers = FakeLayerOverlay();
      final desktop = LinuxDesktop(
        environment: {...wayland, 'ANYPS5_LAYER_SHELL': '2'},
        overlay: layers,
        cardStay: const Duration(milliseconds: 300),
      );
      expect(desktop.cardWay, LinuxCardWay.layerShell);
      expect(desktop.canShowCard, isTrue);
      expect(desktop.cardScale(null), 2, reason: 'the monitor\'s scale, for a sharp card');
      expect(await desktop.showCard(card), isTrue);
      expect(layers.calls, ['show card', 'update card', 'hide card']);
      expect(layers.shown.single, ('card', LayerAnchor.top, 0, 0, 2.0, 0.0));
      expect(layers.updates.first.$1, lessThan(0.5), reason: 'it fades in');
      expect(layers.updates.map((update) => update.$2), everyElement(inInclusiveRange(0, 18)));
      expect(layers.updates.map((update) => update.$1), contains(1.0));
    });

    test('one card at a time; a surface that cannot show says so and is taken away', () async {
      final layers = FakeLayerOverlay();
      final desktop = LinuxDesktop(
        environment: {...wayland, 'ANYPS5_LAYER_SHELL': '1'},
        overlay: layers,
        cardStay: const Duration(milliseconds: 50),
      );
      final first = desktop.showCard(card);
      expect(await desktop.showCard(card), isFalse);
      expect(await first, isTrue);
      layers
        ..works = false
        ..calls.clear();
      expect(await desktop.showCard(card), isFalse, reason: 'then the notification is the way');
      expect(layers.calls, ['show card', 'hide card']);
    });

    test('the LIVE badge is a surface at the top left, taken away with null', () async {
      final layers = FakeLayerOverlay();
      final desktop = LinuxDesktop(environment: {...wayland, 'ANYPS5_LAYER_SHELL': '1'}, overlay: layers);
      expect(desktop.badgeReach, BadgeReach.excluded);
      expect(await desktop.showBadge(card, pid: 4), isTrue);
      expect(layers.shown.single, ('badge', LayerAnchor.topLeft, 18, 14, 1.0, 1.0));
      expect(await desktop.showBadge(null), isTrue);
      expect(layers.calls, ['show badge', 'hide badge']);
    });

    test('without layer shell (GNOME) there is no card or badge, and nothing is asked of the runner', () async {
      final layers = FakeLayerOverlay();
      final desktop = LinuxDesktop(environment: wayland, overlay: layers);
      expect(desktop.cardWay, LinuxCardWay.notification);
      expect(desktop.canShowCard, isFalse);
      expect(desktop.badgeReach, BadgeReach.none);
      expect(desktop.cardScale(null), 1);
      expect(await desktop.showCard(card), isFalse);
      expect(await desktop.showBadge(card), isFalse);
      expect(layers.calls, isEmpty);
    });

    test('a runner without the channel (no overlay) keeps the notification', () {
      final desktop = LinuxDesktop(environment: {...wayland, 'ANYPS5_LAYER_SHELL': '1'});
      expect(desktop.canShowCard, isFalse);
      expect(desktop.badgeReach, BadgeReach.none);
    });
  });
}
