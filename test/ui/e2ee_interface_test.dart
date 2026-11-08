import 'package:anyps5_desktop/core/together/e2ee.dart';
import 'package:anyps5_desktop/core/together/e2ee_client.dart';
import 'package:anyps5_desktop/core/together/messages.dart';
import 'package:anyps5_desktop/core/together/people.dart';
import 'package:anyps5_desktop/ui/app_model.dart' hide Command, GameState;
import 'package:anyps5_desktop/ui/app_model.dart' as launcher show Command;
import 'package:anyps5_desktop/ui/launcher.dart';
import 'package:anyps5_desktop/ui/strings.dart';
import 'package:anyps5_desktop/ui/together_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/ui_support.dart';
import 'together_interface_test.dart' show signedInPreview;

/// End-to-end encrypted direct messages on screen, headless: the lock under the conversation's
/// name, the devices-changed notice, the messages this device cannot read, the sheet with the
/// safety number and both people's devices, and a conversation that is not encrypted.
void main() {
  late Fixture fixture;
  late AppModel model;

  const ana = Person(id: 'u-ana', handle: 'ana', displayName: 'Ana');
  const me = Person(id: 'u-me', handle: 'utku', displayName: 'Utku Halis');
  const sealed = SealedMessage(device: 'd', eph: 'e', nonce: 'n', body: 'b', sig: 's', keys: {});

  PublicDevice device(String id, String name) =>
      PublicDevice(id: id, signKey: '', boxKey: '', sig: '', name: name, createdAt: DateTime(2026, 11, 3, 12));

  ConversationLock lock(EncryptionState state, {DevicesChange? notice, bool compared = false}) => ConversationLock(
    state: state,
    mine: UserDevices('u-me', [device('a1', 'DESKTOP-7Q2'), device('a2', 'Utku’s iPhone')], const []),
    theirs: UserDevices('u-ana', [device('b1', 'Ana’s MacBook Air')], const []),
    safetyNumber: state == EncryptionState.on ? '444833229223133859356397456524514178834181618208160147718510' : null,
    compared: compared,
    notice: notice,
  );

  ChatMessage message(int seq, String author, String? text, {SealState? seal = SealState.opened}) => ChatMessage(
    id: 'm$seq',
    conversationId: 'c-ana',
    seq: seq,
    authorId: author,
    text: text,
    createdAt: DateTime.utc(2026, 11, 6, 20, seq),
    sealed: seal == null ? null : sealed,
    seal: seal,
  );

  void conversationWithAna(List<ChatMessage> thread, ConversationLock shown) {
    signedInPreview(model);
    model.together.hub.messages
      ..conversations = [
        Conversation(
          id: 'c-ana',
          group: false,
          title: null,
          members: const [me, ana],
          lastSeq: thread.length,
          readSeq: thread.length,
          lastMessage: thread.last,
          updatedAt: DateTime.utc(2026, 11, 6),
          encrypted: shown.state != EncryptionState.off,
        ),
      ]
      ..loaded = true
      ..openId = 'c-ana'
      ..thread = thread;
    model.together.e2ee.showLock('c-ana', shown);
    model.open(Layer.messages);
    model.together
      ..messagesInThread = true
      ..messageFocus = 5;
  }

  List<ChatMessage> encryptedThread() => [
    message(1, 'u-ana', null, seal: SealState.beforeDevice),
    message(2, 'u-ana', 'Did you get the new Neon Alley patch?'),
    message(3, 'u-me', 'Yes, downloading now. Party at nine?'),
    message(4, 'u-ana', null, seal: SealState.undecryptable),
    message(5, 'u-ana', 'Nine works. Bring Cem.'),
  ];

  tearDown(() {
    T.language = Language.english;
    fixture.dispose();
  });

  testWidgets('golden: an encrypted conversation, its devices changed, and what this device cannot read', (
    tester,
  ) async {
    fixture = makeFixture();
    model = fixture.model;
    conversationWithAna(encryptedThread(), lock(EncryptionState.on, notice: DevicesChange.theirs));
    await pumpLauncher(tester, model);
    expect(find.text('End-to-end encrypted'), findsOneWidget);
    expect(find.text("Ana's devices changed. Compare the safety number again."), findsOneWidget);
    expect(find.text('Sent before this device was added.'), findsOneWidget);
    expect(find.text('This message could not be decrypted.'), findsOneWidget);
    expect(find.text('Nine works. Bring Cem.'), findsWidgets);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_e2ee.png'));
  });

  testWidgets('golden: the encryption sheet, opened from the conversation menu', (tester) async {
    fixture = makeFixture();
    model = fixture.model;
    conversationWithAna(encryptedThread(), lock(EncryptionState.on, notice: DevicesChange.theirs));
    await pumpLauncher(tester, model);
    // △ on the conversation: its encryption first.
    model.handle(launcher.Command.options);
    expect(model.together.messageMenuItems.first, 'lock');
    model.handle(launcher.Command.select);
    await tester.pumpAndSettle();
    expect(model.together.lockSheet, isTrue);
    expect(find.text('44483'), findsOneWidget);
    expect(find.text('18510'), findsOneWidget);
    expect(find.text('We compared them'), findsOneWidget);
    // Each device as its kind and the day it was added: never the computer's own name.
    expect(find.text('Ana’s MacBook Air'), findsNothing);
    expect(find.text('DESKTOP-7Q2'), findsNothing);
    expect(find.text('Utku’s iPhone'), findsNothing);
    expect(find.text('Mac'), findsOneWidget);
    expect(find.text('Windows PC'), findsOneWidget);
    expect(find.text('iPhone'), findsOneWidget);
    expect(find.text('Added 2026-11-03'), findsNWidgets(3));
    expect(find.text('A new device cannot read messages sent before it was added.'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_e2ee_sheet.png'));

    // "We compared them": marked, and the notice goes with it.
    model.handle(launcher.Command.select);
    await tester.pumpAndSettle();
    expect(model.together.e2ee.lockOf('c-ana')!.compared, isTrue);
    expect(model.together.e2ee.lockOf('c-ana')!.notice, isNull);
    expect(find.text('Compared'), findsOneWidget);
    model.handle(launcher.Command.back);
    await tester.pumpAndSettle();
    expect(model.together.lockSheet, isFalse);
  });

  testWidgets('golden: the sheet in Turkish', (tester) async {
    fixture = makeFixture(language: Language.byCode('tr'));
    model = fixture.model;
    conversationWithAna(encryptedThread(), lock(EncryptionState.on, compared: true));
    model.together.openLockSheet();
    await pumpLauncher(tester, model);
    expect(find.text('Uçtan uca şifreli'), findsWidgets);
    expect(find.text('Güvenlik numarası'), findsOneWidget);
    expect(find.text('Karşılaştırıldı'), findsOneWidget);
    expect(find.text('Windows bilgisayar'), findsOneWidget);
    expect(find.text('Eklenme: 2026-11-03'), findsNWidgets(3));
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_e2ee_sheet_tr.png'));
  });

  testWidgets('golden: not encrypted, said under the name; encrypted with nobody to read it, said in the composer', (
    tester,
  ) async {
    fixture = makeFixture();
    model = fixture.model;
    conversationWithAna([
      message(1, 'u-ana', 'My phone app is old, sorry', seal: null),
      message(2, 'u-me', 'No problem', seal: null),
    ], lock(EncryptionState.off));
    await pumpLauncher(tester, model);
    expect(find.text('Not end-to-end encrypted'), findsOneWidget);
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_e2ee_off.png'));

    model.together.e2ee.showLock('c-ana', lock(EncryptionState.noDevice));
    await tester.pumpAndSettle();
    expect(
      find.text('Ana is not signed in on a device that can read encrypted messages. They need an up-to-date app.'),
      findsOneWidget,
    );
    await expectLater(find.byType(LauncherShell), matchesGoldenFile('goldens/together_messages_e2ee_nodevice.png'));
  });

  testWidgets('a sealed message in the list says Encrypted message until it is opened; the report says who reads it', (
    tester,
  ) async {
    fixture = makeFixture();
    model = fixture.model;
    conversationWithAna([
      message(1, 'u-ana', 'Opened', seal: SealState.opened),
      message(2, 'u-ana', null, seal: SealState.opening),
    ], lock(EncryptionState.on));
    await pumpLauncher(tester, model);
    expect(find.text('Encrypted message'), findsOneWidget);
    model.together.openMessageMenu(model.together.hub.messages.thread.first);
    expect(model.together.messageMenuItems, contains('report'));
    model.together.runMenuItem('report');
    await tester.pumpAndSettle();
    expect(find.textContaining('Reporting sends this message to the moderators so they can read it.'), findsOneWidget);
    expect(model.together.messageMenuItems, [
      'report-spam',
      'report-harassment',
      'report-hate',
      'report-sexual',
      'report-other',
      'cancel',
    ]);
  });
}
