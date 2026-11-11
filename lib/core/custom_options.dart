/// A game's own options as typed in its Advanced settings: Custom relinker options, added to the
/// relinker's on the next rebuild, and Launch options, the variables and arguments the game
/// starts with. The text is split into words here, never by a shell, the same way as on the Mac.
library;

/// What is wrong with an options text: the first problem, left to right.
enum OptionProblemKind {
  /// A ' or " that is not closed.
  openQuote,

  /// An option the launcher chooses itself (the system, the target, a path, the patches).
  launcherOption,

  /// An option that gives no game, or one that does not start.
  breaksGame,

  /// An option with a switch of its own above (Trace system library calls).
  hasSwitch,

  /// A word that looks like an option the relinker does not have.
  unknown,

  /// An option without the value it takes after it.
  needsValue,

  /// A word that is not an option: the launcher gives the relinker the game's files.
  positional,
}

/// A problem in an options text, and the word it is about.
class OptionProblem {
  const OptionProblem(this.kind, [this.word = '']);

  final OptionProblemKind kind;
  final String word;

  /// The word as a message shows it: an empty one as "".
  String get shown => word.isEmpty ? '""' : word;

  @override
  bool operator ==(Object other) => other is OptionProblem && other.kind == kind && other.word == word;

  @override
  int get hashCode => Object.hash(kind, word);

  @override
  String toString() => 'OptionProblem(${kind.name}, $word)';
}

/// An options text split into words, or what stops it.
class OptionWords {
  const OptionWords(this.words) : problem = null;
  const OptionWords.refused(OptionProblem this.problem) : words = const [];

  final List<String> words;
  final OptionProblem? problem;

  bool get ok => problem == null;
}

/// Splits [text] into words as a shell would, without ever running one: unquoted spaces, tabs
/// and line breaks separate words; '...' is taken as it is; in "...", \" is a quote and \\ a
/// backslash (a backslash before anything else stays); outside quotes a backslash makes the next
/// character plain (a lone one at the end stays). A quoted part joins the word it touches, and
/// '' or "" alone is an empty word.
OptionWords splitOptionWords(String text) {
  const space = 0x20, tab = 0x09, newline = 0x0A, carriageReturn = 0x0D;
  const singleQuote = 0x27, doubleQuote = 0x22, backslash = 0x5C;
  final characters = text.runes.toList();
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  var index = 0;
  while (index < characters.length) {
    final character = characters[index];
    if (character == space || character == tab || character == newline || character == carriageReturn) {
      if (inWord) {
        words.add(word.toString());
        word.clear();
        inWord = false;
      }
      index++;
      continue;
    }
    inWord = true;
    if (character == singleQuote) {
      final end = characters.indexOf(singleQuote, index + 1);
      if (end < 0) return const OptionWords.refused(OptionProblem(OptionProblemKind.openQuote));
      word.write(String.fromCharCodes(characters.sublist(index + 1, end)));
      index = end + 1;
    } else if (character == doubleQuote) {
      index++;
      var closed = false;
      while (index < characters.length) {
        final inside = characters[index];
        if (inside == doubleQuote) {
          closed = true;
          index++;
          break;
        }
        if (inside == backslash && index + 1 < characters.length) {
          final next = characters[index + 1];
          if (next == doubleQuote || next == backslash) {
            word.writeCharCode(next);
          } else {
            word
              ..writeCharCode(backslash)
              ..writeCharCode(next);
          }
          index += 2;
          continue;
        }
        word.writeCharCode(inside);
        index++;
      }
      if (!closed) return const OptionWords.refused(OptionProblem(OptionProblemKind.openQuote));
    } else if (character == backslash) {
      if (index + 1 < characters.length) {
        word.writeCharCode(characters[index + 1]);
        index += 2;
      } else {
        word.writeCharCode(backslash);
        index++;
      }
    } else {
      word.writeCharCode(character);
      index++;
    }
  }
  if (inWord) words.add(word.toString());
  return OptionWords(words);
}

/// The relinker's options (AnyPS5-ARM core/relinker/cli/src/CliArgs.cpp) by what a player may do
/// with them.
abstract final class RelinkerOptions {
  /// Chosen by the launcher for the system, the target and the game's files.
  static const launcherOwned = {
    '--windows',
    '--windows-gui',
    '--macos',
    '--to-intel',
    '--to-rosetta',
    '--sce-module-path',
    '--module-dir',
    '--executable',
    '--rpath',
    '--patches',
    '--no-patches',
  };

  /// Give no game, or one that cannot start.
  static const breaking = {
    '--skip-sce-module',
    '--dry-run',
    '--autorun',
    '--verify-patches',
    '--verify-output',
    '--help',
    '--version',
  };

  /// Have a switch of their own (RelinkerFlag).
  static const switched = {'--trace-imports'};

  /// Take the next word as their value.
  static const withValue = {'--exclude-sce-module', '--windows-fixed-base', '--linux-fixed-base', '--macos-fixed-base'};

  /// Taken as they are.
  static const plain = {
    '--windows-diagnostics',
    '--frame-red-zone',
    '--omit-unavailable-dependencies',
    '--registry',
    '--skip-syscall-check',
    '--trap-sdk-syscall-stubs',
    '--lazy-binding',
  };

  /// The unused-import filter levels, written without dashes.
  static const unusedFilters = {'unused-filter=0', 'unused-filter=1', 'unused-filter=2'};
}

/// The words of a Custom relinker options [text], or the first word the launcher will not pass.
OptionWords checkRelinkerOptions(String text) {
  final split = splitOptionWords(text);
  if (!split.ok) return split;
  final words = split.words;
  OptionWords refuse(OptionProblemKind kind, String word) => OptionWords.refused(OptionProblem(kind, word));
  var index = 0;
  while (index < words.length) {
    final word = words[index];
    if (word.startsWith('--') && word != '--') {
      if (RelinkerOptions.launcherOwned.contains(word)) return refuse(OptionProblemKind.launcherOption, word);
      if (RelinkerOptions.breaking.contains(word)) return refuse(OptionProblemKind.breaksGame, word);
      if (RelinkerOptions.switched.contains(word)) return refuse(OptionProblemKind.hasSwitch, word);
      if (RelinkerOptions.withValue.contains(word)) {
        final value = index + 1 < words.length ? words[index + 1] : null;
        if (value == null || value.isEmpty || value.startsWith('--')) {
          return refuse(OptionProblemKind.needsValue, word);
        }
        index += 2;
        continue;
      }
      if (RelinkerOptions.plain.contains(word)) {
        index++;
        continue;
      }
      return refuse(OptionProblemKind.unknown, word);
    }
    if (RelinkerOptions.unusedFilters.contains(word)) {
      index++;
      continue;
    }
    if (word.startsWith('unused-filter')) return refuse(OptionProblemKind.unknown, word);
    return refuse(OptionProblemKind.positional, word);
  }
  return OptionWords(words);
}

/// A game's Launch options: variables first (NAME=value), then the arguments for the game. Where
/// the launcher sets a variable for the start too, the launcher's value is used.
class GameLaunchOptions {
  const GameLaunchOptions({required this.text, this.environment = const {}, this.arguments = const []});

  /// The text as saved.
  final String text;

  /// The variables, in the order given (a name given twice keeps its last value).
  final Map<String, String> environment;

  /// The arguments the game's process gets.
  final List<String> arguments;

  static final _variable = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');

  /// The options in [text], or the problem (only a quote left open) that stops them.
  static (GameLaunchOptions?, OptionProblem?) parse(String text) {
    final split = splitOptionWords(text);
    if (!split.ok) return (null, split.problem);
    final environment = <String, String>{};
    var index = 0;
    for (; index < split.words.length; index++) {
      final word = split.words[index];
      if (!_variable.hasMatch(word)) break;
      final equals = word.indexOf('=');
      environment[word.substring(0, equals)] = word.substring(equals + 1);
    }
    return (GameLaunchOptions(text: text, environment: environment, arguments: split.words.sublist(index)), null);
  }

  /// The environment a start gets: these variables with [launcher]'s over them, and the names
  /// of the variables the launcher's value was used for, sorted.
  (Map<String, String>, List<String>) over(Map<String, String> launcher) {
    final overridden = [
      for (final name in environment.keys)
        if (launcher.containsKey(name)) name,
    ]..sort();
    return ({...environment, ...launcher}, overridden);
  }

  /// The lines the start writes in the game's log after its start line.
  List<String> notes(List<String> overridden) => [
    '[anyps5-launcher] launch options: $text',
    if (overridden.isNotEmpty)
      "[anyps5-launcher] launch options: the launcher's own value is used for ${overridden.join(', ')}",
  ];
}
