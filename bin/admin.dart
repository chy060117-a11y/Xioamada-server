import 'dart:io';
import 'dart:math';

import 'core.dart';
import 'orders.dart';

/// 激活码管理工具（零依赖）
/// 生成：dart bin/admin.dart gen <month|quarter|year|trial> <数量>
/// 查看：dart bin/admin.dart list
/// 重置密码：dart bin/admin.dart reset <邮箱> <新密码>
/// 数据目录：./data（与服务端一致）
Future<void> main(List<String> args) async {
  final store = JsonStore('data');
  final cmd = args.isNotEmpty ? args[0] : '';

  if (cmd == 'gen') {
    final plan = args.length > 1 ? args[1] : '';
    final count = args.length > 2 ? int.tryParse(args[2]) ?? 1 : 1;
    if (!plans.containsKey(plan)) {
      stderr.writeln('用法: dart bin/admin.dart gen <month|quarter|year|trial> <数量>');
      exit(2);
    }
    final codes = store.read('codes.json');
    final generated = <String>[];
    for (var i = 0; i < count; i++) {
      String code;
      do {
        code = _code();
      } while (codes.containsKey(code));
      codes[code] = {
        'plan': plan,
        'used': null,
        'createdAt': DateTime.now().toIso8601String(),
      };
      generated.add(code);
    }
    await store.withLock('codes.json', () async => store.write('codes.json', codes));
    stdout.writeln('已生成 ${generated.length} 张「$plan」激活码（一码一用）：');
    for (final c in generated) {
      stdout.writeln('  $c');
    }
    stdout.writeln('提示：请妥善保存后发给已付款用户。');
    return;
  }

  if (cmd == 'list') {
    final codes = store.read('codes.json');
    final accounts = store.read('accounts.json');
    var used = 0, unused = 0;
    codes.forEach((_, v) => (v as Map)['used'] == null ? unused++ : used++);
    stdout.writeln('激活码：共 ${codes.length} 张（未用 $unused / 已用 $used）');
    stdout.writeln('账号数：${accounts.length}');
    accounts.forEach((email, a) {
      stdout.writeln('  $email → 会员至 ${(a as Map)['vipExpire'] ?? '未开通'}');
    });
    return;
  }

  if (cmd == 'reset') {
    if (args.length < 3) {
      stderr.writeln('用法: dart bin/admin.dart reset <邮箱> <新密码>');
      exit(2);
    }
    final email = args[1].trim().toLowerCase();
    final newPassword = args[2];
    if (newPassword.length < 8) {
      stderr.writeln('新密码至少 8 位');
      exit(2);
    }
    final accounts = store.read('accounts.json');
    if (!accounts.containsKey(email)) {
      stderr.writeln('账号不存在');
      exit(1);
    }
    final acc = accounts[email] as Map<String, dynamic>;
    acc['salt'] = randomHex(16);
    acc['hash'] = pbkdf2HashHex(newPassword, acc['salt'] as String);
    await store.withLock('accounts.json', () async => store.write('accounts.json', accounts));
    stdout.writeln('已重置 $email 的密码。');
    return;
  }

  if (cmd == 'setqr') {
    // 用法: setqr <plan> <二维码图片URL> —— 扫码支付订单用
    if (args.length < 3) {
      stderr.writeln('用法: dart bin/admin.dart setqr <month|quarter|year|trial> <二维码图片URL>');
      exit(2);
    }
    final plan = args[1];
    if (!plans.containsKey(plan)) {
      stderr.writeln('未知套餐: ' + plan);
      exit(2);
    }
    final store2 = JsonStore('data');
    final cfg = store2.read('payconfig.json');
    cfg[plan] = {'qrUrl': args[2], 'amount': payAmounts[plan]};
    await store2.withLock('payconfig.json', () async => store2.write('payconfig.json', cfg));
    stdout.writeln('已设置 $plan 收款码: ${args[2]}');
    return;
  }

  if (cmd == 'confirm') {
    // 用法: confirm <orderId> —— 收到付款后人工确认（自动回调的兜底）
    if (args.length < 2) {
      stderr.writeln('用法: dart bin/admin.dart confirm <订单号>');
      exit(2);
    }
    final ordersSvc = OrderService(JsonStore('data'));
    final r = await ordersSvc.confirmAndGrant(args[1]);
    stdout.writeln(r.$1 ? '已确认并开通会员: ${r.$2}' : '失败: ${r.$2}');
    return;
  }

  if (cmd == 'orders') {
    final os = JsonStore('data').read('orders.json');
    stdout.writeln('订单数: ${os.length}');
    os.forEach((id, o) {
      final m = o as Map;
      stdout.writeln('  $id | ${m['email']} | ${m['plan']} | ¥${m['amount']} | ${m['status']}');
    });
    return;
  }

  stdout.writeln('用法:');
  stdout.writeln('  dart bin/admin.dart gen <month|quarter|year|trial> <数量>  # 生成激活码');
  stdout.writeln('  dart bin/admin.dart list                                  # 查看账号与激活码');
  stdout.writeln('  dart bin/admin.dart reset <邮箱> <新密码>                  # 重置密码（客服核实后）');
  stdout.writeln('  dart bin/admin.dart setqr <套餐> <收款码图片URL>           # 配置扫码支付的收款码');
  stdout.writeln('  dart bin/admin.dart orders                                # 查看全部订单');
  stdout.writeln('  dart bin/admin.dart confirm <订单号>                      # 人工确认订单（兜底）');
}

const plans = kPlans;

/// 激活码格式：XMD-XXXXX-XXXXX（去掉易混淆字符）
String _code() {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final rnd = Random.secure();
  String seg(int n) =>
      List.generate(n, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
  return 'XMD-${seg(5)}-${seg(5)}';
}
