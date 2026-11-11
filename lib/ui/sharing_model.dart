import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/deep_link.dart';
import '../core/game_library.dart';
import '../core/game_settings.dart';
import '../core/shared_settings.dart';
import 'app_model.dart';
import 'strings.dart';
import 'theme_hub_model.dart';

/// A game shared with others: its anyps5:// link (Copy Link, and the links other programs open
/// the launcher with), its settings as a file (Export and Import Settings), and the screenshots
/// folder. The macOS launcher's, with the same link and file formats.
extension GameSharing on AppModel {
  // Links.

  void copyLink(Game game) {
    services.copyText?.call(ShowGameLink(game.titleId).url);
    show(T.text('linkCopied'));
  }

  /// A link the system opened the launcher with, or another launcher handed over. Before the
  /// first run's setup nothing opens; a game not in the library is said.
  void followLink(DeepLink link) {
    if (!preferences.onboarded) return;
    unawaited(raiseLauncher());
    switch (link) {
      case LibraryLink():
        open(Layer.library);
      case SettingsLink():
        open(Layer.settings);
      case ShowGameLink(:final titleId) || PlayLink(:final titleId):
        final index = games.indexWhere((game) => game.titleId.toUpperCase() == titleId);
        if (index < 0) return show(T.format('linkNoGame', [titleId]));
        if (overlay != null) closeOverlay();
        select(index);
        if (link is PlayLink) primaryAction(games[index]);
      case ThemeLink(:final id):
        unawaited(installHubTheme(id));
    }
  }

  // Settings files.

  /// The name a game's settings file is offered under: `<game> - AnyPS5.json`, without the
  /// characters a file name cannot have on Windows.
  static String settingsFileName(Game game) => '${game.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-')} - AnyPS5.json';

  Future<void> exportSettings(Game game) async {
    final path = await services.saveFileAs?.call(settingsFileName(game), 'JSON', const ['json']);
    if (path == null) return;
    try {
      final shared = SharedSettings(titleId: game.titleId, game: game.name, settings: currentSettings(game));
      final file = File(path);
      final temporary = File('$path.tmp')..writeAsStringSync(shared.encode(), flush: true);
      temporary.renameSync(file.path);
      show(T.text('settingsExported'));
    } on Object {
      show(T.text('settingsFileFailed'));
    }
  }

  Future<void> importSettings(Game game) async {
    final path = await services.pickFile?.call('JSON', const ['json']);
    if (path == null) return;
    final SharedSettings shared;
    try {
      shared = SharedSettings.decode(File(path).readAsStringSync());
    } on Object {
      return show(T.text('settingsFileFailed'));
    }
    var imported = shared.settings;
    // A resolution applies only to a title whose patch offers it.
    if (imported.resolution case final String resolution
        when !supportsResolution(game) || !ResolutionPatch.choices.contains(resolution)) {
      imported = imported.copyWith(resolution: null);
    }
    // An engine of its own applies only where that engine is downloaded.
    if (imported.engine case final String key when !engine.downloaded.any((kit) => p.basename(kit.root) == key)) {
      imported = imported.copyWith(engine: null);
    }
    // Options typed and not saved give way to the file's.
    dropOptionDrafts(game);
    saveSettings(game, imported);
    show(
      shared.titleId == game.titleId ? T.text('settingsImported') : T.format('settingsImportedOther', [shared.game]),
    );
  }

  // The screenshots folder.

  Future<void> chooseScreenshotsFolder() async {
    final folder = await services.pickFolder?.call(T.text('screenshotsFolder'));
    if (folder == null) return;
    preferences.screenshotsFolder = folder;
    savePreferences();
    loadGalleryShots();
    refresh();
  }

  void showScreenshots() {
    try {
      Directory(picturesFolder).createSync(recursive: true);
    } on FileSystemException {
      // Shown as it is.
    }
    services.openFolder?.call(picturesFolder);
  }
}
