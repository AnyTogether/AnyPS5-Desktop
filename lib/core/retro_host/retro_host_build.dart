/// Which kind of launcher this was compiled as, for the PS1 host it may run: only a [debug] or
/// [test] build runs the host `ANYPS5_RETRO_HOST` names, unchecked; a [release] never does
/// (docs/AnyPS5 Desktop - Emulator Host Client.md "Debug and test builds").
enum RetroHostBuild {
  /// A published release, and any build compiled without the [testDefine]: only the signed host.
  release,

  /// A release-mode test build compiled with `--dart-define=ANYPS5_UNCHECKED_RETRO_HOST_BUILD=true`.
  test,

  /// A debug build (`kDebugMode`).
  debug;

  /// The `--dart-define` that compiles a test build. It is read when the launcher is compiled
  /// ([testDefined]), never from the environment it runs in.
  static const testDefine = 'ANYPS5_UNCHECKED_RETRO_HOST_BUILD';

  /// Whether this launcher was compiled with [testDefine] set to `true`: a constant of the
  /// compiled program, so no setting, file or environment variable can change it.
  static const testDefined = bool.fromEnvironment(testDefine);

  /// The text a test build's compiled program carries and no other build's does:
  /// `RetroHostInstall.locate` writes it, where it looks for the unchecked host, only when
  /// [testDefined], and the compiler drops that code, and with it this text, from every other
  /// build. `tool/check_release_build.dart` looks for it in a built launcher.
  static const testMark = 'AnyPS5 launcher test build';

  /// The build a [debug] launcher, or one compiled with [test], is.
  static RetroHostBuild of({required bool debug, bool test = testDefined}) => debug
      ? RetroHostBuild.debug
      : test
      ? RetroHostBuild.test
      : RetroHostBuild.release;

  /// Whether this build may run the host `ANYPS5_RETRO_HOST` names, without the checks.
  bool get runsUnchecked => this != RetroHostBuild.release;
}
