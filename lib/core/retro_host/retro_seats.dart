/// A controller taking or leaving one of the console's ports.
class RetroSeatChange {
  const RetroSeatChange(this.port, this.pad, {required this.joined});

  final int port;
  final String pad;

  /// True when [pad] sat down at [port], false when it left it.
  final bool joined;

  @override
  bool operator ==(Object other) =>
      other is RetroSeatChange && other.port == port && other.pad == pad && other.joined == joined;

  @override
  int get hashCode => Object.hash(port, pad, joined);

  @override
  String toString() => 'RetroSeatChange($port, $pad, ${joined ? 'joined' : 'left'})';
}

/// Which launcher controller sits at each of the PS1's two controller ports (anyps5-retro-host
/// docs/protocol.md "input": `port` 0 or 1).
///
/// A controller keeps its port while it stays connected, so a press on another pad never swaps
/// the players. A controller that leaves frees its port and the other one stays where it is. A
/// free port goes to the first waiting controller in the order given, which puts Player 1 (the
/// one used last before the game) at port 1 when the game starts.
class RetroSeats {
  static const portCount = 2;

  final List<String?> _ports = List.filled(portCount, null);

  /// The controller at [port], or null.
  String? at(int port) => _ports[port];

  /// The port [pad] sits at, or null.
  int? portOf(String pad) {
    final index = _ports.indexOf(pad);
    return index < 0 ? null : index;
  }

  /// The `connectedPorts` argument: how many ports, counting from port 1, have a controller in.
  /// Port 1 always counts, because the host keeps a controller there for every game.
  int get connectedPorts => _ports[1] != null ? 2 : 1;

  /// Seats the controllers connected now, [present] in the launcher's order (Player 1 first), and
  /// gives what changed: the controllers that left first, then those that sat down.
  List<RetroSeatChange> sync(List<String> present) {
    final changes = <RetroSeatChange>[];
    final here = present.toSet();
    for (var port = 0; port < portCount; port++) {
      final pad = _ports[port];
      if (pad != null && !here.contains(pad)) {
        _ports[port] = null;
        changes.add(RetroSeatChange(port, pad, joined: false));
      }
    }
    for (final pad in present) {
      if (_ports.contains(pad)) continue;
      final free = _ports.indexOf(null);
      if (free < 0) break;
      _ports[free] = pad;
      changes.add(RetroSeatChange(free, pad, joined: true));
    }
    return changes;
  }
}
