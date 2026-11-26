import 'dart:convert';
import 'dart:io';

import 'package:anyps5_desktop/core/github_contributors.dart';
import 'package:test/test.dart';

/// Settings › About's credits as GitHub's contributors API gives them: people in its order,
/// bots left out, and an empty list for anything but a list of people (an error status, other
/// JSON, no network).
void main() {
  late HttpServer server;
  late List<HttpRequest> requests;
  var status = HttpStatus.ok;
  var body = '[]';

  setUp(() async {
    requests = [];
    status = HttpStatus.ok;
    body = '[]';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(request);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  GithubContributors source() => GithubContributors(api: Uri.parse('http://127.0.0.1:${server.port}/api'));

  Map<String, Object?> person(String login, int contributions) => {
    'login': login,
    'avatar_url': 'https://avatars.githubusercontent.com/$login',
    'html_url': 'https://github.com/$login',
    'contributions': contributions,
    'type': login.endsWith('[bot]') ? 'Bot' : 'User',
  };

  test('the people in GitHub\'s order, bots and nameless entries left out', () async {
    body = jsonEncode([
      person('utkuhalis', 856),
      person('dependabot[bot]', 40),
      person('B-Howell', 119),
      {'avatar_url': 'https://avatars.githubusercontent.com/x', 'contributions': 3},
      'not a person',
      person('Lenny4250gh', 72),
      person('github-actions[bot]', 1),
    ]);
    final people = await source().fetch();
    expect(people.map((c) => c.login), ['utkuhalis', 'B-Howell', 'Lenny4250gh']);
    final lenny = people.last;
    expect(lenny.avatarUrl, 'https://avatars.githubusercontent.com/Lenny4250gh');
    expect(lenny.htmlUrl, 'https://github.com/Lenny4250gh');
    expect(lenny.contributions, 72);
    final request = requests.single;
    expect(request.uri.path, '/api/repos/${GithubContributors.defaultRepository}/contributors');
    expect(request.uri.queryParameters['per_page'], '30');
    expect(request.headers.value(HttpHeaders.acceptHeader), 'application/vnd.github+json');
  });

  test('another repository is asked for by its own path', () async {
    await GithubContributors(api: Uri.parse('http://127.0.0.1:${server.port}/api/'), repository: 'a/b').fetch();
    expect(requests.single.uri.path, '/api/repos/a/b/contributors');
  });

  test('an error status gives no one', () async {
    status = HttpStatus.forbidden;
    body = jsonEncode([person('utkuhalis', 856)]);
    expect(await source().fetch(), isEmpty);
    status = HttpStatus.notFound;
    expect(await source().fetch(), isEmpty);
  });

  test('JSON that is not a list of people gives no one', () async {
    body = jsonEncode({'message': 'API rate limit exceeded'});
    expect(await source().fetch(), isEmpty);
    body = 'not JSON at all';
    expect(await source().fetch(), isEmpty);
  });

  test('no network gives no one', () async {
    final port = server.port;
    await server.close(force: true);
    final offline = GithubContributors(api: Uri.parse('http://127.0.0.1:$port/api'));
    expect(await offline.fetch(), isEmpty);
    // tearDown closes it again.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });
}
