import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/game_library.dart';
import '../core/managed_retro.dart';
import '../core/retro_settings.dart';
import 'app_model.dart';
import 'ps3_settings_model.dart';
import 'retro_controller_settings.dart';
import 'retro_graphics_settings.dart';
import 'retro_quick_optimize.dart';

class RetroSettingsModel {
  RetroSettingsModel(this.app, {required void Function() refresh}) : _optimize = RetroQuickOptimize(app, refresh);

  final AppModel app;
  final RetroQuickOptimize _optimize;
  final Map<RetroPlatform, String> _newOptions = {};
  final Map<String, String> _drafts = {};
  int _biosRegion = 0;

  String? program(RetroPlatform platform) {
    if (platform == RetroPlatform.ps3) return null;
    final path =
        app.preferences.retroEmulators[platform.name] ??
        (app.services.environment ?? Platform.environment)[platform.executableVariable];
    return path != null && p.isAbsolute(path) ? path : null;
  }

  bool _inUse(RetroPlatform platform) =>
      app.running?.$1.retro?.platform == platform || app.starting?.retro?.platform == platform;

  List<PanelCategory> categories(RetroPlatform platform, {Game? game}) {
    if (platform == RetroPlatform.ps3) return _ps3Categories(game);
    final name = platform.emulator;
    final prefix = 'retro-${platform.name}';
    final executable = program(platform);
    final hasPortable = executable != null && File(executable).existsSync();
    final inUse = _inUse(platform);
    final override = app.retroCoreOverride;
    final setup = override != null
        ? [
            PanelRow(
              id: '$prefix-core-override',
              title: 'External core folder',
              detail: override,
              kind: const InfoRow('Configured'),
            ),
            if (ManagedRetro(override).isInstalled(platform) && !inUse) _gamesFolderRow(platform),
          ]
        : !hasPortable && app.managedRetroAvailable
        ? _managedSetupRows(platform)
        : const <PanelRow>[];
    final portableProgram = PanelRow(
      id: '$prefix-program',
      title: '$name executable',
      detail: executable ?? 'Choose an existing portable installation.',
      kind: inUse ? const InfoRow('In use') : ActionRow(() => unawaited(_chooseProgram(platform))),
    );
    final settings = executable == null ? null : _read(executable, platform);
    final graphicsQueued = app.preferences.pendingRetroGraphics[settings?.file.path]?.isNotEmpty == true;
    final options = settings?.options ?? const <RetroOption>[];
    final sections = <String, List<RetroOption>>{};
    for (final option in options) {
      (sections[option.section] ??= []).add(option);
    }
    if (settings != null) {
      sections.putIfAbsent('Pad1', () => []);
      sections.putIfAbsent('Pad2', () => []);
    }
    return [
      PanelCategory(
        id: prefix,
        title: name,
        rows: [
          ...setup,
          if (!app.managedRetroAvailable) portableProgram,
          if (override == null && hasPortable && !inUse) _gamesFolderRow(platform),
          if (executable != null && !inUse)
            if (platform == RetroPlatform.ps1)
              PanelRow(
                id: '$prefix-bios-region',
                title: 'BIOS region to configure',
                kind: ChoiceRow(['NTSC-U', 'NTSC-J', 'PAL'], _biosRegion, (index) {
                  _biosRegion = index;
                  app.show('Selected ${['NTSC-U', 'NTSC-J', 'PAL'][index]} BIOS slot.');
                }),
              ),
          if (executable != null && !inUse)
            PanelRow(
              id: '$prefix-bios',
              title: 'Import console BIOS',
              detail: 'Copy a BIOS file into the emulator profile.',
              kind: ActionRow(() => unawaited(_chooseBios(platform, executable))),
            ),
          if (settings != null && !inUse && !graphicsQueued)
            PanelRow(
              id: '$prefix-add',
              title: 'Add emulator setting',
              detail: 'Use Section/Setting=value. Press Enter to save.',
              kind: TextRow(
                _newOptions[platform] ?? '',
                (text) => _newOptions[platform] = text,
                submit: () {
                  final text = _newOptions[platform] ?? '';
                  final equals = text.indexOf('=');
                  final slash = equals < 0 ? -1 : text.lastIndexOf('/', equals);
                  if (slash < 1 || equals <= slash + 1) {
                    app.show('Enter Section/Setting=value.');
                    return;
                  }
                  _edit(platform, () {
                    settings.add(
                      text.substring(0, slash).trim(),
                      text.substring(slash + 1, equals).trim(),
                      text.substring(equals + 1).trim(),
                    );
                    _newOptions.remove(platform);
                  });
                },
              ),
            ),
        ],
      ),
      if (app.managedRetroAvailable)
        PanelCategory(id: '$prefix-portable', title: 'Existing portable installation', rows: [portableProgram]),
      if (settings != null && !inUse && !graphicsQueued)
        _optimize.category(
          platform,
          settings,
          save: (apply) {
            if (app.preferences.pendingRetroGraphics[settings.file.path]?.isNotEmpty == true) {
              app.show('Discard the queued graphics changes before using Quick Optimize.');
              return;
            }
            _edit(platform, apply);
          },
        ),
      if (settings != null) graphicsCategory(platform),
      if (settings != null && !inUse)
        for (final section in sections.entries)
          PanelCategory(
            id: '$prefix-${section.key}',
            title: platform == RetroPlatform.ps2 && section.key == 'EmuCore/GS'
                ? '$name · Advanced Graphics'
                : '$name · ${section.key}',
            rows: [
              if (section.key == 'Pad1' || section.key == 'Pad2')
                ...RetroControllerSettings.rows(
                  settings: settings,
                  platform: platform,
                  section: section.key,
                  save: (apply) => _edit(platform, apply),
                ),
              for (final option in section.value)
                if ((section.key != 'Pad1' && section.key != 'Pad2') || !RetroControllerSettings.handles(option.key))
                  _row(prefix, settings, option, platform),
            ],
          ),
      if (settings != null && !inUse)
        for (final section in sections.entries)
          if (section.key == 'Pad1' || section.key == 'Pad2')
            if (section.value.any((option) => RetroControllerSettings.handles(option.key)))
              PanelCategory(
                id: '$prefix-${section.key}-bindings',
                title: '$name · ${section.key} Advanced Bindings',
                rows: [
                  for (final option in section.value)
                    if (RetroControllerSettings.handles(option.key)) _row(prefix, settings, option, platform),
                ],
              ),
    ];
  }

  PanelRow _gamesFolderRow(RetroPlatform platform) {
    final label = ManagedRetro.platformName(platform);
    final folder = app.retroSetupFolder(platform);
    return PanelRow(
      id: 'retro-${platform.name}-games-folder',
      title: '$label games library folder',
      detail: folder ?? 'Optional. Choose a folder for extracted games, or add one later.',
      previewGames: folder == null ? const [] : app.retroGamesInFolder(platform, folder),
      kind: ActionRow(() => unawaited(app.addGamesFolder(console: platform))),
    );
  }

  List<PanelRow> _managedSetupRows(RetroPlatform platform) {
    final status = app.managedRetroStatus(platform);
    final ps3 = platform == RetroPlatform.ps3;
    final ready = status.installed && (status.systemReady || (ps3 && app.managedPs3FirmwareDownloaded));
    final busy = app.managedSetupConsole != null || app.starting != null || app.running != null;
    final progress = app.managedSetupConsole == platform ? app.retroSetupProgress : null;
    final backend = switch (platform) {
      RetroPlatform.ps1 => 'SwanStation (DuckStation-based)',
      RetroPlatform.ps2 => 'LRPS2 (PCSX2-based)',
      RetroPlatform.ps3 => 'RPCS3',
    };
    return [
      PanelRow(
        id: 'retro-${platform.name}-setup',
        title: status.installed || progress != null ? backend : 'Install $backend',
        detail: 'Runs inside AnyPS5.',
        kind: !status.installed && progress == null
            ? (busy ? const InfoRow('In use') : ActionRow(() => unawaited(app.setupManagedRetro(platform))))
            : InfoRow(status.installed ? 'Installed' : 'Installing'),
      ),
      if (progress != null)
        PanelRow(
          id: 'retro-${platform.name}-setup-progress',
          title: progress.label,
          kind: InfoRow(progress.percent == null ? '' : '${progress.percent}%'),
        ),
      if (status.installed)
        if (ps3)
          PanelRow(
            id: 'retro-ps3-firmware',
            title: 'PS3 firmware',
            detail: 'AnyPS5 downloads the firmware for you.',
            kind: ready
                ? const InfoRow('Ready')
                : busy
                ? const InfoRow('Preparing')
                : ActionRow(() => unawaited(app.setupManagedRetro(platform))),
          )
        else
          PanelRow(
            id: 'retro-${platform.name}-managed-bios',
            title: 'BIOS selection',
            detail: status.systemReady ? app.managedBiosPath(platform) : 'Select your console BIOS file.',
            kind: busy ? const InfoRow('') : ActionRow(() => unawaited(_chooseManagedBios(platform))),
          ),
      if (ready) ...[
        _gamesFolderRow(platform),
        if (app.running == null && app.starting == null)
          PanelRow(
            id: 'retro-${platform.name}-finish-setup',
            title: 'Finish setup',
            detail: 'Return to Home.',
            pinToBottom: true,
            kind: ActionRow(() => app.finishRetroSetup(platform)),
          ),
      ],
    ];
  }

  List<PanelCategory> _ps3Categories(Game? game) {
    final titleId = game?.retro?.platform == RetroPlatform.ps3 ? game!.titleId : null;
    final preferences = app.preferences;
    return Ps3SettingsModel.categories(
      defaults: preferences.retroPs3Defaults,
      overrides: titleId == null ? null : preferences.retroPs3Graphics[titleId] ?? const {},
      setup: app.managedRetroAvailable
          ? _managedSetupRows(RetroPlatform.ps3)
          : const [
              PanelRow(id: 'retro-ps3-install', title: 'Embedded emulator', kind: InfoRow('Requires Windows x64')),
            ],
      save: (key, value) {
        final settings = titleId == null
            ? preferences.retroPs3Defaults
            : preferences.retroPs3Graphics.putIfAbsent(titleId, () => {});
        if (value == null) {
          settings.remove(key);
          if (titleId != null && settings.isEmpty) preferences.retroPs3Graphics.remove(titleId);
        } else {
          settings[key] = value;
        }
        app.savePreferences();
      },
    );
  }

  PanelCategory graphicsCategory(RetroPlatform platform) {
    final executable = program(platform);
    final settings = executable == null ? null : _read(executable, platform);
    final profile = settings?.file.path;
    final pending = app.preferences.pendingRetroGraphics[profile] ?? const <String, String>{};
    final defer = _inUse(platform) || pending.isNotEmpty;
    return PanelCategory(
      id: 'retro-${platform.name}-graphics',
      title: '${platform.emulator} · Graphics',
      rows: [
        if (settings == null)
          const PanelRow(id: 'graphicsUnavailable', title: 'Graphics profile', kind: InfoRow('Unavailable'))
        else
          ...RetroGraphicsSettings.rows(
            platform: platform,
            settings: settings,
            save: (apply) => _edit(platform, apply),
            queued: pending,
            queue: defer
                ? (key, value) {
                    (app.preferences.pendingRetroGraphics[profile!] ??= {})[key] = value;
                    app.savePreferences();
                  }
                : null,
          ),
        if (defer)
          const PanelRow(
            id: 'graphicsTiming',
            title: 'Applies the next time this emulator starts',
            kind: InfoRow('Shared emulator profile'),
          ),
        if (pending.isNotEmpty)
          PanelRow(
            id: 'discardGraphics',
            title: 'Discard queued changes',
            kind: ActionRow(() {
              app.preferences.pendingRetroGraphics.remove(profile);
              app.savePreferences();
            }),
          ),
      ],
    );
  }

  void applyQueuedGraphics(String executable, RetroPlatform platform) {
    final file = RetroSettings.configFile(executable, platform);
    final pending = app.preferences.pendingRetroGraphics[file.path];
    if (pending == null) return;
    RetroSettings.read(file).setMany(RetroGraphicsSettings.section(platform), {
      for (final entry in pending.entries)
        if (RetroGraphicsSettings.accepts(platform, entry.key, entry.value)) entry.key: entry.value,
    });
    app.preferences.pendingRetroGraphics.remove(file.path);
    app.savePreferences();
  }

  PanelRow _row(String prefix, RetroSettings settings, RetroOption option, RetroPlatform platform) {
    final id = '$prefix-${option.line}';
    final value = option.value;
    final fastBoot = platform == RetroPlatform.ps1 && option.section == 'BIOS' && option.key == 'PatchFastBoot';
    final graphicsQueued =
        option.section == RetroGraphicsSettings.section(platform) &&
        (app.preferences.pendingRetroGraphics[settings.file.path]?.containsKey(option.key) ?? false);
    return PanelRow(
      id: id,
      title: fastBoot ? 'Fast BIOS Boot' : option.key,
      detail: fastBoot ? 'Skip the PlayStation startup animation when the BIOS supports it.' : option.section,
      kind: switch (value.toLowerCase()) {
        _ when graphicsQueued => const InfoRow('Queued in Graphics'),
        'true' || 'false' => ToggleRow(value.toLowerCase() == 'true', (on) {
          _edit(platform, () => settings.replace(option, '$on'));
        }),
        _ => TextRow(
          _drafts[id] ?? value,
          (text) => _drafts[id] = text,
          submit: () {
            _edit(platform, () {
              if (_drafts.remove(id) case final String text) settings.replace(option, text);
            });
          },
        ),
      },
    );
  }

  RetroSettings? _read(String program, RetroPlatform platform) {
    try {
      return RetroSettings.read(RetroSettings.configFile(program, platform));
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void _edit(RetroPlatform platform, void Function() apply) {
    if (_inUse(platform)) {
      app.show('Close the game before changing its emulator profile.');
      return;
    }
    try {
      apply();
      _drafts.clear();
      app.show('Emulator setting saved.');
    } on Object catch (error) {
      app.show('Could not save emulator setting: $error');
    }
  }

  Future<void> _chooseProgram(RetroPlatform platform) async {
    final selected = await app.services.pickFile?.call(platform.emulator, ['exe']);
    if (selected == null || !p.isAbsolute(selected)) return;
    if (_inUse(platform)) {
      app.show('Close the game before changing its emulator profile.');
      return;
    }
    try {
      final marker = File(p.join(p.dirname(selected), 'portable.txt'));
      final file = RetroSettings.configFile(selected, platform);
      if (!file.existsSync()) {
        final asset = platform == RetroPlatform.ps1 ? 'duckstation' : 'pcsx2';
        final defaults = await rootBundle.loadString('assets/retro/$asset.ini');
        if (_inUse(platform)) {
          app.show('Close the game before changing its emulator profile.');
          return;
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(defaults, flush: true);
      }
      if (!marker.existsSync()) marker.writeAsStringSync('', flush: true);
      app.preferences.retroEmulators[platform.name] = selected;
      app.savePreferences();
    } on Object catch (error) {
      app.show('Could not configure ${platform.emulator}: $error');
    }
  }

  Future<void> _chooseBios(RetroPlatform platform, String executable) async {
    final selected = await app.services.pickFile?.call('${platform.emulator} BIOS', ['bin', 'rom0']);
    if (selected == null) return;
    if (_inUse(platform)) {
      app.show('Close the game before changing its emulator profile.');
      return;
    }
    try {
      final folder = Directory(p.join(p.dirname(executable), 'bios'))..createSync(recursive: true);
      final target = File(p.join(folder.path, p.basename(selected)));
      if (target.existsSync()) {
        if (sha256.convert(target.readAsBytesSync()) != sha256.convert(File(selected).readAsBytesSync())) {
          app.show('A different BIOS with that name already exists.');
          return;
        }
      } else {
        await File(selected).copy(target.path);
      }
      if (_inUse(platform)) {
        app.show('The BIOS was copied. Close the game before selecting it.');
        return;
      }
      final file = RetroSettings.configFile(executable, platform);
      switch (platform) {
        case RetroPlatform.ps1:
          RetroSettings.read(file).set('BIOS', 'SearchDirectory', 'bios');
          RetroSettings.read(file)
              .set('BIOS', ['PathNTSCU', 'PathNTSCJ', 'PathPAL'][_biosRegion], target.uri.pathSegments.last);
        case RetroPlatform.ps2:
          RetroSettings.read(file).set('Folders', 'Bios', 'bios');
          RetroSettings.read(file).set('Filenames', 'BIOS', target.uri.pathSegments.last);
        case RetroPlatform.ps3:
          break;
      }
      app.show('${platform.emulator} BIOS imported.');
    } on Object catch (error) {
      app.show('Could not import BIOS: $error');
    }
  }

  Future<void> _chooseManagedBios(RetroPlatform platform) async {
    try {
      if (await app.chooseManagedBios(platform)) app.show('Console BIOS imported.');
    } on Object catch (error) {
      app.show('Could not import BIOS: $error');
    }
  }
}
