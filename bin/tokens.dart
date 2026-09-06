// 令牌签发/校验（HMAC-SHA256 签名的 base64url payload）
import 'dart:convert';

import 'core.dart';

class Tokens {
  static String secret = '';
  static const _validDays = 30;

  static String issue(String email) {
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'email': email,
      'exp': DateTime.now()
          .add(const Duration(days: _validDays))
          .millisecondsSinceEpoch,
    })));
    final sig =
        hmacSha256(utf8.encode(secret), utf8.encode(payload));
    return '$payload.${_b64(sig)}';
  }

  static String? verify(String token) {
    final parts = token.split('.');
    if (parts.length != 2) return null;
    final sig = hmacSha256(utf8.encode(secret), utf8.encode(parts[0]));
    if (!constantTimeEquals(_b64(sig), parts[1])) return null;
    try {
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(parts[0]))) as Map<String, dynamic>;
      final exp = payload['exp'] as int;
      if (DateTime.fromMillisecondsSinceEpoch(exp).isBefore(DateTime.now())) {
        return null;
      }
      return payload['email'] as String;
    } catch (_) {
      return null;
    }
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
