// 密码学基元自检：NIST/RFC 标准测试向量。全绿才允许启动服务。
import 'core.dart';

bool _fail = false;

void expect(String label, String actual, String expected) {
  final ok = actual == expected;
  if (!ok) _fail = true;
  print('${ok ? "PASS" : "FAIL"}  $label');
  if (!ok) {
    print('  expected: $expected');
    print('  actual  : $actual');
  }
}

void main() {
  // SHA-256（NIST FIPS 180-4 示例）
  expect('sha256("")', sha256Hex(''),
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
  expect('sha256("abc")', sha256Hex('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  expect('sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")',
      sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');

  // HMAC-SHA256（RFC 4231 Test Case 1 & 2）
  final tc1 = hmacSha256(List.filled(20, 0x0b), 'Hi There'.codeUnits)
      .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  expect('hmac-sha256 rfc4231 tc1', tc1,
      'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7');

  final tc2 = hmacSha256('Jefe'.codeUnits, 'what do ya want for nothing?'.codeUnits)
      .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  expect('hmac-sha256 rfc4231 tc2', tc2,
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');

  // PBKDF2-HMAC-SHA256（RFC 7914 附录 / 公开向量）
  expect('pbkdf2(password,salt,1)', pbkdf2HashHex('password', '73616c74', iterations: 1),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
  expect('pbkdf2(password,salt,2)', pbkdf2HashHex('password', '73616c74', iterations: 2),
      'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
  expect('pbkdf2(password,salt,4096)', pbkdf2HashHex('password', '73616c74', iterations: 4096),
      'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');

  print(_fail ? 'SELFTEST FAILED' : 'SELFTEST ALL PASS');
  if (_fail) {
    throw StateError('crypto selftest failed');
  }
}
