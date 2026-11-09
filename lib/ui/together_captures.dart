part of 'together_model.dart';

/// What can be done on a focused post, left to right.
enum CaptureAction { like, comments, view, delete }

/// The post being written over the gallery: its caption, who sees it, Post.
enum DraftRow { caption, visibility, post }

enum PostStage { idle, uploading, posting }

/// Where the gallery's Share menu sends the focused screenshot or clip, as on the Mac.
sealed class ShareTarget {
  const ShareTarget();
}

/// A post on AnyTogether's Captures.
class PostShare extends ShareTarget {
  const PostShare();
}

class ChatShare extends ShareTarget {
  const ChatShare(this.conversation);
  final Conversation conversation;
}

/// Pinned to the user's own profile gallery.
class GalleryShare extends ShareTarget {
  const GalleryShare();
}

/// The file in the system's file manager.
class FolderShare extends ShareTarget {
  const FolderShare();
}

/// Captures on AnyTogether as the launcher holds them: the gallery's Share menu, the post being
/// written over the gallery, the Captures feed, a post's comments and the picture viewed.
class CapturesState {
  // The Share menu over the gallery, and its focused row; something going up.
  bool sharing = false;
  int shareIndex = 0;
  bool working = false;

  // The post being written: nil when the sheet is closed, the capture it shares, the row the
  // keys are on, a clip's length and size against what a post takes, and how far it is.
  PostDraft? draft;
  String? draftFile;
  DraftRow draftRow = DraftRow.caption;
  ClipCheck? clipCheck;
  int? clipMs;
  PostStage stage = PostStage.idle;

  /// The file already uploaded for this draft, so trying again does not send it twice.
  (String, String)? uploaded;

  // The feed: the focused post and its focused action, a Delete pressed once, and where it goes
  // back to.
  final CapturesFeed feed = CapturesFeed();
  bool failed = false;
  int index = 0;
  int action = 0;
  String? armedPost;
  PanelSpot? back;
  bool loadingOlder = false;

  // A post's comments: 0 the composer, then the lines from 1; in the composer the quick
  // comments then the field (the last); the reply being written, a Delete pressed once.
  CommentThread? thread;
  bool commentsFailed = false;
  int line = 0;
  int composer = 0;
  String commentDraft = '';
  PostComment? replyTo;
  String? armedComment;
  bool sending = false;
  bool loadingOlderComments = false;

  /// A post's picture or clip over the whole screen.
  MediaItem? viewing;

  /// Pictures behind signed links, by their address without the signature.
  final Map<String, Future<Uint8List>> pictures = {};

  /// Whose feed this is: another account signed in starts it again.
  String? viewer;

  void follow(String? user) {
    if (user == viewer) return;
    viewer = user;
    feed.load(const [], null);
    feed.loaded = false;
    failed = false;
    thread = null;
    viewing = null;
    pictures.clear();
  }
}

extension TogetherCaptures on TogetherModel {
  static const captionRow = 'capture-caption';
  static const commentRow = 'capture-comment';

  /// How close to the end of the list the next, older page is read.
  static const prefetch = 3;

  static List<String> get quickComments => [
    'GG',
    T.text('capturesQuickNice'),
    '🔥',
    T.text('capturesQuickWow'),
    T.text('capturesQuickHaha'),
  ];

  Posts get posts => Posts(account);
  MediaFiles get mediaFiles => MediaFiles(account);
  StorageInfo? get storage => app.saveSync.info;

  /// Signed in to a server that keeps files.
  bool get cloudAvailable => app.saveSync.cloudAvailable;

  /// Captures need a server that keeps files (or one not asked yet).
  bool get capturesOffered => signedIn && storage?.enabled != false;

  /// A clip too big to send that only ffmpeg could make smaller.
  static const _ffmpegNeeded = 'ffmpeg_needed';

  ClipTools? get clipTools => clipToolsOverride ?? app.replayFfmpeg?.let(FfmpegClipTools.new);

  String? get _shot {
    final shots = app.galleryShots;
    if (shots.isEmpty) return null;
    return shots[app.galleryIndex.clamp(0, shots.length - 1)];
  }

  // The Share menu.

  List<ShareTarget> get shareTargets => [
    const PostShare(),
    for (final conversation in hub.messages.conversations.take(6)) ChatShare(conversation),
    const GalleryShare(),
    const FolderShare(),
  ];

  /// △ in the gallery: the Share menu where AnyTogether keeps files, else the file's folder.
  void openShareMenu() {
    final shot = _shot;
    if (shot == null) return;
    if (!cloudAvailable) return showInFolder(shot);
    if (!hub.messages.loaded) unawaited(hub.messages.refresh().then((_) => app.refresh(), onError: (Object _) {}));
    captures
      ..shareIndex = 0
      ..sharing = true;
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closeShareMenu() {
    captures.sharing = false;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  void showInFolder(String file) => app.services.openFolder?.call(p.dirname(file));

  void shareCommand(Command command) {
    final targets = shareTargets;
    switch (command) {
      case Command.up || Command.down:
        final next = (captures.shareIndex + (command == Command.down ? 1 : -1)).clamp(0, targets.length - 1);
        if (next == captures.shareIndex) return;
        captures.shareIndex = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        unawaited(share(targets[captures.shareIndex.clamp(0, targets.length - 1)]));
      case Command.back || Command.options || Command.left:
        closeShareMenu();
      default:
        break;
    }
  }

  Future<void> share(ShareTarget target) async {
    final shot = _shot;
    if (shot == null) return;
    if (target is PostShare) return openPostDraft();
    captures.sharing = false;
    app.refresh();
    switch (target) {
      case ChatShare(:final conversation):
        await sendShot(shot, conversation);
      case GalleryShare():
        await shareShotToGallery(shot);
      case FolderShare():
        showInFolder(shot);
      case PostShare():
        break;
    }
  }

  bool _mediaAllowed() {
    if (family.mediaAllowed) return true;
    app.show(FamilyGate.restrictedText('media_sharing'));
    return false;
  }

  /// A screenshot or clip into a conversation: made small enough, uploaded (sealed where the
  /// conversation is end-to-end encrypted), sent.
  Future<void> sendShot(String file, Conversation conversation) async {
    if (!_mediaAllowed() || captures.working) return;
    captures.working = true;
    app.show(T.text('cloudSending'));
    final clip = Screenshots.isClip(file);
    try {
      await hub.messages.sendMedia(
        conversation.id,
        kind: clip ? 'clip' : 'image',
        plain: () async => (await uploadShot(file)).id,
        sealed: () => uploadSealedShot(file),
      );
      app.sounds.play(Cue.select);
      app.show(T.format('cloudSentTo', [conversation.name(user?.id)]));
    } on Object catch (error) {
      app.show(cloudMessage(error));
    } finally {
      captures.working = false;
      app.refresh();
    }
  }

  /// Picture files of the user's own (picked or dropped) into [conversation], one after the
  /// other, as on the Mac. Each is drawn again from its pixels first, sealed or not, so no
  /// location or camera data goes along.
  Future<void> sendPictures(List<String> files, Conversation conversation) async {
    if (files.isEmpty || !_mediaAllowed() || captures.working) return;
    captures.working = true;
    app.show(T.text('cloudSending'));
    final limits = storage?.media ?? const MediaLimits();
    try {
      for (final file in files) {
        await hub.messages.sendMedia(
          conversation.id,
          kind: 'image',
          plain: () async {
            final photo = await _ownPicture(file, limits.image);
            return (await mediaFiles.upload('image', photo.bytes, photo.type)).id;
          },
          sealed: () async {
            final e2ee = hub.messages.e2ee;
            if (e2ee == null) throw const E2eeUnavailable();
            final photo = await _ownPicture(file, SealedPhoto.maxBytes);
            return e2ee.uploadSealed(
              file: photo.bytes,
              kind: 'image',
              type: photo.type,
              width: photo.width,
              height: photo.height,
            );
          },
        );
        app.sounds.play(Cue.select);
        app.show(T.format('cloudSentTo', [conversation.name(user?.id)]));
      }
    } on FormatException catch (error) {
      app.show(T.text(error.message == 'too big' ? 'cloudMediaTooBig' : 'cloudBadMedia'));
    } on E2eeUnavailable {
      app.show(T.format('e2eeNoDevice', [conversation.name(user?.id)]));
    } on FileSystemException {
      app.show(T.text('cloudBadMedia'));
    } on Object catch (error) {
      app.show(cloudMessage(error));
    } finally {
      captures.working = false;
      app.refresh();
    }
  }

  /// A picture file of the user's own made ready to go: drawn again from its pixels (as a PNG,
  /// smaller until it fits [limit]), so nothing of the file but the picture goes along.
  Future<SealedPhoto> _ownPicture(String file, int limit) async {
    final source = File(file);
    if (source.lengthSync() > SealedPhoto.maxSourceBytes) throw const FormatException('too big');
    return SealedPhoto.clean(source.readAsBytesSync(), limit: limit);
  }

  /// A screenshot or clip pinned to the end of the user's profile gallery.
  Future<void> shareShotToGallery(String file) async {
    if (!_mediaAllowed() || captures.working) return;
    final max = storage?.galleryMax ?? 12;
    captures.working = true;
    app.show(T.text('cloudPreparing'));
    try {
      // Full already: nothing goes up only to be deleted unpinned a day later.
      if ((await mediaFiles.myGallery()).length >= max) return app.show(T.format('cloudGalleryFull', [max]));
      final media = await uploadShot(file);
      if (!await mediaFiles.pinToGallery(media.id, max: max)) return app.show(T.format('cloudGalleryFull', [max]));
      app.sounds.play(Cue.select);
      app.show(T.text('cloudAddedToGallery'));
    } on Object catch (error) {
      app.show(cloudMessage(error));
    } finally {
      captures.working = false;
      app.refresh();
    }
  }

  /// Uploads a screenshot (as it is, or drawn again smaller past the limit) or a clip (made
  /// smaller past the limit) with a poster from its first second.
  Future<MediaItem> uploadShot(String file) async {
    final limits = storage?.media ?? const MediaLimits();
    final bytes = File(file).readAsBytesSync();
    if (!Screenshots.isClip(file)) {
      final (data, type) = await _readyPicture(bytes, limits);
      return mediaFiles.upload('image', data, type);
    }
    final (ready, temp) = await _readyClip(file, limits.clip);
    try {
      final media = await mediaFiles.upload('clip', File(ready).readAsBytesSync(), 'video/mp4');
      final still = await clipTools?.poster(ready);
      if (still != null && still.length <= limits.poster) {
        try {
          return await mediaFiles.setPoster(media.id, still, 'image/jpeg');
        } on Object {
          return media;
        }
      }
      return media;
    } finally {
      temp?.deleteSync(recursive: true);
    }
  }

  /// A picture as it goes: the file itself when the server takes it (it re-encodes it there), else
  /// drawn again smaller until it fits.
  Future<(Uint8List, String)> _readyPicture(Uint8List bytes, MediaLimits limits) async {
    final png = bytes.length > 8 && bytes[0] == 0x89 && bytes[1] == 0x50;
    final jpeg = bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8;
    if ((png || jpeg) && bytes.length <= limits.image) return (bytes, png ? 'image/png' : 'image/jpeg');
    final photo = await SealedPhoto.clean(bytes, limit: limits.image);
    return (photo.bytes, photo.type);
  }

  /// The clip as it goes, and the folder of a smaller copy made for it.
  Future<(String, Directory?)> _readyClip(String file, int maxBytes) async {
    final size = File(file).lengthSync();
    if (size <= maxBytes) return (file, null);
    final tools = clipTools;
    final ms = await tools?.durationMs(file);
    if (tools == null || ms == null) {
      if (tools == null && app.ffmpegTool.offered) throw const TogetherProblem(413, _ffmpegNeeded, 'ffmpeg is needed');
      throw const TogetherProblem(413, 'payload_too_large', 'The file is too big');
    }
    final temp = Directory.systemTemp.createTempSync('anyps5_share');
    try {
      return (await tools.shrink(file, maxBytes: maxBytes, durationMs: ms, folder: temp.path), temp);
    } on Object {
      temp.deleteSync(recursive: true);
      // An ffmpeg on this computer that lacks x264: the download can do what it cannot.
      if (await app.ffmpegTool.systemLacksX264()) {
        throw const TogetherProblem(413, _ffmpegNeeded, 'ffmpeg cannot make the clip smaller');
      }
      throw const TogetherProblem(413, 'payload_too_large', 'The file is too big');
    }
  }

  /// A screenshot (drawn again, so nothing of the file goes along) or a clip sealed for an
  /// end-to-end encrypted conversation.
  Future<SealedAttachment> uploadSealedShot(String file) async {
    final e2ee = hub.messages.e2ee;
    if (e2ee == null) throw const E2eeUnavailable();
    final limits = storage?.media ?? const MediaLimits();
    if (!Screenshots.isClip(file)) {
      final photo = await SealedPhoto.clean(File(file).readAsBytesSync());
      return e2ee.uploadSealed(
        file: photo.bytes,
        kind: 'image',
        type: photo.type,
        width: photo.width,
        height: photo.height,
      );
    }
    final (ready, temp) = await _readyClip(file, limits.clip - 16);
    try {
      final tools = clipTools;
      return await e2ee.uploadSealed(
        file: File(ready).readAsBytesSync(),
        kind: 'clip',
        type: 'video/mp4',
        durationMs: await tools?.durationMs(ready),
        poster: await tools?.poster(ready),
        posterType: 'image/jpeg',
      );
    } finally {
      temp?.deleteSync(recursive: true);
    }
  }

  /// A refusal about files on AnyTogether, in words.
  String cloudMessage(Object error) {
    if (error is TogetherProblem) {
      switch (error.code) {
        case 'quota_exceeded':
          return T.text('cloudQuotaFull');
        case 'payload_too_large':
          return T.text('cloudMediaTooBig');
        case _ffmpegNeeded:
          return T.text('clipNeedsFfmpeg');
        case 'bad_media' || 'bad_image':
          return T.text('cloudBadMedia');
        case 'storage_disabled':
          return T.text('cloudCloudOff');
      }
    }
    if (error is FormatException) return T.text('cloudBadMedia');
    return message(error);
  }

  // Writing a post from the gallery.

  /// The sheet over the gallery for the focused screenshot or clip: caption, who sees it, Post.
  Future<void> openPostDraft() async {
    final shot = _shot;
    if (shot == null || !_mediaAllowed()) return;
    captures
      ..sharing = false
      ..uploaded = null
      ..draftFile = shot
      ..draftRow = DraftRow.caption
      ..stage = PostStage.idle
      ..clipCheck = null
      ..clipMs = null
      ..draft = PostDraft(titleId: app.selectedGame?.titleId);
    app.sounds.play(Cue.select);
    app.refresh();
    if (Screenshots.isClip(shot)) await checkClip(shot);
  }

  /// Reads the clip's length and size, so a clip a post cannot take is said before it goes up.
  Future<void> checkClip(String file) async {
    final maxBytes = storage?.media.clip ?? PostLimits.clipBytes;
    final ms = await clipTools?.durationMs(file);
    final bytes = File(file).lengthSync();
    if (captures.draftFile != file) return;
    captures
      ..clipMs = ms
      ..clipCheck = ClipCheck.check(durationMs: ms, bytes: bytes, maxBytes: maxBytes);
    app.refresh();
  }

  void closePostDraft() {
    if (captures.stage != PostStage.idle) return;
    captures
      ..draft = null
      ..draftFile = null
      ..uploaded = null;
    if (app.editingRow == captionRow) app.stopEditing();
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// The caption's field.
  PanelRow get captionField => PanelRow(
    id: captionRow,
    title: '',
    kind: TextRow(
      captures.draft?.caption ?? '',
      (text) => captures.draft?.caption = String.fromCharCodes(text.runes.take(PostLimits.caption)),
      submit: () {
        captures.draftRow = DraftRow.post;
        app.refresh();
      },
      hint: T.text('capturesCaptionPlaceholder'),
    ),
  );

  /// Up and down through caption, who sees it and Post; Enter types, switches or posts; left and
  /// right pick Friends or Public; Back leaves the sheet.
  void postDraftCommand(Command command) {
    if (captures.draft == null) return;
    switch (command) {
      case Command.up || Command.down:
        final next = captures.draftRow.index + (command == Command.down ? 1 : -1);
        if (next < 0 || next >= DraftRow.values.length) return;
        captures.draftRow = DraftRow.values[next];
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right:
        if (captures.draftRow != DraftRow.visibility) return;
        setDraftVisibility(command == Command.right ? PostVisibility.public : PostVisibility.friends);
      case Command.select:
        switch (captures.draftRow) {
          case DraftRow.caption:
            app.startEditing(captionRow);
          case DraftRow.visibility:
            setDraftVisibility(
              captures.draft?.visibility == PostVisibility.public ? PostVisibility.friends : PostVisibility.public,
            );
          case DraftRow.post:
            unawaited(postCapture());
        }
      case Command.back || Command.options:
        closePostDraft();
      default:
        break;
    }
  }

  void setDraftVisibility(PostVisibility visibility) {
    final draft = captures.draft;
    if (draft == null || draft.visibility == visibility) return;
    draft.visibility = visibility;
    app.sounds.play(Cue.move);
    app.refresh();
  }

  bool get canPostDraft =>
      captures.draft != null && captures.stage == PostStage.idle && captures.clipCheck?.blocks != true;

  String get clipTooLongText => T.format('capturesClipTooLong', [clock(captures.clipMs ?? 0)]);

  /// 1:05 for 65 seconds.
  static String clock(int ms) {
    final seconds = (ms / 1000).round();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  /// Uploads the capture (once), makes the post, and puts it at the top of Captures.
  Future<void> postCapture() async {
    final draft = captures.draft;
    final file = captures.draftFile;
    if (draft == null || file == null || captures.stage != PostStage.idle) return;
    if (captures.clipCheck?.blocks == true) {
      app.sounds.play(Cue.back);
      return app.show(clipTooLongText);
    }
    if (!_mediaAllowed()) return;
    app.sounds.play(Cue.select);
    captures.stage = PostStage.uploading;
    app.refresh();
    try {
      final String media;
      if (captures.uploaded case (final String uploadedFile, final String id) when uploadedFile == file) {
        media = id;
      } else {
        media = (await uploadShot(file)).id;
        captures.uploaded = (file, media);
      }
      captures.stage = PostStage.posting;
      app.refresh();
      final post = await posts.create([media], draft);
      if (captures.feed.loaded) captures.feed.upsert(post);
      captures
        ..stage = PostStage.idle
        ..draft = null
        ..draftFile = null
        ..uploaded = null;
      if (app.editingRow == captionRow) app.stopEditing();
      app.sounds.play(Cue.select);
      app.show(T.text('capturesPosted'));
    } on Object catch (error) {
      captures.stage = PostStage.idle;
      if (PostRefusal.of(error) == PostRefusal.familyFriends) draft.visibility = PostVisibility.friends;
      app.show(postMessage(error));
    }
    app.refresh();
  }

  /// A refusal about a post or a comment, in words.
  String postMessage(Object error) => switch (PostRefusal.of(error)) {
    PostRefusal.commentsOff => T.text('capturesRefusedCommentsOff'),
    PostRefusal.linkBlocked => T.text('capturesRefusedLink'),
    PostRefusal.accountMuted => T.text('capturesRefusedMuted'),
    PostRefusal.familyFriends => T.text('capturesRefusedFamilyFriends'),
    PostRefusal.family => message(error),
    PostRefusal.rateLimited => T.text('capturesRefusedRateLimited'),
    PostRefusal.storageDisabled => T.text('capturesRefusedStorage'),
    PostRefusal.clipTooLong => T.text('capturesClipTooLongDetail'),
    PostRefusal.badMedia => T.text('capturesRefusedBadMedia'),
    PostRefusal.gone => T.text('capturesRefusedGone'),
    PostRefusal.quotaFull || PostRefusal.tooBig || null => cloudMessage(error),
  };

  // The feed.

  List<CaptureAction> captureActions(Post post) => [
    CaptureAction.like,
    CaptureAction.comments,
    CaptureAction.view,
    if (post.mine) CaptureAction.delete,
  ];

  Post? get focusedCapture => captures.feed.items.elementAtOrNull(captures.index);

  /// Friends › Captures.
  void openCaptures() {
    if (!signedIn) return;
    captures.follow(user?.id);
    final from = app.overlay;
    if (from != null && from != Layer.captures && from != Layer.profile) captures.back = app.spot;
    captures
      ..index = 0
      ..action = 0
      ..armedPost = null
      ..thread = null
      ..viewing = null;
    app.open(Layer.captures);
    unawaited(loadCaptures());
  }

  Future<void> loadCaptures() async {
    try {
      final (items, next) = await posts.captures();
      captures.feed.load(items, next);
      captures
        ..failed = false
        ..index = captures.index.clamp(0, items.isEmpty ? 0 : items.length - 1);
    } on Object catch (error) {
      // A server that keeps no files says so; the Captures screen says that instead of a failure.
      if (PostRefusal.of(error) == PostRefusal.storageDisabled) app.saveSync.info = StorageInfo.disabled;
      captures.failed = !captures.feed.loaded;
    }
    app.refresh();
  }

  /// The next, older page, once the focus nears the end.
  Future<void> loadOlderCaptures() async {
    final before = captures.feed.next;
    if (before == null || captures.loadingOlder) return;
    captures.loadingOlder = true;
    try {
      final (items, next) = await posts.captures(before: before);
      captures.feed.loadOlder(items, next);
    } on Object {
      // Tried again when the focus moves on.
    } finally {
      captures.loadingOlder = false;
      app.refresh();
    }
  }

  void closeCaptures() {
    final back = captures.back;
    captures.back = null;
    app.returnTo(back);
  }

  /// Up and down through the posts, left and right through Like, Comments, View (and Delete on
  /// one's own), Enter does it, △ opens the author's profile.
  void capturesCommand(Command command) {
    if (captures.viewing != null) {
      if (command == Command.back || command == Command.select || command == Command.options) closeViewer();
      return;
    }
    if (captures.thread != null) return commentsCommand(command);
    final items = captures.feed.items;
    switch (command) {
      case Command.up || Command.down:
        if (items.isEmpty) return;
        final next = (captures.index + (command == Command.down ? 1 : -1)).clamp(0, items.length - 1);
        if (next == captures.index) return;
        captures
          ..index = next
          ..action = 0
          ..armedPost = null;
        if (next >= items.length - prefetch) unawaited(loadOlderCaptures());
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right:
        final post = focusedCapture;
        if (post == null) return;
        final next = (captures.action + (command == Command.right ? 1 : -1)).clamp(0, captureActions(post).length - 1);
        if (next == captures.action) return;
        captures
          ..action = next
          ..armedPost = null;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        final post = focusedCapture;
        if (post == null) return;
        final actions = captureActions(post);
        runCaptureAction(actions[captures.action.clamp(0, actions.length - 1)], post);
      case Command.options:
        final post = focusedCapture;
        if (post != null) unawaited(openProfile(post.author.handle, card: post.author));
      case Command.back:
        if (captures.armedPost != null) {
          captures.armedPost = null;
          app.sounds.play(Cue.back);
          app.refresh();
        } else {
          closeCaptures();
        }
      default:
        break;
    }
  }

  void runCaptureAction(CaptureAction action, Post post) {
    switch (action) {
      case CaptureAction.like:
        unawaited(toggleLike(post));
      case CaptureAction.comments:
        unawaited(openComments(post));
      case CaptureAction.view:
        viewCapture(post);
      case CaptureAction.delete:
        if (captures.armedPost == post.id) {
          unawaited(deleteCapture(post));
        } else {
          captures.armedPost = post.id;
          app.sounds.play(Cue.move);
          app.refresh();
        }
    }
  }

  /// A click on a post's action: the keys go there and it is done.
  void tapCaptureAction(int index, CaptureAction action) {
    final post = captures.feed.items.elementAtOrNull(index);
    if (post == null) return;
    captures
      ..index = index
      ..action = captureActions(post).indexOf(action).clamp(0, 3);
    runCaptureAction(action, post);
  }

  /// The like shows at once, then what the server says; a failure puts the old count back.
  Future<void> toggleLike(Post post) async {
    final before = captures.feed.toggleLike(post.id);
    if (before == null) return;
    app.sounds.play(Cue.select);
    app.refresh();
    try {
      final (likes, liked) = await posts.setLiked(!before.$2, post.id);
      captures.feed.setLikes(post.id, likes, liked);
    } on Object catch (error) {
      captures.feed.setLikes(post.id, before.$1, before.$2);
      if (PostRefusal.of(error) == PostRefusal.gone) captures.feed.remove(post.id);
      app.show(postMessage(error));
    }
    app.refresh();
  }

  /// The picture or the clip over the whole screen (a clip plays in the launcher, as on the Mac).
  void viewCapture(Post post) {
    final media = post.clip ?? post.shown.firstOrNull;
    if (media == null) return;
    captures.viewing = media;
    app.sounds.play(Cue.select);
    app.refresh();
  }

  void closeViewer() {
    captures.viewing = null;
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// A picture behind a signed link, read once (the cache leaves out the signature, so a link
  /// read again finds the same picture).
  Future<Uint8List> picture(String link) {
    final key = link.split('?').first;
    final known = captures.pictures[key];
    if (known != null) return known;
    if (captures.pictures.length >= 60) captures.pictures.remove(captures.pictures.keys.first);
    final loading = account.fetchBytes(link, limit: 20 * 1024 * 1024);
    captures.pictures[key] = loading;
    loading.then(
      (_) {},
      onError: (Object _) {
        captures.pictures.remove(key);
      },
    );
    return loading;
  }

  Future<void> deleteCapture(Post post) async {
    try {
      await posts.delete(post.id);
      captures.feed.remove(post.id);
      captures
        ..armedPost = null
        ..action = 0
        ..index = captures.index.clamp(0, captures.feed.items.isEmpty ? 0 : captures.feed.items.length - 1);
      app.show(T.text('capturesDeleted'));
    } on Object catch (error) {
      app.show(postMessage(error));
    }
    app.refresh();
  }

  // Comments.

  Future<void> openComments(Post post) async {
    captures
      ..commentsFailed = false
      ..line = 0
      ..composer = quickComments.length
      ..commentDraft = ''
      ..replyTo = null
      ..armedComment = null
      ..thread = CommentThread(post.id);
    app.sounds.play(Cue.select);
    app.refresh();
    try {
      final (items, next) = await posts.comments(post.id);
      final thread = captures.thread;
      if (thread == null || thread.postId != post.id) return;
      thread.load(items, next);
      // The count on the card follows what is there now.
      final seen = thread.lines.length;
      final shown = captures.feed.items.where((item) => item.id == post.id).firstOrNull?.comments;
      if (next == null && shown != null && shown != seen) captures.feed.addComments(post.id, seen - shown);
    } on Object {
      captures.commentsFailed = true;
    }
    app.refresh();
  }

  Future<void> loadOlderComments() async {
    final thread = captures.thread;
    final before = thread?.next;
    if (thread == null || before == null || captures.loadingOlderComments) return;
    captures.loadingOlderComments = true;
    try {
      final (items, next) = await posts.comments(thread.postId, before: before);
      if (identical(captures.thread, thread)) thread.loadOlder(items, next);
    } on Object {
      // Tried again when the focus moves on.
    } finally {
      captures.loadingOlderComments = false;
      app.refresh();
    }
  }

  void closeComments() {
    captures.thread = null;
    if (app.editingRow == commentRow) app.stopEditing();
    app.sounds.play(Cue.back);
    app.refresh();
  }

  /// The post the open comments are on.
  Post? get commentsPost {
    final id = captures.thread?.postId;
    return id == null ? null : captures.feed.items.where((post) => post.id == id).firstOrNull;
  }

  /// The comment field.
  PanelRow get commentField => PanelRow(
    id: commentRow,
    title: '',
    kind: TextRow(
      captures.commentDraft,
      (text) => captures.commentDraft = String.fromCharCodes(text.runes.take(PostLimits.comment)),
      submit: () => unawaited(sendComment(captures.commentDraft)),
      hint: T.text('capturesWrite'),
    ),
  );

  /// Row 0 is the composer (left and right through the quick comments and the field); below it
  /// the comments: Enter replies, △ deletes one's own (pressed twice), Back steps back.
  void commentsCommand(Command command) {
    final thread = captures.thread;
    if (thread == null) return;
    final lines = thread.lines;
    final open = commentsPost?.commentsOff != true;
    switch (command) {
      case Command.up || Command.down:
        final first = open ? 0 : 1;
        final next = (captures.line + (command == Command.down ? 1 : -1)).clamp(first, lines.length);
        if (next == captures.line || (next > 0 && next - 1 >= lines.length)) return;
        captures
          ..line = next
          ..armedComment = null;
        if (next >= lines.length - prefetch) unawaited(loadOlderComments());
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.left || Command.right:
        if (captures.line != 0 || !open) return;
        final next = (captures.composer + (command == Command.right ? 1 : -1)).clamp(0, quickComments.length);
        if (next == captures.composer) return;
        captures.composer = next;
        app.sounds.play(Cue.move);
        app.refresh();
      case Command.select:
        if (captures.line == 0) {
          if (!open) return;
          if (captures.composer < quickComments.length) {
            unawaited(sendComment(quickComments[captures.composer]));
          } else {
            app.startEditing(commentRow);
          }
        } else if (open && captures.line - 1 < lines.length) {
          // Replies are one level: answering a reply answers the comment it is under.
          final line = lines[captures.line - 1];
          final top = (line.parent == null ? null : thread.comment(line.parent!)) ?? line.comment;
          captures
            ..replyTo = top
            ..line = 0
            ..composer = quickComments.length;
          app.sounds.play(Cue.select);
          app.startEditing(commentRow);
        }
      case Command.options:
        if (captures.line == 0 || captures.line - 1 >= lines.length) return;
        final comment = lines[captures.line - 1].comment;
        if (!comment.canDelete) return;
        if (captures.armedComment == comment.id) {
          unawaited(deleteComment(comment));
        } else {
          captures.armedComment = comment.id;
          app.sounds.play(Cue.move);
          app.refresh();
        }
      case Command.back:
        if (captures.armedComment != null) {
          captures.armedComment = null;
          app.sounds.play(Cue.back);
          app.refresh();
        } else if (captures.replyTo != null) {
          captures.replyTo = null;
          app.sounds.play(Cue.back);
          app.refresh();
        } else {
          closeComments();
        }
      default:
        break;
    }
  }

  Future<void> sendComment(String text) async {
    final thread = captures.thread;
    final words = text.trim();
    if (thread == null || captures.sending || words.isEmpty) return;
    captures.sending = true;
    try {
      final comment = await posts.comment(thread.postId, words, replyTo: captures.replyTo?.id);
      if (!identical(captures.thread, thread)) return;
      thread.add(comment);
      captures.feed.addComments(thread.postId, 1);
      captures
        ..commentDraft = ''
        ..replyTo = null;
      if (app.editingRow == commentRow) app.stopEditing();
      app.sounds.play(Cue.select);
      app.show(T.text('capturesCommentSent'));
    } on Object catch (error) {
      app.show(postMessage(error));
    } finally {
      captures.sending = false;
      app.refresh();
    }
  }

  Future<void> deleteComment(PostComment comment) async {
    final thread = captures.thread;
    if (thread == null) return;
    try {
      await posts.deleteComment(comment.id, thread.postId);
      final gone = thread.remove(comment.id);
      captures.feed.addComments(thread.postId, -gone);
      captures
        ..armedComment = null
        ..line = captures.line.clamp(0, thread.lines.length);
      app.show(T.text('capturesCommentDeleted'));
    } on Object catch (error) {
      app.show(postMessage(error));
    }
    app.refresh();
  }

  /// The feed follows the server's word: a new post from a friend, counts that changed, one gone.
  void capturesEvent(TogetherEvent event) {
    if (!captures.feed.loaded) return;
    final data = event.json;
    switch (event.type) {
      case 'post.new':
        try {
          captures.feed.upsert(Post.fromJson(data));
        } on Object {
          return;
        }
      case 'post.counts':
        final id = data['postId'];
        if (id is! String) return;
        final at = captures.feed.indexOf(id);
        if (at < 0) return;
        final post = captures.feed.items[at];
        captures.feed.items = [...captures.feed.items]
          ..[at] = post.copyWith(
            likes: (data['likes'] as num?)?.toInt() ?? post.likes,
            comments: (data['comments'] as num?)?.toInt() ?? post.comments,
          );
      case 'post.removed':
        final id = data['postId'];
        if (id is! String) return;
        captures.feed.remove(id);
        captures.index = captures.index.clamp(0, captures.feed.items.isEmpty ? 0 : captures.feed.items.length - 1);
      default:
        return;
    }
    app.refresh();
  }
}

extension<T extends Object> on T {
  R let<R>(R Function(T) transform) => transform(this);
}
