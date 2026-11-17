import 'package:anyps5_desktop/core/retro_host/retro_host_client.dart';
import 'package:anyps5_desktop/ui/retro_host/retro_host_keeper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_retro_host_session.dart';

void main() {
  test('a kept host is given to the next game of the same program, once', () {
    final keeper = RetroHostKeeper();
    final session = FakeRetroHostSession();
    keeper.keep(session, program: '/host/anyps5-retro-host');
    expect(keeper.holding, isTrue);
    expect(keeper.take(program: '/host/anyps5-retro-host'), same(session));
    expect(keeper.holding, isFalse);
    expect(keeper.take(program: '/host/anyps5-retro-host'), isNull);
    expect(session.shutdownAsked, isFalse);
  });

  test('a host of another program is shut down, not given', () async {
    final keeper = RetroHostKeeper();
    final session = FakeRetroHostSession();
    keeper.keep(session, program: '/old/anyps5-retro-host');
    expect(keeper.take(program: '/new/anyps5-retro-host'), isNull);
    await keeper.shutdown();
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isTrue);
  });

  test('a second host kept shuts the first down', () async {
    final keeper = RetroHostKeeper();
    final first = FakeRetroHostSession();
    final second = FakeRetroHostSession();
    keeper.keep(first, program: 'host');
    keeper.keep(second, program: 'host');
    await pumpEventQueue();
    expect(first.closed, isTrue);
    expect(keeper.take(program: 'host'), same(second));
  });

  test('a kept host is shut down after the idle limit', () async {
    final keeper = RetroHostKeeper(idleLimit: const Duration(milliseconds: 10));
    final session = FakeRetroHostSession();
    keeper.keep(session, program: 'host');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(keeper.holding, isFalse);
    await keeper.shutdown();
    expect(session.shutdownAsked, isTrue);
    expect(session.closed, isTrue);
  });

  test('taking the host stops its idle limit', () async {
    final keeper = RetroHostKeeper(idleLimit: const Duration(milliseconds: 10));
    final session = FakeRetroHostSession();
    keeper.keep(session, program: 'host');
    expect(keeper.take(program: 'host'), same(session));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(session.shutdownAsked, isFalse);
  });

  test('a kept host that ends by itself is forgotten and freed', () async {
    final keeper = RetroHostKeeper();
    final session = FakeRetroHostSession();
    keeper.keep(session, program: 'host');
    session.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    expect(keeper.holding, isFalse);
    expect(session.closed, isTrue);
    expect(session.shutdownAsked, isFalse);
    expect(keeper.take(program: 'host'), isNull);
  });

  test('a host that ends after it was taken is the game\'s to free, not the keeper\'s', () async {
    final keeper = RetroHostKeeper();
    final session = FakeRetroHostSession();
    keeper.keep(session, program: 'host');
    keeper.take(program: 'host');
    session.endedCompleter.complete(RetroHostEnd.hostFailure);
    await pumpEventQueue();
    expect(session.closed, isFalse);
  });

  test('shutdown with nothing kept does nothing', () async {
    final keeper = RetroHostKeeper();
    await keeper.shutdown();
    expect(keeper.holding, isFalse);
  });
}
