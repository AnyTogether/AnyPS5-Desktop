part of 'app_model.dart';

typedef HomeTile = ({int gameIndex, RetroPlatform? folder});

extension RetroHomeFolders on AppModel {
  bool _groupsHomePlatform(RetroPlatform platform) {
    return preferences.showRetroFolders && standaloneEmulator(platform) != null;
  }

  RetroPlatform? get activeHomeRetroFolder {
    final folder = _homeRetroFolder;
    return folder != null && selectedGame?.retro?.platform == folder && _groupsHomePlatform(folder) ? folder : null;
  }

  RetroPlatform? get selectedHomeFolder {
    final platform = selectedGame?.retro?.platform;
    return platform != null && activeHomeRetroFolder == null && _groupsHomePlatform(platform) ? platform : null;
  }

  Game? get homePreviewGame => selectedHomeFolder == null ? selectedGame : null;

  RetroPlatform? get homeFolderPlatform => activeHomeRetroFolder ?? selectedHomeFolder;

  List<HomeTile> get homeTiles {
    final titles = <HomeTile>[];
    final folders = <RetroPlatform, int>{};
    final installed = <RetroPlatform, bool>{};
    for (final (index, game) in games.indexed) {
      final platform = game.retro?.platform;
      if (platform != null && installed.putIfAbsent(platform, () => _groupsHomePlatform(platform))) {
        folders.putIfAbsent(platform, () => index);
      } else {
        titles.add((gameIndex: index, folder: null));
      }
    }
    return [
      ...titles,
      for (final platform in RetroPlatform.values)
        if (folders[platform] case final index?) (gameIndex: index, folder: platform),
    ];
  }

  List<HomeTile> get homeFolderTiles {
    final folder = homeFolderPlatform;
    return [
      if (folder != null)
        for (final (index, game) in games.indexed)
          if (game.retro?.platform == folder) (gameIndex: index, folder: null),
    ];
  }

  int homeTileIndex(List<HomeTile> tiles, {bool folderContents = false}) {
    final folder = folderContents ? null : homeFolderPlatform;
    final index = tiles.indexWhere((tile) => folder == null ? tile.gameIndex == selected : tile.folder == folder);
    return index < 0 ? 0 : index;
  }

  void setShowRetroFolders(bool enabled) {
    if (preferences.showRetroFolders == enabled) return;
    preferences.showRetroFolders = enabled;
    _homeRetroFolder = null;
    if (selectedHomeFolder != null) focus = HomeFocus.tiles;
    savePreferences();
  }

  void selectHomeTile(int index, {bool folderContents = false}) {
    final tiles = folderContents ? homeFolderTiles : homeTiles;
    final tile = tiles.elementAtOrNull(index);
    if (tile == null) return;
    if (homeTileIndex(tiles, folderContents: folderContents) != index) sounds.play(Cue.move);
    _setHomeAnchor(tile, folderContents: folderContents, keepFocus: false);
  }

  void moveHomeSelection(int delta, {bool? folderContents}) {
    if (!preferences.showRetroFolders) return moveSelection(delta);
    final contents = folderContents ?? activeHomeRetroFolder != null;
    final tiles = contents ? homeFolderTiles : homeTiles;
    if (tiles.isEmpty) return;
    final current = homeTileIndex(tiles, folderContents: contents);
    final next = (current + delta).clamp(0, tiles.length - 1);
    if (next == current) return;
    sounds.play(Cue.move);
    _setHomeAnchor(tiles[next], folderContents: contents, keepFocus: true);
  }

  void _setHomeAnchor(HomeTile tile, {required bool folderContents, required bool keepFocus}) {
    final folder = homeFolderPlatform;
    _homeRetroFolder = folderContents ? folder : null;
    if (folderContents || tile.folder == null || tile.folder != folder) selected = tile.gameIndex;
    if (!keepFocus || tile.folder != null) focus = HomeFocus.tiles;
    if (focus.isActions && focus.index >= actionCount) focus = HomeFocus.actions(actionCount - 1);
    if (tile.folder == null) measureSelected();
    _changed();
  }

  bool openSelectedHomeFolder() {
    final folder = selectedHomeFolder;
    if (folder == null) return false;
    _homeRetroFolder = folder;
    focus = HomeFocus.tiles;
    sounds.play(Cue.select);
    measureSelected();
    _changed();
    return true;
  }

  bool closeHomeFolder() {
    if (activeHomeRetroFolder == null) return false;
    _homeRetroFolder = null;
    focus = HomeFocus.tiles;
    sounds.play(Cue.back);
    _changed();
    return true;
  }
}
