import 'package:anyps5_desktop/core/retro_host/retro_seats.dart';
import 'package:test/test.dart';

void main() {
  test('Player 1 sits at port 1 and the next controller at port 2', () {
    final seats = RetroSeats();
    expect(seats.connectedPorts, 1);
    expect(seats.sync(['a', 'b', 'c']), [
      const RetroSeatChange(0, 'a', joined: true),
      const RetroSeatChange(1, 'b', joined: true),
    ]);
    expect(seats.at(0), 'a');
    expect(seats.at(1), 'b');
    expect(seats.portOf('c'), isNull);
    expect(seats.connectedPorts, 2);
  });

  test('a new order does not swap the players', () {
    final seats = RetroSeats()..sync(['a', 'b']);
    expect(seats.sync(['b', 'a']), isEmpty);
    expect(seats.portOf('a'), 0);
    expect(seats.portOf('b'), 1);
  });

  test('a controller that leaves frees its port for the next one waiting', () {
    final seats = RetroSeats()..sync(['a', 'b', 'c']);
    expect(seats.sync(['a', 'c']), [
      const RetroSeatChange(1, 'b', joined: false),
      const RetroSeatChange(1, 'c', joined: true),
    ]);
    expect(seats.connectedPorts, 2);
  });

  test('when Player 1 leaves, Player 2 keeps port 2 and port 2 stays connected', () {
    final seats = RetroSeats()..sync(['a', 'b']);
    expect(seats.sync(['b']), [const RetroSeatChange(0, 'a', joined: false)]);
    expect(seats.at(0), isNull);
    expect(seats.at(1), 'b');
    expect(seats.connectedPorts, 2);
    expect(seats.sync(['b', 'd']), [const RetroSeatChange(0, 'd', joined: true)]);
  });

  test('port 2 is disconnected once its controller leaves', () {
    final seats = RetroSeats()..sync(['a', 'b']);
    seats.sync(['a']);
    expect(seats.connectedPorts, 1);
    expect(seats.sync([]), [const RetroSeatChange(0, 'a', joined: false)]);
    expect(seats.connectedPorts, 1);
  });
}
