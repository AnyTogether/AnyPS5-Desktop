import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/discord_presence.dart';
import 'app_model.dart';
import 'strings.dart';

/// What the user's Discord profile shows, when Settings › Behaviour › Show the game you play on
/// Discord is on (as on the Mac): the running game from when it started, the party they are in
/// ("In a party", with its size, even with no game), and the Join button with the party's code.
/// The party's leader gets a code made for the button when none works, but not where they
/// stopped it themselves; a code running out is such a time. Discord is told only when something
/// changed.
class DiscordModel {
  DiscordModel(this.app) : presence = _presenceFor(app);

  final AppModel app;

  /// Null in the tests (unless they give one) and wherever the application ID was turned off.
  final DiscordPresence? presence;

  static DiscordPresence? _presenceFor(AppModel app) {
    final given = app.services.discord;
    if (given != null) return given();
    final environment = app.services.environment ?? Platform.environment;
    // flutter test never talks to the Discord on the machine running it.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final made = DiscordPresence.system(app.system, environment);
    return made.applicationId.isEmpty ? null : made;
  }

  DiscordActivity? _shown;
  bool _cleared = true;
  bool _gamesLoading = false;

  /// Parties whose code the user stopped here: no code is made for the button again.
  final Set<String> codeStopped = {};

  /// Parties a code is being made for the button, or one failed for (not tried again).
  final Set<String> _making = {};

  /// Since when the user is in the party they are in.
  (String, DateTime)? _partySince;
  Timer? _refresh;
  DateTime? _refreshAt;

  /// The activity last sent, for the tests.
  DiscordActivity? get shown => _shown;

  /// The settings rows (Settings › Behaviour, after Show Hidden Trophies, as on the Mac).
  List<PanelRow> settingsRows() => [
    PanelRow(
      id: 'discord',
      title: T.text('discordPresence'),
      detail: T.text('discordPresenceDetail'),
      kind: ToggleRow(app.preferences.discordPresence, (value) {
        app.preferences.discordPresence = value;
        app.savePreferences();
        update();
      }),
    ),
    PanelRow(
      id: 'discordJoin',
      title: T.text('discordJoin'),
      detail: T.text('discordJoinDetail'),
      kind: ToggleRow(app.preferences.discordJoin, (value) {
        app.preferences.discordJoin = value;
        app.savePreferences();
        update();
      }),
    ),
  ];

  /// Something Discord shows may have changed: the game, the party, its code, the settings.
  void update() {
    final presence = this.presence;
    if (presence == null) return;
    final together = app.together;
    // An emulator game's name is its disc's file name: Discord never sees it.
    final running = app.running?.$1.retro == null ? app.running : null;
    final party = together.signedIn ? together.hub.parties.party : null;
    if (party?.id != _partySince?.$1) _partySince = party == null ? null : (party.id, DateTime.now());
    DateTime? refreshAt;
    try {
      if (!app.preferences.discordPresence || (running == null && party == null)) {
        _shown = null;
        if (!_cleared) {
          _cleared = true;
          unawaited(presence.clear());
        }
        return;
      }
      final buttons = <DiscordButton>[];
      final me = together.user?.id;
      if (app.preferences.discordJoin && party != null && me != null) {
        final code = party.joinCode;
        final plan = DiscordJoinPlan.of(
          partyId: party.id,
          codeUrl: code?.url,
          codeExpires: code?.expiresAt,
          leader: party.leaderId == me,
          mayMake:
              (together.family.rules?.publicMatchmaking ?? true) &&
              !codeStopped.contains(party.id) &&
              !_making.contains(party.id),
        );
        switch (plan) {
          case DiscordJoinButton(:final url):
            buttons.add(DiscordButton(T.text('discordJoinLabel'), url));
            final expires = code?.expiresAt;
            if (expires != null) refreshAt = expires;
          case DiscordJoinMake(:final partyId):
            _makeCode(partyId);
          case DiscordJoinNone():
            break;
        }
      }
      final game = running?.$1;
      final since = game == null
          ? _partySince?.$2
          : DateTime.tryParse(app.preferences.lastPlayed[game.id] ?? '') ?? DateTime.now();
      final activity = DiscordActivity(
        system: app.system,
        partyText: T.text('discordInParty'),
        game: game?.name,
        since: since,
        party: party == null ? null : DiscordParty(id: party.id, size: party.members.length, max: party.max),
        buttons: buttons,
      );
      if (game != null) _loadGames();
      if (activity == _shown) return;
      _shown = activity;
      _cleared = false;
      unawaited(presence.show(activity));
    } finally {
      _refreshWhen(refreshAt);
    }
  }

  /// Discord again once the code its button opens runs out.
  void _refreshWhen(DateTime? at) {
    if (at == _refreshAt) return;
    _refresh?.cancel();
    _refreshAt = at;
    if (at == null) return;
    final wait = at.difference(DateTime.now()) + const Duration(seconds: 1);
    _refresh = Timer(wait.isNegative ? Duration.zero : wait, () {
      _refreshAt = null;
      update();
    });
  }

  /// A code for the Join button, made once; one that fails is not tried again this run.
  void _makeCode(String partyId) {
    _making.add(partyId);
    unawaited(() async {
      try {
        await app.together.hub.parties.newCode();
        // Only a code that works now lets another be made when it runs out; one that came back
        // already out of time is not asked for again.
        final expires = app.together.hub.parties.party?.joinCode?.expiresAt;
        if (expires == null || expires.isAfter(DateTime.now())) _making.remove(partyId);
      } on Object {
        // Refused (family settings, a muted account, too many): no button for it.
      }
      update();
    }());
  }

  /// The user stopped the party's code (or made a new one): the button follows their choice.
  void codeStoppedByUser(String partyId) {
    codeStopped.add(partyId);
    update();
  }

  void codeMadeByUser(String partyId) {
    codeStopped.remove(partyId);
    update();
  }

  /// Discord's list of the games it knows, so a known game shows as itself: from the cache,
  /// read again from Discord once a week.
  void _loadGames() {
    final presence = this.presence;
    if (_gamesLoading || presence == null) return;
    _gamesLoading = true;
    unawaited(
      DiscordGames.load(
        cacheFile: p.join(app.paths.cache, 'discord-games.json'),
        fetch: app.services.discordGames ?? DiscordGames.httpGet,
        update: (games) {
          presence.use(games);
          // Shown again as the game itself, if Discord knows it.
          final shown = _shown;
          if (shown != null && !games.isEmpty) unawaited(presence.show(shown));
        },
      ),
    );
  }

  /// The launcher quits: the profile shows nothing of it any more.
  Future<void> close() async {
    _refresh?.cancel();
    _shown = null;
    _cleared = true;
    await presence?.close();
  }
}
