import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core.dart';
import 'orders.dart';
import 'tokens.dart';
import 'admin_page.dart' show adminPageHtml;

/// 小马达能量营 · 账号与订阅服务端（零依赖，仅需 Dart SDK）
///
/// 功能：手机号/邮箱注册登录、错密锁定、自助改密、扫码支付订单、
///       支付回调自动开通、网页管理后台（/admin）。
/// 运行：dart bin/server.dart [端口]（默认 8080；数据目录 ./data）
/// 管理：浏览器打开 http://本机IP:8080/admin  密钥 = data/secret.key 内容
/// 部署：任意装有 Dart SDK 的机器/VPS；建议前置 Nginx + HTTPS。

final store = JsonStore('data');
final orders = OrderService(store);
final ipFailCount = <String, int>{};

Future<void> main(List<String> args) async {
  // 密码学自检（防止静默的算法错误）；路径基于本脚本位置，与启动目录无关
  final selftest = File.fromUri(Platform.script.resolve('selftest.dart'));
  final r = Process.runSync(Platform.executable, [selftest.path]);
  if (r.exitCode != 0) {
    stderr.writeln(r.stdout);
    stderr.writeln(r.stderr);
    stderr.writeln('密码学自检未通过，拒绝启动');
    exit(3);
  }
  print('密码学自检通过');

  final port = args.isNotEmpty ? int.tryParse(args[0]) ?? 8080 : 8080;
  _loadOrCreateSecret();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('小马达账号服务已启动: http://0.0.0.0:$port  (data dir: ./data)');
  stdout.writeln('管理后台: http://127.0.0.1:$port/admin  密钥见 data/secret.key');
  await for (final req in server) {
    unawaited(_handle(req));
  }
}

void _loadOrCreateSecret() {
  Directory('data').createSync(recursive: true);
  final f = File('data/secret.key');
  if (f.existsSync()) {
    Tokens.secret = f.readAsStringSync().trim();
  } else {
    Tokens.secret = randomHex(48);
    f.writeAsStringSync(Tokens.secret);
  }
}

Future<void> _handle(HttpRequest req) async {
  try {
    final path = req.uri.path;
    final ip = req.connectionInfo?.remoteAddress.address ?? '?';

    // 网页管理后台（自有密钥保护，不参与登录限速）
    if (path == '/admin' || path.startsWith('/admin/')) {
      return await _admin(req, path);
    }
    // 收款码图片（App 内 Image.network 直接加载）
    if (req.method == 'GET' && path.startsWith('/qr/')) {
      return await _serveQr(req, path);
    }

    if ((path == '/auth/login' || path == '/auth/register') &&
        (ipFailCount[ip] ?? 0) >= 15) {
      return _json(req, 429, {'error': '尝试次数过多，请 10 分钟后再试'});
    }

    if (req.method == 'GET' && path == '/health') {
      return _json(req, 200, {'ok': true, 'service': 'xiaomada-account'});
    }

    if (req.method == 'POST' && path == '/auth/register') {
      return await _register(req, ip, await _body(req));
    }
    if (req.method == 'POST' && path == '/auth/login') {
      return await _login(req, ip, await _body(req));
    }
    if (req.method == 'POST' && path == '/auth/change-password') {
      return await _changePassword(req, await _body(req));
    }
    if (req.method == 'GET' && path == '/me') {
      return await _me(req);
    }
    if (req.method == 'POST' && path == '/sub/redeem') {
      return await _redeem(req, await _body(req));
    }
    if (req.method == 'POST' && path == '/order/create') {
      return await _orderCreate(req, await _body(req));
    }
    if (req.method == 'GET' && path == '/order/status') {
      return await _orderStatus(req);
    }
    if (req.method == 'POST' && path == '/pay/notify') {
      return await _payNotify(req, await _body(req));
    }

    _json(req, 404, {'error': 'not found'});
  } catch (e) {
    stderr.writeln('handler error: $e');
    _json(req, 500, {'error': '服务器内部错误'});
  }
}

// ---------- 注册 / 登录 / 自助改密 ----------

Future<void> _register(HttpRequest req, String ip, Map<String, dynamic> body) async {
  final account = _normAccount(body['account'] ?? body['email']);
  final password = body['password'] as String? ?? '';
  final err = _validateAccount(account);
  if (err != null) return _json(req, 400, {'error': err});
  if (password.length < 8 || password.length > 128) {
    return _json(req, 400, {'error': '密码需 8-128 位'});
  }
  final created = await store.withLock('accounts.json', () async {
    final accounts = store.read('accounts.json');
    if (accounts.containsKey(account)) return false;
    final salt = randomHex(16);
    accounts[account] = {
      'salt': salt,
      'hash': pbkdf2HashHex(password, salt),
      'createdAt': DateTime.now().toIso8601String(),
      'vipExpire': null,
      'failCount': 0,
      'lockUntil': null,
    };
    store.write('accounts.json', accounts);
    return true;
  });
  if (!created) {
    ipFailCount[ip] = (ipFailCount[ip] ?? 0) + 1;
    return _json(req, 409, {'error': '该账号已注册，请直接登录'});
  }
  ipFailCount.remove(ip);
  return _json(req, 200, {
    'token': Tokens.issue(account),
    'account': account,
    'vipExpire': null,
  });
}

Future<void> _login(HttpRequest req, String ip, Map<String, dynamic> body) async {
  final account = _normAccount(body['account'] ?? body['email']);
  final password = body['password'] as String? ?? '';
  final lockErr = await store.withLock('accounts.json', () async {
    final accounts = store.read('accounts.json');
    final acc = accounts[account] as Map<String, dynamic>?;
    if (acc == null) return '账号或密码不正确';
    // 账号级锁定：连续输错 5 次禁用 15 分钟，再错时长递增
    final lockUntil = DateTime.tryParse(acc['lockUntil'] as String? ?? '');
    if (lockUntil != null && lockUntil.isAfter(DateTime.now())) {
      final mins = lockUntil.difference(DateTime.now()).inMinutes + 1;
      return '账号已暂时禁用，请 $mins 分钟后再试';
    }
    if (!constantTimeEquals(
        pbkdf2HashHex(password, acc['salt'] as String), acc['hash'] as String)) {
      final fails = ((acc['failCount'] as num?)?.toInt() ?? 0) + 1;
      acc['failCount'] = fails;
      if (fails >= 5) {
        acc['lockUntil'] = DateTime.now()
            .add(Duration(minutes: 15 * (fails - 4)))
            .toIso8601String();
        acc['failCount'] = 0;
        store.write('accounts.json', accounts);
        return '密码错误次数过多，账号已暂时禁用 15 分钟';
      }
      store.write('accounts.json', accounts);
      return '账号或密码不正确';
    }
    acc['failCount'] = 0;
    acc['lockUntil'] = null;
    store.write('accounts.json', accounts);
    return null;
  });
  if (lockErr != null) {
    ipFailCount[ip] = (ipFailCount[ip] ?? 0) + 1;
    return _json(req, 401, {'error': lockErr});
  }
  ipFailCount.remove(ip);
  final acc = store.read('accounts.json')[account] as Map<String, dynamic>?;
  return _json(req, 200, {
    'token': Tokens.issue(account),
    'account': account,
    'vipExpire': acc?['vipExpire'],
  });
}

Future<void> _changePassword(HttpRequest req, Map<String, dynamic> body) async {
  final account = _auth(req);
  if (account == null) return _json(req, 401, {'error': '请先登录'});
  final oldPwd = body['oldPassword'] as String? ?? '';
  final newPwd = body['newPassword'] as String? ?? '';
  if (newPwd.length < 8 || newPwd.length > 128) {
    return _json(req, 400, {'error': '新密码需 8-128 位'});
  }
  final result = await store.withLock('accounts.json', () async {
    final accounts = store.read('accounts.json');
    final acc = accounts[account] as Map<String, dynamic>?;
    if (acc == null) return '账号不存在';
    if (!constantTimeEquals(
        pbkdf2HashHex(oldPwd, acc['salt'] as String), acc['hash'] as String)) {
      return '当前密码不正确';
    }
    acc['salt'] = randomHex(16);
    acc['hash'] = pbkdf2HashHex(newPwd, acc['salt'] as String);
    acc['failCount'] = 0;
    acc['lockUntil'] = null;
    store.write('accounts.json', accounts);
    return null;
  });
  if (result != null) return _json(req, 400, {'error': result});
  return _json(req, 200, {'ok': true});
}

Future<void> _me(HttpRequest req) async {
  final account = _auth(req);
  if (account == null) return _json(req, 401, {'error': '请先登录'});
  final acc = store.read('accounts.json')[account] as Map<String, dynamic>?;
  return _json(req, 200, {'account': account, 'vipExpire': acc?['vipExpire']});
}

// ---------- 兑换 / 订单 / 支付回调 ----------

Future<void> _redeem(HttpRequest req, Map<String, dynamic> body) async {
  final account = _auth(req);
  if (account == null) return _json(req, 401, {'error': '请先登录'});
  final code = (body['code'] as String? ?? '').trim().toUpperCase();
  if (code.isEmpty) return _json(req, 400, {'error': '请输入激活码'});

  final result = await store.withLock('codes.json', () async {
    final codes = store.read('codes.json');
    final c = codes[code] as Map<String, dynamic>?;
    if (c == null) return ('notfound', '');
    if (c['used'] != null) return ('used', '');
    final plan = c['plan'] as String;
    if (!kPlans.containsKey(plan)) return ('badplan', '');
    c['used'] = account;
    c['usedAt'] = DateTime.now().toIso8601String();
    store.write('codes.json', codes);
    return ('ok', plan);
  });
  if (result.$1 == 'notfound') return _json(req, 404, {'error': '激活码不存在'});
  if (result.$1 == 'used') return _json(req, 409, {'error': '激活码已被使用'});
  if (result.$1 != 'ok') return _json(req, 400, {'error': '激活码无效'});

  final vipExpire = await _grant(account, kPlans[result.$2]!);
  return _json(req, 200, {'account': account, 'vipExpire': vipExpire, 'plan': result.$2});
}

Future<void> _orderCreate(HttpRequest req, Map<String, dynamic> body) async {
  final account = _auth(req);
  if (account == null) return _json(req, 401, {'error': '请先登录'});
  final plan = body['plan'] as String? ?? '';
  try {
    final order = await orders.create(email: account, plan: plan);
    // 收款码统一经 /qr/<plan> 提供：管理后台改码后，App 端无需更新
    order['qrUrl'] = req.requestedUri.origin + '/qr/$plan';
    return _json(req, 200, order);
  } on StateError catch (e) {
    return _json(req, 400, {'error': e.message});
  }
}

Future<void> _orderStatus(HttpRequest req) async {
  final account = _auth(req);
  if (account == null) return _json(req, 401, {'error': '请先登录'});
  final id = req.uri.queryParameters['orderId'] ?? '';
  final o = orders.status(id);
  if (o == null) return _json(req, 404, {'error': '订单不存在'});
  if (o['email'] != account) return _json(req, 403, {'error': '无权查看该订单'});
  return _json(req, 200, {
    'orderId': o['orderId'],
    'status': o['status'],
    'amount': o['amount'],
    'plan': o['plan'],
  });
}

Future<void> _payNotify(HttpRequest req, Map<String, dynamic> body) async {
  final secret = req.uri.queryParameters['secret'] ?? '';
  if (!constantTimeEquals(secret, Tokens.secret)) {
    return _json(req, 403, {'error': 'invalid secret'});
  }
  // orderId 与 price 均支持 query 或 body 两种传法
  final orderId =
      (req.uri.queryParameters['orderId'] ?? body['orderId']) as String?;
  final priceRaw = req.uri.queryParameters['price'] ?? body['price'];
  if (orderId != null && orderId.isNotEmpty) {
    final r = await orders.confirmAndGrant(orderId);
    return _json(req, r.$1 ? 200 : 404, {'ok': r.$1, 'detail': r.$2});
  }
  final priceInt = priceRaw is num
      ? priceRaw.toInt()
      : int.tryParse(priceRaw?.toString() ?? '');
  if (priceInt != null) {
    final id = await orders.matchPendingByAmount(priceInt);
    if (id == null) {
      return _json(req, 404, {'ok': false, 'detail': 'no pending order for amount'});
    }
    final r = await orders.confirmAndGrant(id);
    return _json(req, r.$1 ? 200 : 404, {'ok': r.$1, 'orderId': id, 'detail': r.$2});
  }
  return _json(req, 400, {'error': 'orderId 或 price 必填其一'});
}

/// 写入会员到期时间（叠加），返回新的到期时间
Future<String> _grant(String account, Duration dur) async {
  return store.withLock('accounts.json', () async {
    final accounts = store.read('accounts.json');
    final acc = accounts[account] as Map<String, dynamic>?;
    if (acc == null) throw StateError('账号不存在');
    final current = acc['vipExpire'] as String?;
    final base = (current != null &&
            DateTime.tryParse(current)?.isAfter(DateTime.now()) == true)
        ? DateTime.parse(current)
        : DateTime.now();
    final newExp = base.add(dur).toIso8601String();
    acc['vipExpire'] = newExp;
    store.write('accounts.json', accounts);
    return newExp;
  });
}

// ---------- 收款码图片 ----------

Future<void> _serveQr(HttpRequest req, String path) async {
  final plan = path.substring('/qr/'.length);
  final cfg = store.read('payconfig.json')[plan] as Map<String, dynamic>?;
  if (cfg == null) {
    req.response.statusCode = 404;
    await req.response.close();
    return;
  }
  final dataUrl = cfg['dataUrl'] as String?;
  if (dataUrl != null && dataUrl.startsWith('data:image')) {
    final bytes = base64.decode(dataUrl.split(',').last);
    req.response.headers.contentType = ContentType('image', 'png');
    await req.response.addStream(Stream.value(bytes));
    await req.response.close();
    return;
  }
  final url = cfg['qrUrl'] as String?;
  if (url != null && url.isNotEmpty) {
    req.response.statusCode = 302;
    req.response.headers.set('Location', url);
    await req.response.close();
    return;
  }
  req.response.statusCode = 404;
  await req.response.close();
}

// ---------- 网页管理后台 ----------

Future<void> _admin(HttpRequest req, String path) async {
  if (path == '/admin' && req.method == 'GET') {
    req.response.headers.contentType = ContentType.html;
    req.response.write(adminPageHtml);
    await req.response.close();
    return;
  }
  final key = req.uri.queryParameters['key'] ??
      req.headers.value('x-admin-key') ??
      '';
  if (!constantTimeEquals(key, Tokens.secret)) {
    return _json(req, 403, {'error': '管理密钥错误'});
  }
  if (req.method == 'GET' && path == '/admin/data') {
    final accounts = store.read('accounts.json');
    final sanitized = accounts.map((k, v) => MapEntry(k, {
          'vipExpire': (v as Map)['vipExpire'],
          'locked': ((v['lockUntil'] as String? ?? '').isNotEmpty &&
              (DateTime.tryParse(v['lockUntil'] as String? ?? '')
                      ?.isAfter(DateTime.now()) ==
                  true)),
        }));
    return _json(req, 200, {
      'payconfig': store.read('payconfig.json'),
      'orders': store.read('orders.json'),
      'accounts': sanitized,
    });
  }
  if (req.method == 'POST' && path == '/admin/setqr') {
    final body = await _body(req);
    final plan = body['plan'] as String? ?? '';
    if (!kPlans.containsKey(plan)) return _json(req, 400, {'error': '未知套餐'});
    await store.withLock('payconfig.json', () async {
      final cfg = store.read('payconfig.json');
      cfg[plan] = {
        if (body['dataUrl'] != null) 'dataUrl': body['dataUrl'],
        if (body['url'] != null) 'qrUrl': body['url'],
        'amount': payAmounts[plan],
      };
      store.write('payconfig.json', cfg);
    });
    return _json(req, 200, {'ok': true});
  }
  if (req.method == 'POST' && path == '/admin/confirm') {
    final body = await _body(req);
    final orderId = body['orderId'] as String? ?? '';
    final r = await orders.confirmAndGrant(orderId);
    return _json(req, r.$1 ? 200 : 404, {'ok': r.$1, 'detail': r.$2});
  }
  if (req.method == 'POST' && path == '/admin/resetpw') {
    final body = await _body(req);
    final account = (body['account'] as String? ?? '').trim().toLowerCase();
    final newPwd = body['newPassword'] as String? ?? '';
    if (newPwd.length < 8) return _json(req, 400, {'error': '新密码至少 8 位'});
    await store.withLock('accounts.json', () async {
      final accounts = store.read('accounts.json');
      final acc = accounts[account] as Map<String, dynamic>?;
      if (acc == null) return;
      acc['salt'] = randomHex(16);
      acc['hash'] = pbkdf2HashHex(newPwd, acc['salt'] as String);
      acc['failCount'] = 0;
      acc['lockUntil'] = null;
      store.write('accounts.json', accounts);
    });
    return _json(req, 200, {'ok': true});
  }
  _json(req, 404, {'error': 'not found'});
}

// ---------- 工具 ----------

String _normAccount(Object? raw) => (raw?.toString() ?? '').trim().toLowerCase();

String? _validateAccount(String account) {
  final isEmail = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(account) &&
      account.length <= 254;
  final isPhone = RegExp(r'^1[3-9]\d{9}$').hasMatch(account);
  if (!isEmail && !isPhone) return '请输入正确的手机号或邮箱';
  return null;
}

Future<Map<String, dynamic>> _body(HttpRequest req) async {
  try {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.isEmpty) return {};
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : {};
  } catch (_) {
    return {};
  }
}

String? _auth(HttpRequest req) {
  final h = req.headers.value('authorization') ?? '';
  if (!h.startsWith('Bearer ')) return null;
  return Tokens.verify(h.substring(7).trim());
}

void _json(HttpRequest req, int status, Map<String, dynamic> data) {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(data));
  req.response.close();
}
