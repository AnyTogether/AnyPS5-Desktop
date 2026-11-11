import 'dart:async';
import 'dart:io';

import 'package:anyps5_desktop/core/cli.dart';
import 'package:anyps5_desktop/core/game_library.dart';
import 'package:anyps5_desktop/core/game_settings.dart';
import 'package:anyps5_desktop/core/host.dart';
import 'package:anyps5_desktop/core/installer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_toolkit.dart';
import '../support/fixtures.dart';
import '../support/phone/fake_phone.dart';
import '../support/phone/messages.dart';
import '../support/self_builder.dart';

void main() {
  late Directory temp;

  setUp(() => temp = temporaryFolder('cli'));
  tearDown(() => temp.deleteSync(recursive: true));

  Future<(int, String, String)> run(
    List<String> arguments, {
    Map<String, String>? environment,
    Future<void>? until,
  }) async {
    final out = StringBuffer();
    final err = StringBuffer();
    final code = await runCli(
      arguments,
      out: out,
      err: err,
      environment: environment ?? {'HOME': p.join(temp.path, 'home')},
      system: HostSystem.linux,
      until: until,
    );
    return (code, out.toString(), err.toString());
  }

  test('usage, unwrap, scan', () async {
    expect((await run([])).$1, 2);
    expect((await run([])).$3, contains('usage: anyps5_tool'));
    final self = p.join(temp.path, 'eboot.bin');
    File(self).writeAsBytesSync(typicalSelf());
    final unwrapped = await run(['unwrap', self, p.join(temp.path, 'eboot.elf')]);
    expect(unwrapped.$1, 0);
    expect(unwrapped.$2, startsWith('wrote '));
    final refused = await run(['unwrap', p.join(temp.path, 'eboot.elf'), p.join(temp.path, 'x.elf')]);
    expect(refused.$1, 2);
    expect(refused.$3, contains('not a SELF container'));
    final root = p.join(temp.path, 'Games');
    makeDump(root, 'G', titleId: 'PPSA07007', names: {'en-US': 'Seven'});
    final scanned = await run(['scan', root]);
    expect(scanned.$2.trim().split('\t').take(4), ['PPSA07007', 'Seven', 'elf', 'locked']);
    // Several folders, as the launcher's library: a title in both once, from the first.
    final second = p.join(temp.path, 'Drive2');
    makeDump(second, 'G', titleId: 'PPSA07007', names: {'en-US': 'Seven'});
    makeDump(second, 'E', titleId: 'PPSA08008', names: {'en-US': 'Eight'});
    final both = (await run(['scan', root, second, p.join(temp.path, 'unplugged')])).$2.trim().split('\n');
    expect(both.map((line) => line.split('\t').first), ['PPSA08008', 'PPSA07007']);
    expect(both.last, endsWith(p.join(root, 'G')));
    // Unlocked into the second folder's store, it is installed there.
    final eight = makeDump(second, 'E', titleId: 'PPSA08008', names: {'en-US': 'Eight'});
    final store = Installer.installedFolder(GameLibrary.inspect(eight)!, second);
    Directory(store).createSync(recursive: true);
    File(p.join(store, 'app.elf')).writeAsStringSync('');
    File(p.join(store, Installer.recordName)).writeAsStringSync(
      '{"date":"2026-10-24T12:00:00Z","source":"$eight","system":"linux","titleID":"PPSA08008","toolkit":"t"}',
    );
    expect((await run(['scan', root, second])).$2, contains('PPSA08008\tEight\telf\tinstalled'));
  });

  test('install with the toolkit from ANYPS5_TOOLKIT, then play', () async {
    final toolkit = makeFakeToolkit(p.join(temp.path, 'toolkit'));
    final root = p.join(temp.path, 'Games');
    final game = makeDump(root, 'G', titleId: 'PPSA07007', eboot: const [0]);
    File(p.join(game, 'eboot.bin')).writeAsBytesSync(typicalSelf());
    final environment = {'HOME': p.join(temp.path, 'home'), 'ANYPS5_TOOLKIT': toolkit};
    expect((await run(['install', game, root], environment: {'HOME': temp.path})).$3, contains('no toolkit'));
    final installed = await run(['install', game, root], environment: environment);
    expect(installed.$1, 0, reason: installed.$3);
    expect(installed.$2, contains('[relink 100%]'));
    expect(installed.$2, contains('installed '));
    expect((await run(['scan', root])).$2, contains('\tinstalled\t'));
    final played = await run(['play', game, root], environment: environment);
    expect(played.$1, 0);
    expect(played.$2, contains('exit 0'));
    final log = File(p.join(temp.path, 'home', '.local', 'state', 'AnyPS5', 'logs', 'PPSA07007.log'))
        .readAsStringSync();
    expect(log, contains('relinked game'));
    expect(log, isNot(contains(' trace\n')));
    // --trace: this start with detailed logging, as its start line says.
    final traced = await run(['play', game, root, '--trace'], environment: environment);
    expect(traced.$1, 0, reason: traced.$3);
    expect(traced.$2, contains('detailed logging'));
    final again = File(p.join(temp.path, 'home', '.local', 'state', 'AnyPS5', 'logs', 'PPSA07007.log'))
        .readAsStringSync();
    expect(RegExp(r'^--- \S+ \S+ trace$', multiLine: true).hasMatch(again), isTrue);
    expect(again, contains('ANYPS5_FULLSCREEN=0'));
    // Settings › Default Display reaches a game started here too.
    final preferences = File(AppPaths.forSystem(HostSystem.linux, environment: environment).preferencesFile)
      ..createSync(recursive: true)
      ..writeAsStringSync('{"displayDefaults":{"fullscreen":true,"windowSize":75,"vsync":true}}');
    expect(preferences.existsSync(), isTrue);
    final full = await run(['play', game, root], environment: environment);
    expect(full.$1, 0, reason: full.$3);
    final log3 = File(p.join(temp.path, 'home', '.local', 'state', 'AnyPS5', 'logs', 'PPSA07007.log'))
        .readAsStringSync();
    final last = log3.substring(log3.lastIndexOf('relinked game'));
    expect(last, contains('ANYPS5_FULLSCREEN=1'));
  });

  test(
    "install passes the game's custom relinker options; play its launch options, the launcher's values winning",
    () async {
      final toolkit = makeFakeToolkit(p.join(temp.path, 'toolkit'));
      final root = p.join(temp.path, 'Games');
      final game = makeDump(root, 'G', titleId: 'PPSA07007', eboot: const [0]);
      File(p.join(game, 'eboot.bin')).writeAsBytesSync(typicalSelf());
      final environment = {'HOME': p.join(temp.path, 'home'), 'ANYPS5_TOOLKIT': toolkit};
      final paths = AppPaths.forSystem(HostSystem.linux, environment: environment);
      GameSettingsStore(paths.gameSettingsFolder).save(
        GameLibrary.inspect(game)!.slug,
        const GameSettings(
          customRelinkerOptions: '--exclude-sce-module "lib a.sprx"',
          launchOptions: 'ANYPS5_MINE="a b" ANYPS5_FULLSCREEN=1 --aps5-report=off "two words"',
        ),
      );
      final installed = await run(['install', game, root], environment: environment);
      expect(installed.$1, 0, reason: installed.$3);
      final arguments = fakeRelinkerArguments(toolkit);
      expect(arguments.sublist(arguments.length - 4, arguments.length - 2), ['--exclude-sce-module', 'lib a.sprx']);
      final record = Installer.record(
        Installer.installedFolder(GameLibrary.inspect(game)!, root),
        system: HostSystem.linux,
      );
      expect(record!.customRelinkerOptions, ['--exclude-sce-module', 'lib a.sprx']);
      final played = await run(['play', game, root], environment: environment);
      expect(played.$1, 0, reason: played.$3);
      final log = File(paths.logFile('PPSA07007')).readAsStringSync();
      expect(log, contains('relinked game --aps5-report=off two words'));
      expect(log, contains('ANYPS5_MINE=a b'));
      expect(log, contains('ANYPS5_FULLSCREEN=0'), reason: "the launcher's own value");
      expect(
        log,
        contains(
          '[anyps5-launcher] launch options: ANYPS5_MINE="a b" ANYPS5_FULLSCREEN=1 --aps5-report=off "two words"',
        ),
      );
      expect(log, contains("[anyps5-launcher] launch options: the launcher's own value is used for ANYPS5_FULLSCREEN"));
    },
  );

  test('remote: a phone is let in with --allow-all and sees the games', () async {
    final root = p.join(temp.path, 'Games');
    makeDump(root, 'G', titleId: 'PPSA07007', names: {'en-US': 'Seven'});
    final stop = Completer<void>();
    final out = StringBuffer();
    final running = runCli(
      [
        'remote',
        '--allow-all',
        '--hidden',
        '--port',
        '0',
        '--devices',
        p.join(temp.path, 'devices.json'),
        '--games',
        root,
      ],
      out: out,
      err: StringBuffer(),
      environment: {'HOME': temp.path},
      system: HostSystem.linux,
      until: stop.future,
    );
    for (var tries = 0; tries < 100 && !out.toString().contains('listening on'); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final port = int.parse(RegExp(r'listening on (\d+)').firstMatch(out.toString())!.group(1)!);
    final phone = await FakePhone.connect(port);
    phone.hello('p', 'Phone');
    await phone.next<Pairing>();
    await phone.next<Welcome>();
    final library = await phone.next<Library>();
    expect(library.games.single.name, 'Seven');
    phone.send(const Command('left'));
    for (var tries = 0; tries < 100 && !out.toString().contains('"command"'); tries++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(out.toString(), contains('from p: {"type":"command","name":"left"}'));
    await phone.close();
    stop.complete();
    expect(await running, 0);
  });

  test('steam: status, add and remove in a Steam folder, refused without one', () async {
    final home = p.join(temp.path, 'home');
    expect((await run(['steam', 'status'])).$3, contains('Steam not found'));
    Directory(p.join(home, '.local', 'share', 'Steam', 'userdata', '52079950', 'config')).createSync(recursive: true);
    expect((await run(['steam', 'add'])).$1, 2, reason: '--program is needed');
    final added = await run(['steam', 'add', '--program', '/opt/AnyPS5/anyps5_desktop', '--fullscreen']);
    expect(added.$1, 0, reason: added.$3);
    expect(added.$2, contains('added '));
    final status = await run(['steam', 'status']);
    expect(status.$2, contains('user 52079950 52079950: 1 AnyPS5 shortcuts'));
    expect(status.$2, contains('AnyPS5 "/opt/AnyPS5/anyps5_desktop" --steam --fullscreen'));
    final removed = await run(['steam', 'remove']);
    expect(removed.$2, startsWith('removed '));
    expect((await run(['steam', 'remove'])).$2, startsWith('no AnyPS5 shortcuts'));
    expect((await run(['steam', 'remove', '--user', '7'])).$3, contains('no Steam account 7'));
  });
}
