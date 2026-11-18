/// The values and message rules of the emulator host's protocol, version 1 (anyps5-retro-host
/// docs/protocol.md), as the launcher's client checks them.
library;

import 'dart:convert';

/// The other side broke a rule that protocol.md "Protocol errors" lists. The launcher kills the
/// host and handles it as a host failure.
class RetroProtocolError implements Exception {
  const RetroProtocolError(this.message);

  final String message;

  @override
  String toString() => 'RetroProtocolError: $message';
}

/// A call's `error` reply (protocol.md "call and reply"). [code] is what programs act on; a code
/// this launcher does not know is a failure without a known cause.
class RetroCallError implements Exception {
  const RetroCallError(this.code, this.message);

  final String code;
  final String message;

  static const unknownMethod = 'unknownMethod';
  static const argument = 'argument';
  static const busy = 'busy';
  static const start = 'start';
  static const tooLarge = 'tooLarge';

  /// `loadState`: the slot or file holds no state (protocol.md "saveState and loadState").
  static const noState = 'noState';

  /// `loadState`: not a state file of a version the host reads, or one whose header does not
  /// match its size.
  static const badState = 'badState';

  /// `loadState`: the state was saved from another game (another console or disc name).
  static const otherGame = 'otherGame';

  /// `loadState`: the state was saved by another core or core build (`status.core` differs).
  static const otherCore = 'otherCore';

  /// The core gave no state, or refused the one in the file; the game runs on.
  static const coreRefused = 'coreRefused';

  /// The state file could not be written or read, or not in time.
  static const fileError = 'fileError';

  @override
  String toString() => 'RetroCallError($code): $message';
}

/// The two frame pixel formats version 1 defines, and their codes in the ring header.
abstract final class RetroPixelFormat {
  static const rgba8 = 'rgba8';
  static const bgra8 = 'bgra8';

  static int code(String format) => format == rgba8 ? 1 : 2;
}

/// The protocol version this launcher speaks.
const retroProtocolVersion = 1;

/// The capability every method of version 1 needs.
const retroCapabilityPs1 = 'ps1';

/// The capability that plays PS2 games on LRPS2: `start.console` and `status.console`
/// (protocol.md "Capabilities", anyps5-retro-host docs/ps2.md).
const retroCapabilityPs2 = 'ps2';

/// The capability that says the host limits a PS2 game's internal resolution
/// (`pcsx2_upscale_multiplier`) to what it can pass on, as it limits PS1's (protocol.md
/// "Capabilities" and "status"). A launcher offers and sends a PS2 internal resolution only to a
/// host that lists it: a `ps2` host without it gives LRPS2 the value as given.
const retroCapabilityPs2ResolutionLimits = 'ps2ResolutionLimits';

/// The capability that saves and loads a game's state for one player: `start.states` and the
/// methods `saveState` and `loadState` (protocol.md "saveState and loadState").
const retroCapabilitySaveStates = 'saveStates';

/// The consoles `start.console` names and `status.console` gives (capability [retroCapabilityPs2]).
abstract final class RetroConsole {
  static const ps1 = 'ps1';
  static const ps2 = 'ps2';

  static const all = {ps1, ps2};
}

/// The `errorCode` values a `status` can carry, and the two the client reports itself after a host
/// failure (protocol.md "Host failure").
abstract final class RetroErrorCode {
  static const none = '';
  static const bios = 'bios';
  static const disc = 'disc';
  static const core = 'core';
  static const stalled = 'stalled';
  static const didNotStart = 'didNotStart';
  static const frameTooLarge = 'frameTooLarge';
  static const other = 'other';
  static const hostExited = 'hostExited';
  static const hostHung = 'hostHung';
}

/// Reads fields of a received message, throwing [RetroProtocolError] when one is missing, has the
/// wrong type, or is out of its range.
class RetroFields {
  const RetroFields(this.map, this.where);

  final Map<String, Object?> map;
  final String where;

  static const maxId = 2147483647;
  static const maxUint32 = 4294967295;

  /// The largest integer a JSON number holds exactly (protocol.md "Values").
  static const maxSafeInteger = 9007199254740991;

  Never _bad(String key, String rule) => throw RetroProtocolError('$where.$key $rule.');

  bool has(String key) => map.containsKey(key);

  int integer(String key, int min, int max) {
    final value = map[key];
    if (value is! int) _bad(key, 'must be an integer');
    if (value < min || value > max) _bad(key, 'must be from $min to $max');
    return value;
  }

  double number(String key, {double? above, double? atMost}) {
    final value = map[key];
    if (value is! num) _bad(key, 'must be a number');
    final number = value.toDouble();
    if (above != null && !(number > above)) _bad(key, 'must be greater than $above');
    if (atMost != null && number > atMost) _bad(key, 'must be at most $atMost');
    return number;
  }

  String string(String key) {
    final value = map[key];
    if (value is! String) _bad(key, 'must be a string');
    return value;
  }

  String? stringOrNull(String key) {
    if (!map.containsKey(key)) _bad(key, 'is missing');
    final value = map[key];
    if (value != null && value is! String) _bad(key, 'must be a string or null');
    return value as String?;
  }

  bool boolean(String key) {
    final value = map[key];
    if (value is! bool) _bad(key, 'must be a boolean');
    return value;
  }

  List<String> strings(String key) {
    final value = map[key];
    if (value is! List<Object?> || value.any((item) => item is! String)) _bad(key, 'must be an array of strings');
    return value.cast<String>();
  }

  RetroFields object(String key) {
    final value = map[key];
    if (value is! Map<String, Object?>) _bad(key, 'must be an object');
    return RetroFields(value, '$where.$key');
  }
}

/// One core option a `status` lists (protocol.md "status").
class RetroOption {
  const RetroOption({
    required this.key,
    required this.title,
    required this.values,
    required this.labels,
    required this.selected,
    required this.activeValue,
    required this.restart,
  });

  final String key;
  final String title;
  final List<String> values;
  final List<String> labels;
  final int selected;
  final String activeValue;
  final bool restart;

  Map<String, Object?> toJson() => {
    'title': title,
    'values': values,
    'labels': labels,
    'selected': selected,
    'activeValue': activeValue,
    'restart': restart,
  };
}

/// The discs of a multi-disc game.
class RetroDiscs {
  const RetroDiscs({
    required this.labels,
    required this.inserted,
    required this.insertedDiscPath,
    required this.playedDiscPath,
    required this.busy,
    required this.failed,
  });

  final List<String> labels;
  final int? inserted;
  final String? insertedDiscPath;
  final String playedDiscPath;
  final bool busy;
  final bool failed;

  Map<String, Object?> toJson() => {
    'labels': labels,
    'inserted': inserted,
    'insertedDiscPath': insertedDiscPath,
    'playedDiscPath': playedDiscPath,
    'busy': busy,
    'failed': failed,
  };
}

/// A loaded game's state, from `status`, or the shorter form the client gives after a host failure.
class RetroStatus {
  const RetroStatus({
    required this.ready,
    required this.ended,
    required this.error,
    required this.errorCode,
    this.aspect = 4 / 3,
    this.hardware = false,
    this.resolutionError = '',
    this.graphicsPending = false,
    this.progressLabel,
    this.progressPercent,
    this.options = const {},
    this.cardUnreadable = false,
    this.discs,
    this.console,
  });

  /// What the client reports from a host failure until the UI calls `release`.
  const RetroStatus.failed({required this.error, required this.errorCode})
    : ready = false,
      ended = true,
      aspect = 4 / 3,
      hardware = false,
      resolutionError = '',
      graphicsPending = false,
      progressLabel = null,
      progressPercent = null,
      options = const {},
      cardUnreadable = false,
      discs = null,
      console = null;

  final bool ready;
  final bool ended;
  final String error;
  final String errorCode;
  final double aspect;
  final bool hardware;
  final String resolutionError;
  final bool graphicsPending;
  final String? progressLabel;
  final int? progressPercent;
  final Map<String, RetroOption> options;

  /// Memory card 1's file is there but the host could not read it as a card, so it is left as it
  /// is and this game's saves are not written anywhere. False from a status without the field.
  final bool cardUnreadable;

  final RetroDiscs? discs;

  /// The console the game was started as ([RetroConsole]); null from a host without
  /// [retroCapabilityPs2].
  final String? console;

  /// The most discs `status.discs.labels` may list.
  static const maxDiscs = 128;

  /// The status as protocol.md "status" writes it.
  Map<String, Object?> toJson() => {
    ...toFailureJson(),
    'aspect': aspect,
    'hardware': hardware,
    'resolutionError': resolutionError,
    'graphicsPending': graphicsPending,
    'progressLabel': progressLabel,
    'progressPercent': progressPercent,
    'options': {for (final option in options.values) option.key: option.toJson()},
    'cardUnreadable': cardUnreadable,
    'discs': ?discs?.toJson(),
    'console': ?console,
  };

  /// Whether [other] says the same as this status, field by field, as protocol.md "status" writes
  /// it (the order of the options too, which is the menu's order).
  bool sameAs(RetroStatus other) => identical(this, other) || jsonEncode(toJson()) == jsonEncode(other.toJson());

  /// The four fields protocol.md "Host failure" gives for a status the client made.
  Map<String, Object?> toFailureJson() => {'ready': ready, 'ended': ended, 'error': error, 'errorCode': errorCode};

  /// Whether [map] is the client's own failure report rather than a host's status, which always
  /// has every field.
  static bool isFailureReport(Map<String, Object?> map) =>
      map.length == 4 && (map['errorCode'] == RetroErrorCode.hostExited || map['errorCode'] == RetroErrorCode.hostHung);

  /// Reads a `status` result, throwing [RetroProtocolError] for a field out of what protocol.md
  /// allows. Unknown fields are ignored. A host's `errorCode` of `hostExited` or `hostHung`, which
  /// only the client may report, is read as `other` (protocol.md "status"). A host that lists
  /// [retroCapabilityPs2] ([ps2]) sends `console` in every status, `"ps1"` or `"ps2"`; any other
  /// host's `console` is ignored.
  static RetroStatus parse(Map<String, Object?> map, {bool ps2 = false}) {
    final f = RetroFields(map, 'status');
    final options = <String, RetroOption>{};
    final optionFields = f.object('options');
    for (final key in optionFields.map.keys) {
      final o = optionFields.object(key);
      final values = o.strings('values');
      final labels = o.strings('labels');
      if (labels.length != values.length) throw RetroProtocolError('status.options.$key.labels must match values.');
      options[key] = RetroOption(
        key: key,
        title: o.string('title'),
        values: values,
        labels: labels,
        selected: values.isEmpty
            ? throw RetroProtocolError('status.options.$key.values is empty.')
            : o.integer('selected', 0, values.length - 1),
        activeValue: o.string('activeValue'),
        restart: o.boolean('restart'),
      );
    }
    RetroDiscs? discs;
    if (f.has('discs')) {
      final d = f.object('discs');
      final labels = d.strings('labels');
      if (labels.length > maxDiscs) throw const RetroProtocolError('status.discs.labels has more than 128 discs.');
      if (!d.has('inserted')) throw const RetroProtocolError('status.discs.inserted is missing.');
      final inserted = d.map['inserted'];
      if (inserted != null && (inserted is! int || inserted < 0 || inserted >= labels.length)) {
        throw const RetroProtocolError('status.discs.inserted must be a disc index or null.');
      }
      discs = RetroDiscs(
        labels: labels,
        inserted: inserted as int?,
        insertedDiscPath: d.stringOrNull('insertedDiscPath'),
        playedDiscPath: d.string('playedDiscPath'),
        busy: d.boolean('busy'),
        failed: d.boolean('failed'),
      );
    }
    if (!f.has('progressPercent')) throw const RetroProtocolError('status.progressPercent is missing.');
    final percent = map['progressPercent'];
    if (percent != null && (percent is! int || percent < 0 || percent > 100)) {
      throw const RetroProtocolError('status.progressPercent must be an integer from 0 to 100 or null.');
    }
    final errorCode = f.string('errorCode');
    return RetroStatus(
      ready: f.boolean('ready'),
      ended: f.boolean('ended'),
      error: f.string('error'),
      errorCode: errorCode == RetroErrorCode.hostExited || errorCode == RetroErrorCode.hostHung
          ? RetroErrorCode.other
          : errorCode,
      aspect: f.number('aspect', above: 0, atMost: 10),
      hardware: f.boolean('hardware'),
      resolutionError: f.string('resolutionError'),
      graphicsPending: f.boolean('graphicsPending'),
      progressLabel: f.stringOrNull('progressLabel'),
      progressPercent: percent as int?,
      options: options,
      cardUnreadable: f.has('cardUnreadable') && f.boolean('cardUnreadable'),
      discs: discs,
      console: ps2 ? _console(f) : null,
    );
  }

  static String _console(RetroFields f) {
    final console = f.string('console');
    if (!RetroConsole.all.contains(console)) throw RetroProtocolError('status.console $console is unknown.');
    return console;
  }
}
