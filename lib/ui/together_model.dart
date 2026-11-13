import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Color, Icons;

import '../core/audio/tones.dart';
import '../core/game_library.dart';
import '../core/gamepad/feel.dart' show HapticCue;
import '../core/host.dart';
import '../core/online/online_peer.dart';
import '../core/online/online_peer_mesh.dart';
import '../core/online/online_play.dart';
import '../core/profiles/profiles.dart' show ProfileAccount, ProfileMode;
import '../core/remote/remote_protocol.dart';
import '../core/capture/clip_tools.dart';
import '../core/screenshots.dart';
import '../core/together/account.dart';
import '../core/together/cloud_saves.dart' show MediaLimits, StorageInfo;
import '../core/together/e2ee.dart' show SealedAttachment;
import '../core/together/media_files.dart';
import '../core/together/posts.dart';
import '../core/together/challenges.dart';
import '../core/together/compat.dart';
import '../core/together/discover.dart';
import '../core/together/e2ee_client.dart';
import '../core/together/family.dart';
import '../core/together/friends.dart';
import '../core/together/hub.dart';
import '../core/together/join_advice.dart';
import '../core/together/levels.dart';
import '../core/together/people.dart';
import '../core/together/self.dart';
import '../core/together/share_play.dart';
import '../core/together/server.dart';
import '../core/together/social.dart';
import '../core/together/socket.dart';
import '../core/together/game_sessions.dart';
import '../core/together/messages.dart';
import '../core/together/private_identity.dart';
import '../core/together/profile_look.dart';
import '../core/together/profiles.dart';
import '../core/together/parties.dart';
import '../core/together/party_chat.dart';
import '../core/together/play_together.dart';
import '../core/together/sync.dart';
import '../core/together/talk_key.dart';
import '../core/together/voice.dart';
import '../core/together/voice_mesh.dart' show VoiceDenied;
import '../core/controls.dart';
import '../core/together/token_store.dart';

import 'package:path/path.dart' as p;

import '../core/trophies.dart';
import '../core/game_settings.dart';
import 'app_model.dart';
import 'clip_player.dart' show ViewedMedia, mediaAspect;
import 'compare_view.dart';
import 'countries.dart';
import 'family_gate.dart';
import 'livekit_room.dart';
import 'now_playing_model.dart';
import 'online_webrtc.dart';
import 'sealed_photo.dart';
import 'strings.dart';
import 'voice_note_player.dart';
import 'voice_webrtc.dart';

part 'together_messages.dart';
part 'together_ask.dart';
part 'together_party.dart';
part 'together_party_chat.dart';
part 'together_join.dart';
part 'together_play.dart';
part 'together_profile.dart';
part 'together_find.dart';
part 'together_social.dart';
part 'together_challenges.dart';
part 'together_captures.dart';
part 'together_calls.dart';

/// The launcher's version, as AnyTogether hears it.
const launcherVersion = '0.1.23';

/// AnyTogether in the launcher: the account and how it signs in (an email code, a code approved
/// on the website, or the paired phone), the server it uses, and the rows the settings show for
/// it. The interface reads it through [AppModel].
class TogetherModel {
  TogetherModel(this.app) : environment = app.services.environment ?? Platform.environment {
    // The session of the profile playing; another profile's goes in when it plays.
    sessions = ProfileTokenStore(app.tokenStoreFor(app.sessionProfileId));
    account = TogetherAccount(
      base: app.services.togetherServer ?? TogetherServer.base(environment, app.preferences.togetherServer),
      store: sessions,
      clientName: clientName(app.system),
      pollEvery: app.services.togetherPollEvery,
    );
    // This device's end-to-end encryption keys, kept by the profile signed in.
    e2ee = EndToEnd(
      account: account,
      keys: () => app.e2eeKeysFor(app.sessionProfileId),
      notes: () => app.e2eeNotesFor(app.sessionProfileId),
      deviceName: () => e2eeDeviceName,
    );
    hub = TogetherHub(
      account: account,
      e2ee: e2ee,
      voiceEngine: app.services.voiceEngine ?? WebRtcVoice.new,
      sfuRoom: app.services.sfuRoom ?? LiveKitRoom.new,
      bridgeFile: GameSessions.defaultBridgeFile(app.paths.config),
    );
    hub.games.onInvite = (invite) {
      disturbingSound();
      inviteRing();
      final text = T.format('gameInvitedYou', [invite.from?.displayName ?? '', gameName(invite.titleId)]);
      app.show(text);
      if (!doNotDisturb) {
        unawaited(app.noticeOverGame(text, detail: T.text('friendsTitle'), symbol: Icons.sports_esports_rounded));
      }
    };
    hub.games.onEnded = (host) => app.show(
      T.format(hub.games.ended?.together == true ? 'togetherEnded' : 'sessionEnded', [host?.displayName ?? '']),
    );
    hub.games.onStarted = togetherStarted;
    hub.games.onAnyEnded = togetherEnded;
    hub.games.onPlayersChanged = () => unawaited(hub.parties.refresh().catchError((Object _) {}));
    app.onUnlocked = togetherUnlockDone;
    // Someone asks to join the party led here: the Mac's words, and over a game its card (Do
    // Not Disturb or not, as on the Mac). The party's row says whether they asked with the code.
    hub.parties.onRequest = (person, via) {
      _noticeSound();
      final text = T.format('discoverAsksParty', [person.displayName]);
      app.show(text);
      unawaited(app.noticeOverGame(text, detail: T.text('partyTitle'), symbol: Icons.back_hand_rounded));
    };
    // Handed the lead, as the Mac says it.
    hub.parties.onBecameLeader = () => app.show(T.text('partyYouLead'));
    hub.parties.onRequestAnswered = (accepted) {
      // A yes is an invite, which says so itself.
      if (!accepted) app.show(T.text('partyRequestDeclined'));
    };
    // Before the redraw: the list may have moved under the conversation chosen.
    hub.messages.addListener(followMessagesSelection);
    hub.friends.addListener(followMessagesSelection);
    hub.addListener(app.refresh);
    hub.social
      ..onNotice = noticeArrived
      ..onActivity = profileActivityChanged
      ..holdFeedFocus = keepFeedFocus
      ..onFamilyNotice = (_) => unawaited(family.refresh());
    // The friends-only names and pictures the friends list brought, for every card shown.
    identities = hub.friends.identities;
    // A friend request: over a game the card with the handle, unless the user asked not to be
    // disturbed, as on the Mac.
    hub.friends.onRequest = (person) {
      disturbingSound();
      final text = T.format('friendsAsked', [person.displayName]);
      app.show(text);
      if (!doNotDisturb) {
        unawaited(app.noticeOverGame(text, detail: '@${person.handle}', symbol: Icons.person_add_alt_1_rounded));
      }
    };
    hub.friends.onAccepted = (person) => app.show(T.format('friendsNowFriends', [person.displayName]));
    // A friend went up a trophy level: only while the launcher is in front and no game runs, as
    // on the Mac.
    hub.friends.onLevelUp = (friend, level) {
      if (!app.active || app.running != null) return;
      app.show(T.format('friendLevelUp', [TogetherModel.shown(friend.person).name, level.level]));
    };
    // A trophy level reached: the trophy's sound (heard over a game too) and the toast with the
    // badge.
    hub.self.onLevelUp = (level) {
      app.sounds.play(Cue.unlocked, overGame: true);
      app.show(T.format('levelUp', [level.level]), level: level);
    };
    sync = TogetherSync(
      account: account,
      file: app.outboxFile(app.sessionProfileId),
      deviceName: deviceName,
      platform: app.system.name,
      model: machineModel(app.system),
    );
    online = OnlineHost(
      logFolder: app.paths.onlineLogs,
      call: account.call,
      user: () => account.user,
      // Signals to the other players' launchers go out on the gateway socket.
      signal: (to, device, sessionId, kind, data) =>
          hub.socket.send(OnlinePeerSignal.frame(to: to, device: device, sessionId: sessionId, kind: kind, data: data)),
      transport: (context) =>
          OnlinePeerMesh(context: context, links: app.services.gameLinks?.call() ?? WebRtcGameLinks()),
      locale: Platform.localeName,
    );
    // Online play follows the game session this launcher keeps for the running game.
    hub.games.addListener(() => online.follow(hub.games.session?.id));
    _ready = hub.socket.events.listen(_event);
    hub.messages.onSendFailed = (error) => sendFailed(error);
    // The party's chat is read while the party screen shows it.
    hub.partyChat
      ..shown = (() => app.overlay == Layer.party)
      ..onSendFailed = partySendFailed;
    hub.voice
      ..pushToTalk = app.preferences.pushToTalk
      ..noiseSuppression = app.preferences.noiseSuppression
      ..onMoved = (client) {
        app.show(T.text(client == 'phone' ? 'voiceMovedPhone' : 'voiceMovedAway'));
      }
      ..onAnswered = callAnswered
      ..onCallEnded = callEnded
      ..addListener(_voiceChanged);
    final reader = app.services.talkKeys != null ? app.services.talkKeys!() : KeyStateReader.system();
    if (reader != null) {
      talkWatch = TalkKeyWatch(reader: reader, onChange: hub.voice.talkKey, ignore: () => app.editingRow != null)
        ..usage = talkKey;
    }
    account.addListener(_accountChanged);
  }

  /// Play sessions and trophies on their way to the server.
  late final TogetherSync sync;

  /// The store the account keeps its session in: the profile playing's.
  late final ProfileTokenStore sessions;

  /// The friends' private names and pictures as the friends list said (the model's in use).
  static IdentityBook identities = IdentityBook();

  /// Someone as the launcher shows them: their friends-only name and picture when they let this
  /// user see them, the handle beside.
  static ShownIdentity shown(Person person) => ShownIdentity.of(person, identities);

  /// Online play for the running game (Settings › AnyTogether › Online play): the bridge the game
  /// connects to, the platform's web API answered from AnyTogether, the peer mesh.
  late final OnlineHost online;

  /// Family limits: the kept status, play time, age ratings, asking a parent.
  late final FamilyGate family = FamilyGate(this);

  /// Files are being dragged over the open conversation: it says what letting go does.
  bool chatDropping = false;

  /// The voice notes in chats.
  late final VoiceNotes voiceNotes = VoiceNotes(
    create: app.services.voicePlayback,
    onSystemPlayer: _voiceInSystemPlayer,
    onFailed: (_) => app.show(T.text('messagesAttachmentFailed')),
    onMissing: (missing) => app.show(
      missing.commands.length == 1
          ? T.format('libmpvMissingVoice', [missing.commands.single])
          : T.text('libmpvMissingVoicePlain'),
    ),
  );
  late final StreamSubscription<TogetherEvent> _ready;
  Timer? _flush;

  final AppModel app;
  final Map<String, String> environment;
  late final TogetherAccount account;

  /// The live side: the gateway socket and the lists it keeps current.
  late final TogetherHub hub;

  /// End-to-end encryption of direct messages (together_messages.dart shows it).
  late final EndToEnd e2ee;

  /// The talk key read anywhere on the desktop; null where it is read only in the launcher.
  TalkKeyWatch? talkWatch;

  /// Waiting for the key to become the talk key.
  bool capturingTalkKey = false;

  int get talkKey => app.preferences.talkKey ?? TalkKeys.standard;

  /// Party: whether a party started now is open to friends.
  bool partyStartsOpen = false;

  /// Party: Join with a code as it stands, and the Discord link being typed (null while it is
  /// not).
  JoinEntry joinEntry = JoinEntry();
  Timer? _joinLookup;
  String? discordDraft;

  /// The open profile's pinned gallery; null until read or where the server keeps no files.
  Section<List<MediaItem>>? profileGallery;
  int _profileGallerySeq = 0;

  /// Party: its chat's keys and field (together_party_chat.dart).
  final PartyChatKeys partyChatKeys = PartyChatKeys();

  /// Captures and the gallery's Share menu (together_captures.dart); tests choose the clip tools.
  final CapturesState captures = CapturesState();
  ClipTools? clipToolsOverride;

  /// Calls with one friend (together_calls.dart): the one ringing here.
  final CallState calls = CallState();

  /// Messages: the conversation or friend chosen on the left, whether the keys are in the thread,
  /// which quick reply (or the field, the last) is focused there, and what is typed.
  int messagesIndex = 0;
  bool messagesInThread = false;

  /// Which target [messagesIndex] means (TogetherMessages.targetKey): the list moves when a
  /// message comes in, and the keys stay on the conversation they were on.
  String? messagesSelectedKey;
  int messageFocus = 0;
  String draft = '';

  /// Messages: the new group's row the keys are on (0 its name, then the friends, then Start
  /// the group), the friends picked for it and its name.
  int groupFocus = 0;
  final Set<String> groupPicked = {};
  String groupName = '';

  /// Messages: the message the keys are on (counted from the newest; null while they are on
  /// the quick replies and the field), the menu open over the thread (a message's or a
  /// conversation's), and what the composer is doing: answering a message (its seq) or editing
  /// one of the user's.
  int? messageCursor;
  MessageMenu? messageMenu;

  /// Messages: a picture or clip from the thread over the whole screen (a clip plays).
  ViewedMedia? chatViewing;

  /// Messages: the encryption sheet over the open conversation (its lock, safety number and
  /// devices) and the row the keys are on in it; sealed files opened here, by message.
  bool lockSheet = false;
  int lockSheetRow = 0;
  final Map<String, Future<Uint8List>> sealedFiles = {};
  int? replyingTo;
  ChatMessage? editingMessage;

  /// The activity feed, the leaderboards, the notifications and "How did it run?" (together_social.dart).
  final SocialScreens screens = SocialScreens();

  /// Find Players, a game's hub and the post form (together_find.dart).
  final FindState findState = FindState();

  /// The profile shown: the page once read, the card it was opened with, whether reading failed,
  /// the row the keys are on, and the layer it goes back to.
  ProfilePage? profile;
  Person? profileCard;
  bool profileFailed = false;
  int profileIndex = 0;
  PanelSpot? profileReturn;

  /// The user's own profile being edited: the pins while choosing (null when not), the pins
  /// saved last, whether a save is on its way and the pins waiting for it; the Theme Hub's
  /// themes to wear (null while they are read); the profile item Theme: name was chosen on, while
  /// the Hub it opened is shown.
  ShowcasePins? showcasePins;
  ShowcasePins? _savedPins;
  bool savingPins = false;
  ShowcasePins? _pinsToSave;
  ({List<EarnedTrophy> trophies, List<PlayedGame> games})? _pinChoices;
  Section<List<ProfileTheme>>? themeChoices;
  int? hubFromProfile;

  /// Comparing trophies: with whom, their games (once read), the game the keys are on; one
  /// game's trophies side by side once one is opened, and the trophy the keys are on; the layer
  /// it goes back to.
  Person? compareWith;
  Section<List<ComparedGame>>? compareGames;
  int compareIndex = 0;
  String? compareTitleId;
  Section<TrophyComparison>? comparison;
  int comparisonIndex = 0;
  PanelSpot? compareReturn;

  /// A game session being opened for the game that just started.
  bool openingSession = false;

  /// Play Together: party members' games to join, a join waiting for its game to unlock, and the
  /// session the next game starts in with online play on whatever the setting.
  List<PlayTogetherOffer> togetherOffers = const [];
  (String, PlayTogetherOffer)? togetherAfterUnlock;
  String? togetherSession;

  /// Play Together games the user chose to join with a game version that does not fit (Try
  /// anyway), and games the server refused for the version though the check here let them by.
  Set<String> togetherTryAnyway = {};
  Set<String> togetherVersionRefused = {};

  /// What holds a join back, for the panel that says it whole, and the game being started while
  /// someone the user knows plays it (together_join.dart).
  JoinBlock? joinBlock;
  JoinChoice? joinChoice;

  /// The row whose social step is asking first (together_ask.dart): it shows the question instead.
  String? askingRow;

  /// Update Required was shown for AnyTogether's client_too_old (once a run).
  bool _updateRequiredShown = false;

  /// A handle typed in the friends panel, and the friend whose options are open.
  String friendHandle = '';
  Friend? chosen;

  /// What is typed in the sign-in rows, until it is sent.
  String email = '';
  String code = '';
  String serverDraft = '';
  String? _signedIn;

  TogetherUser? get user => account.user;
  bool get signedIn => account.user != null;

  /// launcher-windows/0.1.0 (Windows 10.0.22631), as the server's AnyTogether-Client header wants.
  static String clientName(HostSystem system) {
    final os = Platform.operatingSystemVersion.replaceAll(RegExp(r'[()"]'), '').trim();
    final short = os.length > 48 ? os.substring(0, 48) : os;
    return 'launcher-${system.name}/$launcherVersion (${system == HostSystem.windows ? 'Windows' : 'Linux'} $short)';
  }

  /// This device's name for end-to-end encryption, which friends' device lists read: what it is,
  /// never the computer's own name (docs/e2ee.md in AnyTogether).
  String get e2eeDeviceName => app.system == HostSystem.windows ? 'AnyPS5 on Windows' : 'AnyPS5 on Linux';

  /// This computer's name as the server and the phone show it.
  String get deviceName {
    final name = app.services.computerName ?? Platform.localHostname;
    final trimmed = name.trim().isEmpty ? (app.system == HostSystem.windows ? 'Windows PC' : 'Linux PC') : name.trim();
    return trimmed.length > 60 ? trimmed.substring(0, 60) : trimmed;
  }

  /// The session from the last run, then whatever follows from being signed in. A session kept
  /// from before profiles makes the profile just migrated online; an offline profile, or the
  /// picker at start, leaves the session where it is.
  Future<void> start() async {
    family.load();
    if (app.profiles.migrated) {
      final saved = await sessions.load();
      if (saved != null) app.profiles.adoptLegacySession(saved.user);
    }
    final profile = app.profiles.book.currentProfile;
    if (!app.profileFlow.atLaunch && (profile == null || profile.mode == ProfileMode.online)) await account.restore();
    _accountChanged();
  }

  void _accountChanged() {
    // AnyTogether retired this version: Update Required, once.
    if (account.tooOld case final ClientTooOld old when !_updateRequiredShown) {
      _updateRequiredShown = true;
      app.showUpdateRequired(old);
    }
    final id = account.user?.id;
    if (id != _signedIn) {
      _signedIn = id;
      signedInChanged();
    }
    // A handle changed on the website: the profile picker shows the new one.
    final profile = app.profiles.book.currentProfile;
    final handle = account.user?.handle;
    final linked = profile?.account;
    if (profile != null && linked != null && handle != null && linked.userId == id && linked.handle != handle) {
      app.profiles.setAccount(profile.id, ProfileAccount(userId: linked.userId, handle: handle));
    }
    app.refresh();
  }

  /// Signed in or out: what depends on it starts or stops.
  void signedInChanged() {
    app.remote?.togetherServer = account.base.toString();
    // Another account (or none): what was typed for the last one's profile goes, and so do a
    // call ringing and the Captures read for it.
    nameDraft = bioDraft = countryDraft = handleDraft = null;
    stopRinging();
    calls.noAnswer?.cancel();
    captures.follow(user?.id);
    if (!signedIn) {
      friendHandle = '';
      chosen = null;
      draft = '';
      _joinLookup?.cancel();
      joinEntry = JoinEntry();
      discordDraft = null;
      messagesIndex = 0;
      messagesSelectedKey = null;
      messagesInThread = false;
      groupFocus = 0;
      groupPicked.clear();
      groupName = '';
      messageCursor = null;
      messageMenu = null;
      chatViewing = null;
      replyingTo = null;
      editingMessage = null;
      partyChatKeys
        ..reset()
        ..replyingTo = null
        ..editing = null
        ..draft = '';
      profile = null;
      showcasePins = null;
      _savedPins = null;
      _pinsToSave = null;
      themeChoices = null;
      hubFromProfile = null;
      compareWith = null;
      compareGames = null;
      comparison = null;
      compareTitleId = null;
      screens.clear();
      findState.clear();
      if (const {
        Layer.friendOptions,
        Layer.messages,
        Layer.profile,
        Layer.showcaseEdit,
        Layer.profileTheme,
        Layer.countryPicker,
        Layer.compare,
        Layer.feed,
        Layer.captures,
        Layer.leaderboard,
        Layer.challenge,
        Layer.notifications,
        Layer.compat,
        Layer.findPlayers,
        Layer.lfgPost,
        Layer.gameHub,
      }.contains(app.overlay)) {
        app.closeOverlay();
      }
    } else {
      // Every game's trophies go up once, the earned ones with their dates.
      for (final game in app.games) {
        final set = app.trophies[game.id];
        if (set != null) recordTrophies(game, set, flush: false);
      }
      flushSoon();
    }
    family.signedInChanged();
    _followGame();
  }

  // Play and trophies.

  /// The computer's model for the devices list: the firmware's product name.
  static String? machineModel(HostSystem system) {
    try {
      if (system == HostSystem.linux) {
        final name = File('/sys/devices/virtual/dmi/id/product_name').readAsStringSync().trim();
        return name.isEmpty ? null : name;
      }
      if (!Platform.isWindows) return null;
      final result = Process.runSync('reg', [
        'query',
        r'HKLM\HARDWARE\DESCRIPTION\System\BIOS',
        '/v',
        'SystemProductName',
      ]);
      final match = RegExp(r'SystemProductName\s+REG_SZ\s+(.+)').firstMatch(result.stdout as String);
      final name = match?.group(1)?.trim();
      return name == null || name.isEmpty ? null : (name.length > 120 ? name.substring(0, 120) : name);
    } on Object {
      return null;
    }
  }

  /// A game played for a while: the session goes to AnyTogether, or waits until it can.
  void recordPlay(Game game, DateTime start, DateTime end, {String exit = 'normal'}) {
    family.played(start, end, reported: signedIn && TogetherSync.titleIdPattern.hasMatch(game.titleId));
    if (!signedIn) return;
    sync.recordSession(
      titleId: game.titleId,
      gameName: game.name,
      startedAt: start,
      endedAt: end,
      exit: exit,
      ageLevels: game.ageLevels,
    );
    flushSoon();
  }

  /// The game's trophy set as read now: the earned ones not sent yet go to AnyTogether.
  void recordTrophies(Game game, TrophySet set, {bool flush = true}) {
    if (!signedIn || set.trophies.isEmpty) return;
    final tag = ConsoleLanguage.tag(T.language.consoleLanguage);
    sync.recordTrophies(
      SyncTrophySet(
        titleId: game.titleId,
        gameName: game.name,
        language: tag?.split('-').first.toLowerCase() ?? 'en',
        trophies: [
          for (final trophy in set.trophies)
            SyncTrophy(
              id: SyncTrophy.idFor(trophy.serviceLabel, trophy.number),
              grade: trophy.grade.name,
              hidden: trophy.hidden,
              name: trophy.name,
              detail: trophy.detail,
              earnedAt: trophy.unlocked,
            ),
        ],
      ),
    );
    if (flush) flushSoon();
  }

  /// Sends what waits, a moment later, so a burst of changes goes up together.
  void flushSoon() {
    _flush?.cancel();
    _flush = Timer(app.services.togetherPollEvery ?? const Duration(seconds: 2), () {
      if (signedIn) unawaited(sync.flush().catchError((Object _) {}));
    });
  }

  // Presence.

  /// A game started or stopped: friends see it.
  void gameChanged() => _followGame();

  void _followGame() {
    family.followGame();
    followGameSession();
    // An emulator game is not an AnyTogether title: friends see the user online, as with none.
    final running = app.running?.$1.retro == null ? app.running : null;
    final since = running == null ? null : DateTime.tryParse(app.preferences.lastPlayed[running.$1.id] ?? '');
    hub.socket.presence = running == null
        ? const PresenceOnline()
        : PresenceInGame(running.$1.titleId, since ?? DateTime.now());
  }

  bool get connected => hub.socket.status == SocketStatus.ready;

  /// How old the own profile may get while the launcher is in front, and when it comes back in
  /// front or a screen showing it opens: a name or handle changed on the website shows here.
  static const ownProfileAge = Duration(minutes: 5);
  static const ownProfileAgeShown = Duration(seconds: 20);

  /// Reads the own profile again when it is older than [age] (the launcher's clock asks a few
  /// times a second, with [ownProfileAge]).
  void refreshOwnProfile({Duration age = ownProfileAgeShown}) {
    if (!signedIn || !connected) return;
    unawaited(hub.self.refreshIfOlder(age));
  }

  /// Friends see this user as offline (their choice); the socket and heartbeats go on as ever.
  bool get appearingOffline => hub.self.appearOffline;

  /// What this user chose to show friends.
  PresenceStatus get myStatus => hub.self.status;

  /// The user's own Do Not Disturb: no word over a game for what comes in.
  bool get doNotDisturb => myStatus == PresenceStatus.dnd;

  /// How each other player in the Play Together session is reached ([TogetherPlay.linkText]).
  Map<String, PeerPath> togetherLinks = const {};
  Timer? _linkPoll;

  /// The dot for a status this user chose; null for online, which needs none on their own rows.
  static PersonStatus? ownDot(PresenceStatus status) => switch (status) {
    PresenceStatus.online => null,
    PresenceStatus.idle => PersonStatus.idle,
    PresenceStatus.dnd => PersonStatus.dnd,
    PresenceStatus.invisible => PersonStatus.offline,
  };

  /// The status in words, as the choice lists it; invisible as "Appearing offline".
  static String ownStatusText(PresenceStatus status) => switch (status) {
    PresenceStatus.online => T.text('presenceOnline'),
    PresenceStatus.idle => T.text('presenceIdle'),
    PresenceStatus.dnd => T.text('presenceDnd'),
    PresenceStatus.invisible => T.text('presenceAppearing'),
  };

  /// The user as their own rows show them: their status's dot (a grey one while invisible).
  PanelPerson get myCard => PanelPerson(name: user?.displayName ?? '', avatar: user?.avatar, status: ownDot(myStatus));

  /// Online or appear offline: shown at once, turned back with a word when the server cannot.
  Future<void> setAppearOffline(bool on) => setStatus(on ? PresenceStatus.invisible : PresenceStatus.online);

  /// Online, idle, do not disturb or invisible: shown at once, turned back with a word when the
  /// server cannot (a server before statuses keeps online and invisible only).
  Future<void> setStatus(PresenceStatus next) async {
    if (next == myStatus) return;
    try {
      await hub.self.setStatus(next);
    } on PresenceStatusUnsupported {
      app.show(T.text('presenceStatusNotYet'));
    } on TogetherProblem catch (problem) {
      app.show(problem.status == 404 ? T.text('presenceNotYet') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  /// Read receipts on or off: shown at once, turned back with a word when the server cannot; the
  /// others' receipts change with it, so the conversations are read again.
  Future<void> setPublicProfile(bool on) async {
    if (on == hub.self.publicProfile) return;
    try {
      await hub.self.setPublicProfile(on);
    } on Object catch (error) {
      app.show(
        error is TogetherProblem && error.code == 'restricted_by_family'
            ? T.text('publicProfileFamily')
            : message(error),
      );
    }
    app.refresh();
  }

  Future<void> setReadReceipts(bool on) async {
    if (on == hub.self.readReceipts) return;
    try {
      await hub.self.setReadReceipts(on);
      unawaited(hub.messages.refresh().catchError((Object _) {}));
    } on Object catch (error) {
      app.show(message(error));
    }
    app.refresh();
  }

  // Signing in.

  Future<void> sendCode() async {
    final address = email.trim();
    if (!address.contains('@') || account.step is SignInBusy) return app.show(T.text('togetherEmailInvalid'));
    try {
      await account.startEmail(address);
      code = '';
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> verify() async {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) return;
    try {
      _welcome(await account.verifyEmail(digits));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void otherEmail() {
    code = '';
    account.cancel();
  }

  /// A code to type on the website, which opens in the browser with the code filled in: passkeys
  /// and every other way the website signs in work there.
  Future<void> signInWithWebsite() async {
    try {
      _welcome(await account.signInWithWebsite(deviceName, show: (page) => app.services.openUrl?.call(page)));
    } on TogetherCancelled {
      // Given up here.
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// The first connected phone's name, when one is connected.
  String? get phoneName => app.remote?.connectedDevices.firstOrNull;

  /// The paired phone signs this launcher in: the launcher starts a hand-off and asks the phone,
  /// signed in to AnyTogether, to approve it.
  Future<void> signInWithPhone() async {
    final phone = phoneName;
    final remote = app.remote;
    if (phone == null || remote == null) return;
    try {
      final handoff = await account.startHandoff(deviceName, phone);
      remote.publish(RemoteTogetherHandoff(id: handoff.id, deviceName: deviceName));
      _welcome(await account.waitForPhone(handoff));
    } on TogetherCancelled {
      // Given up, or the phone said no.
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void cancel() => account.cancel();

  /// Something a friend did while the launcher is behind another window: the sound of a notice
  /// (the Mac shows it over the other window with the same sound).
  void _noticeSound() {
    if (!app.active) app.sounds.play(Cue.unlocked);
  }

  /// [_noticeSound] for a request, an invite or a message: none on Do Not Disturb, as the Mac
  /// keeps its notice over the other window, and so its sound, off then.
  void disturbingSound() {
    if (!doNotDisturb) _noticeSound();
  }

  /// A game invite, a party invite or a Play Together offer: the ring on the controller, none on
  /// Do Not Disturb, as on the Mac. Asked whether or not the launcher is in front: the pulse
  /// itself stays still behind a game or another window, and with Controller Vibration off
  /// (the haptics' own gate), as every pulse does. A call rings on its own, as before.
  void inviteRing() {
    if (!doNotDisturb) app.vibrate(HapticCue.ring);
  }

  void _welcome(TogetherUser user) {
    code = '';
    app.sounds.play(Cue.select);
    app.show(T.format('togetherWelcome', [user.displayName]));
    app.profileSignedIn(user);
  }

  Future<void> signOut() async {
    await account.signOut();
  }

  /// A phone's side of a hand-off: it asks to be signed in as us, or answers ours.
  void phoneMessage(RemoteMessage received, String deviceId) {
    switch (received) {
      case RemoteTogetherHandoff(:final id, :final deviceName):
        // Only phones paired with this launcher get here; signed in, it approves at once.
        if (!signedIn) {
          app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: false), deviceId);
          return;
        }
        unawaited(() async {
          try {
            await account.approveHandoff(id);
            app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: true), deviceId);
            app.show(T.format('togetherPhoneSignedIn', [deviceName]));
          } on Object catch (error) {
            app.remote?.tell(RemoteTogetherHandoffAnswer(id: id, approved: false), deviceId);
            app.show(message(error));
          }
        }());
      case RemoteTogetherHandoffAnswer(:final id, approved: false):
        final step = account.step;
        if (step is! SignInWaitingForPhone || step.handoff.id != id) return;
        account.cancel();
        app.show(T.text('togetherPhoneDeclined'));
      default:
        break;
    }
  }

  // Server.

  /// ANYTOGETHER_URL, when set, decides the server.
  Uri? get forcedServer => TogetherServer.forced(environment);

  /// Another server: a session belongs to one server, so this one is signed out first.
  Future<void> useServer(String text) async {
    if (forcedServer != null) return;
    if (family.serverLocked) return app.show(T.text('familyServerLocked'));
    final url = TogetherServer.address(text.trim().isEmpty ? account.base.toString() : text);
    if (url == null) return app.show(T.text('togetherServerInvalid'));
    if (url == account.base) return;
    account.cancel();
    if (signedIn) await account.signOut();
    account.base = url;
    app.preferences.togetherServer = url == TogetherServer.standard ? null : url.toString();
    serverDraft = '';
    app.remote?.togetherServer = url.toString();
    app.savePreferences();
    app.show(T.format('togetherServerNow', [url.host]));
  }

  // Friends.

  Future<void> askFriend() async {
    final handle = Friends.clean(friendHandle);
    if (handle.isEmpty) return;
    // A parent approves whom the child befriends: they are asked instead.
    if (family.friendsThroughParent) {
      friendHandle = '';
      return family.askToAddFriend(handle);
    }
    try {
      final now = await hub.friends.add(handle);
      friendHandle = '';
      app.show(T.format(now ? 'friendsNowFriends' : 'friendsRequestSent', [handle]));
    } on TogetherProblem catch (problem) {
      if (familyFeature(problem) == 'friend_requests' && family.restricted) {
        friendHandle = '';
        return family.askToAddFriend(handle);
      }
      app.show(problem.status == 404 ? T.format('friendsNoOne', [handle]) : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> answerFriend(Person person, {required bool accept}) async {
    try {
      await hub.friends.answer(person.id, accept: accept);
      if (accept) app.show(T.format('friendsNowFriends', [person.displayName]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> removeFriend(Friend friend) async {
    try {
      await hub.friends.remove(friend.person.id);
      app.show(T.format('friendsRemoved', [friend.person.displayName]));
      if (app.overlay == Layer.friendOptions) app.open(Layer.friends);
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// A request the user sent, taken back before they answered.
  Future<void> withdrawRequest(Person person) async {
    try {
      await hub.friends.withdraw(person.id);
      app.show(T.format('friendsRequestCancelled', [person.displayName]));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Opens the settings at the AnyTogether rows.
  void openSettings() {
    app.open(Layer.settings);
    final index = app.panelCategories().indexWhere((category) => category.id == 'together');
    if (index >= 0) app.selectCategory(index);
  }

  void openFriend(Friend friend) {
    chosen = friend;
    app.open(Layer.friendOptions);
  }

  /// A game's name in this library, else its title ID.
  String gameName(String titleId) =>
      app.games.where((game) => game.titleId == titleId).firstOrNull?.nameFor([T.language.code]) ?? titleId;

  /// "Playing Neon Alley · 25 min", "Online", "Idle", "Do Not Disturb", "Offline", with the
  /// party they are in.
  String presenceText(Presence presence, {DateTime? now}) {
    if (!presence.online) return T.text('friendsOffline');
    final titleId = presence.titleId;
    var text = switch (presence.state) {
      // In a game the game says more; the dot still shows idle or do not disturb.
      PresenceState.online || PresenceState.away when presence.status == PresenceStatus.idle => T.text('presenceIdle'),
      PresenceState.online || PresenceState.away when presence.status == PresenceStatus.dnd => T.text('presenceDnd'),
      PresenceState.inGame when titleId != null =>
        presence.since == null
            ? T.format('friendsPlaying', [gameName(titleId)])
            : T.format('friendsPlayingFor', [
                gameName(titleId),
                ((now ?? DateTime.now()).difference(presence.since!).inMinutes).clamp(1, 1 << 30),
              ]),
      PresenceState.away => T.text('friendsAway'),
      _ => T.text('friendsOnline'),
    };
    // What they listen to, when they chose to show it: "Online · Listening to Title, Artist".
    final listening = presence.listening;
    final heard = listening == null ? '' : ' · ${NowPlayingModel.listeningText(listening)}';
    // Playing together with their party: "Playing Minecraft together (2/8)".
    final game = presence.game;
    if (game != null && game.together) {
      return T.format('togetherPresence', [gameName(game.titleId), game.players, game.capacity]) + heard;
    }
    if (presence.game?.joinable == true) text += ' · ${T.text('gameJoinable')}';
    final party = presence.party;
    if (party != null) text += ' · ${T.format('friendsInParty', [party.size, party.max])}';
    return text + heard;
  }

  /// A friend's dot: do not disturb and idle as they chose them, else what they do (a server
  /// before statuses sends none).
  static PersonStatus status(Presence presence) => switch (presence.state) {
    PresenceState.offline => PersonStatus.offline,
    _ when presence.status == PresenceStatus.dnd => PersonStatus.dnd,
    _ when presence.status == PresenceStatus.idle => PersonStatus.idle,
    PresenceState.inGame => PersonStatus.playing,
    PresenceState.online => PersonStatus.online,
    PresenceState.away => PersonStatus.away,
  };

  /// A person's avatar on a row: their friends-only name and picture when there.
  static PanelPerson card(Person person, {PersonStatus? status, bool speaking = false}) {
    final identity = shown(person);
    return PanelPerson(name: identity.name, avatar: identity.avatar, status: status, speaking: speaking);
  }

  /// The friends panel: requests to answer, adding someone by handle, the friends by what they
  /// do, the requests waiting for an answer.
  List<PanelRow> friendRows() {
    final me = user;
    if (me == null) {
      return [
        PanelRow(id: 'friends-out', title: T.text('friendsSignIn'), kind: InfoRow(T.text('togetherIntroDetail'))),
        PanelRow(id: 'friends-signin', title: T.text('togetherSignIn'), kind: ActionRow(openSettings)),
      ];
    }
    final friends = hub.friends;
    return [
      ...callRows(),
      PanelRow(
        id: 'friends-me',
        title: T.text('profileMine'),
        detail: myStatus == PresenceStatus.online
            ? T.text('profileMineDetail')
            : '${ownStatusText(myStatus)} · ${T.text('profileMineDetail')}',
        person: myCard,
        level: hub.self.level,
        kind: ActionRow(() => unawaited(openMyProfile())),
      ),
      if (matchmakingAllowed)
        PanelRow(
          id: 'friends-find',
          title: T.text('discoverFindPlayers'),
          detail: T.text('discoverFindPlayersDetail'),
          kind: ActionRow(openFindPlayers),
        ),
      ...socialRows(),
      ...app.sharePlay.watchRows(),
      ...gameRows(),
      for (final person in friends.incoming) ...[
        PanelRow(
          id: 'accept-${person.id}',
          title: T.format('friendsAccept', [person.displayName]),
          detail: '@${person.handle} · ${T.text('friendsWantsToBe')}',
          person: card(person),
          kind: ActionRow(() => unawaited(answerFriend(person, accept: true))),
        ),
        PanelRow(
          id: 'decline-${person.id}',
          title: T.format('friendsDecline', [person.displayName]),
          kind: ActionRow(() => unawaited(answerFriend(person, accept: false)), destructive: true),
        ),
      ],
      PanelRow(
        id: 'friends-handle',
        title: T.text('friendsAddByHandle'),
        kind: TextRow(
          friendHandle,
          (text) => friendHandle = text,
          submit: () => unawaited(askFriend()),
          hint: '@handle',
        ),
      ),
      PanelRow(
        id: 'friends-ask',
        title: T.text(family.friendsThroughParent ? 'familyAskFriend' : 'friendsSendRequest'),
        kind: ActionRow(() => unawaited(askFriend())),
      ),
      if (friends.loaded && friends.friends.isEmpty)
        PanelRow(
          id: 'friends-none',
          title: T.text('friendsNone'),
          kind: InfoRow(T.format('friendsYourHandle', [me.handle])),
        ),
      for (final friend in friends.friends) ...[
        PanelRow(
          id: 'friend-${friend.person.id}',
          // Their friends-only name when they set one, the handle (and public name) beside.
          title: shown(friend.person).name,
          detail: '${shown(friend.person).handleLine} · ${presenceText(friend.presence)}',
          person: card(friend.person, status: status(friend.presence)),
          level: friend.level,
          kind: ActionRow(() => openFriend(friend)),
        ),
        // Online friends can be called, as on the Mac.
        ?callRow(friend),
      ],
      for (final person in friends.outgoing) ...[
        PanelRow(
          id: 'waiting-${person.id}',
          title: person.displayName,
          detail: '@${person.handle} · ${T.text('friendsWaiting')}',
          person: card(person),
          kind: const InfoRow(''),
        ),
        // Taken back as on the website; a new request can always be sent again.
        PanelRow(
          id: 'unsend-${person.id}',
          title: T.format('friendsCancelRequest', [person.displayName]),
          kind: ActionRow(() => unawaited(withdrawRequest(person)), destructive: true),
        ),
      ],
    ];
  }

  /// What can be done with the chosen friend.
  List<PanelRow> friendOptionRows() {
    final friend = chosen == null ? null : hub.friends.byId(chosen!.person.id) ?? chosen;
    if (friend == null) return const [];
    return [
      PanelRow(
        id: 'friend-card',
        title: friend.person.displayName,
        detail: '@${friend.person.handle} · ${presenceText(friend.presence)}',
        person: card(friend.person, status: status(friend.presence)),
        level: friend.level,
        kind: const InfoRow(''),
      ),
      PanelRow(
        id: 'friend-profile',
        title: T.text('profileTitle'),
        detail: T.text('profileMineDetail'),
        kind: ActionRow(() => unawaited(openProfile(friend.person.handle, card: friend.person))),
      ),
      PanelRow(
        id: 'friend-compare',
        title: T.text('compareTrophies'),
        detail: T.text('compareTrophiesDetail'),
        kind: ActionRow(() => unawaited(openCompare(friend.person))),
      ),
      if (friend.presence.game case final PresenceGame game when game.joinable)
        PanelRow(
          id: 'friend-game',
          title: T.format('gameJoin', [friend.person.displayName, gameName(game.titleId)]),
          detail: T.format(game.capacity == 1 ? 'gamePlayersOne' : 'gamePlayers', [game.players, game.capacity]),
          kind: ActionRow(
            () => unawaited(joinFriendGame(game.sessionId, titleId: game.titleId, host: friend.person.displayName)),
          ),
        ),
      if (family.messagesAllowed)
        PanelRow(
          id: 'friend-message',
          title: T.text('friendsMessage'),
          kind: ActionRow(() => unawaited(messageFriend(friend.person))),
        ),
      if (hub.parties.party case final Party party when !party.has(friend.person.id) && !party.full)
        PanelRow(
          id: 'friend-party',
          title: T.format('partyInvite', [friend.person.displayName]),
          kind: ActionRow(() => unawaited(inviteToParty(friend.person))),
        ),
      ...askingFirst(
        PanelRow(
          id: 'friend-remove',
          title: T.text('friendsRemove'),
          kind: ActionRow(() => unawaited(removeFriend(friend)), destructive: true),
        ),
        T.format('askRemoveFriend', [friend.person.displayName]),
      ),
      PanelRow(id: 'friend-back', title: T.text('back'), kind: ActionRow(() => app.open(Layer.friends))),
    ];
  }

  // Rows.

  /// The sign-in screen's rows: the ways in, without the server's rows.
  List<PanelRow> signInRows() => [
    for (final row in settingsRows(signingIn: true))
      if (!row.id.startsWith('together-server') && row.id != 'together-intro') row,
  ];

  List<PanelRow> settingsRows({bool signingIn = false}) {
    final me = user;
    // An offline profile that had an account (it went offline, its session kept): going online
    // is the way in. One that never had one signs in here as ever, and is online then.
    final profile = app.currentProfile;
    if (!signingIn &&
        me == null &&
        profile?.mode == ProfileMode.offline &&
        profile?.account != null &&
        app.profileFlow.pendingId == null) {
      return [
        PanelRow(
          id: 'together-offline',
          title: T.text('profileOfflineTogether'),
          kind: InfoRow(T.text('profileOfflineTogetherDetail')),
        ),
        PanelRow(
          id: 'together-go-online',
          title: T.text('profileGoOnline'),
          detail: T.text('profileGoOnlineDetail'),
          kind: ActionRow(() => unawaited(app.toggleProfileMode())),
        ),
      ];
    }
    if (me != null) {
      return [
        PanelRow(
          id: 'together-user',
          title: '@${me.handle}',
          detail: myStatus == PresenceStatus.online ? me.displayName : '${me.displayName} · ${ownStatusText(myStatus)}',
          person: myCard,
          level: hub.self.level,
          kind: const InfoRow(''),
        ),
        PanelRow(
          id: 'together-online',
          title: T.text('togetherOnline'),
          kind: InfoRow(connected ? T.text('togetherConnected') : T.text('togetherConnecting')),
        ),
        PanelRow(
          id: 'together-presence',
          title: T.text('presenceShowAs'),
          detail: T.text(switch (myStatus) {
            PresenceStatus.online => 'presenceOnlineDetail',
            PresenceStatus.idle => 'presenceIdleDetail',
            PresenceStatus.dnd => 'presenceDndDetail',
            PresenceStatus.invisible => 'presenceHint',
          }),
          kind: ChoiceRow(
            [
              for (final status in PresenceStatus.values)
                switch (status) {
                  PresenceStatus.online => T.text('presenceOnline'),
                  PresenceStatus.idle => T.text('presenceIdle'),
                  PresenceStatus.dnd => T.text('presenceDnd'),
                  PresenceStatus.invisible => T.text('presenceInvisible'),
                },
            ],
            PresenceStatus.values.indexOf(myStatus),
            (index) => unawaited(setStatus(PresenceStatus.values[index])),
          ),
        ),
        PanelRow(
          id: 'together-receipts',
          title: T.text('readReceipts'),
          detail: T.text('readReceiptsHint'),
          kind: ToggleRow(hub.self.readReceipts, (value) => unawaited(setReadReceipts(value))),
        ),
        ?family.settingsRow(),
        PanelRow(
          id: 'together-profile',
          title: T.text('profileMine'),
          detail: T.text('profileMineDetail'),
          kind: ActionRow(() => unawaited(openMyProfile())),
        ),
        ...profileEditRows(),
        ...privateIdentityRows(),
        if (hub.self.loaded)
          PanelRow(
            id: 'together-public-profile',
            title: T.text('publicProfile'),
            detail: hub.self.publicProfile
                ? T.text('publicProfileHint')
                : '${T.text('publicProfileHint')} ${T.text('publicProfileOffNote')}',
            kind: ToggleRow(hub.self.publicProfile, (value) => unawaited(setPublicProfile(value))),
          ),
        ...privacyRows(),
        ...discoveryRows(),
        PanelRow(
          id: 'together-join',
          title: T.text('togetherFriendsJoin'),
          detail: T.text('togetherFriendsJoinDetail'),
          kind: ToggleRow(app.preferences.friendsJoin, (value) => unawaited(setFriendsJoin(value))),
        ),
        PanelRow(
          id: 'together-online-play',
          title: T.text('togetherOnlinePlay'),
          detail: T.format('togetherOnlinePlayDetail', [me.handle]),
          kind: ToggleRow(app.preferences.onlinePlay, setOnlinePlay),
        ),
        PanelRow(
          id: 'together-online-log',
          title: T.text('togetherOnlineLog'),
          detail: T.text('togetherOnlineLogDetail'),
          kind: ActionRow(openOnlineLog),
        ),
        PanelRow(
          id: 'together-signout',
          title: T.text('togetherSignOut'),
          kind: ActionRow(() => unawaited(signOut()), destructive: true),
        ),
        ..._serverRows(),
      ];
    }
    final rows = [
      ?family.settingsRow(),
      PanelRow(id: 'together-intro', title: T.text('togetherIntro'), kind: InfoRow(T.text('togetherIntroDetail'))),
    ];
    switch (account.step) {
      case SignInIdle() || SignInBusy():
        final phone = phoneName;
        rows.addAll([
          if (phone != null)
            PanelRow(
              id: 'together-phone',
              title: T.text('togetherWithPhone'),
              detail: T.format('togetherWithPhoneDetail', [phone]),
              kind: ActionRow(() => unawaited(signInWithPhone())),
            ),
          PanelRow(
            id: 'together-web',
            title: T.text('togetherWithWebsite'),
            detail: T.text('togetherWithWebsiteDetail'),
            kind: ActionRow(() => unawaited(signInWithWebsite())),
          ),
          PanelRow(
            id: 'together-email',
            title: T.text('togetherEmail'),
            kind: TextRow(email, (text) => email = text, submit: () => unawaited(sendCode()), hint: 'name@example.com'),
          ),
          PanelRow(
            id: 'together-send',
            title: T.text('togetherSendCode'),
            kind: ActionRow(() => unawaited(sendCode())),
          ),
          ..._serverRows(),
        ]);
      case SignInCodeSent(email: final address):
        rows.addAll([
          PanelRow(id: 'together-sent', title: T.format('togetherCodeSent', [address]), kind: const InfoRow('')),
          PanelRow(
            id: 'together-code',
            title: T.text('togetherCode'),
            kind: TextRow(
              code,
              (text) {
                code = text;
                if (text.replaceAll(RegExp(r'\D'), '').length == 6) unawaited(verify());
              },
              submit: () => unawaited(verify()),
              hint: '123456',
            ),
          ),
          PanelRow(id: 'together-verify', title: T.text('togetherSignIn'), kind: ActionRow(() => unawaited(verify()))),
          PanelRow(id: 'together-other', title: T.text('togetherOtherEmail'), kind: ActionRow(otherEmail)),
        ]);
      case SignInDeviceCode(:final userCode, :final page):
        rows.addAll([
          PanelRow(
            id: 'together-device',
            title: userCode,
            kind: InfoRow(T.format('togetherTypeCode', ['${page.scheme}://${page.authority}'])),
          ),
          PanelRow(
            id: 'together-open',
            title: T.text('togetherOpenWebsite'),
            kind: ActionRow(() => app.services.openUrl?.call(page)),
          ),
          PanelRow(id: 'together-cancel', title: T.text('cancel'), kind: ActionRow(cancel)),
        ]);
      case SignInWaitingForPhone(:final phone):
        rows.addAll([
          PanelRow(id: 'together-onphone', title: T.format('togetherOnPhone', [phone]), kind: const InfoRow('')),
          PanelRow(id: 'together-cancel', title: T.text('cancel'), kind: ActionRow(cancel)),
        ]);
    }
    return rows;
  }

  List<PanelRow> _serverRows() {
    if (family.serverLocked) {
      return [
        PanelRow(
          id: 'together-server',
          title: T.text('togetherServer'),
          detail: T.text('familyServerLocked'),
          kind: InfoRow(account.base.toString()),
        ),
      ];
    }
    final forced = forcedServer;
    if (forced != null) {
      return [
        PanelRow(
          id: 'together-server',
          title: T.text('togetherServer'),
          detail: T.text('togetherServerForced'),
          kind: InfoRow(forced.toString()),
        ),
      ];
    }
    return [
      PanelRow(
        id: 'together-server',
        title: T.text('togetherServer'),
        detail: T.text('togetherServerDetail'),
        kind: TextRow(
          serverDraft.isEmpty ? account.base.toString() : serverDraft,
          (text) => serverDraft = text,
          submit: () => unawaited(useServer(serverDraft)),
        ),
      ),
      PanelRow(
        id: 'together-server-use',
        title: T.text('togetherServerUse'),
        kind: ActionRow(() => unawaited(useServer(serverDraft))),
      ),
    ];
  }

  // Online play.

  /// Online play (experimental) on or off; a game started from now on gets it.
  void setOnlinePlay(bool on) {
    app.preferences.onlinePlay = on;
    app.savePreferences();
    app.refresh();
  }

  /// Shows the folder of the games' online logs (made first, so it opens even before a game
  /// wrote one).
  void openOnlineLog() {
    final folder = app.paths.onlineLogs;
    try {
      Directory(folder).createSync(recursive: true);
    } on FileSystemException {
      // The file manager says so.
    }
    app.services.openFolder?.call(folder);
  }

  /// What [game] is started with for online play: nothing while the setting is off.
  Future<Map<String, String>> onlineEnvironment(Game game) async {
    // A Play Together game has online play on for that start whatever the setting.
    if (!app.preferences.onlinePlay && togetherSession == null) return const {};
    online.platformGroups = app.preferences.onlinePlatformGroups;
    return online.environment(titleId: game.titleId, gameVersion: gameVersion(game), engineBuild: engineBuild(game));
  }

  /// The game ended: its online bridge closes.
  Future<void> onlineGameEnded() {
    togetherSession = null;
    return online.stop();
  }

  /// What to tell the user about a failed call.
  String message(Object error) {
    if (isFamilyRestriction(error)) {
      return FamilyGate.restrictedText(familyFeature(error), side: familySide(error));
    }
    if (error is TogetherProblem) {
      return switch (error.code) {
        'code_invalid' => T.text('togetherCodeWrong'),
        'code_expired' || 'expired_token' => T.text('togetherCodeExpired'),
        'code_locked' => T.text('togetherCodeLocked'),
        'rate_limited' => T.text('togetherTooMany'),
        'handle_taken' => T.text('togetherHandleTaken'),
        'handle_reserved' => T.text('togetherHandleReserved'),
        'handle_cooldown' => switch (DateTime.tryParse(error.extra['handleChangeAt'] as String? ?? '')) {
          final DateTime at => T.format('togetherHandleAgain', [CompareView.day(at)]),
          null => T.format('togetherErrorOther', [error.code]),
        },
        'links_not_allowed' => T.text('togetherNoLinks'),
        'media_server_off' => T.format('togetherMediaServerOff', [(error.extra['max'] as num?)?.toInt() ?? 4]),
        // The server's own words are English: every code gets the launcher's.
        'bad_request' => T.text('togetherErrorBadRequest'),
        'unauthorized' || 'session_revoked' || 'refresh_reused' => T.text('togetherErrorSignedOut'),
        'forbidden' => T.text('togetherErrorForbidden'),
        'not_found' => T.text('togetherErrorNotFound'),
        'conflict' => T.text('togetherErrorConflict'),
        'full' => T.text('togetherErrorFull'),
        'payload_too_large' => T.text('togetherErrorTooLarge'),
        'internal' => T.text('togetherErrorInternal'),
        // A code the launcher has no words for yet: the server's sentence in English (which is
        // English), the launcher's own with the code in every other language, as on the Mac.
        _ when T.language.code == 'en' && error.title.isNotEmpty => error.title, // not a text
        final code => code.isEmpty ? T.text('togetherUnreachable') : T.format('togetherErrorOther', [code]),
      };
    }
    return T.text('togetherUnreachable');
  }

  /// Gateway events worth a word on screen, and the outbox's chance after a reconnect.
  void _event(TogetherEvent event) {
    // Online play follows the same game session: players joining, leaving, signalling.
    online.handle(event);
    // Share play: the one hosted, the one watched, the invites.
    if (event.type == 'live.ready' || event.type.startsWith('share_play.')) app.sharePlay.event(event);
    findEvent(event);
    if (event.type.startsWith('post.')) capturesEvent(event);
    if (const {'call.ringing', 'call.answered', 'call.ended'}.contains(event.type)) callEvent(event);
    final data = event.json;
    switch (event.type) {
      case 'live.ready':
        // Back online: whatever waited goes up.
        flushSoon();
      case 'family.updated':
        // A parent changed the limits or gave extra time.
        unawaited(family.refresh());
      // A party's chat brings no word: it sits beside the party.
      case 'message.created' when !hub.messages.elsewhere.contains(data['conversationId']):
        _messageArrived(data);
      case 'party.invite':
        final from = data['from'];
        disturbingSound();
        inviteRing();
        final text = T.format('partyInvitedYou', [
          from is Map<String, dynamic> ? (from['displayName'] as String?) ?? '' : '',
        ]);
        app.show(text);
        // Over a game the card, unless the user asked not to be disturbed, as on the Mac.
        if (!doNotDisturb) {
          unawaited(app.noticeOverGame(text, detail: T.text('partyTitle'), symbol: Icons.groups_rounded));
        }
      case 'party.member_joined' when data['partyId'] == hub.parties.party?.id:
        final member = data['member'];
        if (member is Map<String, dynamic> && member['userId'] != user?.id) {
          app.show(T.format('partyJoined', [(member['displayName'] as String?) ?? '']));
        }
      case 'party.member_left':
        if (data['userId'] == user?.id) {
          if (data['reason'] == 'kicked') app.show(T.text('partyKicked'));
        } else {
          final name = hub.parties.party?.members.where((person) => person.id == data['userId']).firstOrNull;
          if (name != null) app.show(T.format('partyLeft', [name.displayName]));
        }
      case 'party.ended' when data['partyId'] == hub.parties.party?.id:
        app.show(T.text('partyEnded'));
    }
  }

  void _voiceChanged() {
    final watch = talkWatch;
    if (watch == null) return;
    if (hub.voice.active) {
      watch.start();
    } else {
      watch.stop();
    }
  }

  // The profile: name, bio, country and handle, and who sees what.

  /// What is typed in Your profile, until it is saved (null: the profile's own, which follows a
  /// change made on the website).
  String? nameDraft;
  String? bioDraft;
  String? countryDraft;
  String? handleDraft;

  List<PanelRow> profileEditRows() {
    final self = hub.self;
    final me = user;
    if (!self.loaded || me == null) return const [];
    final next = self.handleChangeAt;
    return [
      PanelRow(id: 'together-edit', title: T.text('togetherEditProfile'), kind: const InfoRow('')),
      PanelRow(
        id: 'together-name',
        title: T.text('togetherName'),
        kind: TextRow(nameDraft ?? me.displayName, (text) => nameDraft = text, submit: () => unawaited(saveProfile())),
      ),
      PanelRow(
        id: 'together-bio',
        title: T.text('togetherBio'),
        kind: TextRow(bioDraft ?? self.bio ?? '', (text) => bioDraft = text, submit: () => unawaited(saveProfile())),
      ),
      PanelRow(
        id: 'together-country',
        title: T.text('togetherCountry'),
        // The country by its name, chosen from the list: never a code to know and type.
        detail: Countries.name(countryDraft ?? self.country) ?? T.text('togetherCountryChoose'),
        kind: ActionRow(openCountryPicker),
      ),
      PanelRow(
        id: 'together-save',
        title: T.text('togetherSaveProfile'),
        kind: ActionRow(() => unawaited(saveProfile())),
      ),
      PanelRow(
        id: 'together-handle',
        title: T.text('togetherHandle'),
        detail: next == null
            ? T.text('togetherHandleDetail')
            : T.format('togetherHandleAgain', [CompareView.day(next)]),
        kind: TextRow(handleDraft ?? me.handle, (text) => handleDraft = text, submit: () => unawaited(changeHandle())),
      ),
      PanelRow(
        id: 'together-handle-save',
        title: T.text('togetherChangeHandle'),
        kind: ActionRow(() => unawaited(changeHandle())),
      ),
    ];
  }

  // The country: a list to search, by name in the launcher's language (Layer.countryPicker).

  /// The search field's row, and the rows of no country and of each one.
  static const countrySearchRow = 'country-search';
  static const countryNoneRow = 'country-none';
  static String countryRowId(String code) => 'country-$code';

  /// What is typed in the picker's search, and where Back from the picker goes.
  String countryQuery = '';
  PanelSpot? countryReturn;

  /// The country the profile would get on Save: the one picked, else the profile's own.
  String get countryChosen => (countryDraft ?? hub.self.country ?? '').trim().toUpperCase();

  /// Opens the list over Settings, on the row of the country chosen now.
  void openCountryPicker() {
    countryReturn = app.spot;
    countryQuery = '';
    app.open(Layer.countryPicker);
    final chosen = countryChosen;
    final row = countryRows().indexWhere((row) => row.id == (chosen.isEmpty ? countryNoneRow : countryRowId(chosen)));
    if (row > 0) app.panelRow = row;
    app.refresh();
  }

  /// Back to the row the picker was opened from, nothing chosen.
  void backFromCountry() {
    app.stopEditing();
    app.returnTo(countryReturn);
    countryReturn = null;
  }

  /// [code] is the profile's country from now on (null: none): the list closes and the profile
  /// is saved at once, as on the Mac.
  void chooseCountry(String? code) {
    countryDraft = code ?? '';
    backFromCountry();
    unawaited(saveProfile());
  }

  /// The search field, None (while nothing is searched for) and the countries the search finds.
  List<PanelRow> countryRows() {
    final found = Countries.search(countryQuery);
    final searching = countryQuery.trim().isNotEmpty;
    return [
      PanelRow(
        id: countrySearchRow,
        title: T.text('togetherCountrySearch'),
        kind: TextRow(
          countryQuery,
          (text) {
            countryQuery = text;
            // The rows under the field change: the focus stays on the field.
            app.panelRow = 0;
            app.refresh();
          },
          // Enter: on to the first country found.
          submit: () {
            if (Countries.search(countryQuery).isEmpty) return;
            app.panelRow = 1;
            app.refresh();
          },
        ),
      ),
      if (!searching)
        PanelRow(id: countryNoneRow, title: T.text('togetherCountryNone'), kind: ActionRow(() => chooseCountry(null))),
      for (final (code, name) in found)
        PanelRow(id: countryRowId(code), title: name, kind: ActionRow(() => chooseCountry(code))),
      if (found.isEmpty)
        PanelRow(
          id: 'country-no-match',
          title: T.format('togetherCountryNoMatch', [countryQuery.trim()]),
          kind: const InfoRow(''),
        ),
    ];
  }

  /// The name, bio and country as typed: only what changed goes, and a blank name stays as it was.
  Future<void> saveProfile() async {
    final me = user;
    final self = hub.self;
    if (me == null) return;
    final name = (nameDraft ?? me.displayName).trim();
    final bio = bioDraft ?? self.bio ?? '';
    final country = countryDraft ?? self.country ?? '';
    try {
      await self.updateProfile(
        displayName: name != me.displayName && name.isNotEmpty ? name : null,
        bio: bio != (self.bio ?? '') ? bio : null,
        country: country.trim().toUpperCase() != (self.country ?? '') ? country : null,
      );
      nameDraft = null;
      bioDraft = null;
      countryDraft = null;
      app.show(T.text('togetherProfileSaved'));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  Future<void> changeHandle() async {
    final handle = (handleDraft ?? '').trim();
    if (handle.isEmpty || handle.toLowerCase() == user?.handle) return;
    try {
      await hub.self.changeHandle(handle);
      handleDraft = null;
      app.show(T.format('togetherHandleChanged', [user?.handle ?? handle]));
    } on TogetherProblem catch (problem) {
      app.show(problem.code == 'bad_request' ? T.text('togetherHandleInvalid') : message(problem));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// Who sees the games, trophies, friends, being online and being found by name; the gallery's
  /// own setting where the server keeps files.
  List<PanelRow> privacyRows() {
    final self = hub.self;
    if (!self.loaded) return const [];
    final sections = [
      (PrivacySection.library, 'privacyLibrary'),
      (PrivacySection.trophies, 'privacyTrophies'),
      (PrivacySection.friends, 'privacyFriends'),
      (PrivacySection.presence, 'privacyPresence'),
      (PrivacySection.search, 'privacySearch'),
      if (app.saveSync.cloudAvailable) (PrivacySection.gallery, 'cloudPrivacyGallery'),
    ];
    return [
      PanelRow(id: 'together-privacy', title: T.text('togetherPrivacyTitle'), kind: const InfoRow('')),
      for (final (section, title) in sections)
        PanelRow(
          id: 'privacy-${section.name}',
          title: T.text(title),
          kind: ChoiceRow(
            [
              for (final visibility in ProfileVisibility.values)
                T.text(switch (visibility) {
                  ProfileVisibility.everyone => 'visibilityEveryone',
                  ProfileVisibility.friends => 'visibilityFriends',
                  ProfileVisibility.nobody => section == PrivacySection.search ? 'visibilityNoOne' : 'visibilityNobody',
                }),
            ],
            ProfileVisibility.values.indexOf(self.privacy[section] ?? ProfileVisibility.friends),
            (index) => unawaited(setPrivacy(section, ProfileVisibility.values[index])),
          ),
        ),
    ];
  }

  Future<void> setPrivacy(PrivacySection section, ProfileVisibility visibility) async {
    if (hub.self.privacy[section] == visibility) return;
    try {
      await hub.self.setPrivacy(section, visibility);
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  // The friends-only name and picture.

  /// What is typed as the friends-only name, until it is saved (null: the one kept).
  static String? privateNameDraft;

  List<PanelRow> privateIdentityRows() {
    final self = hub.self;
    if (!self.loaded) return const [];
    final draft = privateNameDraft ?? self.privateName ?? '';
    return [
      PanelRow(id: 'private-title', title: T.text('privateTitle'), kind: InfoRow(T.text('privateDetail'))),
      PanelRow(
        id: 'private-name',
        title: T.text('privateName'),
        kind: TextRow(
          draft,
          (text) => privateNameDraft = text,
          submit: () => unawaited(savePrivateName()),
          hint: user?.displayName ?? '',
        ),
      ),
      PanelRow(
        id: 'private-name-save',
        title: T.text(draft.trim().isEmpty && self.privateName != null ? 'privateNameClear' : 'privateNameSave'),
        kind: ActionRow(() => unawaited(savePrivateName())),
      ),
      PanelRow(
        id: 'private-picture',
        title: T.text('privatePicture'),
        detail: T.text('privatePictureDetail'),
        person: self.privateAvatar == null
            ? null
            : PanelPerson(name: self.privateName ?? user?.displayName ?? '', avatar: self.privateAvatar),
        kind: ActionRow(() => unawaited(choosePrivatePicture())),
      ),
      if (self.privateAvatar != null)
        PanelRow(
          id: 'private-picture-remove',
          title: T.text('privatePictureRemove'),
          kind: ActionRow(() => unawaited(removePrivatePicture()), destructive: true),
        ),
    ];
  }

  Future<void> savePrivateName() async {
    final text = (privateNameDraft ?? hub.self.privateName ?? '').trim();
    try {
      await hub.self.setPrivateName(text);
      privateNameDraft = null;
      app.show(T.text(hub.self.privateName == null ? 'privateNameCleared' : 'privateNameSaved'));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  /// A PNG or JPEG chosen on this computer, as the friends-only picture (the public one stays).
  Future<void> choosePrivatePicture() async {
    final path = await app.services.pickImage?.call();
    if (path == null) return;
    try {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length > 5 * 1024 * 1024) return app.show(T.text('privatePictureFailed'));
      await hub.self.uploadPrivateAvatar(bytes);
      app.show(T.text('privatePictureSaved'));
    } on FileSystemException {
      app.show(T.text('privatePictureFailed'));
    } on Object catch (error) {
      app.show('${T.text('privatePictureFailed')}: ${message(error)}');
    }
  }

  Future<void> removePrivatePicture() async {
    try {
      await hub.self.removePrivateAvatar();
      app.show(T.text('privatePictureRemoved'));
    } on Object catch (error) {
      app.show(message(error));
    }
  }

  void dispose() {
    _linkPoll?.cancel();
    _linkPoll = null;
    stopRinging();
    calls.noAnswer?.cancel();
    unawaited(voiceNotes.dispose());
    unawaited(online.stop());
    _joinLookup?.cancel();
    family.dispose();
    talkWatch?.stop();
    talkWatch?.reader.close();
    hub.voice.removeListener(_voiceChanged);
    _flush?.cancel();
    unawaited(_ready.cancel());
    account.removeListener(_accountChanged);
    hub.dispose();
    account.close();
  }
}
