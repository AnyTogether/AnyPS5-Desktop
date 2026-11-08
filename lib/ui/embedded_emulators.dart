part of 'app_model.dart';

extension EmbeddedEmulators on AppModel {
  EmbeddedRetroGame? get embeddedGame => switch (running?.$2) {
    final EmbeddedRetroGame game => game,
    _ => null,
  };

  ManagedRetro? get _managedRetro {
    final host = EmbeddedCoreHost.current;
    if (host == null || (host == EmbeddedCoreHost.windowsX64) != (system == HostSystem.windows)) return null;
    return ManagedRetro(
      p.join(p.dirname(paths.toolkits), 'Emulators'),
      host,
      ps3CoreDigests: (services.environment ?? Platform.environment)['ANYPS5_PS3_CORE_DIGESTS'],
    );
  }

  bool _embeddedReady(RetroPlatform platform) {
    final managed = _managedRetro;
    if (managed == null || !managed.isInstalled(platform)) return false;
    return platform == RetroPlatform.ps3
        ? managed.hasPs3Firmware || managed.hasPs3FirmwarePackage
        : managed.hasBios(platform);
  }

  List<PanelRow> _embeddedSetupRows() {
    final managed = _managedRetro;
    if (managed == null) return const [];
    return [
      for (final (platform, label, core) in [
        (RetroPlatform.ps1, 'PS1', 'SwanStation'),
        (RetroPlatform.ps2, 'PS2', 'ParaLLEl PS2'),
        if (managed.host.supports(RetroPlatform.ps3)) (RetroPlatform.ps3, 'PS3', 'RPCS3'),
      ]) ...[
        PanelRow(
          id: 'retro-${platform.name}-embedded-core',
          title: T.format('retroEmbeddedInstall', [label, core]),
          detail: managed.isInstalled(platform) ? managed.libraryPath(platform) : T.text('retroEmbeddedInstallDetail'),
          kind: ActionRow(() => unawaited(_pickEmbeddedFile(managed, platform, label, bios: false))),
        ),
        if (managed.isInstalled(platform) && platform == RetroPlatform.ps3)
          PanelRow(
            id: 'retro-ps3-embedded-firmware',
            title: T.text('retroPs3Firmware'),
            detail: managed.hasPs3Firmware
                ? T.text('retroPs3FirmwareInstalled')
                : (managed.hasPs3FirmwarePackage ? managed.ps3FirmwarePackage : T.text('retroPs3FirmwareDetail')),
            kind: managed.hasPs3Firmware
                ? const InfoRow('')
                : ActionRow(() => unawaited(_pickEmbeddedFile(managed, platform, label, bios: true))),
          )
        else if (managed.isInstalled(platform))
          PanelRow(
            id: 'retro-${platform.name}-embedded-bios',
            title: T.format('retroEmbeddedBios', [label]),
            detail: managed.biosPath(platform) ?? T.text('retroBiosSelectionDetail'),
            kind: ActionRow(() => unawaited(_pickEmbeddedFile(managed, platform, label, bios: true))),
          ),
      ],
      if (!managed.host.supports(RetroPlatform.ps3))
        PanelRow(
          id: 'retro-ps3-embedded-unavailable',
          title: T.text('retroEmbeddedWindowsOnly'),
          kind: const InfoRow(''),
        ),
    ];
  }

  Future<void> _pickEmbeddedFile(
    ManagedRetro managed,
    RetroPlatform platform,
    String label, {
    required bool bios,
  }) async {
    if (_embeddedSetupBusy || running != null || starting != null) return;
    _embeddedSetupBusy = true;
    try {
      final firmware = bios && platform == RetroPlatform.ps3;
      final path = await services.pickFile?.call(
        firmware
            ? T.text('retroPs3FirmwareSelect')
            : (bios ? T.format('retroSelectBios', [label]) : T.text('retroSelectCoreZip')),
        firmware ? const ['pup'] : (bios ? const ['bin', 'rom', 'rom0'] : const ['zip']),
      );
      if (path == null || _disposed) return;
      if (firmware) {
        await managed.importPs3Firmware(path);
        if (!_disposed) show(T.text('retroPs3FirmwareSelected'));
        return;
      }
      if (bios) {
        await managed.importBios(platform, path);
      } else {
        await managed.install(platform, path);
      }
      if (!_disposed) show(T.text(bios ? 'retroBiosImported' : 'retroEmbeddedInstalled'));
    } on Object catch (error) {
      debugPrint('Embedded emulator setup failed: $error');
      final key = switch ((bios, platform, error)) {
        (true, RetroPlatform.ps3, FormatException()) => 'retroPs3FirmwareInvalid',
        (true, RetroPlatform.ps3, _) => 'retroPs3FirmwareCopyFailed',
        (true, _, _) => 'retroBiosImportFailed',
        _ => 'retroCorePackageInvalid',
      };
      if (!_disposed) show(T.text(key));
    } finally {
      _embeddedSetupBusy = false;
      if (!_disposed) _changed();
    }
  }

  Future<EmbeddedRetroGame> _startEmbeddedRetro(Game game, RetroDisc disc, ManagedRetro managed) async {
    if (!await managed.verifiesInstalled(disc.platform)) throw StateError('Installed core SHA-256 mismatch');
    final settings = preferences.retroGraphics[game.id] ?? const <String, String>{};
    void save(String key, String value) {
      final choices = preferences.retroGraphics.putIfAbsent(game.id, () => {});
      choices[key] = value;
      savePreferences();
    }

    final scale = switch (disc.platform) {
      RetroPlatform.ps1 => 'swanstation_GPU_ResolutionScale',
      RetroPlatform.ps2 => 'pcsx2_upscale_multiplier',
      RetroPlatform.ps3 => 'rpcs3_resolution_scale',
    };
    return EmbeddedRetroGame.start(
      managed,
      disc,
      internalResolution: settings[scale],
      graphics: settings,
      onResolutionSelected: (value) => save(scale, value),
      onGraphicsSelected: save,
      readPad: () {
        final player = controllers.playerOne ?? controllers.pads.firstOrNull;
        return player == null ? PadState.idle : controllers.stateOf(player.id) ?? PadState.idle;
      },
      changed: _changed,
    );
  }

  List<PanelCategory> _ps3GameSettings(Game game) => Ps3SettingsModel.categories(
    saved: preferences.retroGraphics[game.id] ?? const {},
    save: (key, value) {
      final choices = preferences.retroGraphics.putIfAbsent(game.id, () => {});
      if (value == null) {
        choices.remove(key);
        if (choices.isEmpty) preferences.retroGraphics.remove(game.id);
      } else {
        choices[key] = value;
      }
      savePreferences();
    },
    setup: _gameRows(game),
  );

  List<PanelRow> _embeddedGameRows(EmbeddedRetroGame game) => [
    for (final (key, label) in const [
      ('swanstation_GPU_ResolutionScale', 'retroInternalResolution'),
      ('pcsx2_upscale_multiplier', 'retroInternalResolution'),
      ('swanstation_GPU_TextureFilter', 'retroTextureFiltering'),
      ('pcsx2_trilinear_filtering', 'retroTrilinearFiltering'),
      ('pcsx2_anisotropic_filtering', 'retroAnisotropicFiltering'),
    ])
      if (game.options[key] case final option?)
        PanelRow(
          id: key,
          title: T.text(label),
          detail: option.restart ? T.text('retroStartupOptionsDetail') : null,
          kind: ChoiceRow(
            option.labels.length == option.values.length ? option.labels : option.values,
            option.selected,
            (choice) => unawaited(game.setOption(key, option.values[choice])),
          ),
        ),
    for (final key in const ['rpcs3_resolution_scale', 'rpcs3_anisotropic_filter'])
      if (game.options[key] case final option?)
        PanelRow(
          id: key,
          title: Ps3SettingsModel.optionTitle(key)!,
          detail: option.restart ? T.text('retroStartupOptionsDetail') : null,
          kind: ChoiceRow(
            [for (final value in option.values) Ps3SettingsModel.optionLabel(key, value) ?? value],
            option.selected,
            (choice) => unawaited(game.setOption(key, option.values[choice])),
          ),
        ),
    if (game.resolutionError.isNotEmpty)
      PanelRow(id: 'retroGraphicsError', title: T.text('retroGraphicsChangeFailed'), kind: const InfoRow('')),
  ];
}
