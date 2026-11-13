import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../core/remote/browser_pad_server.dart';
import '../core/audio/tones.dart';
import 'app_model.dart';
import 'components.dart';
import 'strings.dart';
import 'theme.dart';

/// Play from a browser (Settings › Phones, the macOS launcher's BrowserPlay.swift): a phone with
/// no app scans a QR code and its browser becomes a pad, through the phone server like the phone
/// app (BrowserPadServer). The server runs only while the QR code is shown, while browsers it let
/// in are connected (and two minutes after, for a reload or a locked screen), or always with Keep
/// browser play on; with the setting off it never runs.
class BrowserPlayModel {
  BrowserPlayModel(this.app);

  final AppModel app;

  /// The address to serve on, in place of the computer's local network one (tests).
  static String? hostOverride;

  /// After the last browser leaves, how long the server stays up for it to come back.
  static const grace = Duration(minutes: 2);

  BrowserPadServer? _server;
  bool showing = false;

  /// No local network address, or the port would not open.
  bool unavailable = false;
  DateTime? _quietSince;
  bool _hadPads = false;
  Timer? _timer;
  List<int>? _page;
  List<(String, String, bool)> _pads = const [];

  bool get enabled => app.preferences.browserPlay;
  bool get running => _server != null;
  Uri? get url => _server?.pairingUrl;
  DateTime? get expires => _server?.access.currentToken().expires;

  /// The browsers with the page open: name, device ID, and whether each has been let in.
  List<(String, String, bool)> get pads => _server?.connected ?? const [];

  /// Starts or stops the server for what the settings and the screen want now.
  Future<void> update() => _queue = _queue.then((_) => _update());
  Future<void> _queue = Future.value();

  Future<void> _update() async {
    try {
      final connected = pads.isNotEmpty;
      // The grace is for a browser that was here: with none ever, closing the code stops it.
      if (connected) {
        _quietSince = null;
        _hadPads = true;
      } else if (_hadPads) {
        _quietSince ??= DateTime.now();
      }
      final since = _quietSince;
      final recent = since != null && DateTime.now().difference(since) < grace;
      final remote = app.remote;
      final wanted =
          enabled &&
          remote?.port != null &&
          (showing || app.preferences.browserPlayAlways || connected || (_server != null && recent));
      final host = wanted ? hostOverride ?? await BrowserPadServer.lanAddress() : null;
      final server = _server;
      if (server != null && (!wanted || host != server.host)) {
        _server = null;
        _hadPads = false;
        _quietSince = null;
        await server.stop();
      }
      if (wanted && host == null) unavailable = true;
      if (!wanted || _server != null || host == null || remote == null) return;
      final page = _page ??= await _loadPage();
      if (page == null) {
        unavailable = true;
        return;
      }
      try {
        _server = await BrowserPadServer.startPreferred(
          host: host,
          page: page,
          controlPort: remote.port!,
          devices: remote.devices,
          players: () => remote.phonePlayers,
          changed: _padsChanged,
        );
        unavailable = false;
      } on Object {
        unavailable = true;
      }
    } finally {
      _watch();
      app.refresh();
    }
  }

  static Future<List<int>?> _loadPage() async {
    try {
      final data = await rootBundle.load('assets/browser_pad/index.html');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } on Object {
      return null;
    }
  }

  void _padsChanged() {
    final now = pads;
    if (_same(now, _pads)) return;
    _pads = now;
    app.refresh();
  }

  static bool _same(List<(String, String, bool)> a, List<(String, String, bool)> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// Once a second while anything is up: the code's countdown, a new token, whether to stop.
  void _watch() {
    if (_server == null && !showing) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (showing) app.refresh();
      unawaited(update());
    });
  }

  /// A fresh code at once (the old one stops working).
  void renew() {
    _server?.access.renewToken();
    app.refresh();
  }

  void open() {
    showing = true;
    app.open(Layer.browserPlay);
    unawaited(update().then((_) => renew()));
  }

  void close() {
    showing = false;
    app.open(Layer.settings, cue: Cue.back);
    final index = app.panelCategories().indexWhere((category) => category.id == 'phone');
    if (index >= 0) app.selectCategory(index);
    unawaited(update());
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    final server = _server;
    _server = null;
    await server?.stop();
  }

  bool command(Command command) {
    switch (command) {
      case Command.back || Command.select:
        close();
      case Command.options:
        renew();
      default:
        break;
    }
    return true;
  }

  /// Settings › Phones: the rows under the phone controller.
  List<PanelRow> settingsRows() => [
    PanelRow(
      id: 'browserPlay',
      title: T.text('browserPlay'),
      detail: T.text(enabled ? 'browserPlayDetail' : 'browserPlayOff'),
      kind: ToggleRow(enabled, (value) {
        app.preferences.browserPlay = value;
        app.savePreferences();
        unawaited(update());
      }),
    ),
    if (enabled) ...[
      PanelRow(
        id: 'browserPlayShow',
        title: T.text('browserPlayShow'),
        detail: T.text('browserPlayShowDetail'),
        kind: ActionRow(open),
      ),
      PanelRow(
        id: 'browserPlayKeep',
        title: T.text('browserPlayKeep'),
        detail: T.text('browserPlayKeepDetail'),
        kind: ToggleRow(app.preferences.browserPlayAlways, (value) {
          app.preferences.browserPlayAlways = value;
          app.savePreferences();
          unawaited(update());
        }),
      ),
    ],
  ];

  /// What the screen shows, for goldens.
  void preview({Uri? url, int? secondsLeft, List<(String, String, bool)> pads = const [], bool unavailable = false}) {
    _previewUrl = url;
    _previewLeft = secondsLeft;
    _previewPads = pads;
    this.unavailable = unavailable;
  }

  Uri? _previewUrl;
  int? _previewLeft;
  List<(String, String, bool)>? _previewPads;

  Uri? get shownUrl => _previewUrl ?? url;

  /// How long the code shown is good for, in seconds.
  int get secondsLeft => _previewLeft ?? (expires?.difference(DateTime.now()).inSeconds.clamp(0, 999) ?? 0);
  List<(String, String, bool)> get shownPads => _previewPads ?? pads;
}

/// The QR code to scan, how to, and the browsers connected so far.
class BrowserPlayView extends StatelessWidget {
  const BrowserPlayView({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final scale = LayoutScale.of(context);
    final play = model.browserPlay;
    final accent = model.accentChoice.color;
    final url = play.shownUrl;
    final left = play.secondsLeft;
    Widget step(int number, String text) => Padding(
      padding: EdgeInsets.only(bottom: 12 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24 * scale,
            height: 24 * scale,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            child: Text(
              '$number',
              style: AppText.display(13 * scale, weight: FontWeight.w800, color: Colors.black87),
            ),
          ),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Text(text, style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.85))),
          ),
        ],
      ),
    );
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.55),
      child: Center(
        child: SizedBox(
          width: 940 * scale,
          child: Glass(
            radius: 30 * scale,
            opacity: 0.5,
            padding: EdgeInsets.all(44 * scale),
            child: Row(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 300 * scale,
                      height: 300 * scale,
                      child: CustomPaint(
                        foregroundPainter: _Viewfinder(accent, 4 * scale),
                        child: Padding(
                          padding: EdgeInsets.all(10 * scale),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(26 * scale),
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(20 * scale),
                              child: url == null
                                  ? Center(
                                      child: Text(
                                        T.text(play.unavailable ? 'browserPlayNoNetwork' : 'browserPlayStarting'),
                                        textAlign: TextAlign.center,
                                        style: AppText.display(
                                          14 * scale,
                                          weight: FontWeight.w600,
                                          color: Colors.black54,
                                        ),
                                      ),
                                    )
                                  : CustomPaint(
                                      key: ValueKey(url),
                                      painter: _QrPainter(url.toString()),
                                      size: Size.infinite,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (url != null) ...[
                      SizedBox(height: 12 * scale),
                      Text(
                        '${url.host}:${url.port}',
                        style: AppText.display(
                          15 * scale,
                          weight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.75),
                        ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      SizedBox(height: 4 * scale),
                      Text(
                        T.format('browserPlayRenews', [left ~/ 60, (left % 60).toString().padLeft(2, '0')]),
                        style: AppText.display(13 * scale, color: Colors.white.withValues(alpha: 0.5)),
                      ),
                    ],
                  ],
                ),
                SizedBox(width: 40 * scale),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(T.text('browserPlay'), style: AppText.display(34 * scale, weight: FontWeight.w600)),
                      SizedBox(height: 6 * scale),
                      Text(
                        T.text('browserPlaySubtitle'),
                        style: AppText.display(16 * scale, color: Colors.white.withValues(alpha: 0.62)),
                      ),
                      SizedBox(height: 18 * scale),
                      step(1, T.text('browserPlayStep1')),
                      step(2, T.text('browserPlayStep2')),
                      step(3, T.text('browserPlayStep3')),
                      for (final (name, _, allowed) in play.shownPads)
                        Padding(
                          padding: EdgeInsets.only(top: 6 * scale),
                          child: Row(
                            children: [
                              Container(
                                width: 9 * scale,
                                height: 9 * scale,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: allowed ? const Color(0xFF4CD97B) : const Color(0xFFFF9F33),
                                ),
                              ),
                              SizedBox(width: 10 * scale),
                              Text(PhoneLabel.title(name), style: AppText.display(16 * scale, weight: FontWeight.w600)),
                              SizedBox(width: 8 * scale),
                              Text(
                                T.text(allowed ? 'browserPlayPlaying' : 'browserPlayAsking'),
                                style: AppText.display(15 * scale, color: Colors.white.withValues(alpha: 0.55)),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(height: 20 * scale),
                      Row(
                        children: [
                          ConsoleButton(
                            title: T.text('browserPlayNewCode'),
                            icon: Icons.refresh_rounded,
                            focused: false,
                            onPressed: play.renew,
                          ),
                          SizedBox(width: 14 * scale),
                          ConsoleButton(
                            title: T.text('browserPlayDone'),
                            icon: Icons.check_rounded,
                            focused: true,
                            onPressed: play.close,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.text) : _image = QrImage(QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M));

  final String text;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = _image.moduleCount;
    final side = size.shortestSide;
    final module = (side / count).floorToDouble().clamp(1.0, double.infinity);
    final offset = Offset((size.width - module * count) / 2, (size.height - module * count) / 2);
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var y = 0; y < count; y++) {
      for (var x = 0; x < count; x++) {
        if (_image.isDark(y, x)) {
          canvas.drawRect(Rect.fromLTWH(offset.dx + x * module, offset.dy + y * module, module, module), paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.text != text;
}

/// The four corner ticks of a viewfinder, in the launcher's accent.
class _Viewfinder extends CustomPainter {
  _Viewfinder(this.color, this.width);
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final arm = size.shortestSide * 0.12;
    final paint = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final (corner, dx, dy) in [
      (Offset.zero, 1.0, 1.0),
      (Offset(size.width, 0), -1.0, 1.0),
      (Offset(0, size.height), 1.0, -1.0),
      (Offset(size.width, size.height), -1.0, -1.0),
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(corner.dx, corner.dy + dy * arm)
          ..lineTo(corner.dx, corner.dy)
          ..lineTo(corner.dx + dx * arm, corner.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Viewfinder old) => old.color != color || old.width != width;
}
