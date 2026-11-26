import 'package:anyps5_desktop/core/gamepad/pad_navigation.dart';
import 'package:anyps5_desktop/core/github_contributors.dart';
import 'package:anyps5_desktop/ui/app_model.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';

/// Settings › About's credits: the owner first, also with GitHub out of reach, then up to twelve
/// contributors, each face reached with the keys, the pad or the mouse and opening that person's
/// profile, and See all on GitHub. The macOS launcher's AboutContributorsTests.
class FakeContributors extends GithubContributors {
  FakeContributors(this.people);

  final List<GithubContributor> people;
  int asked = 0;

  @override
  Future<List<GithubContributor>> fetch({int perPage = 30}) async {
    asked++;
    return people;
  }
}

GithubContributor person(String login, int contributions, {String? avatar}) => GithubContributor(
  login: login,
  avatarUrl: avatar ?? 'https://avatars.githubusercontent.com/$login',
  htmlUrl: 'https://github.com/$login',
  contributions: contributions,
);

void main() {
  Fixture? fixture;

  tearDown(() {
    fixture?.model.dispose();
    fixture?.dispose();
    fixture = null;
    T.language = Language.english;
  });

  /// The launcher in Settings › About, its contributors from [people] (none: no source at all).
  Future<AppModel> about([List<GithubContributor>? people]) async {
    fixture = makeFixture(contributors: people == null ? null : FakeContributors(people));
    final model = fixture!.model..open(Layer.settings);
    model.panelCategory = model.panelCategories().indexWhere((category) => category.id == 'about');
    await pumpEventQueue();
    return model;
  }

  List<PanelRow> rows(AppModel model) => model.panelCategories()[model.panelCategory].rows;
  int gridIndex(AppModel model) => rows(model).indexWhere((row) => row.id == 'contributorsGrid');
  ContributorsGridRow grid(AppModel model) => rows(model)[gridIndex(model)].kind as ContributorsGridRow;

  final team = [person('B-Howell', 119), person('UtkuHalis', 856), person('Lenny4250gh', 72), person('QguAr71', 1)];

  test('without GitHub the owner is there alone, first, and opens his profile', () async {
    final model = await about();
    final ids = rows(model).map((row) => row.id).toList();
    expect(ids, isNot(contains('author')), reason: 'the credits take Made by\'s place');
    expect(ids.indexOf('contributorsAll'), ids.indexOf('contributorsGrid') + 1);
    expect(ids.indexOf('github'), ids.indexOf('contributorsAll') + 1);
    final credits = grid(model);
    expect(credits.owner.login, 'Utku Halis');
    expect(credits.owner.htmlUrl, 'https://github.com/utkuhalis');
    expect(credits.owner.avatarUrl, isEmpty, reason: 'his initial until GitHub answers');
    expect(credits.people, isEmpty);
    expect(rows(model)[gridIndex(model)].focusable, isTrue, reason: 'the keys and the pad reach it');
    model.activateRow(gridIndex(model));
    expect(fixture!.opened.last, Uri.parse('https://github.com/utkuhalis'));
  });

  test('GitHub answering no one (offline, an error) leaves the owner alone too', () async {
    final model = await about(const []);
    expect(grid(model).owner.login, 'Utku Halis');
    expect(grid(model).people, isEmpty);
  });

  test('the owner is taken out of the list and shown first with GitHub\'s picture', () async {
    final model = await about(team);
    final credits = grid(model);
    expect(credits.owner.login, 'Utku Halis', reason: 'his name, not his login');
    expect(credits.owner.avatarUrl, 'https://avatars.githubusercontent.com/UtkuHalis');
    expect(credits.owner.contributions, 856);
    expect(credits.people.map((c) => c.login), ['B-Howell', 'Lenny4250gh', 'QguAr71'], reason: 'GitHub\'s order');
    expect(credits.faces.first, same(credits.owner));
    expect((fixture!.model.services.contributors! as FakeContributors).asked, 1);
    model.panelCategories();
    model.panelCategories();
    expect((fixture!.model.services.contributors! as FakeContributors).asked, 1, reason: 'asked once');
  });

  test('at most twelve others; See all on GitHub has the rest', () async {
    final model = await about([for (var index = 0; index < 20; index++) person('person$index', 100 - index)]);
    expect(grid(model).people.map((c) => c.login), [for (var index = 0; index < 12; index++) 'person$index']);
    final all = rows(model).firstWhere((row) => row.id == 'contributorsAll');
    expect(all.title, 'See all on GitHub');
    expect(all.detail, 'github.com/AnyTogether/AnyPS5-Desktop/graphs/contributors');
    (all.kind as ActionRow).run();
    expect(fixture!.opened.last, Uri.parse('https://github.com/AnyTogether/AnyPS5-Desktop/graphs/contributors'));
  });

  test('commits are counted in the language shown, one and many', () async {
    expect(T.format('contributorCommitsOne', [T.number(1)]), '1 commit');
    expect(T.format('contributorCommits', [T.number(1180)]), '1,180 commits');
    T.language = Language.byCode('de');
    expect(T.format('contributorCommits', [T.number(1180)]), '1.180 Commits');
    expect(T.text('contributors'), 'Mitwirkende');
  });

  test('the keys: ← and → go from face to face, Enter opens that profile', () async {
    final model = await about(team);
    model.panelRow = gridIndex(model);
    model.command(Command.right);
    expect(grid(model).selected, 1);
    model.command(Command.right);
    expect(grid(model).selected, 2);
    model.command(Command.select);
    expect(fixture!.opened.last, Uri.parse('https://github.com/Lenny4250gh'));
    model.command(Command.left);
    model.command(Command.left);
    expect(grid(model).selected, 0);
    model.command(Command.select);
    expect(fixture!.opened.last, Uri.parse('https://github.com/UtkuHalis'));
    expect(model.panelRow, gridIndex(model), reason: 'the focus stays on the credits');
    model.command(Command.down);
    expect(rows(model)[model.panelRow].id, 'contributorsAll', reason: '↓ goes on to See all');
  });

  test('the pad: ← and → at once, Cross opens, ← on the owner back to the sections', () async {
    final model = await about(team);
    model.panelSections = false;
    model.panelRow = gridIndex(model);
    model.padCommand(PadCommand.right);
    model.padCommand(PadCommand.right);
    model.padCommand(PadCommand.right);
    expect(grid(model).selected, 3);
    model.padCommand(PadCommand.right);
    expect(grid(model).selected, 3, reason: 'stops at the last face');
    expect(model.panelSections, isFalse);
    model.padCommand(PadCommand.select);
    expect(fixture!.opened.last, Uri.parse('https://github.com/QguAr71'));
    for (var step = 0; step < 3; step++) {
      model.padCommand(PadCommand.left);
    }
    expect(grid(model).selected, 0);
    expect(model.panelSections, isFalse);
    model.padCommand(PadCommand.left);
    expect(model.panelSections, isTrue, reason: 'as from any other row');
  });

  testWidgets('a click on a face opens that profile and leaves the focus on it', (tester) async {
    fixture = makeFixture(
      contributors: FakeContributors([for (final c in team) person(c.login, c.contributions, avatar: '')]),
    );
    final model = fixture!.model;
    await pumpLauncher(tester, model);
    model.open(Layer.settings);
    model.selectCategory(model.panelCategories().indexWhere((category) => category.id == 'about'));
    await settle(tester);
    final face = find.byKey(const ValueKey('contributor-2'));
    await tester.ensureVisible(face);
    await settle(tester);
    expect(find.text('72 commits'), findsOneWidget);
    expect(find.text('1 commit'), findsOneWidget);
    await tester.tap(face);
    await settle(tester);
    expect(fixture!.opened.last, Uri.parse('https://github.com/Lenny4250gh'));
    expect(model.panelRow, gridIndex(model));
    expect(grid(model).selected, 2);
  });
}
