import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

/// 酷狗接口用到的加密原语。
///
/// 全部同步实现：调用点都在异步上下文里，但加密是纯计算，拆成异步只会让
/// “签名与请求体一起拼装”变得难读。
class KugouCrypto {
  KugouCrypto._();

  /// 酷狗标准版 RSA 公钥（1024 位），用于加密会话串与 AES 密钥。
  static const rsaPublicKeyPem =
      '-----BEGIN PUBLIC KEY-----\n'
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/g'
      'bjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+'
      'UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE'
      '5E221wf/4WLFxwAtRQIDAQAB\n'
      '-----END PUBLIC KEY-----';

  // 概念版用不同的服务端公钥接收登录和云盘的加密参数。
  static const _liteRsaPublicKeyPem =
      '-----BEGIN PUBLIC KEY-----\n'
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01'
      'rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFV'
      'xtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB\n'
      '-----END PUBLIC KEY-----';

  static final _publicKey = _parsePublicKey(rsaPublicKeyPem);
  static final _litePublicKey = _parsePublicKey(_liteRsaPublicKeyPem);
  static pc.RSAPublicKey _parsePublicKey(String pem) => pc.RSAPublicKey(
    BigInt.parse(_hex(_readRsaModulus(pem)), radix: 16),
    BigInt.from(65537),
  );
  static final Random _random = Random.secure();

  static String md5(String input) => crypto.md5.convert(utf8.encode(input)).toString();

  static String sha1(String input) => crypto.sha1.convert(utf8.encode(input)).toString();

  /// AES-CBC/PKCS7 加密，返回小写 hex。
  ///
  /// 酷狗把 key 和 iv 直接当 UTF-8 文本用：32 字符对应 256 位，16 字符对应
  /// 128 位。这里按字节长度选择，不做任何补齐。
  static String aesCbcEncryptHex(String plain, String key, String iv) {
    final engine = pc.CBCBlockCipher(pc.AESEngine())
      ..init(
        true,
        pc.ParametersWithIV<pc.KeyParameter>(
          pc.KeyParameter(_keyBytes(key)),
          _keyBytes(iv),
        ),
      );
    return _hex(_processPadded(engine, utf8.encode(plain)));
  }

  /// AES-CBC/PKCS7 解密。解不开时返回原密文，交由调用方判定失败。
  static String aesCbcDecryptHex(String cipherHex, String key, String iv) {
    try {
      final engine = pc.CBCBlockCipher(pc.AESEngine())
        ..init(
          false,
          pc.ParametersWithIV<pc.KeyParameter>(
            pc.KeyParameter(_keyBytes(key)),
            _keyBytes(iv),
          ),
        );
      return utf8.decode(
        _unprocessPadded(engine, _unhex(cipherHex)),
        allowMalformed: true,
      );
    } on Object {
      return cipherHex;
    }
  }

  /// AES-CBC/PKCS7 解密 base64 密文。解不开时返回原串，交由调用方判定失败。
  static String aesCbcDecryptBase64(String base64Cipher, String key, String iv) {
    try {
      return _decryptWith(key, iv, base64Decode(base64Cipher.trim()));
    } on Object {
      return base64Cipher;
    }
  }

  /// AES-CBC/PKCS7 解密裸字节。云歌单服务的响应是二进制密文，
  /// 不能先当文本读再解。解不开时返回空串，由调用方回退到明文解析。
  static String aesCbcDecryptBytes(Uint8List bytes, String key, String iv) {
    try {
      return _decryptWith(key, iv, bytes);
    } on Object {
      return '';
    }
  }

  static String _decryptWith(
    String key,
    String iv,
    Uint8List bytes, {
    bool allowMalformed = true,
  }) {
    final engine = pc.CBCBlockCipher(pc.AESEngine())
      ..init(
        false,
        pc.ParametersWithIV<pc.KeyParameter>(
          pc.KeyParameter(_keyBytes(key)),
          _keyBytes(iv),
        ),
      );
    return utf8.decode(
      _unprocessPadded(engine, bytes),
      allowMalformed: allowMalformed,
    );
  }

  /// RSA PKCS#1 v1.5 加密，返回大写 hex。
  static String rsaEncryptHex(String plain, {bool lite = false}) {
    final key = lite ? _litePublicKey : _publicKey;
    final blockSize = (key.modulus!.bitLength + 7) ~/ 8;
    final bytes = utf8.encode(plain);
    if (bytes.length > blockSize - 11) {
      throw ArgumentError('待加密内容超出 RSA 密钥长度');
    }
    final engine = pc.RSAEngine()
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
    final input = Uint8List(blockSize)..setAll(0, bytes);
    return _hex(engine.process(input)).toUpperCase();
  }

  /// 云歌单写入使用带随机填充的 RSA，和登录请求的原始 RSA 格式不同。
  static String rsaEncryptPkcs1(String plain, {bool lite = false}) {
    final key = lite ? _litePublicKey : _publicKey;
    final engine = pc.PKCS1Encoding(pc.RSAEngine())
      ..init(true, pc.PublicKeyParameter<pc.RSAPublicKey>(key));
    return _hex(engine.process(Uint8List.fromList(utf8.encode(plain)))).toUpperCase();
  }

  static int randomInt(int max) => _random.nextInt(max);

  /// 酷狗登录接口的“随机密钥”约定。
  ///
  /// 对应 KuGouMusicApi 的 `cryptoAesEncrypt`（默认分支，手机号登录用的就是
  /// 这条）：生成 **16 位** 随机种子，取其 MD5 的 32 个字符**整体**当 AES
  /// key，再取 key 的后 16 位当 iv。注意这是 **AES-256**（32 字节 key），
  /// 与 `playlistAesEncrypt` 的 6 位种子 + AES-128 是两套不同的约定，
  /// 用错会导致服务端解不开 `params`，报错却只显示“参数错误”。
  static ({String cipher, String key}) aesEncryptWithSeed(String plain) {
    final seed = _randomSeed(16);
    final derived = md5(seed);
    return (
      cipher: aesCbcEncryptHex(plain, derived, derived.substring(16, 32)),
      key: seed,
    );
  }

  /// 解 [aesEncryptWithSeed] 的产物，用于解密设备注册接口返回的 base64 密文。
  static String aesDecryptWithSeed(String base64Cipher, String seed) {
    final derived = md5(seed);
    return aesCbcDecryptBase64(base64Cipher, derived, derived.substring(16, 32));
  }

  /// 登录响应使用 hex 密文，密钥派生与 [aesEncryptWithSeed] 一致。
  static String? aesDecryptHexWithSeed(String cipher, String seed) {
    final key = md5(seed);
    try {
      return _decryptWith(
        key,
        key.substring(16),
        _unhex(cipher),
        allowMalformed: false,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static const _seedAlphabet = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  static String _randomSeed(int length) =>
      List.generate(length, (_) => _seedAlphabet[_random.nextInt(_seedAlphabet.length)]).join().toLowerCase();

  static Uint8List _keyBytes(String key) {
    final bytes = utf8.encode(key);
    if (bytes.length != 16 && bytes.length != 24 && bytes.length != 32) {
      throw ArgumentError('AES 密钥长度必须是 16/24/32 字节，实际 ${bytes.length}');
    }
    return Uint8List.fromList(bytes);
  }

  /// CBC 需要按 16 字节对齐，PKCS7 补齐后逐块加密。
  static Uint8List _processPadded(pc.BlockCipher engine, List<int> plain) {
    final blockSize = engine.blockSize;
    final pad = blockSize - plain.length % blockSize;
    final padded = Uint8List(plain.length + pad)
      ..setAll(0, plain)
      ..fillRange(plain.length, plain.length + pad, pad);
    final out = Uint8List(padded.length);
    for (var offset = 0; offset < padded.length; offset += blockSize) {
      engine.processBlock(padded, offset, out, offset);
    }
    return out;
  }

  static Uint8List _unprocessPadded(pc.BlockCipher engine, Uint8List cipher) {
    final blockSize = engine.blockSize;
    if (cipher.isEmpty || cipher.length % blockSize != 0) {
      throw const FormatException('密文长度不是分组大小的整数倍');
    }
    final out = Uint8List(cipher.length);
    for (var offset = 0; offset < cipher.length; offset += blockSize) {
      engine.processBlock(cipher, offset, out, offset);
    }
    final pad = out.last;
    if (pad < 1 || pad > blockSize) throw const FormatException('填充无效');
    for (var i = out.length - pad; i < out.length; i++) {
      if (out[i] != pad) throw const FormatException('填充无效');
    }
    return Uint8List.sublistView(out, 0, out.length - pad);
  }

  /// 从 PEM 里取出 SubjectPublicKeyInfo 的模数，避免依赖完整的 ASN.1 解析。
  static List<int> _readRsaModulus(String pem) {
    final der = base64Decode(
      pem.split('\n').where((line) => !line.startsWith('-----')).join(),
    );
    for (var i = 0; i < der.length - 2; i++) {
      // 0x02 0x81 0x81 0x00 之后紧跟 128 字节模数。
      if (der[i] == 0x02 && der[i + 1] == 0x81 && der[i + 2] == 0x81 && der[i + 3] == 0x00) {
        return der.sublist(i + 4, i + 4 + 128);
      }
    }
    throw StateError('无法从公钥中解析出模数');
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhex(String hex) {
    if (hex.length.isOdd) throw const FormatException('hex 长度必须是偶数');
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
