import 'account.dart';
import 'posts.dart';
import 'profiles.dart';

/// Photos and clips on AnyTogether, the user's own: uploaded (POST /me/media, checked and
/// re-encoded there), a clip's poster, and the profile's gallery. As the Mac's TogetherStorage
/// media calls.
class MediaFiles {
  const MediaFiles(this.account);

  final TogetherAccount account;

  static MediaItem _media(Map<String, dynamic> answer) {
    final view = answer['media'] is Map<String, dynamic> ? answer['media'] as Map<String, dynamic> : answer;
    final media = MediaItem.fromJson(view);
    if (media == null) throw const TogetherProblem(500, 'internal', 'No media came back');
    return media;
  }

  /// A picture (image) or a clip (clip) up as the user's media.
  Future<MediaItem> upload(String kind, List<int> bytes, String contentType) async =>
      _media(await account.upload('POST', 'me/media?kind=$kind', bytes, contentType));

  /// The still a clip shows before it plays.
  Future<MediaItem> setPoster(String id, List<int> bytes, String contentType) async =>
      _media(await account.upload('PUT', 'me/media/${Uri.encodeComponent(id)}/poster', bytes, contentType));

  static List<MediaItem> _items(Map<String, dynamic> answer) => [
    for (final item in answer['items'] as List<dynamic>? ?? const []) ?MediaItem.fromJson(item),
  ];

  /// A profile's gallery, as the owner's setting shows it to this user.
  Future<Section<List<MediaItem>>> gallery(String handle) async {
    try {
      return SectionShown(_items(await account.call('GET', 'users/${Uri.encodeComponent(handle)}/gallery')));
    } on TogetherProblem catch (problem) {
      return Profiles.isPrivate(problem) ? const SectionPrivate() : const SectionFailed();
    } on Object {
      return const SectionFailed();
    }
  }

  /// The profile gallery's photos and clips, in order.
  Future<List<MediaItem>> myGallery() async => _items(await account.call('GET', 'me/gallery'));

  Future<List<MediaItem>> setGallery(List<String> ids) async =>
      _items(await account.call('PUT', 'me/gallery', {'items': ids}));

  /// Pins a piece of the user's media at the end of the gallery; false when it is full.
  Future<bool> pinToGallery(String id, {int max = 12}) async {
    final current = [for (final item in await myGallery()) item.id];
    if (current.contains(id)) return true;
    if (current.length >= max) return false;
    await setGallery([...current, id]);
    return true;
  }
}
