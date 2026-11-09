part of 'app_model.dart';

/// The themes made in the Theme Studio or installed from `.anyps5theme` files: which one is in
/// use, its colours over the built-in look, the Themes and Studio panels, installing one, and
/// the user's own background and menu music. The macOS launcher's ThemesPanel.swift and
/// ThemeLibrary.swift.
extension LauncherThemes on AppModel {
  /// The Theme studio's hue and accent turn this many degrees a press: a change the eye sees,
  /// round the circle in 18 presses.
  static const hueStep = 20;

  /// The custom theme in use; null for a built-in look.
  ThemeDesign? get activeDesign {
    final id = preferences.customTheme;
    if (id == null) return null;
    return designs.where((design) => design.id == id).firstOrNull;
  }

  /// The background's deep, middle and bright tones: the custom theme's, else the look's.
  ThemePalette get palette {
    final design = activeDesign;
    if (design == null) return look.palette;
    return (deep: _color(design.deepRgb), middle: _color(design.middleRgb), bright: _color(design.brightRgb));
  }

  static Color _color(Rgb rgb) =>
      Color.fromRGBO((rgb.r * 255).round(), (rgb.g * 255).round(), (rgb.b * 255).round(), 1);

  /// The picture or video behind the launcher: the custom theme's, else the one chosen in
  /// Appearance › Background; null for the theme's animation.
  ({String path, bool video})? get ownBackground {
    final design = activeDesign;
    if (design != null) {
      final file = themes.file(design.background, design);
      if (file != null) return (path: file, video: design.backgroundIsVideo);
    }
    final file = preferences.backdropFile;
    if (preferences.backdrop == 'theme' || file == null || !File(file).existsSync()) return null;
    return (path: file, video: preferences.backdrop == 'video');
  }

  /// The music when the selected game has no song: the custom theme's, else the user's own.
  String? get menuMusic {
    final design = activeDesign;
    if (design != null) {
      final file = themes.file(design.music, design);
      if (file != null) return file;
    }
    final file = preferences.menuMusicFile;
    return file != null && File(file).existsSync() ? file : null;
  }

  /// Reads the themes folder again.
  void reloadDesigns() {
    designs = themes.all;
    _changed();
  }

  /// Uses [design], or the built-in look chosen in Appearance for null.
  void useTheme(ThemeDesign? design) {
    preferences.customTheme = design?.id;
    sounds.play(Cue.select);
    savePreferences();
    _publishLook();
  }

  /// Installs a theme file (from the file manager, a download, Install from a File or the Hub)
  /// and, unless [use] is false, uses it. The unpacking runs away from the interface, since a
  /// theme may bring a large video. Null when the file is no theme or could not be installed,
  /// and the launcher has said so.
  Future<ThemeDesign?> installTheme(String file, {bool use = true}) async {
    final folder = themes.folder;
    try {
      final design = await Isolate.run(() => ThemeLibrary(folder).install(file));
      designs = themes.all;
      if (use) useTheme(design);
      show(T.format('themeInstalled', [design.name]));
      return design;
    } on Object {
      show(T.text('themeInstallFailed'));
      return null;
    }
  }

  /// Whether [path] names a theme file, by its ending.
  static bool isThemeFile(String path) => p.extension(path).toLowerCase() == '.${ThemeDesign.fileExtension}';

  /// The Studio goes back to the themes, the themes back to Appearance on the Themes row.
  void backFromThemes() {
    if (overlay == Layer.themeStudio) return open(Layer.themes, cue: Cue.back);
    // Opened from Theme: name on a profile: back to it.
    if (together.backFromHubToProfile()) return;
    open(Layer.settings, cue: Cue.back);
    final categories = panelCategories();
    final index = categories.indexWhere((category) => category.id == 'appearance');
    if (index < 0) return;
    panelCategory = index;
    panelRow = categories[index].rows
        .indexWhere((row) => row.id == 'themes')
        .clamp(0, categories[index].rows.length - 1);
    _changed();
  }

  // Rows.

  List<PanelRow> themeRows() {
    final active = activeDesign;
    return [
      PanelRow(id: 'here', title: T.text('themesOnMac'), kind: const InfoRow('')),
      for (final style in LookStyle.values)
        PanelRow(
          id: 'builtin-${style.name}',
          title: style.title,
          detail: active == null && preferences.theme == style.index ? T.text('themeActive') : null,
          kind: ActionRow(() {
            preferences
              ..theme = style.index
              ..accent = null;
            if (style == LookStyle.glass) {
              preferences.glassTooSlow = false;
              glassFallback = false;
            }
            useTheme(null);
          }),
        ),
      for (final design in designs)
        PanelRow(
          id: 'design-${design.id}',
          title: design.name,
          detail: active?.id == design.id
              ? T.text('themeActive')
              : (design.author.isEmpty ? null : T.format('themeBy', [design.author])),
          kind: ActionRow(() => useTheme(design)),
        ),
      PanelRow(
        id: 'studio',
        title: T.text('themeStudio'),
        detail: T.text('themeStudioDetail'),
        kind: ActionRow(openStudio),
      ),
      PanelRow(id: 'file', title: T.text('installThemeFile'), kind: ActionRow(() => unawaited(chooseThemeFile()))),
      // The Hub: the themes people share, and sharing the one in use (theme_hub_model.dart).
      ...hubRows(),
      PanelRow(
        id: 'share',
        title: T.text('shareTheme'),
        detail: together.signedIn ? T.text('socialHubShareDetail') : T.text('shareThemeHint'),
        kind: ActionRow(() {
          final design = activeDesign;
          design == null ? openStudio() : unawaited(shareOnHub(design));
        }),
      ),
    ];
  }

  List<PanelRow> studioRows() {
    final design = activeDesign;
    if (design == null) return const [];
    final knobs = _knobsOf(design);
    String degrees(int value) => '$value°';
    return [
      PanelRow(
        id: 'name',
        title: T.text('themeName'),
        kind: TextRow(design.name, (text) => editTheme((design) => design.copyWith(name: text))),
      ),
      PanelRow(
        id: 'author',
        title: T.text('themeAuthor'),
        kind: TextRow(design.author, (text) => editTheme((design) => design.copyWith(author: text))),
      ),
      PanelRow(
        id: 'motion',
        title: T.text('themeMotion'),
        kind: ChoiceRow(
          [for (final style in LookStyle.values) style.title],
          LookStyle.fromIndex(design.style).index,
          (index) => editTheme((design) => design.copyWith(style: index)),
        ),
      ),
      PanelRow(
        id: 'hue',
        title: T.text('themeHue'),
        // Steps of a size that shows: round the circle in 18 presses.
        kind: StepperRow(
          value: knobs.hue.round(),
          min: 0,
          max: 360 - LauncherThemes.hueStep,
          step: LauncherThemes.hueStep,
          format: degrees,
          wraps: true,
          set: (value) => _turn((knobs) => knobs.copyWith(hue: value.toDouble())),
        ),
      ),
      PanelRow(
        id: 'highlight',
        title: T.text('themeHighlight'),
        kind: StepperRow(
          value: knobs.highlight.round(),
          min: -90,
          max: 90,
          // End to end in 12 presses.
          step: 15,
          format: degrees,
          set: (value) => _turn((knobs) => knobs.copyWith(highlight: value.toDouble())),
        ),
      ),
      PanelRow(
        id: 'depth',
        title: T.text('themeDepth'),
        kind: StepperRow(
          value: knobs.depth,
          min: 1,
          max: 10,
          step: 1,
          format: (value) => T.number(value),
          set: (value) => _turn((knobs) => knobs.copyWith(depth: value)),
        ),
      ),
      PanelRow(
        id: 'accent',
        title: T.text('themeAccent'),
        kind: StepperRow(
          value: knobs.accentHue.round(),
          min: 0,
          max: 360 - LauncherThemes.hueStep,
          step: LauncherThemes.hueStep,
          format: degrees,
          wraps: true,
          set: (value) => _turn((knobs) => knobs.copyWith(accentHue: value.toDouble())),
        ),
      ),
      PanelRow(
        id: 'background',
        title: T.text('themeBackground'),
        detail: design.background == null
            ? T.text('themeNoFile')
            : T.text(design.backgroundIsVideo ? 'backgroundVideo' : 'backgroundImage'),
        kind: ActionRow(() => unawaited(chooseThemeMedia(music: false))),
      ),
      if (design.background != null)
        PanelRow(
          id: 'backgroundOff',
          title: T.text('themeRemoveBackground'),
          kind: ActionRow(() => editTheme((design) => design.copyWith(background: () => null))),
        ),
      PanelRow(
        id: 'music',
        title: T.text('themeMusic'),
        detail: design.music == null ? T.text('themeNoFile') : T.text('themeMusicDetail'),
        kind: ActionRow(() => unawaited(chooseThemeMedia(music: true))),
      ),
      if (design.music != null)
        PanelRow(
          id: 'musicOff',
          title: T.text('themeRemoveMusic'),
          kind: ActionRow(() => editTheme((design) => design.copyWith(music: () => null))),
        ),
      PanelRow(
        id: 'export',
        title: T.text('exportTheme'),
        detail: T.text('exportThemeDetail'),
        kind: ActionRow(() => unawaited(exportTheme(design))),
      ),
      PanelRow(
        id: 'share',
        title: T.text('shareTheme'),
        detail: together.signedIn ? T.text('socialHubShareDetail') : T.text('shareThemeDetail'),
        kind: ActionRow(() => unawaited(shareOnHub(design))),
      ),
      PanelRow(
        id: 'delete',
        title: T.text('deleteTheme'),
        kind: ActionRow(() => deleteTheme(design), destructive: true),
      ),
    ];
  }

  // The Studio.

  /// The Studio on the theme in use; a built-in look is copied into a new theme first.
  void openStudio() {
    if (activeDesign == null) {
      final colors = look.palette;
      final accent = accentChoice.color;
      Rgb rgb(Color color) => (r: color.r, g: color.g, b: color.b);
      try {
        final saved = themes.save(
          ThemeDesign(
            id: ThemeLibrary.newId(),
            name: T.text('newThemeName'),
            author: preferences.profileName,
            style: look.index,
            deep: ThemeDesign.hex(rgb(colors.deep)),
            middle: ThemeDesign.hex(rgb(colors.middle)),
            bright: ThemeDesign.hex(rgb(colors.bright)),
            accent: ThemeDesign.hex(rgb(accent)),
          ),
        );
        designs = themes.all;
        preferences.customTheme = saved.id;
        savePreferences();
      } on ThemeFailure {
        return show(T.text('themeSaveFailed'));
      }
    }
    open(Layer.themeStudio);
  }

  /// Changes the theme in use and saves it at once, so the launcher behind the Studio shows it.
  /// A file taken off goes from the theme's folder too.
  void editTheme(ThemeDesign Function(ThemeDesign design) change) {
    final before = activeDesign;
    if (before == null) return;
    final after = change(before);
    if (after == before) return;
    try {
      final saved = themes.save(after);
      for (final (old, now) in [(before.background, saved.background), (before.music, saved.music)]) {
        if (old == null || now != null) continue;
        final file = themes.file(old, before);
        if (file != null) File(file).deleteSync();
      }
      designs = [for (final design in designs) design.id == saved.id ? saved : design];
    } on Object {
      show(T.text('themeSaveFailed'));
    }
    _publishLook();
    _changed();
  }

  void _turn(ThemeKnobs Function(ThemeKnobs knobs) change) {
    final design = activeDesign;
    if (design == null) return;
    final knobs = change(_knobsOf(design));
    editTheme(knobs.applyTo);
    final made = activeDesign;
    if (made != null) _studioKnobs = (id: made.id, knobs: knobs, colours: _colours(made));
  }

  /// The knobs for [design]: the ones last turned while its colours are what they made, else
  /// read from the colours.
  ThemeKnobs _knobsOf(ThemeDesign design) {
    final kept = _studioKnobs;
    if (kept != null && kept.id == design.id && kept.colours == _colours(design)) return kept.knobs;
    return ThemeKnobs.of(design);
  }

  static String _colours(ThemeDesign design) => '${design.deep} ${design.middle} ${design.bright} ${design.accent}';

  /// A picture or video for the theme in use, or its menu music, from a file the user picks.
  Future<void> chooseThemeMedia({required bool music}) async {
    final design = activeDesign;
    final pick = services.pickFile;
    if (design == null || pick == null) return;
    final file = await pick(
      T.text(music ? 'themeMusic' : 'themeBackground'),
      music ? ThemeDesign.musicExtensions : [...ThemeDesign.pictureExtensions, ...ThemeDesign.videoExtensions],
    );
    if (file == null) return;
    try {
      final saved = themes.save(design, background: music ? null : file, music: music ? file : null);
      designs = [for (final known in designs) known.id == saved.id ? saved : known];
      _changed();
    } on Object {
      show(T.text('themeSaveFailed'));
    }
  }

  /// Save as a File: the theme as one `.anyps5theme` file, to give to anyone (the macOS launcher
  /// installs it too).
  Future<void> exportTheme(ThemeDesign design) async {
    final save = services.saveFileAs;
    if (save == null) return;
    final target = await save('${design.name}.${ThemeDesign.fileExtension}', 'AnyPS5 theme', const [
      ThemeDesign.fileExtension,
    ]);
    if (target == null) return;
    final file = isThemeFile(target) ? target : '$target.${ThemeDesign.fileExtension}';
    try {
      await themes.export(design, file);
      show(T.text('themeSaved'));
    } on Object {
      show(T.text('themeSaveFailed'));
    }
  }

  void deleteTheme(ThemeDesign design) {
    try {
      themes.remove(design.id);
    } on FileSystemException {
      return show(T.text('themeSaveFailed'));
    }
    designs = themes.all;
    if (preferences.customTheme == design.id) {
      preferences.customTheme = null;
      savePreferences();
      _publishLook();
    }
    open(Layer.themes, cue: Cue.back);
  }

  /// Install from a File: a theme file the user picks.
  Future<void> chooseThemeFile() async {
    final pick = services.pickFile;
    if (pick == null) return;
    final file = await pick('AnyPS5 theme', const [ThemeDesign.fileExtension]);
    if (file != null) await installTheme(file);
  }

  // Appearance.

  /// Appearance's Theme row: the built-in looks and the custom themes.
  List<PanelRow> appearanceThemeRows() {
    final custom = designs.indexWhere((design) => design.id == preferences.customTheme);
    final builtIn = LookStyle.values.length;
    return [
      PanelRow(
        id: 'theme',
        title: T.text('theme'),
        kind: ChoiceRow(
          [for (final style in LookStyle.values) style.title, for (final design in designs) design.name],
          custom >= 0 ? builtIn + custom : LookStyle.fromIndex(preferences.theme).index,
          (index) {
            if (index >= builtIn) return useTheme(designs[index - builtIn]);
            preferences
              ..theme = index
              ..accent = null
              ..customTheme = null;
            // Glass picked again: its transparency gets another try on this graphics card.
            if (index == LookStyle.glass.index) {
              preferences.glassTooSlow = false;
              glassFallback = false;
            }
            savePreferences();
            _publishLook();
          },
        ),
      ),
    ];
  }

  /// Appearance's Themes and Theme Studio rows, after the accent as on the Mac.
  List<PanelRow> appearanceThemeLinks() {
    return [
      PanelRow(
        id: 'themes',
        title: T.text('themes'),
        detail: T.text('themesDetail'),
        kind: ActionRow(() => open(Layer.themes)),
      ),
      PanelRow(
        id: 'studio',
        title: T.text('themeStudio'),
        detail: T.text('themeStudioDetail'),
        kind: ActionRow(openStudio),
      ),
    ];
  }

  /// Appearance › Background and Menu Music.
  List<PanelRow> appearanceMediaRows() {
    final kinds = Preferences.backdrops;
    final kind = kinds.indexOf(preferences.backdrop).clamp(0, kinds.length - 1);
    final file = preferences.backdropFile;
    final video = preferences.backdrop == 'video';
    return [
      PanelRow(
        id: 'backdrop',
        title: T.text('background'),
        detail: activeDesign?.background != null ? T.text('backgroundThemeOwn') : null,
        kind: ChoiceRow([T.text('backgroundTheme'), T.text('backgroundImage'), T.text('backgroundVideo')], kind, (
          index,
        ) {
          final chosen = kinds[index];
          if (chosen != 'theme' && (file == null || chosen != preferences.backdrop)) {
            unawaited(chooseBackdrop(chosen));
          } else {
            preferences.backdrop = chosen;
            savePreferences();
          }
        }),
      ),
      if (preferences.backdrop != 'theme')
        PanelRow(
          id: 'backdropFile',
          title: T.text('chooseFile'),
          detail: video && replayFfmpeg == null
              ? T.text('backgroundVideoNeedsFfmpeg')
              : (file == null ? T.text('themeNoFile') : p.basename(file)),
          kind: ActionRow(() => unawaited(chooseBackdrop(preferences.backdrop))),
        ),
      if (video && replayFfmpeg == null) ...ffmpegTool.rows(),
      PanelRow(
        id: 'menuMusic',
        title: T.text('themeMusic'),
        detail: preferences.menuMusicFile == null ? T.text('menuMusicDetail') : p.basename(preferences.menuMusicFile!),
        kind: ActionRow(() => unawaited(chooseMenuMusic())),
      ),
      if (preferences.menuMusicFile != null)
        PanelRow(
          id: 'menuMusicOff',
          title: T.text('themeRemoveMusic'),
          kind: ActionRow(() {
            preferences.menuMusicFile = null;
            savePreferences();
          }),
        ),
    ];
  }

  /// My Picture or My Video: the file it shows, picked by the user.
  Future<void> chooseBackdrop(String kind) async {
    final pick = services.pickFile;
    if (pick == null || kind == 'theme') return;
    final video = kind == 'video';
    final file = await pick(
      T.text(video ? 'backgroundVideo' : 'backgroundImage'),
      video ? ThemeDesign.videoExtensions : ThemeDesign.pictureExtensions,
    );
    if (file == null) return;
    preferences
      ..backdrop = kind
      ..backdropFile = file;
    savePreferences();
  }

  /// Menu Music: a song of the user's own for when the selected game has none.
  Future<void> chooseMenuMusic() async {
    final pick = services.pickFile;
    if (pick == null) return;
    final file = await pick(T.text('themeMusic'), ThemeDesign.musicExtensions);
    if (file == null) return;
    preferences.menuMusicFile = file;
    savePreferences();
  }
}
