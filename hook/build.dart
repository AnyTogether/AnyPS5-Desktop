// Builds native/atrac9 (LibAtrac9, MIT) into a shared library beside the launcher: MSVC on
// Windows, the system's C compiler on Linux (and on the Mac for `flutter test`). Dart finds it by
// its asset id (lib/core/audio/atrac9.dart). native/capture is the game's sound for Remote Play,
// broadcasting and clips (WASAPI loopback on Windows; elsewhere it says there is none).
// native/retro_host is the launcher's side of the emulator host's control stream and frame ring
// (lib/core/retro_host/).
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final folder = Directory.fromUri(input.packageRoot.resolve('native/atrac9/'));
    final sources = [
      for (final entry in folder.listSync())
        if (entry is File && entry.path.endsWith('.c')) 'native/atrac9/${entry.uri.pathSegments.last}',
    ]..sort();
    final os = input.config.code.targetOS;
    await CBuilder.library(
      name: 'anyps5_atrac9',
      assetName: 'core/audio/atrac9.dart',
      sources: sources,
      includes: const ['native/atrac9', 'native/atrac9/include'],
      defines: {if (os == OS.windows) '_CRT_SECURE_NO_WARNINGS': null},
      libraries: [if (os == OS.linux) 'm'],
    ).run(input: input, output: output);
    await CBuilder.library(
      name: 'anyps5_capture',
      assetName: 'core/capture/game_sound_native.dart',
      sources: const ['native/capture/anyps5_sound.c'],
      libraries: [if (os == OS.windows) 'ole32'],
    ).run(input: input, output: output);
    await CBuilder.library(
      name: 'anyps5_retro_host',
      assetName: 'core/retro_host/retro_host_native.dart',
      sources: const ['native/retro_host/anyps5_retro_host.c'],
      libraries: [if (os == OS.linux) ...['pthread', 'dl']],
    ).run(input: input, output: output);
  });
}
