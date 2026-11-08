import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../core/font_download.dart';
import '../core/game_library.dart';
import '../core/system_fonts.dart';
import '../core/toolkit_download.dart' show DownloadCancel;
import 'app_model.dart';
import 'strings.dart';

/// The console system fonts games get (sceFontOpenFontSet), as the launcher gives them: the
/// Noto set inside the app for Latin, Vietnamese, typewriter, Thai and Arabic, Noto Sans CJK
/// downloaded the first time a game needs Japanese, Chinese or Korean, and a folder of the
/// user's own (the console's fonts, say) before both. Every game is started with
/// ANYPS5_SYSTEM_FONTS on the folder they are put together in.
class FontsModel {
  FontsModel(this.app);

  final AppModel app;

  /// The console languages whose games show Japanese, Korean or Chinese text, and the script
  /// each needs: Japanese (0), Korean (9), Traditional (10) and Simplified Chinese (11).
  static const cjkLanguages = {
    0: FontScript.japanese,
    9: FontScript.korean,
    10: FontScript.chinese,
    11: FontScript.chinese,
  };

  static const _cjk = [FontScript.japanese, FontScript.chinese, FontScript.korean];

  FontArchive? get _archive => app.services.cjkFonts;

  /// Whether the CJK fonts can be downloaded at all (not in tests without a fake).
  bool get online => _archive != null;

  late final FontInstaller installer = FontInstaller(
    app.paths.downloadedFonts,
    archive: _archive ?? FontArchive.notoSansCjk,
    client: app.services.fontClient,
  );

  /// The fonts that come with the launcher, on disk.
  late final String? builtIn = app.services.builtInFonts ?? SystemFonts.locateBuiltIn();

  /// The user's own fonts folder: the one they chose, else the fixed one in the config folder
  /// when it exists.
  String? get userFolder {
    final chosen = app.preferences.fontsFolder;
    if (chosen != null) return chosen;
    final fixed = app.paths.fontsFolder;
    return Directory(fixed).existsSync() ? fixed : null;
  }

  SystemFonts get layers => SystemFonts(user: userFolder, downloaded: app.paths.downloadedFonts, builtIn: builtIn);

  // What is on disk, read once until something changes (the settings ask on every frame).
  bool? _installed;
  Map<String, (FontSource, String)>? _files;

  /// Reads the folders again.
  void refresh() {
    _installed = null;
    _files = null;
  }

  bool get cjkInstalled => _installed ??= installer.installed;

  Map<String, (FontSource, String)> get files => _files ??= layers.files();

  /// The file games get for [script] now, null for none.
  FontPick? pick(FontScript script) => layers.pick(script, files: files);

  /// Whether games would get a CJK font only once it is downloaded: one of [scripts] has none,
  /// and the download is not there yet.
  bool needsDownload(Iterable<FontScript> scripts) =>
      online && !cjkInstalled && scripts.any((script) => script.isCjk && pick(script) == null);

  // The download.

  /// How far the CJK download is, from 0 to 1; null when none is under way.
  double? progress;

  /// Why the last download failed.
  String? error;

  Future<bool>? _download;
  DownloadCancel? _cancel;
  final List<void Function(int percent)> _percentWatchers = [];

  int get percent => ((progress ?? 0) * 100).floor();

  /// Downloads the CJK fonts, once however many ask; true when they are in place after.
  Future<bool> downloadCjk() => _download ??= _runDownload().whenComplete(() => _download = null);

  Future<bool> _runDownload() async {
    final cancel = _cancel = DownloadCancel();
    progress = 0;
    error = null;
    app.refresh();
    var shown = -1;
    try {
      await installer.install(
        cancel: cancel,
        onProgress: (fraction) {
          progress = fraction;
          if (percent == shown) return;
          shown = percent;
          for (final watcher in List.of(_percentWatchers)) {
            watcher(shown);
          }
          app.refresh();
        },
      );
      return true;
    } on FontInstallFailure catch (failure) {
      if (!failure.cancelled) error = failure.message;
      return false;
    } on Object catch (failure) {
      error = '$failure';
      return false;
    } finally {
      progress = null;
      _cancel = null;
      refresh();
      app.refresh();
    }
  }

  /// Stops the download; what came is kept for the next try.
  void stop() => _cancel?.cancel();

  /// Downloads the CJK fonts from the settings.
  Future<void> downloadNow() async {
    if (await downloadCjk()) {
      await assemble();
      app.show(T.text('fontsCjkReady'));
    } else if (error case final String message) {
      app.show(T.format('fontsCjkFailed', [message]));
    }
  }

  /// Deletes the downloaded CJK fonts (not while a game may hold them open).
  Future<void> removeCjk() async {
    if (app.running != null) return app.show(T.text('closeGameFirst'));
    try {
      installer.remove();
    } on FileSystemException catch (failure) {
      app.show(failure.message);
    }
    refresh();
    await assemble();
    app.show(T.text('fontsCjkRemoved'));
  }

  // The user's folder.

  Future<void> chooseFolder() async {
    final folder = await app.services.pickFolder?.call(T.text('fontsOwnChoose'));
    if (folder == null) return;
    app.preferences.fontsFolder = folder;
    refresh();
    app.savePreferences();
  }

  void forgetFolder() {
    app.preferences.fontsFolder = null;
    refresh();
    app.savePreferences();
  }

  // Starting a game.

  /// Gets the fonts ready for [game] started in console [language]: a game in Japanese,
  /// Korean or Chinese, or one seen asking for those fonts before, waits for them to download
  /// (the toast shows how far; a failure is said and the game starts all the same). Returns the
  /// folder for ANYPS5_SYSTEM_FONTS, null when there are no fonts at all.
  Future<String?> prepare(Game game, int language) async {
    final scripts = {?cjkLanguages[language], if (app.preferences.cjkGames.contains(game.titleId)) ..._cjk};
    if (needsDownload(scripts)) {
      void say(int percent) => app.show(T.format('fontsCjkForGame', [game.name, percent]));
      say(percent);
      _percentWatchers.add(say);
      try {
        if (await downloadCjk()) {
          app.show(T.text('fontsCjkReady'));
        } else if (error case final String message) {
          app.show(T.format('fontsCjkFailed', [message]));
        }
      } finally {
        _percentWatchers.remove(say);
      }
    }
    return assemble();
  }

  /// Puts the fonts together in the folder games get (away from the interface: a copy on
  /// Windows can take a moment); its path, or null when there are no fonts.
  Future<String?> assemble() async {
    final folder = app.paths.gameFonts;
    refresh();
    try {
      final count = await _assembleAway(layers, folder);
      return count > 0 ? folder : null;
    } on Object {
      // Whatever is there is better than nothing.
      return Directory(folder).existsSync() ? folder : null;
    }
  }

  static Future<int> _assembleAway(SystemFonts fonts, String folder) => Isolate.run(() => fonts.assemble(folder));

  // While a game runs.

  FontLogScanner? _scanner;
  Game? _watched;
  Timer? _scanTimer;

  /// Reads the font sets [game] opens from its log from now on (call before it starts), every
  /// few seconds while it runs and once more when it ends ([ended]).
  void watch(Game game, String logFile) {
    _scanTimer?.cancel();
    final file = File(logFile);
    _scanner = FontLogScanner(logFile, offset: file.existsSync() ? file.lengthSync() : 0);
    _watched = game;
    _scanTimer = Timer.periodic(const Duration(seconds: 3), (_) => _scan());
  }

  /// The game ended: its log is read to the end and the watch stops.
  void ended() {
    _scanTimer?.cancel();
    _scanTimer = null;
    _scan();
    _scanner = null;
    _watched = null;
  }

  void _scan() {
    final scanner = _scanner;
    final game = _watched;
    if (scanner == null || game == null || scanner.scan().isEmpty) return;
    final scripts = {for (final type in scanner.types) ...SystemFontSet.scripts(type)};
    if (!scripts.any((script) => script.isCjk) || !needsDownload(scripts)) return;
    // Its next start waits for the fonts; this time they come in the background.
    if (app.preferences.cjkGames.add(game.titleId)) app.savePreferences();
    if (_download != null) return;
    app.show(T.format('fontsCjkNeeded', [game.name]));
    unawaited(
      downloadCjk().then((done) async {
        if (done) {
          await assemble();
          app.show(T.text('fontsCjkReadyRestart'));
        } else if (error case final String message) {
          app.show(T.format('fontsCjkFailed', [message]));
        }
      }),
    );
  }

  void dispose() {
    _scanTimer?.cancel();
    _cancel?.cancel();
  }

  // The settings.

  String _sourceName(FontSource source) => T.text(switch (source) {
    FontSource.user => 'fontsYourFolder',
    FontSource.downloaded => 'fontsDownloaded',
    FontSource.builtIn => 'fontsBuiltIn',
  });

  String _describe(FontScript script) {
    final found = pick(script);
    return found == null ? T.text('fontsMissing') : '${found.family} · ${_sourceName(found.source)}';
  }

  String get _cjkText {
    if (pick(FontScript.japanese) != null) return _describe(FontScript.japanese);
    if (progress != null) return T.format('fontsCjkDownloading', [percent]);
    return T.text('fontsCjkLater');
  }

  List<PanelRow> settingsRows() {
    final chosen = app.preferences.fontsFolder;
    final folder = userFolder;
    return [
      PanelRow(id: 'fontLatin', title: T.text('fontsLatin'), kind: InfoRow(_describe(FontScript.latin))),
      PanelRow(id: 'fontItalic', title: T.text('fontsItalic'), kind: InfoRow(_describe(FontScript.latinItalic))),
      PanelRow(id: 'fontTypewriter', title: T.text('fontsTypewriter'), kind: InfoRow(_describe(FontScript.typewriter))),
      PanelRow(id: 'fontThai', title: T.text('fontsThai'), kind: InfoRow(_describe(FontScript.thai))),
      PanelRow(id: 'fontArabic', title: T.text('fontsArabic'), kind: InfoRow(_describe(FontScript.arabic))),
      PanelRow(id: 'fontCjk', title: T.text('fontsCjk'), kind: InfoRow(_cjkText)),
      if (progress != null)
        PanelRow(
          id: 'cjkDownload',
          title: T.format('fontsCjkDownloading', [percent]),
          detail: T.text('fontsCjkStop'),
          kind: ActionRow(stop),
        )
      else if (cjkInstalled)
        PanelRow(
          id: 'cjkRemove',
          title: T.text('fontsCjkRemove'),
          kind: ActionRow(() => unawaited(removeCjk()), destructive: true),
        )
      else if (online)
        PanelRow(
          id: 'cjkDownload',
          title: T.text('fontsCjkDownload'),
          detail: error == null ? null : T.format('fontsCjkFailed', [error!]),
          kind: ActionRow(() => unawaited(downloadNow())),
        ),
      // Above the folder rows, so the focus on them (the last ones) brings it into view.
      PanelRow(id: 'fontsOrder', title: T.text('fontsOrder'), kind: InfoRow(T.text('fontsOrderDetail'))),
      PanelRow(
        id: 'fontsFolder',
        title: T.text('fontsOwnFolder'),
        detail: folder ?? T.text('fontsOwnNone'),
        kind: ActionRow(() => unawaited(chooseFolder())),
      ),
      if (chosen != null)
        PanelRow(
          id: 'fontsFolderForget',
          title: T.text('fontsOwnRemove'),
          detail: T.text('fontsOwnRemoveDetail'),
          kind: ActionRow(forgetFolder, destructive: true),
        ),
    ];
  }
}
