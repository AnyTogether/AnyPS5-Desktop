import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/core/retro_host/retro_host_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The launcher's conformance test (anyps5-retro-host docs/protocol.md "Fixtures"): every session
/// whose `tests` includes `launcher` is played by the host repository's fake host, which the client
/// starts through its real start path as if it were the host. This test does what a launcher's UI
/// would (the calls, `input`, `shutdown`, reading frames and what the client reports) and checks
/// the outcome; the fake checks every message the client sends and writes a report.
///
/// ANYPS5_RETRO_HOST_CHECKOUT names a checkout of anyps5-retro-host that has `fixtures/v1` and
/// `tests/fake_host.py`; without it the test is skipped. Python 3 must be on PATH.
void main() {
  final checkout = Platform.environment['ANYPS5_RETRO_HOST_CHECKOUT'];
  if (checkout == null || checkout.isEmpty) {
    test('fixture sessions', () {}, skip: 'ANYPS5_RETRO_HOST_CHECKOUT is not set');
    return;
  }
  final sessions = Directory(p.join(checkout, 'fixtures', 'v1', 'sessions')).listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final python = _python();
  for (final file in sessions) {
    final session = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    if (!(session['tests']! as List).contains('launcher')) continue;
    final name = p.basenameWithoutExtension(file.path);
    final skip = _runsHere(session['os'] as String?) ? null : 'only on ${session['os']}';
    test(
      name,
      () => _Session(checkout, python, file, session).play(),
      skip: skip,
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
  test('a reply with a wrong result still answers its call', () async {
    final directory = Directory.systemTemp.createTempSync('retro-host-own-');
    try {
      final session = <String, Object?>{
        'description': 'The host answers pause with true instead of null.',
        'tests': ['launcher'],
        'outcome': 'protocolError',
        'steps': [
          ..._greeting,
          {
            'from': 'launcher',
            'message': {'type': 'call', 'id': 2, 'method': 'pause', 'args': true},
            'anyValueFor': ['id'],
          },
          {
            'from': 'host',
            'message': {'type': 'reply', 'id': 2, 'result': true},
            'anyValueFor': ['id'],
            'invalid': 'pause returns null',
          },
        ],
      };
      final file = File(p.join(directory.path, 'pause-result-not-null.json'))..writeAsStringSync(jsonEncode(session));
      await _Session(checkout, python, file, session).play();
    } finally {
      directory.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
  test(
    'a frame of another game takes away the frame shown',
    () => _playOwn(checkout, python, 'A drawn frame, then a frame of another epoch in the same ring.', 'clean', [
      ..._startedGame(checkout),
      {'launcherDraws': true},
      {
        'from': 'host',
        'message': {'type': 'frame'},
        'publish': {
          'latest': 1,
          'slot': {'width': 320, 'height': 240, 'visible': 1, 'epoch': 7, 'sequence': 2},
        },
      },
      {'launcherDraws': false},
      {
        'from': 'launcher',
        'message': {'type': 'shutdown'},
      },
      {'hostExits': 0},
    ]),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a call refused before it is sent leaves the next call in order',
    () => _playOwn(
      checkout,
      python,
      'A call too large to send, then a status call that must still be answered in order.',
      'clean',
      [
        {
          'from': 'launcher',
          'message': {'type': 'call', 'id': 2, 'method': 'status', 'args': null},
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {'type': 'reply', 'id': 2, 'result': null},
          'anyValueFor': ['id'],
        },
      ],
      afterReady: (client) => expectLater(
        client.call('option', {'key': 'k', 'value': 'x' * 1100000}),
        throwsA(isA<RetroCallError>().having((e) => e.code, 'code', RetroCallError.argument)),
      ),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a pause with no game does not silence the rumble of the next game',
    () => _playOwn(
      checkout,
      python,
      'pause with no game loaded, then start, then rumble that must be forwarded.',
      'clean',
      [
        {
          'from': 'launcher',
          'message': {'type': 'call', 'id': 2, 'method': 'pause', 'args': true},
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {'type': 'reply', 'id': 2, 'result': null},
          'anyValueFor': ['id'],
        },
        {
          'from': 'launcher',
          'message': {
            'type': 'call',
            'id': 3,
            'method': 'start',
            'args': {'core': r'${core}', 'disc': r'${disc}', 'system': r'${system}', 'saves': r'${saves}'},
          },
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {
            'type': 'reply',
            'id': 3,
            'result': {'epoch': 1},
          },
          'anyValueFor': ['id'],
        },
        {
          'from': 'host',
          'message': {'type': 'rumble', 'port': 0, 'strong': 1000, 'weak': 0},
        },
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) => expect(session.rumbles.any((r) => r.strong == 1000), isTrue, reason: 'rumble forwarded'),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a rumble listener may close the client',
    () => _playOwn(
      checkout,
      python,
      'A game rumbles and the launcher closes the client from its rumble listener.',
      'hostFailure',
      [
        ..._startCall(checkout),
        {
          'from': 'host',
          'message': {'type': 'rumble', 'port': 0, 'strong': 1000, 'weak': 0},
        },
      ],
      afterReady: (client) async => client.rumble.listen((rumble) {
        if (rumble.strong == 1000) unawaited(client.close());
      }),
      check: (session) => expect(session.rumbles.last, _zero(1), reason: 'motors zeroed on close'),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'rumble reaches only ports with a controller, and leaving port 2 stops the motors',
    () => _playOwn(
      checkout,
      python,
      'Port 2 rumbles before a controller joins it, while one is in it, and after it left.',
      'clean',
      [
        ..._startCall(checkout),
        _rumbleStep(1, 3000),
        ..._status(checkout, 3, ended: false),
        ..._call('connectedPorts', 2, true, id: 4),
        _rumbleStep(1, 1000),
        ..._status(checkout, 5, ended: false),
        ..._call('connectedPorts', 1, true, id: 6),
        _rumbleStep(1, 2000),
        ..._status(checkout, 7, ended: false),
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) {
        final strong = [for (final r in session.rumbles) r.strong];
        expect(strong, isNot(contains(3000)), reason: 'no rumble before a controller joined port 2');
        expect(strong, isNot(contains(2000)), reason: 'no rumble after the controller left port 2');
        final forwarded = strong.indexOf(1000);
        expect(forwarded, isNot(-1), reason: 'rumble forwarded while port 2 had a controller');
        final zeros = session.rumbles.skip(forwarded + 1).where((r) => r.port == 1 && r.strong == 0 && r.weak == 0);
        expect(zeros.length, 2, reason: 'port 2 zeroed when its controller left, and again at the end');
      },
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'shutting down a game that rumbles stops the motors',
    () => _playOwn(checkout, python, 'A game rumbles, then the launcher shuts the host down.', 'clean', [
      ..._startCall(checkout),
      {
        'from': 'host',
        'message': {'type': 'rumble', 'port': 0, 'strong': 1000, 'weak': 0},
      },
      {
        'from': 'launcher',
        'message': {'type': 'shutdown'},
      },
      {'hostExits': 0},
    ], check: (session) => expect(session.rumbles.last, _zero(1), reason: 'motors zeroed at the end')),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'connectedPorts sent before the start reply still counts',
    () => _playOwn(
      checkout,
      python,
      'start and connectedPorts(2) sent together, then rumble on port 2.',
      'clean',
      [
        _startCall(checkout)[0],
        _call('connectedPorts', 2, true, id: 3)[0],
        _startCall(checkout)[1],
        _call('connectedPorts', 2, true, id: 3)[1],
        _rumbleStep(1, 1000),
        ..._status(checkout, 4, ended: false),
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) =>
          expect([for (final r in session.rumbles) r.strong], contains(1000), reason: 'rumble on port 2 forwarded'),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a pause sent before the start reply still silences rumble',
    () => _playOwn(
      checkout,
      python,
      'start and pause(true) sent together, then rumble.',
      'clean',
      [
        _startCall(checkout)[0],
        _call('pause', true, null, id: 3)[0],
        _startCall(checkout)[1],
        _call('pause', true, null, id: 3)[1],
        _rumbleStep(0, 1000),
        ..._status(checkout, 4, ended: false),
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) =>
          expect([for (final r in session.rumbles) r.strong], isNot(contains(1000)), reason: 'no rumble while paused'),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a start refused with busy does not undo a pause',
    () => _playOwn(
      checkout,
      python,
      'A paused game, a second start, then rumble before its busy reply.',
      'clean',
      [
        ..._startCall(checkout),
        ..._call('pause', true, null, id: 3),
        _secondStart(checkout, 4),
        _rumbleStep(0, 1000),
        {
          'from': 'host',
          'message': {
            'type': 'reply',
            'id': 4,
            'error': {'code': 'busy', 'message': 'A game is loaded.'},
          },
          'anyValueFor': ['id'],
        },
        _rumbleStep(0, 2000),
        ..._status(checkout, 5, ended: false),
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) {
        final strong = [for (final r in session.rumbles) r.strong];
        expect(strong, isNot(contains(1000)), reason: 'no rumble while start was waiting');
        expect(strong, isNot(contains(2000)), reason: 'no rumble after the busy reply');
      },
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'rumble after the game ended is not forwarded',
    () => _playOwn(
      checkout,
      python,
      'status shows the game ended, then a late rumble, then status again.',
      'clean',
      [
        ..._startCall(checkout),
        ..._status(checkout, 3, ended: true),
        _rumbleStep(0, 1000),
        ..._status(checkout, 4, ended: true),
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) =>
          expect([for (final r in session.rumbles) r.strong], isNot(contains(1000)), reason: 'no rumble after the end'),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a status of null forgets a game released before its end was seen',
    () => _playOwn(
      checkout,
      python,
      'release answered before any status showed the end, status null, then the host exits unasked.',
      'hostFailure',
      [
        ..._startCall(checkout),
        ..._call('release', null, null, id: 3),
        ..._call('status', null, null, id: 4),
        {'hostExits': 1},
      ],
      check: (session) => expectLater(session.client.status(), throwsA(isA<RetroHostGone>())),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a host that exits right after releasing an ended game reports no game',
    () => _playOwn(
      checkout,
      python,
      'status shows the game ended, release is answered, then the host exits, as after a stuck core.',
      'hostFailure',
      [
        ..._startCall(checkout),
        ..._status(checkout, 3, ended: true),
        ..._call('release', null, null, id: 4),
        {'hostExits': 0},
      ],
      check: (session) => expectLater(session.client.status(), throwsA(isA<RetroHostGone>())),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'release of a running game does not hide a later protocol error',
    () => _playOwn(
      checkout,
      python,
      'release answered while the game runs, then a rumble for a port that does not exist.',
      'protocolError',
      [
        ..._startCall(checkout),
        ..._call('release', null, null, id: 3),
        {
          'from': 'host',
          'message': {'type': 'rumble', 'port': 2, 'strong': 1000, 'weak': 0},
          'invalid': 'port is 0 or 1',
        },
      ],
      check: (session) => expectLater(session.client.status(), completion(_failedGame)),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a host that plays on after release and then exits reports the game failed and stops the motors',
    () => _playOwn(
      checkout,
      python,
      'release answered while the game runs, rumble, then the host exits unasked.',
      'hostFailure',
      [
        ..._startCall(checkout),
        ..._call('release', null, null, id: 3),
        _rumbleStep(0, 1000),
        {'hostExits': 1},
      ],
      check: (session) {
        final strong = [for (final r in session.rumbles) r.strong];
        expect(strong, contains(1000), reason: 'rumble forwarded');
        expect(session.rumbles.last, _zero(1), reason: 'motors zeroed at the end');
        expectLater(session.client.status(), completion(_failedGame));
      },
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'the end of a game zeroes the motors even with the next start waiting',
    () => _playOwn(
      checkout,
      python,
      'status, release and the next start sent together; the old game rumbles before status shows its end.',
      'clean',
      [
        ..._startCall(checkout),
        _status(checkout, 3, ended: true)[0],
        _call('release', null, null, id: 4)[0],
        _secondStart(checkout, 5),
        _rumbleStep(0, 1000),
        _status(checkout, 3, ended: true)[1],
        _rumbleStep(0, 3000),
        _call('release', null, null, id: 4)[1],
        {
          'from': 'host',
          'message': {
            'type': 'reply',
            'id': 5,
            'result': {'epoch': 2},
          },
          'anyValueFor': ['id'],
        },
        {
          'from': 'launcher',
          'message': {'type': 'shutdown'},
        },
        {'hostExits': 0},
      ],
      check: (session) {
        final forwarded = session.rumbles.indexWhere((r) => r.strong == 1000);
        expect(forwarded, isNot(-1), reason: 'rumble of the old game forwarded while it ran');
        final zeros = session.rumbles.skip(forwarded + 1).where((r) => r.strong == 0 && r.weak == 0);
        expect(zeros.length, 4, reason: 'zeroed when the game ended, and again at the end');
        expect([for (final r in session.rumbles) r.strong], isNot(contains(3000)), reason: 'no rumble after the end');
      },
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'a host that exits right after releasing a running game reports the game failed',
    () => _playOwn(
      checkout,
      python,
      'release answered while the game runs, which does nothing, then the host exits unasked.',
      'hostFailure',
      [
        ..._startCall(checkout),
        ..._call('release', null, null, id: 3),
        {'hostExits': 1},
      ],
      check: (session) => expectLater(session.client.status(), completion(_failedGame)),
    ),
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test('a status answered before stop does not lift the stop time limit', () async {
    final fixture =
        (jsonDecode(File(p.join(checkout, 'fixtures', 'v1', 'sessions', 'stop-deadline.json')).readAsStringSync())
                as Map<String, Object?>)['steps']!
            as List<Object?>;
    final steps = fixture.cast<Map<String, Object?>>();
    Map<String, Object?> withId(Map<String, Object?> step, int id) => {
      ...step,
      'message': {...step['message']! as Map<String, Object?>, 'id': id},
    };
    await _playOwn(
      checkout,
      python,
      'status, start and stop sent together with no game loaded; the game then never ends.',
      'hostFailure',
      [
        _call('status', null, null, id: 2)[0],
        withId(steps[4], 3),
        withId(steps[8], 4),
        _call('status', null, null, id: 2)[1],
        withId(steps[5], 3),
        withId(steps[9], 4),
        ...steps.sublist(10),
      ],
      check: (session) =>
          expect(session.client.failureReason, contains('after stop'), reason: 'killed by the stop limit'),
    );
  }, timeout: const Timeout(Duration(seconds: 90)));
}

final _failedGame = isA<RetroStatus>()
    .having((s) => s.ended, 'ended', isTrue)
    .having((s) => s.errorCode, 'errorCode', RetroErrorCode.hostExited);

Matcher _zero(int port) => isA<RetroRumble>()
    .having((r) => r.port, 'port', port)
    .having((r) => r.strong, 'strong', 0)
    .having((r) => r.weak, 'weak', 0);

Map<String, Object?> _rumbleStep(int port, int strong) => {
  'from': 'host',
  'message': {'type': 'rumble', 'port': port, 'strong': strong, 'weak': 0},
};

/// A call the launcher sends and the host's reply; [id] is the session's id for the call, which the
/// fake host maps to the id the client used.
List<Map<String, Object?>> _call(String method, Object? args, Object? result, {int id = 2}) => [
  {
    'from': 'launcher',
    'message': {'type': 'call', 'id': id, 'method': method, 'args': args},
    'anyValueFor': ['id'],
  },
  {
    'from': 'host',
    'message': {'type': 'reply', 'id': id, 'result': result},
    'anyValueFor': ['id'],
  },
];

/// The `start` call of ring-grows again, as the session's call [id].
Map<String, Object?> _secondStart(String checkout, int id) {
  final step = _startCall(checkout)[0];
  return {
    ...step,
    'message': {...step['message']! as Map<String, Object?>, 'id': id},
  };
}

/// A `status` call, as the session's call [id], whose reply is play-and-quit's status of its game,
/// running or [ended].
List<Map<String, Object?>> _status(String checkout, int id, {required bool ended}) {
  final steps =
      (jsonDecode(File(p.join(checkout, 'fixtures', 'v1', 'sessions', 'play-and-quit.json')).readAsStringSync())
              as Map<String, Object?>)['steps']!
          as List<Object?>;
  final reply = steps.cast<Map<String, Object?>>().firstWhere((step) {
    final message = step['message'] as Map<String, Object?>?;
    final result = message?['result'];
    return message?['type'] == 'reply' && result is Map && result['ended'] == ended;
  });
  return [
    _call('status', null, null, id: id)[0],
    {
      ...reply,
      'message': {...reply['message']! as Map<String, Object?>, 'id': id},
    },
  ];
}

/// Steps 4 and 5 of ring-grows: `start` and its reply.
List<Map<String, Object?>> _startCall(String checkout) => _startedGame(checkout).sublist(0, 2);

Future<void> _playOwn(
  String checkout,
  String python,
  String name,
  String outcome,
  List<Map<String, Object?>> steps, {
  Future<void> Function(RetroHostClient client)? afterReady,
  void Function(_Session session)? check,
}) async {
  final directory = Directory.systemTemp.createTempSync('retro-host-own-');
  try {
    final session = <String, Object?>{
      'description': name,
      'tests': ['launcher'],
      'outcome': outcome,
      'steps': [..._greeting, ...steps],
    };
    final file = File(p.join(directory.path, 'own.json'))..writeAsStringSync(jsonEncode(session));
    await _Session(checkout, python, file, session, afterReady: afterReady, check: check).play();
  } finally {
    directory.deleteSync(recursive: true);
  }
}

/// Steps 4 to 7 of ring-grows: `start`, its reply, a ring, and a frame of the game.
List<Map<String, Object?>> _startedGame(String checkout) {
  final steps =
      (jsonDecode(File(p.join(checkout, 'fixtures', 'v1', 'sessions', 'ring-grows.json')).readAsStringSync())
              as Map<String, Object?>)['steps']!
          as List<Object?>;
  return [for (final step in steps.sublist(4, 8)) step! as Map<String, Object?>];
}

/// The start of a session: hello, welcome and the first volume call.
const _greeting = [
  {
    'from': 'launcher',
    'message': {
      'type': 'hello',
      'minVersion': 1,
      'maxVersion': 1,
      'pixelFormats': ['rgba8', 'bgra8'],
    },
    'anyValueFor': ['pixelFormats'],
  },
  {
    'from': 'host',
    'message': {
      'type': 'welcome',
      'version': 1,
      'pid': 1,
      'hostVersion': '1.0.0',
      'capabilities': ['ps1'],
      'pixelFormat': 'rgba8',
    },
    'anyValueFor': ['pid', 'hostVersion', 'pixelFormat'],
  },
  {
    'from': 'launcher',
    'message': {
      'type': 'call',
      'id': 1,
      'method': 'volume',
      'args': {'level': 1, 'muted': false},
    },
    'anyValueFor': ['id', 'args'],
  },
  {
    'from': 'host',
    'message': {'type': 'reply', 'id': 1, 'result': null},
    'anyValueFor': ['id'],
  },
];

String _python() {
  final name = Platform.isWindows ? 'python' : 'python3';
  final found = Process.runSync(Platform.isWindows ? 'where' : 'which', [name]);
  final path = (found.stdout as String)
      .split(RegExp(r'\r?\n'))
      .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
  if (path.isEmpty) throw StateError('$name is not on PATH');
  return path.trim();
}

bool _runsHere(String? os) => switch (os) {
  null => true,
  'windows' => Platform.isWindows,
  'posix' => !Platform.isWindows,
  'linux' => Platform.isLinux,
  'macos' => Platform.isMacOS,
  _ => false,
};

class _Session {
  _Session(this.checkout, this.python, this.file, this.session, {this.afterReady, this.check});

  /// Runs once the first `volume` call is answered, before the session's next call.
  final Future<void> Function(RetroHostClient client)? afterReady;

  /// Runs once the host has exited, before the outcome is checked.
  final void Function(_Session session)? check;
  final rumbles = <RetroRumble>[];

  final String checkout;
  final String python;
  final File file;
  final Map<String, Object?> session;
  late final Directory work;
  late final Map<String, String> paths;
  late final File resume;
  late final RetroHostClient client;
  final calls = <Future<Object?>>[];
  final frames = <RetroFrameEvent>[];
  int frameSteps = 0;

  Future<void> play() async {
    work = Directory.systemTemp.createTempSync('retro-host-session-');
    try {
      paths = _placeholders();
      final pathsFile = File(p.join(work.path, 'paths.json'))..writeAsStringSync(jsonEncode(paths));
      final report = File(p.join(work.path, 'report.json'));
      resume = File(p.join(work.path, 'resume'))..writeAsStringSync('-1');
      client = RetroHostClient.start(
        command: [
          python,
          '-I',
          p.join(checkout, 'tests', 'fake_host.py'),
          '--session',
          file.path,
          '--report',
          report.path,
          '--paths',
          pathsFile.path,
          '--resume',
          resume.path,
        ],
      );
      client.frames.listen(frames.add);
      client.rumble.listen(rumbles.add);
      unawaited(client.ready.then((_) {}, onError: (_) {}));
      await _steps(report);
      final end = await client.ended.timeout(const Duration(seconds: 40));
      await client.exited.timeout(const Duration(seconds: 20));
      check?.call(this);
      expect(end.name, session['outcome'], reason: 'outcome (${client.failureReason ?? 'no reason'})');
      // Nothing else in this test reaps children, so the host's exit code must be known: on Linux
      // that shows the client kept the host's pidfd (docs/RETRO_HOST_CLIENT.md).
      if (session['outcome'] == 'clean') expect(client.exitCode, 0, reason: 'exit code');
      await client.close();
      final result = jsonDecode(report.readAsStringSync()) as Map<String, Object?>;
      expect(result['failures'], isEmpty, reason: 'the fake host\'s report');
      expect(result['passed'], isTrue, reason: 'the fake host\'s report: $result');
    } finally {
      try {
        await client.close();
      } on Object {
        // The client was never started.
      }
      work.deleteSync(recursive: true);
    }
  }

  Map<String, String> _placeholders() {
    final made = <String, String>{};
    for (final name in ['core', 'disc', 'playlist', 'disc1', 'disc2']) {
      final extension = switch (name) {
        'core' => Platform.isWindows ? '.dll' : (Platform.isMacOS ? '.dylib' : '.so'),
        'playlist' => '.m3u',
        _ => '.cue',
      };
      made[name] = (File(p.join(work.path, '$name$extension'))..writeAsStringSync('')).absolute.path;
    }
    for (final name in ['system', 'saves']) {
      made[name] = (Directory(p.join(work.path, name))..createSync()).absolute.path;
    }
    return made;
  }

  Object? _fill(Object? value) => switch (value) {
    final String text => text.replaceAllMapped(RegExp(r'\$\{(\w+)\}'), (m) => paths[m[1]] ?? m[0]!),
    final Map<String, Object?> map => {for (final e in map.entries) e.key: _fill(e.value)},
    final List<Object?> list => [for (final item in list) _fill(item)],
    _ => value,
  };

  Future<void> _steps(File report) async {
    final steps = (session['steps']! as List).cast<Map<String, Object?>>();
    final clean = session['outcome'] == 'clean';
    var welcomed = false;
    var shutdown = false;
    Future<RetroStatus?>? stopping;
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      if (step['invalid'] != null && step['from'] == 'host') {
        await Future.wait([for (final pending in calls) pending.then((_) {}, onError: (_) {})])
            .timeout(const Duration(seconds: 15), onTimeout: () => fail('a call was never answered'));
        return;
      }
      final message = step['message'] as Map<String, Object?>?;
      final from = step['from'];
      if (from == 'launcher' && message != null) {
        switch (message['type']) {
          case 'call':
            final method = message['method']! as String;
            if (method == 'volume' && !welcomed) {
              welcomed = true;
              calls.add(
                client.ready.then((_) async {
                  await afterReady?.call(client);
                  return null;
                }),
              );
            } else if (method == 'stop') {
              stopping = client.stopGame();
              calls.add(Future.value());
            } else if (method == 'status' && stopping != null) {
              final stopped = stopping;
              stopping = null;
              calls.add(stopped.then((status) => status?.toJson()));
            } else {
              calls.add(client.call(method, _fill(message['args'])));
            }
          case 'input':
            client.input(
              message['port']! as int,
              message['buttons']! as int,
              leftX: message['leftX']! as int,
              leftY: message['leftY']! as int,
              rightX: message['rightX']! as int,
              rightY: message['rightY']! as int,
            );
          case 'shutdown':
            shutdown = true;
            client.shutdown();
        }
      } else if (from == 'host' && message != null) {
        switch (message['type']) {
          case 'reply':
            final pending = calls.removeAt(0);
            await _checkReply(pending, message, step['anyValueFor'] as List<Object?>?);
          case 'frame':
            frameSteps++;
            await _until(() => frames.length >= frameSteps, 'frame $frameSteps');
          case 'welcome' || 'unsupported':
            break;
        }
      } else if (step.containsKey('launcherDraws')) {
        await _until(() => frames.length >= frameSteps, 'frame $frameSteps');
        expect(frames[frameSteps - 1].drawn, step['launcherDraws'], reason: 'step $index launcherDraws');
        // A frame that is not drawn moved the pin in the frame's ring, so the frame shown before is no
        // longer readable either.
        expect(client.frame, step['launcherDraws'] == true ? isNotNull : isNull, reason: 'step $index frame');
        await _resume(index, report);
      } else if (step.containsKey('launcherReports')) {
        if (!clean) await client.ended.timeout(const Duration(seconds: 30));
        final expected = step['launcherReports']! as Map<String, Object?>;
        final method = expected['method']! as String;
        if (method == 'status') {
          final status = await client.status();
          expect(status?.toFailureJson(), expected['result'], reason: 'step $index launcherReports');
        } else {
          expect(await client.call(method), expected['result'], reason: 'step $index launcherReports');
        }
        await _resume(index, report);
      }
    }
    if (clean && !shutdown) client.shutdown();
  }

  /// Lets the fake host go on past the step at [index], where `--resume` holds it, and waits until
  /// its report shows it has (or it has exited), so the next message the client sends meets the
  /// next step.
  Future<void> _resume(int index, File report) async {
    resume.writeAsStringSync('$index');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (client.exitCode != null) return;
      try {
        final step = (jsonDecode(report.readAsStringSync()) as Map<String, Object?>)['step'];
        if (step is int && step > index) return;
      } on FormatException {
        // The fake is rewriting the report.
      } on FileSystemException {
        // Not written yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('the fake host did not go past step $index');
  }

  Future<void> _checkReply(Future<Object?> pending, Map<String, Object?> reply, List<Object?>? anyValueFor) async {
    final ignore = {for (final key in anyValueFor ?? const []) key as String};
    if (reply.containsKey('error')) {
      final expected = reply['error']! as Map<String, Object?>;
      await expectLater(pending, throwsA(isA<RetroCallError>().having((e) => e.code, 'code', expected['code'])));
      return;
    }
    final Object? result;
    try {
      result = await pending.timeout(const Duration(seconds: 10));
    } on RetroHostGone {
      return;
    }
    if (ignore.contains('result')) return;
    _compare(reply['result'], result, ignore, 'result');
  }

  void _compare(Object? expected, Object? actual, Set<String> ignore, String where) {
    if (ignore.contains(where)) return;
    if (expected is Map<String, Object?> && actual is Map<String, Object?>) {
      for (final key in expected.keys) {
        if (ignore.contains('$where.$key')) continue;
        expect(actual.containsKey(key), isTrue, reason: '$where.$key is missing');
        _compare(expected[key], actual[key], ignore, '$where.$key');
      }
      return;
    }
    expect(actual, _fill(expected), reason: where);
  }

  Future<void> _until(bool Function() done, String what) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
      if (await client.ended.then((_) => true).timeout(const Duration(milliseconds: 20), onTimeout: () => false)) {
        if (!done()) fail('the connection ended while waiting for $what');
      }
    }
  }
}
