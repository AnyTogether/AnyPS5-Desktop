part of 'app_model.dart';

/// Why the sign-in screen is up.
enum ProfileOrigin {
  /// The first start: no profile yet.
  firstStart,

  /// A new profile from the picker, the menus or Settings.
  adding,

  /// The profile playing goes online.
  goingOnline,

  /// A profile picked whose session ended: it signs in again.
  signingInAgain,
}

/// Where the profile screens are: the picker's focus, adding a profile (offline or signing in),
/// and the sign-in a profile going online waits on.
class ProfileFlow {
  /// Add Profile's name field, as the row being typed in (AppModel.editingRow).
  static const nameRow = 'profile-add-name';

  /// The picker's focused tile (the last one is Add Profile).
  int pickerIndex = 0;

  /// The picker came up at start: a profile has to be picked.
  bool atLaunch = false;

  /// Offline (0) or Online (1) on the cards; the name typed for a new profile.
  int modeChoice = 0;
  String name = '';
  ProfileOrigin origin = ProfileOrigin.adding;

  /// Home's profile list is open because the pointer is on the picture or on the list (the
  /// keys open it through the focus, HomeFocus.switcher); [listLeave] closes it a moment after
  /// the pointer left both, so it can cross the gap between them.
  bool listShown = false;
  Timer? listLeave;

  /// A new online profile's ID while it signs in, and the profile to go back to on Cancel.
  String? pendingId;
  String? returnTo;
}

/// The profiles' side of the launcher: who plays, switching, online and offline, adding and
/// deleting, and the friends-only name and picture in Settings › AnyTogether. The macOS
/// launcher's Profiles.swift.
extension LauncherProfiles on AppModel {
  /// The settings that are each profile's own; the rest (games folder, engine, Steam, the
  /// server…) belong to the computer.
  static const personalKeys = {
    'language',
    'theme',
    'accent',
    'customTheme',
    'backdrop',
    'backdropFile',
    'menuMusicFile',
    'gameArtwork',
    'reducedMotion',
    'glassTransparency',
    'glassArtwork',
    'sounds',
    'soundVolume',
    'musicVolume',
    'launcherVolume',
    'hideWhilePlaying',
    'friendsJoin',
    'discordPresence',
    'discordJoin',
    'nowPlayingCard',
    'nowPlayingShare',
    'onlinePlay',
    'pushToTalk',
    'noiseSuppression',
    'talkKey',
    'profileName',
    'showHiddenTrophies',
    'controllerVibration',
    'controllerLight',
    'confirmCircle',
    'stickDeadzone',
    'pauseOnMenu',
    'saveSync',
    'syncFolder',
    'syncThrough',
    'replayBuffer',
    'replaySeconds',
    'shortcuts',
    'lastPlayed',
    'compatNever',
    'compatAsked',
  };

  /// The tiles' colours, as the Mac's.
  static const palette = [
    Color(0xFF5C6BFA),
    Color(0xFF1FB8AD),
    Color(0xFFFA735C),
    Color(0xFFF5B333),
    Color(0xFFA866F2),
    Color(0xFF4DCC73),
    Color(0xFFED5C9E),
    Color(0xFF409EF2),
  ];

  /// The name a profile left without one gets: "Oyuncu", then "Oyuncu 2", in Turkish.
  static String defaultName(int number) =>
      number == 1 ? T.text('profileDefaultName') : T.format('profilePlayerNumber', [number]);

  static Color colorOf(LauncherProfile? profile) => palette[(profile?.color ?? 0) % palette.length];

  static List<String> get colourNames => [
    for (final key in ['Indigo', 'Teal', 'Coral', 'Amber', 'Violet', 'Green', 'Pink', 'Sky']) T.text('colour$key'),
  ];

  LauncherProfile? get currentProfile => profiles.book.currentProfile;

  /// The profile whose session the account uses: the one signing in, else the one playing.
  String get sessionProfileId => profileFlow.pendingId ?? profiles.book.currentProfile?.id ?? LauncherProfile.legacyId;

  bool _isLegacy(String id) => id == (profiles.book.legacyOwner ?? LauncherProfile.legacyId);

  /// Where a profile's session is kept: the first profile's where the launcher kept it before
  /// profiles, every other one's in a store of its own.
  TokenStore tokenStoreFor(String id) {
    if (_isLegacy(id)) return services.togetherStore ?? TokenStore.forProfile(paths, system, id, legacy: true);
    if (services.togetherStoreFor case final stores?) return stores(id);
    // Tests and previews give a store of their own: the other profiles' are in memory too.
    if (services.togetherStore != null) return _memoryStores.putIfAbsent(id, MemoryTokenStore.new);
    return TokenStore.forProfile(paths, system, id, legacy: false);
  }

  /// Where a profile keeps this device's end-to-end encryption keys: beside its session, as
  /// safely (in memory in tests and previews, which keep the session there too).
  E2eeKeyStore e2eeKeysFor(String id) {
    if (services.togetherStore != null || services.togetherStoreFor != null) {
      return _memoryKeys.putIfAbsent(id, MemoryE2eeKeyStore.new);
    }
    return E2eeKeyStore.forProfile(paths, system, id, legacy: _isLegacy(id));
  }

  /// What the profile's device remembers of its encrypted conversations.
  E2eeNotesStore e2eeNotesFor(String id) {
    if (services.togetherStore != null || services.togetherStoreFor != null) {
      return _memoryNotes.putIfAbsent(id, MemoryE2eeNotesStore.new);
    }
    return E2eeNotesStore.forProfile(paths, id, legacy: _isLegacy(id));
  }

  /// Each profile's outbox: the first one keeps the file from before profiles.
  String outboxFile(String id) => _isLegacy(id)
      ? p.join(paths.config, 'Together', 'outbox.json')
      : p.join(paths.config, 'Together', 'profiles', id, 'outbox.json');

  void profilesChanged() => _changed();

  /// At start: the picker when there are several profiles (or Ask every time is on); the
  /// session waits for the one picked.
  void startProfiles() {
    if (!preferences.onboarded || profiles.launchScreen != const LaunchScreen.picker()) return;
    openProfilePicker(atLaunch: true);
  }

  // Saves.

  /// The profile playing has its saves in every installed game's folder (and the game about to
  /// start in particular).
  void activateProfileSaves([Game? only]) {
    final profile = currentProfile;
    final owner = profiles.book.legacyOwner;
    if (root == null || profile == null || owner == null) return;
    for (final game in only == null ? games : [only]) {
      if (records[game.id] == null) continue;
      try {
        ProfileSaves.activate(profile.id, Installer.installedFolder(game, rootOf(game)!), legacyOwner: owner);
      } on FileSystemException {
        show(T.format('profileSavesNotSwapped', [game.name]));
      }
    }
  }

  // Switching.

  ProfileRefusal? switchRefusal(String id) => ProfileSwitch.check(
    id,
    profiles.book,
    running: running?.$1.name,
    starting: starting?.name,
    syncing: saveSync.syncing != null,
  );

  ProfileRefusal? _modeChangeRefusal() =>
      ProfileSwitch.checkModeChange(running: running?.$1.name, starting: starting?.name);

  void tell(ProfileRefusal refusal) {
    switch (refusal) {
      case ProfileRefusal.gameRunning:
        sounds.play(Cue.bump);
        show(T.format('profileCloseGameFirst', [(running?.$1 ?? starting)?.name ?? '']));
      case ProfileRefusal.syncing:
        sounds.play(Cue.bump);
        show(T.text('profileWaitForSync'));
      default:
        break;
    }
  }

  /// Plays as [id] from now on: the account, settings, saves and trophies are theirs.
  Future<void> switchProfile(String id) async {
    final refusal = switchRefusal(id);
    if (refusal == ProfileRefusal.alreadyCurrent) return enterCurrentProfile();
    if (refusal != null) return tell(refusal);
    final next = profiles.profile(id);
    if (next == null) return;
    keepPersonalSettings();
    together.account.detach();
    profiles.select(id);
    overlay = null;
    await _useProfile(next);
    sounds.play(Cue.select);
    show(T.format('profileWelcomeBack', [next.name]));
    if (next.mode == ProfileMode.online && !together.signedIn) beginSignIn(ProfileOrigin.signingInAgain);
    _changed();
  }

  /// The picker's choice was the profile already in use: in it goes.
  Future<void> enterCurrentProfile() async {
    overlay = null;
    sounds.play(Cue.select);
    profileFlow.atLaunch = false;
    final profile = currentProfile;
    if (profile != null && profile.mode == ProfileMode.online && !together.signedIn) {
      await together.account.restore();
      if (!together.signedIn) beginSignIn(ProfileOrigin.signingInAgain);
    }
    _changed();
  }

  /// The profile playing's settings go back into its record before another's come.
  void keepPersonalSettings() {
    final profile = currentProfile;
    if (profile == null) return;
    profiles.setSettings(profile.id, ProfileSettings.pick(personalKeys, _preferencesJson(preferences)));
  }

  static Map<String, dynamic> _preferencesJson(Preferences preferences) =>
      jsonDecode(jsonEncode(preferences.toJson())) as Map<String, dynamic>;

  /// The profile's own settings in place of the ones playing; a profile without any yet starts
  /// from the defaults, in the language in use, with its own name.
  void applyProfileSettings(LauncherProfile profile) {
    final values = ProfileSettings.pick(personalKeys, _preferencesJson(Preferences()));
    final own = profile.settings;
    if (own != null) {
      values.addAll(own);
    } else {
      values['language'] = preferences.language;
    }
    values['profileName'] = profile.name;
    preferences = Preferences.fromJson(ProfileSettings.merge(values, personalKeys, _preferencesJson(preferences)));
    T.language = Language.byCode(preferences.language);
    Motion.reduced = preferences.reducedMotion || powerWatch.dimmed;
    haptics.enabled = preferences.controllerVibration;
    together.hub.voice
      ..pushToTalk = preferences.pushToTalk
      ..noiseSuppression = preferences.noiseSuppression;
    _applySound();
    savePreferences();
  }

  Future<void> _useProfile(LauncherProfile profile) async {
    profileFlow.atLaunch = false;
    applyProfileSettings(profile);
    together.sessions.use(tokenStoreFor(profile.id));
    together.sync.useFile(outboxFile(profile.id));
    _showProfileSaves();
    if (profile.mode == ProfileMode.online) await together.account.restore();
  }

  /// The playing profile's saves in place and its trophies read.
  void _showProfileSaves() {
    activateProfileSaves();
    trophies.clear();
    for (final game in games) {
      _loadTrophies(game);
    }
  }

  // Online and offline.

  /// The profile playing goes offline (its session kept, unused) or online (signing in when it
  /// has none): never while a game plays.
  Future<void> toggleProfileMode() async {
    final profile = currentProfile;
    if (profile == null) return;
    if (_modeChangeRefusal() case final refusal?) return tell(refusal);
    overlay = null;
    if (profile.mode == ProfileMode.online) {
      together.account.detach();
      profiles.setMode(profile.id, ProfileMode.offline);
      sounds.play(Cue.select);
      show(T.text('profileNowOffline'));
    } else {
      await together.account.restore();
      final user = together.user;
      if (user != null) {
        profileSignedIn(user);
        sounds.play(Cue.select);
        show(T.format('togetherWelcome', [user.displayName]));
      } else {
        beginSignIn(ProfileOrigin.goingOnline);
      }
    }
    _changed();
  }

  // Signing in.

  /// The sign-in screen for [origin]: the same email code, website code and phone hand-off as
  /// Settings › AnyTogether.
  void beginSignIn(ProfileOrigin origin) {
    profileFlow.origin = origin;
    together.account.cancel();
    open(Layer.signIn);
  }

  /// A new profile that signs in: its own session from the start, the profile playing kept for
  /// Cancel.
  Future<void> beginOnlineProfile() async {
    if (_modeChangeRefusal() case final refusal?) return tell(refusal);
    final first = profiles.book.profiles.isEmpty;
    final id = first ? LauncherProfile.legacyId : ProfileStore.newId();
    profileFlow.pendingId = id;
    profileFlow.origin = first ? ProfileOrigin.firstStart : ProfileOrigin.adding;
    // Signed in already from before profiles: that account is the first profile's.
    if (first && together.user != null) return profileSignedIn(together.user!);
    if (!first) {
      keepPersonalSettings();
      profileFlow.returnTo = currentProfile?.id;
      together.account.detach();
      together.sessions.use(tokenStoreFor(id));
      together.sync.useFile(outboxFile(id));
    }
    beginSignIn(profileFlow.origin);
  }

  /// Signed in: the waiting profile is made (or the one playing is online now).
  void profileSignedIn(TogetherUser user) {
    final account = ProfileAccount(userId: user.id, handle: user.handle);
    final pending = profileFlow.pendingId;
    if (pending != null) {
      final profile = profiles.add(name: user.displayName, mode: ProfileMode.online, account: account, id: pending);
      profileFlow
        ..pendingId = null
        ..returnTo = null;
      profiles.select(profile.id);
      overlay = null;
      if (profileFlow.origin == ProfileOrigin.firstStart) {
        preferences.profileName = profile.name;
        finishOnboarding();
      } else {
        applyProfileSettings(profile);
        _showProfileSaves();
      }
      _changed();
      return;
    }
    final current = currentProfile;
    if (current == null) return;
    profiles
      ..setMode(current.id, ProfileMode.online)
      ..setAccount(current.id, account);
    if (overlay == Layer.signIn) overlay = null;
    _changed();
  }

  /// Back on the sign-in: a profile that was waiting is not made, and the one before plays on.
  Future<void> cancelSignIn() async {
    together.account.cancel();
    sounds.play(Cue.back);
    final pending = profileFlow.pendingId;
    final origin = profileFlow.origin;
    if (pending != null) {
      final back = profileFlow.returnTo;
      profileFlow
        ..pendingId = null
        ..returnTo = null;
      if (back != null) {
        together.sessions.use(tokenStoreFor(back));
        together.sync.useFile(outboxFile(back));
        if (profiles.profile(back)?.mode == ProfileMode.online) await together.account.restore();
      }
    }
    overlay = origin == ProfileOrigin.adding ? Layer.addProfile : null;
    _changed();
  }

  // Adding.

  void openAddProfile() {
    if (_modeChangeRefusal() case final refusal?) return tell(refusal);
    profileFlow
      ..modeChoice = 0
      ..name = T.format('profilePlayerNumber', [profiles.book.profiles.length + 1])
      ..origin = ProfileOrigin.adding;
    open(Layer.addProfile);
  }

  /// Offline: made at once with the name typed, and it plays.
  Future<void> createOfflineProfile() async {
    if (profiles.book.profiles.isEmpty) {
      preferences.profileName = profiles.add(name: preferences.profileName, mode: ProfileMode.offline).name;
      finishOnboarding();
      return;
    }
    if (_modeChangeRefusal() case final refusal?) return tell(refusal);
    final profile = profiles.add(name: profileFlow.name, mode: ProfileMode.offline);
    await switchProfile(profile.id);
  }

  /// ✕ on a card.
  void confirmModeChoice() {
    // A first start cut short after its profile was made: in it goes.
    if (!preferences.onboarded && profiles.book.profiles.isNotEmpty) return finishOnboarding();
    unawaited(profileFlow.modeChoice == 0 ? createOfflineProfile() : beginOnlineProfile());
  }

  /// The two cards (Add Profile and the first start's last step): left and right pick one.
  void modeChoiceCommand(Command command) {
    switch (command) {
      // Add Profile: the name is over the cards. Up puts the cursor in it (Enter and Esc give
      // the keys back to the cards).
      case Command.up when overlay == Layer.addProfile:
        sounds.play(Cue.move);
        startEditing(ProfileFlow.nameRow);
        return;
      case Command.left || Command.right:
        final next = command == Command.left ? 0 : 1;
        if (next == profileFlow.modeChoice) return;
        profileFlow.modeChoice = next;
        sounds.play(Cue.move);
      case Command.select:
        sounds.play(Cue.select);
        confirmModeChoice();
      case Command.back:
        if (overlay == Layer.addProfile) {
          profileFlow.atLaunch ? open(Layer.profilePicker, cue: Cue.back) : closeOverlay();
        } else {
          onboardingBack();
        }
      default:
        break;
    }
    _changed();
  }

  // Home's profile list: under the picture at the top right, the other profiles and Add profile.

  /// The profiles the list offers: every one but the one playing, as they were made.
  List<LauncherProfile> get switcherProfiles {
    final current = currentProfile;
    return [
      for (final profile in profiles.book.profiles)
        if (profile.id != current?.id) profile,
    ];
  }

  /// The list's entries: the other profiles, then Add profile.
  int get switcherCount => switcherProfiles.length + 1;

  /// The list shows: the keys are on the picture or in the list, or the pointer is.
  bool get profileListOpen => preferences.onboarded && overlay == null && (focus.isSwitcher || profileFlow.listShown);

  /// The pointer came onto the picture or the list (or clicked the picture).
  void showProfileList() {
    profileFlow.listLeave?.cancel();
    profileFlow.listLeave = null;
    if (profileFlow.listShown) return;
    profileFlow.listShown = true;
    sounds.play(Cue.hover);
    _changed();
  }

  /// The pointer left the picture or the list: closed a moment later, unless it came back.
  void leaveProfileList() {
    if (!profileFlow.listShown) return;
    profileFlow.listLeave?.cancel();
    profileFlow.listLeave = Timer(const Duration(milliseconds: 220), () {
      profileFlow.listLeave = null;
      if (_disposed || !profileFlow.listShown) return;
      profileFlow.listShown = false;
      _changed();
    });
  }

  /// Escape, Back or a click elsewhere: the list closes and the keys are back on the games.
  void closeProfileList() {
    profileFlow.listLeave?.cancel();
    profileFlow.listLeave = null;
    if (!profileFlow.listShown && !focus.isSwitcher) return;
    profileFlow.listShown = false;
    if (focus.isSwitcher) focus = HomeFocus.tiles;
    sounds.play(Cue.back);
    _changed();
  }

  /// The list's entry [entry] chosen, from 0: that profile plays from now on, as from the
  /// picker (not while a game runs or saves sync: said as there), or Add profile for the last.
  void chooseFromProfileList(int entry) {
    final others = switcherProfiles;
    if (entry < 0 || entry > others.length) return;
    profileFlow.listLeave?.cancel();
    profileFlow.listLeave = null;
    profileFlow.listShown = false;
    if (focus.isSwitcher) focus = HomeFocus.tiles;
    if (entry < others.length) {
      unawaited(switchProfile(others[entry].id));
    } else {
      openAddProfile();
    }
    _changed();
  }

  // The picker.

  void openProfilePicker({bool atLaunch = false}) {
    if (!atLaunch) {
      if (_modeChangeRefusal() case final refusal?) return tell(refusal);
    }
    profileFlow
      ..atLaunch = atLaunch
      ..pickerIndex = 0;
    open(Layer.profilePicker, cue: atLaunch ? Cue.hover : Cue.select);
  }

  void pickerCommand(Command command) {
    final tiles = profiles.book.pickerOrder;
    final count = tiles.length + 1;
    switch (command) {
      case Command.left || Command.right:
        final next = (profileFlow.pickerIndex + (command == Command.left ? -1 : 1)).clamp(0, count - 1);
        if (next == profileFlow.pickerIndex) return;
        profileFlow.pickerIndex = next;
        sounds.play(Cue.move);
        _changed();
      case Command.select:
        if (profileFlow.pickerIndex < tiles.length) {
          unawaited(switchProfile(tiles[profileFlow.pickerIndex].id));
        } else {
          openAddProfile();
        }
      case Command.back:
        // At start a profile has to be picked.
        if (profileFlow.atLaunch) {
          sounds.play(Cue.bump);
        } else {
          closeOverlay();
        }
      case Command.options:
        if (!profileFlow.atLaunch) openProfileSettings();
      default:
        break;
    }
  }

  // Options and the right click on Home.

  void openProfileMenu() {
    if (!preferences.onboarded || overlay != null || starting != null || pairing != null) return;
    open(Layer.profileMenu);
  }

  /// The right click on Home: the Options menu; false when it is not Home's.
  bool homeRightClick() {
    if (!preferences.onboarded || overlay != null || starting != null || pairing != null || retroPlay != null) {
      return false;
    }
    openProfileMenu();
    return true;
  }

  List<PanelRow> profileMenuRows() {
    final game = selectedGame;
    final others = profiles.book.profiles.length - 1;
    final online = currentProfile?.mode == ProfileMode.online;
    return [
      if (game != null)
        PanelRow(
          id: 'menu-game',
          title: T.text('gameSettings'),
          detail: game.name,
          kind: ActionRow(() => open(Layer.gameSettings)),
        ),
      PanelRow(
        id: 'menu-switch',
        title: T.text('switchProfile'),
        detail: others > 1
            ? T.format('profileOthers', [others])
            : others == 1
            ? T.text('profileOthersOne')
            : T.text('profileAddSomeone'),
        kind: ActionRow(() => others > 0 ? openProfilePicker() : openAddProfile()),
      ),
      PanelRow(
        id: 'menu-mode',
        title: T.text(online ? 'profileGoOffline' : 'profileGoOnline'),
        detail: T.text(online ? 'profileGoOfflineDetail' : 'profileGoOnlineDetail'),
        kind: ActionRow(() => unawaited(toggleProfileMode())),
      ),
      PanelRow(id: 'menu-profiles', title: T.text('profileManage'), kind: ActionRow(openProfileSettings)),
    ];
  }

  void openProfileSettings() {
    open(Layer.settings);
    panelCategory = panelCategories().indexWhere((category) => category.id == 'profiles').clamp(0, 99);
    _skipToFocusable();
    _changed();
  }

  // Settings › Profiles.

  List<PanelRow> profileRows() {
    final profile = currentProfile;
    if (profile == null) return const [];
    final online = profile.mode == ProfileMode.online;
    final user = together.user;
    final others = profiles.book.profiles.where((other) => other.id != profile.id).toList();
    final picture = profiles.pictureOf(profile);
    return [
      PanelRow(
        id: 'profile-current',
        title: profile.name,
        detail: online
            ? (user == null ? T.text('profileOnlineSignedOut') : T.format('profileOnlineAs', [user.handle]))
            : T.text('profileOfflineDetail'),
        person: personOf(profile, avatar: user?.avatar),
        kind: const InfoRow(''),
      ),
      PanelRow(
        id: 'profile-name',
        title: T.text('profileName'),
        kind: TextRow(profile.name, renameCurrentProfile, hint: T.text('profileNameHint')),
      ),
      // The picker is the mouse's (the system's file dialog); the rows are a controller's too.
      PanelRow(
        id: 'profile-picture',
        title: T.text(picture == null ? 'profilePicture' : 'profilePictureChange'),
        detail: T.text('profilePictureDetail'),
        kind: ActionRow(() => unawaited(chooseProfilePicture())),
      ),
      // As on the Mac: the picture up to AnyTogether as the account's, or the account's here.
      if (online && user != null && picture != null)
        PanelRow(
          id: 'profile-picture-upload',
          title: T.text('profilePictureUpload'),
          detail: T.text(pictureBusy ? 'profileLoading' : 'profilePictureUploadDetail'),
          kind: ActionRow(() => unawaited(uploadProfilePicture())),
        ),
      if (user?.avatar case final String avatar when online && avatar.isNotEmpty)
        PanelRow(
          id: 'profile-picture-from-together',
          title: T.text('profilePictureFromTogether'),
          detail: T.text('profilePictureFromTogetherDetail'),
          kind: ActionRow(() => unawaited(useTogetherPicture())),
        ),
      if (picture != null)
        PanelRow(
          id: 'profile-picture-remove',
          title: T.text('profilePictureRemove'),
          kind: ActionRow(removeProfilePicture, destructive: true),
        ),
      PanelRow(
        id: 'profile-color',
        title: T.text('profileColour'),
        detail: T.text('profileColourDetail'),
        kind: ChoiceRow(colourNames, profile.color % palette.length, (index) {
          profiles.setColor(profile.id, index);
          _changed();
        }),
      ),
      PanelRow(
        id: 'profile-mode',
        title: T.text(online ? 'profileGoOffline' : 'profileGoOnline'),
        detail: T.text(online ? 'profileGoOfflineDetail' : 'profileGoOnlineDetail'),
        kind: ActionRow(() => unawaited(toggleProfileMode())),
      ),
      PanelRow(
        id: 'profile-ask',
        title: T.text('profileAskEveryTime'),
        detail: T.text('profileAskEveryTimeDetail'),
        kind: ToggleRow(profiles.book.askEveryTime, (value) {
          profiles.setAskEveryTime(value);
          _changed();
        }),
      ),
      if (others.isNotEmpty)
        PanelRow(id: 'profiles-others', title: T.text('profileOtherTitle'), kind: const InfoRow('')),
      for (final other in others) ...[
        PanelRow(
          id: 'profile-switch-${other.id}',
          title: T.format('profileSwitchTo', [other.name]),
          detail: other.mode == ProfileMode.online
              ? (other.account == null ? T.text('profileOnline') : '@${other.account!.handle}')
              : T.text('profileOffline'),
          person: personOf(other),
          kind: ActionRow(() => unawaited(switchProfile(other.id))),
        ),
        ...together.askingFirst(
          PanelRow(
            id: 'profile-delete-${other.id}',
            title: T.format('profileDelete', [other.name]),
            kind: ActionRow(() => unawaited(deleteProfile(other.id)), destructive: true),
          ),
          T.format('profileDeleteQuestion', [other.name]),
        ),
      ],
      PanelRow(
        id: 'profile-add',
        title: T.text('profileAdd'),
        detail: T.text('profileAddDetail'),
        kind: ActionRow(openAddProfile),
      ),
    ];
  }

  /// How [profile] shows on a row: its picture, or its initial on its colour ([avatar], the
  /// account's picture, when it has none of its own).
  PanelPerson personOf(LauncherProfile profile, {String? avatar}) {
    final picture = profiles.pictureOf(profile);
    return PanelPerson(
      name: profile.name,
      avatar: picture == null ? avatar : null,
      picture: picture,
      tint: colorOf(profile),
    );
  }

  /// A picture chosen on this computer for the profile, opened in the crop to place and zoom
  /// (as on the Mac); the square is kept when saved there.
  Future<void> chooseProfilePicture() async {
    final profile = currentProfile;
    final pick = services.pickImage;
    if (profile == null || pick == null) return;
    final path = await pick();
    if (path == null) return;
    final ui.Image image;
    try {
      final file = File(path);
      if (file.lengthSync() > ProfilePicture.maxBytes) throw const FormatException('too large');
      image = await ProfilePicture.read(file.readAsBytesSync());
    } on Object {
      sounds.play(Cue.bump);
      show(T.text('profilePictureFailed'));
      _changed();
      return;
    }
    if (math.min(image.width, image.height) < ProfilePicture.uploadMinSide) {
      image.dispose();
      sounds.play(Cue.bump);
      show(T.text('profilePictureTooSmall'));
      _changed();
      return;
    }
    pictureCrop?.image.dispose();
    pictureCrop = PictureCrop(image, profileId: profile.id, returnCategory: panelCategory, returnRow: panelRow);
    overlay = Layer.cropPicture;
    sounds.play(Cue.select);
    _changed();
  }

  /// The crop's keys: ← → zoom, Select saves, Back cancels.
  void cropCommand(Command command) {
    final crop = pictureCrop;
    if (crop == null) return;
    switch (command) {
      case Command.left || Command.right:
        final before = crop.zoom;
        crop.zoomTo(crop.zoom + (command == Command.right ? 0.25 : -0.25));
        if (crop.zoom == before) return;
        sounds.play(Cue.move);
        _changed();
      case Command.select:
        unawaited(saveCrop());
      case Command.back || Command.options:
        endCrop(saved: false);
      default:
        break;
    }
  }

  /// The square placed in the crop, kept as the profile's picture.
  Future<void> saveCrop() async {
    final crop = pictureCrop;
    if (crop == null) return;
    try {
      final square = await ProfilePicture.cut(crop.image, crop.rect);
      if (!identical(pictureCrop, crop)) return;
      profiles.setPicture(crop.profileId, square);
      endCrop(saved: true);
      show(T.text('profilePictureSaved'));
    } on Object {
      sounds.play(Cue.bump);
      show(T.text('profilePictureFailed'));
    }
  }

  /// Back to the settings row the picture was chosen from.
  void endCrop({required bool saved}) {
    final crop = pictureCrop;
    pictureCrop = null;
    crop?.image.dispose();
    overlay = Layer.settings;
    panelCategory = crop?.returnCategory ?? panelCategories().indexWhere((category) => category.id == 'profiles');
    panelRow = crop?.returnRow ?? 0;
    sounds.play(saved ? Cue.select : Cue.back);
    _skipToFocusable();
    _changed();
  }

  /// The profile's picture as the account's on AnyTogether (PUT /me/avatar), as on the Mac.
  Future<void> uploadProfilePicture() async {
    final profile = currentProfile;
    final path = profile == null ? null : profiles.pictureOf(profile);
    if (path == null || together.user == null || pictureBusy) return;
    pictureBusy = true;
    _changed();
    try {
      final bytes = File(path).readAsBytesSync();
      if (bytes.length > ProfilePicture.uploadMaxBytes) throw const FormatException('too large');
      await together.hub.self.uploadAvatar(bytes);
      show(T.text('profilePictureUploaded'));
    } on TogetherProblem catch (problem) {
      show('${T.text('privatePictureFailed')}: ${together.message(problem)}');
    } on Object {
      show(T.text('privatePictureFailed'));
    } finally {
      pictureBusy = false;
      _changed();
    }
  }

  /// The account's picture on AnyTogether as this profile's here, as on the Mac.
  Future<void> useTogetherPicture() async {
    final profile = currentProfile;
    final avatar = together.user?.avatar;
    if (profile == null || avatar == null || avatar.isEmpty || pictureBusy) return;
    pictureBusy = true;
    _changed();
    try {
      final bytes = await together.account.fetchBytes(avatar, limit: ProfilePicture.uploadMaxBytes);
      profiles.setPicture(profile.id, await ProfilePicture.square(bytes));
      show(T.text('profilePictureSaved'));
    } on Object {
      show(T.text('profilePictureDownloadFailed'));
    } finally {
      pictureBusy = false;
      _changed();
    }
  }

  void removeProfilePicture() {
    final profile = currentProfile;
    if (profile == null) return;
    profiles.removePicture(profile.id);
    show(T.text('profilePictureRemoved'));
    _skipToFocusable();
    _changed();
  }

  void renameCurrentProfile(String name) {
    final profile = currentProfile;
    if (profile == null) return;
    profiles.rename(profile.id, name);
    preferences.profileName = profile.name;
    savePreferences();
  }

  /// The profile goes: its saves and trophies on this computer are backed up, then removed; its
  /// session ends on the server too.
  Future<void> deleteProfile(String id) async {
    final profile = profiles.profile(id);
    if (profile == null) return;
    if (_modeChangeRefusal() case final refusal?) return tell(refusal);
    final owner = profiles.book.legacyOwner;
    if (root != null && owner != null) {
      for (final game in games) {
        if (records[game.id] == null) continue;
        final installed = Installer.installedFolder(game, rootOf(game)!);
        final place = ProfileSaves.owner(installed, legacyOwner: owner) == id
            ? installed
            : ProfileSaves.parked(id, installed);
        try {
          SaveBackup.backUp(
            place,
            p.join(backupFolder(game), T.format('profileBackupFolder', [profile.name])),
            DateTime.now(),
          );
        } on Object {
          // No saves of theirs for this game.
        }
        try {
          ProfileSaves.remove(id, installed, legacyOwner: owner);
        } on FileSystemException {
          // Left where they are.
        }
      }
    }
    try {
      profiles.remove(id);
    } on ProfileRefusal {
      show(T.text('profileCannotDelete'));
      return;
    }
    show(T.format('profileDeleted', [profile.name]));
    _changed();
    // Its session ends on the server, then is forgotten here.
    final store = tokenStoreFor(id);
    final account = TogetherAccount(base: together.account.base, store: store, clientName: together.account.clientName);
    try {
      await account.restore();
      await account.signOut();
      await store.save(null);
    } on Object {
      // Forgotten here whatever the server says.
    } finally {
      account.close();
    }
  }
}
