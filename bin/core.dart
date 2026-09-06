// 纯 Dart 密码学基元（零依赖）：SHA-256（FIPS 180-4）、HMAC（RFC 2104）、
// PBKDF2-HMAC-SHA256（RFC 2898）。正确性由 selftest.dart 的标准测试向量保证。
// 客户端与服务端共用同一算法与参数。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 套餐时长（激活码与扫码支付共用）
const kPlans = {
  'month': Duration(days: 31),
  'quarter': Duration(days: 93),
  'year': Duration(days: 366),
  'trial': Duration(days: 1),
};

// ---------- SHA-256 ----------

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// SHA-256 摘要（32 字节）
List<int> sha256Bytes(List<int> message) {
  final h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  final bitLen = message.length * 8;
  final data = List<int>.from(message)..add(0x80);
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    data.add((bitLen >> (8 * i)) & 0xff);
  }
  final w = List<int>.filled(64, 0);
  for (var block = 0; block < data.length; block += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = (data[block + t * 4] << 24) |
          (data[block + t * 4 + 1] << 16) |
          (data[block + t * 4 + 2] << 8) |
          data[block + t * 4 + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  final out = <int>[];
  for (final v in h) {
    out..add((v >> 24) & 0xff)..add((v >> 16) & 0xff)..add((v >> 8) & 0xff)..add(v & 0xff);
  }
  return out;
}

String sha256Hex(String s) =>
    sha256Bytes(utf8.encode(s)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// ---------- HMAC-SHA256 ----------

List<int> hmacSha256(List<int> key, List<int> message) {
  const blockSize = 64;
  var k = List<int>.from(key);
  if (k.length > blockSize) {
    k = sha256Bytes(k);
  }
  while (k.length < blockSize) {
    k.add(0);
  }
  final oKeyPad = k.map((b) => b ^ 0x5c).toList();
  final iKeyPad = k.map((b) => b ^ 0x36).toList();
  final inner = sha256Bytes([...iKeyPad, ...message]);
  return sha256Bytes([...oKeyPad, ...inner]);
}

// ---------- PBKDF2-HMAC-SHA256 ----------

/// dkLen 固定 32 字节（单块），与 5 万次迭代参数一起在客户端/服务端保持一致
String pbkdf2HashHex(String password, String saltHex, {int iterations = 50000}) {
  final salt = _hexDecode(saltHex);
  final macKey = utf8.encode(password);
  var u = hmacSha256(macKey, [...salt, 0, 0, 0, 1]);
  final dk = List<int>.from(u);
  for (var iter = 1; iter < iterations; iter++) {
    u = hmacSha256(macKey, u);
    for (var i = 0; i < 32; i++) {
      dk[i] ^= u[i];
    }
  }
  return dk.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

List<int> _hexDecode(String hex) {
  final out = List<int>.filled(hex.length ~/ 2, 0);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 恒定时间字符串比较
bool constantTimeEquals(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

String randomHex(int bytes) {
  final rnd = Random.secure();
  return List.generate(bytes, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

// ---------- JSON 文件存储 ----------

/// 原子写（临时文件+改名）+ 简单互斥；MVP 规模够用，后续可平滑换数据库
class JsonStore {
  final String dir;
  final _locks = <String, Future<void>>{};

  JsonStore(this.dir) {
    Directory(dir).createSync(recursive: true);
  }

  Future<T> withLock<T>(String file, Future<T> Function() fn) async {
    while (_locks.containsKey(file)) {
      await _locks[file];
    }
    final c = Completer<void>();
    _locks[file] = c.future;
    try {
      return await fn();
    } finally {
      _locks.remove(file);
      c.complete();
    }
  }

  Map<String, dynamic> read(String file) {
    final f = File('$dir/$file');
    if (!f.existsSync()) return {};
    try {
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void write(String file, Map<String, dynamic> data) {
    final tmp = File('$dir/$file.tmp');
    tmp.writeAsStringSync(jsonEncode(data));
    tmp.renameSync('$dir/$file');
  }
}
