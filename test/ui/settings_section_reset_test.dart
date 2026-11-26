import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/power_profiles.dart';
import 'package:anyps5_desktop/core/replay_buffer.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Settings › Restore all: the last row of each section with preferences of its own puts that
/// section back to its defaults and leaves every other section, the games folders, the language,
/// the profile name and AnyTogether as they are. The macOS launcher's SettingsSectionResetTests.
void main() {
  late Fixture fixture;
  late AppModel model;

  setUp(() {
    fixture = makeFixture();
    model = fixture.model;
  });

  tearDown(() {
    model.dispose();
    fixture.dispose();
  });

  PanelCategory section(String id) => model.panelCategories().firstWhere((category) => category.id == id);

  /// Restore all chosen in [id], as the pad or the mouse chooses it.
  void restore(String id) {
    model.open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == id);
    final rows = model.panelCategories()[model.panelCategory].rows;
    model.activateRow(rows.indexWhere((row) => row.id == 'reset-$id'));
  }

  test('each section with preferences of its own ends in Restore all; the others have none', () {
    model.open(Layer.settings);
    for (final category in model.panelCategories()) {
      final resets = [
        for (final row in category.rows)
          if (row.id.startsWith('reset-')) row,
      ];
      if (AppModel.settingsSectionsWithReset.contains(category.id)) {
        expect(category.rows.last.id, 'reset-${category.id}', reason: category.id);
        expect(category.rows.last.title, T.text('settingsResetSection'));
        expect(category.rows.last.detail, T.text('settingsResetSectionDetail'));
        expect((category.rows.last.kind as ActionRow).destructive, isTrue, reason: 'as Shortcuts › Reset to defaults');
      } else {
        expect(resets, isEmpty, reason: category.id);
      }
    }
    // Shortcuts and Game Presets keep their own reset rows.
    expect(section('shortcuts').rows.map((row) => row.id), contains('shortcutsReset'));
    expect(section('presets').rows.map((row) => row.id), contains('presetsReset'));
  });

  test('Behaviour comes back to its defaults; the language, the name and friends joining stay', () {
    final preferences = model.preferences
      ..sounds = false
      ..soundVolume = 40
      ..musicVolume = 20
      ..launcherVolume = 50
      ..controllerVibration = false
      ..hideWhilePlaying = true
      ..pauseOnMenu = false
      ..showHiddenTrophies = true
      ..discordPresence = false
      ..discordJoin = false
      ..nowPlayingCard = false
      ..nowPlayingShare = true
      // Other sections' settings, and what Restore all never touches.
      ..friendsJoin = false
      ..confirmCircle = true
      ..replayBuffer = true
      ..saveSync = true;
    final language = preferences.language;
    final folders = [...preferences.gamesFolders];

    restore('general');

    expect(preferences.sounds, isTrue);
    expect(preferences.soundVolume, isNull);
    expect(preferences.musicVolume, isNull);
    expect(preferences.launcherVolume, isNull);
    expect(preferences.controllerVibration, isTrue);
    expect(preferences.hideWhilePlaying, isFalse);
    expect(preferences.pauseOnMenu, isTrue);
    expect(preferences.showHiddenTrophies, isFalse);
    expect(preferences.discordPresence, isTrue);
    expect(preferences.discordJoin, isTrue);
    expect(preferences.nowPlayingCard, isTrue);
    expect(preferences.nowPlayingShare, isFalse);

    expect(preferences.language, language);
    expect(preferences.profileName, 'Utku');
    expect(preferences.gamesFolders, folders);
    expect(preferences.saveSync, isTrue, reason: 'Save Sync is left as it is');
    expect(preferences.friendsJoin, isFalse, reason: 'Settings › AnyTogether owns it');
    expect(preferences.confirmCircle, isTrue);
    expect(preferences.replayBuffer, isTrue);
    expect(model.toast, T.text('settingsResetSectionDone'));
  });

  test('Controllers and Default Display restore only themselves, and the focus stays on the row', () {
    final preferences = model.preferences
      ..controllerLight = 'red'
      ..confirmCircle = true
      ..stickDeadzone = 10
      ..assistPlayerOne = 'controllers'
      ..displayDefaults = const DisplayDefaults(fullscreen: false, windowSize: 50, vsync: false)
      ..sounds = false;

    restore('controllers');
    expect(preferences.controllerLight, isNull);
    expect(preferences.confirmCircle, isFalse);
    expect(preferences.stickDeadzone, 0);
    expect(preferences.assistPlayerOne, isNull);
    expect(preferences.displayDefaults.fullscreen, isFalse, reason: 'Default Display has its own row');
    expect(preferences.sounds, isFalse);
    expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'reset-controllers');

    restore('displayDefaults');
    expect(preferences.displayDefaults.fullscreen, const DisplayDefaults().fullscreen);
    expect(preferences.displayDefaults.windowSize, const DisplayDefaults().windowSize);
    expect(preferences.displayDefaults.vsync, isTrue);
    expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'reset-displayDefaults');
  });

  test('Appearance goes back to Cosmic and its defaults; Glass\'s rows go with it', () {
    final preferences = model.preferences
      ..theme = LookStyle.glass.index
      ..accent = 'coral'
      ..reducedMotion = true
      ..gameArtwork = false
      ..windowButtons = false
      ..glassTransparency = 40
      ..launcherFullscreen = false;
    model.open(Layer.settings);
    expect(section('appearance').rows.map((row) => row.id), contains('transparency'));

    restore('appearance');
    expect(preferences.theme, LookStyle.cosmic.index);
    expect(preferences.accent, isNull);
    expect(preferences.reducedMotion, isFalse);
    expect(preferences.gameArtwork, isTrue);
    expect(preferences.windowButtons, isTrue);
    expect(preferences.glassTransparency, isNull);
    expect(preferences.launcherFullscreen, isNull);
    expect(model.launcherFullscreen, isTrue);
    expect(section('appearance').rows.map((row) => row.id), isNot(contains('transparency')));
    expect(model.panelCategories()[model.panelCategory].rows[model.panelRow].id, 'reset-appearance');
  });

  test('Battery & Heat: the policy at work takes the built-in profiles at once', () {
    const changed = PowerProfiles(
      hot: PowerProfile(
        on: false,
        frameCap: 30,
        lowerResolution: false,
        pauseFrameGeneration: false,
        dimEffects: false,
      ),
    );
    model.powerWatch.setProfiles(changed);
    expect(model.powerWatch.policy.profiles, changed);

    restore('power');
    expect(model.preferences.powerProfiles, isNull);
    expect(model.preferences.heatReader, isFalse);
    expect(model.powerWatch.policy.profiles, const PowerProfiles());
  });

  test('Captures turn the clip buffer off and use the Pictures folder again', () {
    final preferences = model.preferences
      ..replayBuffer = true
      ..replaySeconds = 120
      ..screenshotsFolder = '/somewhere/else'
      ..stickDeadzone = 10;

    restore('captures');
    expect(preferences.replayBuffer, isFalse);
    expect(preferences.replaySeconds, ReplayBuffer.defaultLength);
    expect(preferences.screenshotsFolder, isNull);
    expect(preferences.stickDeadzone, 10);
  });

  test('Emulators restore their switches and keep the emulators chosen; the library keeps Emulator games', () {
    final preferences = model.preferences
      ..retroLibrary = true
      ..showRetroFolders = true
      ..retroEmulators = {'ps1': '/opt/duckstation'};

    model.resetSettingsSection('emulators');
    expect(preferences.showRetroFolders, isFalse);
    expect(preferences.retroHostPs1, isFalse);
    expect(preferences.retroHostPs2, isFalse);
    expect(preferences.retroEmulators, {'ps1': '/opt/duckstation'});
    expect(preferences.retroLibrary, isTrue, reason: 'Settings › Game Library owns it');
  });

  test('Steam restores its own three settings', () {
    final preferences = model.preferences
      ..steamUser = '/steam|1234'
      ..steamGames = true
      ..steamFullscreen = false;

    model.resetSettingsSection('steam');
    expect(preferences.steamUser, isNull);
    expect(preferences.steamGames, isFalse);
    expect(preferences.steamFullscreen, isTrue);
  });
}
