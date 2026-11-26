import 'dart:convert';
import 'dart:io';

/// One person listed by GitHub for a repository's contributors.
class GithubContributor {
  const GithubContributor({
    required this.login,
    required this.avatarUrl,
    required this.htmlUrl,
    required this.contributions,
  });

  final String login;
  final String avatarUrl;
  final String htmlUrl;
  final int contributions;

  factory GithubContributor.fromJson(Map<String, dynamic> json) {
    return GithubContributor(
      login: json['login'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ?? '',
      contributions: json['contributions'] as int? ?? 0,
    );
  }
}

/// Contributors of a GitHub repository, read from the public API the same way releases are.
class GithubContributors {
  GithubContributors({
    Uri? api,
    this.repository = defaultRepository,
    HttpClient Function()? client,
  })  : api = api ?? Uri.parse('https://api.github.com'),
        _client = client ?? HttpClient.new;

  static const defaultRepository = 'AnyTogether/AnyPS5-Desktop';

  /// The owner of the launcher repository, shown first in Settings › About.
  static const ownerLogin = 'utkuhalis';

  /// Display name for the owner when the API has not answered yet.
  static const ownerName = 'Utku Halis';

  final Uri api;
  final String repository;
  final HttpClient Function() _client;

  /// The people who have committed to [repository], highest contribution first.
  /// Bots (logins ending in [bot]) are left out. An empty list when GitHub cannot be reached.
  Future<List<GithubContributor>> fetch({int perPage = 30}) async {
    final client = _client()..connectionTimeout = const Duration(seconds: 15);
    try {
      final base = api.toString().endsWith('/') ? api : Uri.parse('$api/');
      final path = 'repos/$repository/contributors?per_page=$perPage';
      final request = await client.getUrl(base.resolve(path));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'AnyPS5-Desktop')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(const Duration(seconds: 20));
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return const [];
      final json = jsonDecode(body);
      if (json is! List<dynamic>) return const [];
      return [
        for (final entry in json)
          if (entry is Map<String, dynamic>)
            GithubContributor.fromJson(entry),
      ].where((c) => c.login.isNotEmpty && !c.login.endsWith('[bot]')).toList();
    } on Object {
      return const [];
    } finally {
      client.close(force: true);
    }
  }
}
