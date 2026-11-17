import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../child_processes.dart';

/// DNS record types the responder knows.
abstract final class DnsType {
  static const a = 1;
  static const ptr = 12;
  static const txt = 16;
  static const aaaa = 28;
  static const srv = 33;
  static const any = 255;
}

class DnsQuestion {
  const DnsQuestion(this.name, this.type, {this.unicastResponse = false});
  final String name;
  final int type;

  /// The QU bit: the asker wants the answer sent to it directly.
  final bool unicastResponse;
}

class DnsRecord {
  const DnsRecord(this.name, this.type, this.ttl, this.data, {this.cacheFlush = false});
  final String name;
  final int type;
  final int ttl;

  /// The record's data, already encoded.
  final List<int> data;

  /// The record is unique to this host (the class's top bit), so caches replace older ones.
  final bool cacheFlush;
}

class DnsPacket {
  const DnsPacket({
    this.id = 0,
    this.flags = 0,
    this.questions = const [],
    this.answers = const [],
    this.additionals = const [],
  });

  final int id;
  final int flags;
  final List<DnsQuestion> questions;
  final List<DnsRecord> answers;
  final List<DnsRecord> additionals;

  bool get isResponse => flags & 0x8000 != 0;

  /// The packet's wire form; names are written without compression.
  Uint8List encode() {
    final out = BytesBuilder();
    void u16(int value) => out.add([value >> 8 & 0xFF, value & 0xFF]);
    void u32(int value) => out.add([value >> 24 & 0xFF, value >> 16 & 0xFF, value >> 8 & 0xFF, value & 0xFF]);
    u16(id);
    u16(flags);
    u16(questions.length);
    u16(answers.length);
    u16(0);
    u16(additionals.length);
    for (final question in questions) {
      out.add(encodeName(question.name));
      u16(question.type);
      u16(1 | (question.unicastResponse ? 0x8000 : 0));
    }
    for (final record in [...answers, ...additionals]) {
      out.add(encodeName(record.name));
      u16(record.type);
      u16(1 | (record.cacheFlush ? 0x8000 : 0));
      u32(record.ttl);
      u16(record.data.length);
      out.add(record.data);
    }
    return out.toBytes();
  }

  /// A packet's questions and records, null when it is malformed.
  static DnsPacket? decode(List<int> bytes) {
    try {
      final reader = _Reader(bytes);
      final id = reader.u16();
      final flags = reader.u16();
      final questionCount = reader.u16();
      final answerCount = reader.u16();
      final authorityCount = reader.u16();
      final additionalCount = reader.u16();
      final questions = <DnsQuestion>[];
      for (var index = 0; index < questionCount; index++) {
        final name = reader.name();
        final type = reader.u16();
        final klass = reader.u16();
        questions.add(DnsQuestion(name, type, unicastResponse: klass & 0x8000 != 0));
      }
      List<DnsRecord> records(int count) {
        final result = <DnsRecord>[];
        for (var index = 0; index < count; index++) {
          final name = reader.name();
          final type = reader.u16();
          final klass = reader.u16();
          final ttl = reader.u32();
          final length = reader.u16();
          final start = reader.offset;
          // Names inside the data may be compressed: decode them against the whole packet.
          final data = switch (type) {
            DnsType.ptr => encodeName(_Reader(bytes, start).name()),
            DnsType.srv => [...bytes.sublist(start, start + 6), ...encodeName(_Reader(bytes, start + 6).name())],
            _ => bytes.sublist(start, start + length),
          };
          reader.offset = start + length;
          result.add(DnsRecord(name, type, ttl, data, cacheFlush: klass & 0x8000 != 0));
        }
        return result;
      }

      final answers = records(answerCount);
      records(authorityCount);
      final additionals = records(additionalCount);
      return DnsPacket(id: id, flags: flags, questions: questions, answers: answers, additionals: additionals);
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List encodeName(String name) {
    final out = BytesBuilder();
    for (final label in name.split('.')) {
      if (label.isEmpty) continue;
      final bytes = utf8.encode(label);
      if (bytes.length > 63) throw FormatException('label too long: $label');
      out
        ..addByte(bytes.length)
        ..add(bytes);
    }
    out.addByte(0);
    return out.toBytes();
  }

  /// The name an encoded PTR's data points to.
  static String decodeName(List<int> data) => _Reader(data).name();
}

class _Reader {
  _Reader(this.bytes, [this.offset = 0]);
  final List<int> bytes;
  int offset;

  int u16() {
    final value = bytes[offset] << 8 | bytes[offset + 1];
    offset += 2;
    return value;
  }

  int u32() => u16() << 16 | u16();

  String name() {
    final labels = <String>[];
    var at = offset;
    var jumped = false;
    var jumps = 0;
    while (true) {
      final length = bytes[at];
      if (length == 0) {
        at++;
        break;
      }
      if (length & 0xC0 == 0xC0) {
        final pointer = (length & 0x3F) << 8 | bytes[at + 1];
        if (!jumped) offset = at + 2;
        jumped = true;
        if (++jumps > 32) throw const FormatException('name pointer loop');
        at = pointer;
        continue;
      }
      labels.add(utf8.decode(bytes.sublist(at + 1, at + 1 + length), allowMalformed: true));
      at += 1 + length;
    }
    if (!jumped) offset = at;
    return labels.join('.');
  }
}

/// Makes the launcher findable on the local network.
abstract interface class ServiceAdvertiser {
  Future<void> start();
  Future<void> stop();
}

/// A small multicast DNS responder (RFC 6762, DNS-SD RFC 6763) for one service: it answers the
/// PTR, SRV, TXT and address questions a phone's Bonjour or NSD browser asks, announces the
/// service when it starts and says goodbye when it stops. Pure Dart, so it runs the same on
/// Windows and Linux without Bonjour or Avahi.
class MdnsResponder implements ServiceAdvertiser {
  MdnsResponder({
    required this.instance,
    required this.serviceType,
    required this.port,
    String? hostName,
    this.addresses,
    this.mdnsPort = 5353,
    InternetAddress? group,
  }) : hostName = '${_label(hostName ?? Platform.localHostname)}.local',
       group = group ?? InternetAddress('224.0.0.251');

  /// The service's instance name, the computer's name the phone lists.
  final String instance;

  /// `_anyps5-remote._tcp`.
  final String serviceType;
  final int port;

  /// `<host>.local`.
  final String hostName;

  /// The addresses to give out; null reads the computer's IPv4 interfaces at each answer.
  final List<InternetAddress>? addresses;
  final int mdnsPort;
  final InternetAddress group;

  RawDatagramSocket? _socket;
  Timer? _announcer;

  String get serviceName => '$serviceType.local';
  String get instanceName => '$instance.$serviceName';

  static const _servicesName = '_services._dns-sd._udp.local';

  /// A host name as a DNS label: letters, digits and hyphens.
  static String _label(String name) {
    final first = name.split('.').first;
    final cleaned = first.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '-');
    return cleaned.isEmpty ? 'anyps5' : cleaned;
  }

  @override
  Future<void> start() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      mdnsPort,
      reuseAddress: true,
      reusePort: !Platform.isWindows && mdnsPort != 0,
      ttl: 255,
    );
    _socket = socket;
    socket.multicastHops = 255;
    try {
      for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
        try {
          socket.joinMulticast(group, interface);
        } on SocketException {
          // An interface without multicast.
        }
      }
    } on SocketException {
      // No interfaces to join on: unicast questions are still answered.
    }
    socket.listen((event) {
      if (event == RawSocketEvent.read) _receive(socket);
    });
    // Announced twice, a second apart, as RFC 6762 section 8.3 asks.
    await _announce(ttlScale: 1);
    _announcer = Timer(const Duration(seconds: 1), () => _announce(ttlScale: 1));
  }

  @override
  Future<void> stop() async {
    _announcer?.cancel();
    final socket = _socket;
    if (socket == null) return;
    await _announce(ttlScale: 0);
    _socket = null;
    socket.close();
  }

  Future<void> _announce({required int ttlScale}) async {
    final socket = _socket;
    if (socket == null) return;
    final records = await _records();
    final packet = DnsPacket(
      flags: 0x8400,
      answers: [
        for (final record in records)
          DnsRecord(record.name, record.type, record.ttl * ttlScale, record.data, cacheFlush: record.cacheFlush),
      ],
    );
    try {
      socket.send(packet.encode(), group, mdnsPort);
    } on SocketException {
      // No route for multicast; answers to questions still go out.
    }
  }

  void _receive(RawDatagramSocket socket) {
    while (true) {
      final datagram = socket.receive();
      if (datagram == null) return;
      final query = DnsPacket.decode(datagram.data);
      if (query == null || query.isResponse || query.questions.isEmpty) continue;
      unawaited(_reply(socket, query, datagram.address, datagram.port));
    }
  }

  Future<void> _reply(RawDatagramSocket socket, DnsPacket query, InternetAddress from, int fromPort) async {
    final legacy = fromPort != mdnsPort;
    final response = await respond(query, legacy: legacy);
    if (response == null) return;
    final bytes = response.encode();
    final direct = legacy || query.questions.any((question) => question.unicastResponse);
    try {
      if (direct) {
        socket.send(bytes, from, fromPort);
      } else {
        socket.send(bytes, group, mdnsPort);
      }
    } on SocketException {
      // Dropped; the asker asks again.
    }
  }

  /// The answer to [query], null when none of its questions are about this service. A legacy
  /// (one-shot, not from port 5353) question gets its id and questions back and short TTLs.
  Future<DnsPacket?> respond(DnsPacket query, {bool legacy = false}) async {
    final all = await _records();
    DnsRecord find(int type, String name) =>
        all.firstWhere((record) => record.type == type && _same(record.name, name));
    final answers = <DnsRecord>[];
    final additionals = <DnsRecord>[];
    void add(List<DnsRecord> list, DnsRecord record) {
      if (!answers.contains(record) && !additionals.contains(record)) list.add(record);
    }

    for (final question in query.questions) {
      final type = question.type;
      final name = question.name;
      if (_same(name, _servicesName) && (type == DnsType.ptr || type == DnsType.any)) {
        add(answers, DnsRecord(_servicesName, DnsType.ptr, 4500, DnsPacket.encodeName(serviceName)));
      } else if (_same(name, serviceName) && (type == DnsType.ptr || type == DnsType.any)) {
        add(answers, find(DnsType.ptr, serviceName));
        add(additionals, find(DnsType.srv, instanceName));
        add(additionals, find(DnsType.txt, instanceName));
        for (final record in all.where((record) => _same(record.name, hostName))) {
          add(additionals, record);
        }
      } else if (_same(name, instanceName) && (type == DnsType.srv || type == DnsType.txt || type == DnsType.any)) {
        if (type != DnsType.txt) add(answers, find(DnsType.srv, instanceName));
        if (type != DnsType.srv) add(answers, find(DnsType.txt, instanceName));
        for (final record in all.where((record) => _same(record.name, hostName))) {
          add(additionals, record);
        }
      } else if (_same(name, hostName) && (type == DnsType.a || type == DnsType.aaaa || type == DnsType.any)) {
        for (final record in all.where(
          (record) => _same(record.name, hostName) && (type == DnsType.any || record.type == type),
        )) {
          add(answers, record);
        }
      }
    }
    if (answers.isEmpty) return null;
    DnsRecord shorten(DnsRecord record) =>
        legacy ? DnsRecord(record.name, record.type, record.ttl > 10 ? 10 : record.ttl, record.data) : record;
    return DnsPacket(
      id: legacy ? query.id : 0,
      flags: 0x8400,
      questions: legacy ? query.questions : const [],
      answers: answers.map(shorten).toList(),
      additionals: additionals.map(shorten).toList(),
    );
  }

  Future<List<DnsRecord>> _records() async {
    final hosts = addresses ?? await _localAddresses();
    final srv = BytesBuilder()
      ..add([0, 0, 0, 0, port >> 8 & 0xFF, port & 0xFF])
      ..add(DnsPacket.encodeName(hostName));
    return [
      DnsRecord(serviceName, DnsType.ptr, 4500, DnsPacket.encodeName(instanceName)),
      DnsRecord(instanceName, DnsType.srv, 120, srv.toBytes(), cacheFlush: true),
      // An empty TXT record is one empty string.
      DnsRecord(instanceName, DnsType.txt, 4500, const [0], cacheFlush: true),
      for (final address in hosts)
        DnsRecord(
          hostName,
          address.type == InternetAddressType.IPv4 ? DnsType.a : DnsType.aaaa,
          120,
          address.rawAddress,
          cacheFlush: true,
        ),
    ];
  }

  static Future<List<InternetAddress>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses)
            if (!address.isLoopback && !address.isLinkLocal) address,
      ];
    } on SocketException {
      return const [];
    }
  }

  static bool _same(String a, String b) => a.toLowerCase() == b.toLowerCase();
}

/// Advertising through Avahi's avahi-publish on Linux, where the Avahi daemon already answers on
/// port 5353 for the computer.
class AvahiAdvertiser implements ServiceAdvertiser {
  AvahiAdvertiser({required this.instance, required this.serviceType, required this.port, this.tool = 'avahi-publish'});

  final String instance;
  final String serviceType;
  final int port;
  final String tool;
  Process? _process;

  /// Whether avahi-publish can be found.
  static Future<bool> available({String tool = 'avahi-publish'}) async {
    if (!Platform.isLinux) return false;
    try {
      final result = await Process.run('which', [tool]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  Future<void> start() async {
    _process = await ChildProcesses.start(tool, ['-s', instance, serviceType, '$port']);
    unawaited(_process!.stdout.drain<void>());
    unawaited(_process!.stderr.drain<void>());
  }

  @override
  Future<void> stop() async {
    _process?.kill();
    _process = null;
  }
}
