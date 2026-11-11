import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'controls.dart';
import 'custom_options.dart';
import 'game_log.dart';
import 'gyro_aiming.dart';
import 'relinker_flags.dart';

/// Where the performance overlay sits.
enum OverlayCorner {
  off(null),
  topLeft('tl'),
  topRight('tr'),
  bottomLeft('bl'),
  bottomRight('br');

  const OverlayCorner(this.position);

  /// ANYPS5_OVERLAY_POS, null when off.
  final String? position;
}

/// How the performance overlay looks: one line of figures, or the panel with its graph.
enum OverlayStyle { minimal, detailed }

/// How the game's image is brought up to a larger window (ANYPS5_UPSCALER): bilinear, or AMD
/// FidelityFX Super Resolution 1, which only helps where the game renders below the window.
enum Upscaler { bilinear, fsr1 }

/// Settings › Default Display: how a game starts that made no display choice of its own (Game
/// Settings › Display, Window Size and Vertical Sync left at Default). The built-in values are
/// the ones every game started with before there were defaults.
class DisplayDefaults {
  const DisplayDefaults({this.fullscreen = false, this.windowSize = 75, this.vsync = true});

  /// A value missing or of the wrong kind is the built-in one.
  factory DisplayDefaults.fromJson(Object? json) {
    if (json is! Map) return const DisplayDefaults();
    const builtIn = DisplayDefaults();
    final size = json['windowSize'];
    return DisplayDefaults(
      fullscreen: json['fullscreen'] is bool ? json['fullscreen'] as bool : builtIn.fullscreen,
      windowSize: size is num ? size.toInt().clamp(minimumWindowSize, 100) : builtIn.windowSize,
      vsync: json['vsync'] is bool ? json['vsync'] as bool : builtIn.vsync,
    );
  }

  static const minimumWindowSize = 30;

  /// The defaults the launcher saved in its preferences file (`displayDefaults`), for a game
  /// started without the launcher's window (the command line); the built-in ones when there are
  /// none or the file cannot be read.
  static DisplayDefaults load(String preferencesFile) {
    try {
      final json = jsonDecode(File(preferencesFile).readAsStringSync());
      return DisplayDefaults.fromJson(json is Map ? json['displayDefaults'] : null);
    } on Object {
      return const DisplayDefaults();
    }
  }

  final bool fullscreen;

  /// The share of the display the window takes, in percent.
  final int windowSize;
  final bool vsync;

  bool get isBuiltIn => this == const DisplayDefaults();

  DisplayDefaults copyWith({bool? fullscreen, int? windowSize, bool? vsync}) => DisplayDefaults(
    fullscreen: fullscreen ?? this.fullscreen,
    windowSize: windowSize ?? this.windowSize,
    vsync: vsync ?? this.vsync,
  );

  Map<String, Object?> toJson() => {'fullscreen': fullscreen, 'windowSize': windowSize, 'vsync': vsync};

  @override
  bool operator ==(Object other) =>
      other is DisplayDefaults &&
      other.fullscreen == fullscreen &&
      other.windowSize == windowSize &&
      other.vsync == vsync;

  @override
  int get hashCode => Object.hash(fullscreen, windowSize, vsync);
}

/// The per-game choices the launcher passes to a started game as environment variables. Stored
/// as JSON with the macOS launcher's keys, so a settings file reads the same on every system.
class GameSettings {
  const GameSettings({
    this.resolution,
    bool? fullscreen,
    int? windowSize,
    bool? vsync,
    this.overlay = OverlayCorner.off,
    this.overlayStyle,
    this.frameGeneration,
    this.upscaler,
    this.fsrSharpness,
    this.language,
    this.engine,
    this.controls,
    this.tuning,
    this.shaderCache,
    this.phoneLayout,
    this.trace,
    this.gyro,
    this.relinkerFlags,
    this.customRelinkerOptions,
    this.launchOptions,
  }) : ownFullscreen = fullscreen,
       ownWindowSize = windowSize,
       ownVsync = vsync;

  /// Written in every file since display choices can follow [DisplayDefaults]: there the
  /// display keys are present only for a game's own choices. A file without it (an older
  /// launcher's, the macOS launcher's) always had them all; see [GameSettings.fromJson].
  static const version = 2;

  factory GameSettings.fromJson(Map<String, dynamic> json) {
    T? named<T extends Enum>(List<T> values, Object? name) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    final controls = json['controls'];
    final tuning = json['tuning'];
    var fullscreen = json['fullscreen'] is bool ? json['fullscreen'] as bool : null;
    var windowSize = (json['windowSize'] as num?)?.toInt();
    var vsync = json['vsync'] is bool ? json['vsync'] as bool : null;
    if ((json['settingsVersion'] as num? ?? 1) < version) {
      // A file from before the defaults wrote every display key, changed or not: a value that
      // is the old built-in one was most likely never chosen, so it follows the defaults (which
      // start as those same values: nothing changes until they do). Windowed with a size of its
      // own was chosen, though.
      const builtIn = DisplayDefaults();
      if (windowSize == builtIn.windowSize) windowSize = null;
      if (fullscreen == builtIn.fullscreen && windowSize == null) fullscreen = null;
      if (vsync == builtIn.vsync) vsync = null;
    }
    return GameSettings(
      resolution: json['resolution'] as String?,
      fullscreen: fullscreen,
      windowSize: windowSize,
      vsync: vsync,
      overlay: named(OverlayCorner.values, json['overlay']) ?? OverlayCorner.off,
      overlayStyle: named(OverlayStyle.values, json['overlayStyle']),
      frameGeneration: json['frameGeneration'] as bool?,
      upscaler: named(Upscaler.values, json['upscaler']),
      fsrSharpness: json['fsrSharpness'] is num ? (json['fsrSharpness'] as num).toDouble() : null,
      language: (json['language'] as num?)?.toInt(),
      engine: json['engine'] as String?,
      controls: controls is Map<String, dynamic>
          ? {
              for (final entry in controls.entries)
                if (entry.value is List<dynamic>)
                  entry.key: (entry.value as List<dynamic>).whereType<String>().toList(),
            }
          : null,
      tuning: tuning is Map<String, dynamic> ? InputTuning.fromJson(tuning) : null,
      shaderCache: json['shaderCache'] as bool?,
      phoneLayout: json['phoneLayout'] as String?,
      trace: json['trace'] as bool?,
      gyro: json['gyro'] is Map<String, dynamic> ? GyroAiming.fromJson(json['gyro'] as Map<String, dynamic>) : null,
      relinkerFlags: json['relinkerFlags'] is List<dynamic>
          ? (json['relinkerFlags'] as List<dynamic>).whereType<String>().toList()
          : null,
      customRelinkerOptions: optionsText(json['customRelinkerOptions'], (text) => checkRelinkerOptions(text).ok),
      launchOptions: optionsText(json['launchOptions'], (text) => GameLaunchOptions.parse(text).$2 == null),
    );
  }

  /// A typed options text as it is kept: null for anything but a text, one with only spaces, or
  /// one that fails its [check], so a settings file (imported, written by hand) never brings an
  /// invalid one.
  static String? optionsText(Object? value, bool Function(String text) check) =>
      value is String && value.trim().isNotEmpty && check(value) ? value : null;

  /// A WIDTHxHEIGHT the title's patch file can set (see [ResolutionPatch]), null for the title's
  /// own. Taking effect needs the game installed again, as the value is written at relink time.
  final String? resolution;

  /// The game's own display choices; null follows Settings › Default Display ([withDefaults]).
  final bool? ownFullscreen;

  /// The share of the display the window takes, in percent.
  final int? ownWindowSize;
  final bool? ownVsync;

  /// The display as the game starts: its own choice, else the built-in default. A game is
  /// started with [withDefaults] applied, so these are the user's defaults there.
  bool get fullscreen => ownFullscreen ?? const DisplayDefaults().fullscreen;
  int get windowSize => ownWindowSize ?? const DisplayDefaults().windowSize;
  bool get vsync => ownVsync ?? const DisplayDefaults().vsync;

  /// Whether the game made no display choice of its own.
  bool get followsDisplayDefaults => ownFullscreen == null && ownWindowSize == null && ownVsync == null;

  /// These settings with [defaults] in place of the display choices the game did not make.
  GameSettings withDefaults(DisplayDefaults defaults) => copyWith(
    fullscreen: ownFullscreen ?? defaults.fullscreen,
    windowSize: ownWindowSize ?? defaults.windowSize,
    vsync: ownVsync ?? defaults.vsync,
  );

  /// These settings with every display choice back to following the defaults.
  GameSettings followingDisplayDefaults() => copyWith(fullscreen: null, windowSize: null, vsync: null);
  final OverlayCorner overlay;

  /// null is minimal.
  final OverlayStyle? overlayStyle;
  OverlayStyle get style => overlayStyle ?? OverlayStyle.minimal;

  /// A generated frame between each two of the game's (ANYPS5_FRAME_GEN), with vertical sync.
  final bool? frameGeneration;

  /// null is bilinear.
  final Upscaler? upscaler;

  /// FSR 1's sharpening in AMD's stops (ANYPS5_FSR_SHARPNESS): 0 is the sharpest, each stop
  /// halves it; null is AMD's 0.2.
  final double? fsrSharpness;

  static const defaultFsrSharpness = 0.2;
  static const maximumFsrSharpness = 2.0;

  /// The sharpness a start passes, within 0 to 2 stops and to a tenth of a stop.
  double get sharpness => ((fsrSharpness ?? defaultFsrSharpness).clamp(0.0, maximumFsrSharpness) * 10).round() / 10;

  /// The console language number (ANYPS5_LANGUAGE), null to follow the launcher's language.
  final int? language;

  /// The engine that unlocks this game instead of the default: the downloaded toolkit's folder
  /// name in the launcher's engines folder, null to follow Settings › AnyPS5 Engine.
  final String? engine;

  /// Keys moved from the launcher's layout (Controls), by pad action.
  final Map<String, List<String>>? controls;

  /// Stick, mouse and keyboard stick settings, null for the engine's defaults.
  final InputTuning? tuning;

  /// False turns off the shader and pipeline caches (ANYPS5_NO_SHADER_CACHE).
  final bool? shaderCache;

  /// The phone's pad layout for this game, as the phone sent it (its JSON); null for the default.
  final String? phoneLayout;

  /// Detailed logging ([TraceMode]) on every start; null is off.
  final bool? trace;

  /// Gyro aiming (Controls › Gyro Aiming, ANYPS5_GYRO_AIM); null is off.
  final GyroAiming? gyro;

  /// Relinker options for this game's next rebuild ([RelinkerFlag]), as the relinker spells them;
  /// null is none. Read through [chosenRelinkerFlags]: only those the launcher knows are used.
  final List<String>? relinkerFlags;

  /// The relinker options chosen for this game that the launcher knows, in the list's order.
  List<RelinkerFlag> get chosenRelinkerFlags => [
    for (final flag in RelinkerFlag.values)
      if (relinkerFlags?.contains(flag.option) ?? false) flag,
  ];

  /// These settings with [flag] switched [on] or off.
  GameSettings withRelinkerFlag(RelinkerFlag flag, bool on) {
    final current = chosenRelinkerFlags;
    final chosen = [
      for (final candidate in RelinkerFlag.values)
        if (candidate == flag ? on : current.contains(candidate)) candidate.option,
    ];
    return copyWith(relinkerFlags: chosen.isEmpty ? null : chosen);
  }

  /// Advanced › Rebuild options › Custom relinker options, as typed; null is none. Added after the
  /// launcher's own options on the next rebuild, through [customRelinkerWords].
  final String? customRelinkerOptions;

  /// The words [customRelinkerOptions] gives the relinker: none when it is not set or fails its
  /// check ([checkRelinkerOptions]).
  List<String> get customRelinkerWords {
    final text = customRelinkerOptions;
    return text == null ? const [] : checkRelinkerOptions(text).words;
  }

  /// Advanced › Launch › Launch options, as typed; null is none. Read through [launch].
  final String? launchOptions;

  /// The variables and arguments [launchOptions] gives the game's start; null when it is not set
  /// or has a quote left open.
  GameLaunchOptions? get launch {
    final text = launchOptions;
    return text == null || text.trim().isEmpty ? null : GameLaunchOptions.parse(text).$1;
  }

  Map<String, Object?> toJson() => {
    'settingsVersion': version,
    if (ownFullscreen != null) 'fullscreen': ownFullscreen,
    if (ownWindowSize != null) 'windowSize': ownWindowSize,
    if (ownVsync != null) 'vsync': ownVsync,
    'overlay': overlay.name,
    if (resolution != null) 'resolution': resolution,
    if (overlayStyle != null) 'overlayStyle': overlayStyle!.name,
    if (frameGeneration != null) 'frameGeneration': frameGeneration,
    if (upscaler != null) 'upscaler': upscaler!.name,
    if (fsrSharpness != null) 'fsrSharpness': fsrSharpness,
    if (language != null) 'language': language,
    if (engine != null) 'engine': engine,
    if (controls != null) 'controls': controls,
    if (tuning != null) 'tuning': tuning!.toJson(),
    if (shaderCache != null) 'shaderCache': shaderCache,
    if (phoneLayout != null) 'phoneLayout': phoneLayout,
    if (trace != null) 'trace': trace,
    if (gyro != null) 'gyro': gyro!.toJson(),
    if (relinkerFlags != null) 'relinkerFlags': relinkerFlags,
    if (customRelinkerOptions != null) 'customRelinkerOptions': customRelinkerOptions,
    if (launchOptions != null) 'launchOptions': launchOptions,
  };

  static const _keep = Object();

  /// A copy with some choices changed; pass null explicitly to clear an optional one.
  GameSettings copyWith({
    Object? resolution = _keep,
    Object? fullscreen = _keep,
    Object? windowSize = _keep,
    Object? vsync = _keep,
    OverlayCorner? overlay,
    Object? overlayStyle = _keep,
    Object? frameGeneration = _keep,
    Object? upscaler = _keep,
    Object? fsrSharpness = _keep,
    Object? language = _keep,
    Object? engine = _keep,
    Object? controls = _keep,
    Object? tuning = _keep,
    Object? shaderCache = _keep,
    Object? phoneLayout = _keep,
    Object? trace = _keep,
    Object? gyro = _keep,
    Object? relinkerFlags = _keep,
    Object? customRelinkerOptions = _keep,
    Object? launchOptions = _keep,
  }) => GameSettings(
    resolution: identical(resolution, _keep) ? this.resolution : resolution as String?,
    fullscreen: identical(fullscreen, _keep) ? ownFullscreen : fullscreen as bool?,
    windowSize: identical(windowSize, _keep) ? ownWindowSize : windowSize as int?,
    vsync: identical(vsync, _keep) ? ownVsync : vsync as bool?,
    overlay: overlay ?? this.overlay,
    overlayStyle: identical(overlayStyle, _keep) ? this.overlayStyle : overlayStyle as OverlayStyle?,
    frameGeneration: identical(frameGeneration, _keep) ? this.frameGeneration : frameGeneration as bool?,
    upscaler: identical(upscaler, _keep) ? this.upscaler : upscaler as Upscaler?,
    fsrSharpness: identical(fsrSharpness, _keep) ? this.fsrSharpness : fsrSharpness as double?,
    language: identical(language, _keep) ? this.language : language as int?,
    engine: identical(engine, _keep) ? this.engine : engine as String?,
    controls: identical(controls, _keep) ? this.controls : controls as Map<String, List<String>>?,
    tuning: identical(tuning, _keep) ? this.tuning : tuning as InputTuning?,
    shaderCache: identical(shaderCache, _keep) ? this.shaderCache : shaderCache as bool?,
    phoneLayout: identical(phoneLayout, _keep) ? this.phoneLayout : phoneLayout as String?,
    trace: identical(trace, _keep) ? this.trace : trace as bool?,
    gyro: identical(gyro, _keep) ? this.gyro : gyro as GyroAiming?,
    relinkerFlags: identical(relinkerFlags, _keep) ? this.relinkerFlags : relinkerFlags as List<String>?,
    customRelinkerOptions: identical(customRelinkerOptions, _keep)
        ? this.customRelinkerOptions
        : customRelinkerOptions as String?,
    launchOptions: identical(launchOptions, _keep) ? this.launchOptions : launchOptions as String?,
  );

  /// The game reads the controllers (through SDL2) only while its window is in front: with the
  /// launcher brought over it with PS, the pad drives the launcher alone. The engine asks SDL for
  /// background events with a plain SDL_SetHint, which the same name in the environment
  /// overrides (an SDL hint set from the environment wins over every priority but OVERRIDE).
  static const backgroundPadEnvironment = {'SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS': '0'};

  /// The environment a game starts with. [inputFile] is the anyps5-input.ini written for it,
  /// [screenshots] and [fonts] the launcher's folders for F12 screenshots and system fonts,
  /// [shaderCacheFolder] where its shader and pipeline caches go; [trace] turns detailed logging
  /// on for this start even when the setting is off.
  Map<String, String> environment({
    required int launcherLanguage,
    String? inputFile,
    String? screenshots,
    String? fonts,
    String? shaderCacheFolder,
    bool trace = false,
  }) {
    final environment = <String, String>{
      'ANYPS5_FULLSCREEN': fullscreen ? '1' : '0',
      'ANYPS5_WINDOW_SIZE': '${windowSize.clamp(30, 100)}',
      'ANYPS5_PRESENT_MODE': vsync || frameGeneration == true ? 'fifo' : 'immediate',
      'ANYPS5_LANGUAGE': '${language ?? launcherLanguage}',
      ...backgroundPadEnvironment,
    };
    final position = overlay.position;
    if (position != null) {
      environment['ANYPS5_OVERLAY'] = '1';
      environment['ANYPS5_OVERLAY_POS'] = position;
      environment['ANYPS5_OVERLAY_STYLE'] = style.name;
    }
    if (inputFile != null) environment['ANYPS5_INPUT_CONFIG'] = inputFile;
    if (screenshots != null) environment['ANYPS5_SCREENSHOTS'] = screenshots;
    if (fonts != null) environment['ANYPS5_SYSTEM_FONTS'] = fonts;
    if (shaderCache == false) {
      environment['ANYPS5_NO_SHADER_CACHE'] = '1';
    } else if (shaderCacheFolder != null) {
      environment['ANYPS5_SHADER_CACHE_DIR'] = shaderCacheFolder;
    }
    if (frameGeneration == true) environment['ANYPS5_FRAME_GEN'] = '1';
    if (upscaler == Upscaler.fsr1) {
      environment['ANYPS5_UPSCALER'] = Upscaler.fsr1.name;
      environment['ANYPS5_FSR_SHARPNESS'] = sharpness.toStringAsFixed(1);
    }
    if (gyro?.environment case final String aim) environment['ANYPS5_GYRO_AIM'] = aim;
    if (trace || this.trace == true) environment.addAll(TraceMode.environment);
    return environment;
  }

  /// Writes the game's keyboard and mouse layout to [path] for ANYPS5_INPUT_CONFIG.
  void writeInputFile(String path) => Controls.write(path, controls ?? const {}, tuning: tuning ?? const InputTuning());

  @override
  bool operator ==(Object other) => other is GameSettings && jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Each game's settings, one JSON file per game in a folder, named after its title ID.
class GameSettingsStore {
  GameSettingsStore(this.folder);

  final String folder;

  String _file(String slug) => p.join(folder, '$slug.json');

  GameSettings load(String slug) {
    try {
      final json = jsonDecode(File(_file(slug)).readAsStringSync());
      return json is Map<String, dynamic> ? GameSettings.fromJson(json) : const GameSettings();
    } on Object {
      return const GameSettings();
    }
  }

  void save(String slug, GameSettings settings) {
    Directory(folder).createSync(recursive: true);
    final file = File(_file(slug));
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settings.toJson()), flush: true);
    temporary.renameSync(file.path);
  }
}

/// Console language numbers (sceSystemServiceParamGetInt) a game can be started with.
abstract final class ConsoleLanguage {
  static const all = <(int, String)>[
    (19, 'Türkçe'),
    (1, 'English (US)'),
    (18, 'English (UK)'),
    (4, 'Deutsch'),
    (2, 'Français'),
    (3, 'Español'),
    (20, 'Español (Latinoamérica)'),
    (5, 'Italiano'),
    (17, 'Português (Brasil)'),
    (7, 'Português'),
    (8, 'Русский'),
    (16, 'Polski'),
    (6, 'Nederlands'),
    (0, '日本語'),
    (9, '한국어'),
    (11, '简体中文'),
    (10, '繁體中文'),
    (21, 'العربية'),
  ];

  static const _tags = [
    'ja-JP',
    'en-US',
    'fr-FR',
    'es-ES',
    'de-DE',
    'it-IT',
    'nl-NL',
    'pt-PT',
    'ru-RU',
    'ko-KR',
    'zh-Hant', //
    'zh-Hans',
    'fi-FI',
    'sv-SE',
    'da-DK',
    'no-NO',
    'pl-PL',
    'pt-BR',
    'en-GB',
    'tr-TR',
    'es-419',
    'ar-AE',
  ];

  /// The locale tag of a console language number, as the engine's trophy library maps them.
  static String? tag(int number) => number >= 0 && number < _tags.length ? _tags[number] : null;

  /// Locale codes the console has its own language for, beyond the languages in [_tags].
  static const _aliases = {
    'en': 1,
    'es': 3,
    'pt': 7,
    'zh': 11,
    'zh-tw': 10,
    'zh-hk': 10,
    'zh-mo': 10,
    'zh-cn': 11, //
    'zh-sg': 11,
    'no': 15,
    'nb': 15,
    'nn': 15,
    'es-mx': 20,
    'es-ar': 20,
    'es-co': 20,
    'es-cl': 20,
  };

  /// The console language a launcher language starts games in, by its file's locale code (de,
  /// pt-BR, zh-Hant, es_419): the code itself, then its language alone; null when the console has
  /// no language of that code (the caller starts games in English then).
  static int? forLocale(String code) {
    final wanted = code.replaceAll('_', '-').toLowerCase();
    int? find(String tag) {
      final index = _tags.indexWhere((known) => known.toLowerCase() == tag);
      return index >= 0 ? index : _aliases[tag];
    }

    final exact = find(wanted);
    if (exact != null) return exact;
    final language = wanted.split('-').first;
    final alone = find(language);
    if (alone != null) return alone;
    final regional = _tags.indexWhere((known) => known.toLowerCase().startsWith('$language-'));
    return regional >= 0 ? regional : null;
  }
}

/// A title's resolution patch: the title's patch file in the toolkit (patches/<TITLE ID>.toml,
/// upstream's relinker-patches format) with typed entries named `width` and `height`. The
/// launcher writes a copy with the chosen values and hands it to the relinker with --patches.
abstract final class ResolutionPatch {
  static const choices = ['1280x720', '1600x900', '1920x1080', '2560x1440', '3840x2160'];

  /// (width, height) of a WIDTHxHEIGHT text, null when it is not one.
  static (int, int)? parse(String text) {
    final parts = text.toLowerCase().split('x');
    if (parts.length != 2) return null;
    final width = int.tryParse(parts[0]);
    final height = int.tryParse(parts[1]);
    if (width == null || height == null || width <= 0 || height <= 0) return null;
    return (width, height);
  }

  /// Whether the patch file has the entries a resolution needs.
  static bool supports(String toml) => _entryNamed(toml, 'width') != null && _entryNamed(toml, 'height') != null;

  /// The WIDTHxHEIGHT the patch file itself sets (the title's own), null when it has no such
  /// entries or their values are not numbers.
  static String? defaultOf(String toml) {
    int? valueOf(String name) {
      final range = _entryNamed(toml, name);
      if (range == null) return null;
      for (final line in toml.split('\n').sublist(range.$1, range.$2)) {
        final match = RegExp(r'^\s*value\s*=\s*([^#\s]+)').firstMatch(line);
        if (match != null) return int.tryParse(match.group(1)!);
      }
      return null;
    }

    final width = valueOf('width');
    final height = valueOf('height');
    return width == null || height == null ? null : '${width}x$height';
  }

  /// The largest of [choices] with fewer pixels than [current], null when there is none; a battery
  /// or heat profile unlocks a game one step lower, as on the Mac (PowerResolution).
  static String? lower(String current, List<String> choices) {
    int? pixels(String text) {
      final size = parse(text);
      return size == null ? null : size.$1 * size.$2;
    }

    final limit = pixels(current);
    if (limit == null) return null;
    String? best;
    var most = 0;
    for (final choice in choices) {
      final count = pixels(choice);
      if (count != null && count < limit && count > most) {
        best = choice;
        most = count;
      }
    }
    return best;
  }

  /// The guest address of the width or height entry [name], for a 4-byte value in the main
  /// executable; null without one.
  static int? addressOf(String toml, String name) {
    final range = _entryNamed(toml, name);
    if (range == null) return null;
    String? field(String key) {
      for (final line in toml.split('\n').sublist(range.$1, range.$2)) {
        final match = RegExp('^\\s*$key\\s*=\\s*([^#\\s]+)').firstMatch(line);
        if (match != null) return match.group(1)!.replaceAll('"', '');
      }
      return null;
    }

    final type = field('type');
    if (type != 'u32' && type != 'i32') return null;
    final target = field('target');
    if (target != null && target != 'eboot.bin') return null;
    final address = field('va');
    return address == null ? null : int.tryParse(address);
  }

  /// The patch file with the width and height entries' `value` set to [resolution]; the file as
  /// it is when it has no such entries or the text is not a resolution.
  static String apply(String toml, String resolution) {
    final size = parse(resolution);
    if (size == null || !supports(toml)) return toml;
    var lines = toml.split('\n');
    for (final (name, value) in [('width', size.$1), ('height', size.$2)]) {
      final range = _entryNamed(lines.join('\n'), name)!;
      lines = [
        for (var index = 0; index < lines.length; index++)
          if (index >= range.$1 && index < range.$2 && RegExp(r'^\s*value\s*=').hasMatch(lines[index]))
            lines[index].replaceFirst(RegExp(r'=\s*[^#]*'), '= $value ')
          else
            lines[index],
      ];
    }
    return lines.join('\n');
  }

  /// The line range [start, end) of the [[patch]] entry with `name = "<name>"`.
  static (int, int)? _entryNamed(String toml, String name) {
    final lines = toml.split('\n');
    var start = -1;
    for (var index = 0; index <= lines.length; index++) {
      final atEnd = index == lines.length;
      if (atEnd || lines[index].trim() == '[[patch]]') {
        if (start >= 0) {
          final entry = lines.sublist(start, index);
          if (entry.any((line) => RegExp('^\\s*name\\s*=\\s*"$name"').hasMatch(line))) return (start, index);
        }
        start = index;
      }
    }
    return null;
  }
}
