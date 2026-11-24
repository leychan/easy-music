import 'dart:convert';
import 'dart:io';

import 'signature.dart';

/// 请求酷狗接口时随请求携带的设备标识。
///
/// 酷狗会把这些值当作同一台设备的凭证，其中 [guid] 一旦变化，
/// 服务端会视为新设备，可能触发额外的安全校验。因此首次生成后要持久化。
class KugouDevice {
  KugouDevice({
    required this.guid,
    required this.mac,
    String? dfid,
  }) : dfid = dfid ?? '-',
       mid = KugouSignature.mid(guid);

  final String guid;
  final String mac;
  final String mid;
  String dfid;

  Map<String, String> toJson() => {'guid': guid, 'mac': mac, 'dfid': dfid};

  static KugouDevice fromJson(Map<String, dynamic> json) {
    final guid = json['guid'];
    final mac = json['mac'];
    if (guid is! String || guid.isEmpty || mac is! String || mac.isEmpty) {
      throw const FormatException('设备标识不完整');
    }
    final dfid = json['dfid'];
    return KugouDevice(
      guid: guid,
      mac: mac,
      dfid: dfid is String && dfid.isNotEmpty ? dfid : null,
    );
  }

  /// 首次启动时按真实网卡 MAC 生成稳定标识。
  ///
  /// 取不到网卡时退回固定值：酷狗只要求该字段存在且格式合法，
  /// 真正的设备区分依赖 [guid]。
  factory KugouDevice.generate() {
    final guid = KugouSignature.uuidV4();
    final mac = _detectMac() ?? '02:00:00:00:00:00';
    return KugouDevice(guid: guid, mac: mac.toUpperCase());
  }

  static String? _detectMac() {
    try {
      final net = Directory('/sys/class/net');
      if (!net.existsSync()) return null;
      for (final entry in net.listSync()) {
        final name = entry.path.split('/').last;
        if (name == 'lo') continue;
        final mac = _readMac(name);
        if (mac != null) return mac;
      }
    } on Object {
      // 无网络设备或权限不足时退回默认值。
    }
    return null;
  }

  static String? _readMac(String name) {
    try {
      final file = File('/sys/class/net/$name/address');
      if (!file.existsSync()) return null;
      final value = file.readAsStringSync().trim().toUpperCase();
      if (value.isEmpty || value == '00:00:00:00:00:00') return null;
      return value;
    } on Object {
      return null;
    }
  }

  static KugouDevice decode(String source) =>
      KugouDevice.fromJson(jsonDecode(source) as Map<String, dynamic>);

  String encode() => jsonEncode(toJson());
}
