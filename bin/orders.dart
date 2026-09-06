// 订单与支付自动开通：创建订单 → 用户扫码支付 → 回调/监听确认 → 自动开通会员。
//
// 支付渠道对接方式（二选一或并用）：
// A. 官方渠道（推荐，需个体户/企业资质）：微信支付 Native / 支付宝当面付。
//    商户后台把回调地址配置为 https://你的域名/pay/notify?secret=XXX，
//    回调体里带 orderId 字段即可精确确认。
// B. 个人收款码监听（V免签等开源方案）：按「金额+时间窗」匹配待支付订单。
//    监听 App 收到到账通知后回调 /pay/notify?secret=XXX&price=58。
//    注意：个人收款码用于经营存在被支付平台限制的风险，建议尽早走官方渠道。
//
// 金额单位：元（整数）。套餐价格在 PAY_AMOUNTS 配置。

import 'dart:math';

import 'core.dart';

const payAmounts = {
  'month': 58,
  'quarter': 138,
  'year': 288,
  'trial': 1,
};

/// 订单有效期（分钟）
const orderTtlMinutes = 15;

class OrderService {
  final JsonStore store;
  OrderService(this.store);

  /// 创建订单。qrUrl 来自支付配置（管理员用 admin.dart setqr 配置各档收款码图片地址）。
  Future<Map<String, dynamic>> create({
    required String email,
    required String plan,
  }) async {
    if (!payAmounts.containsKey(plan)) {
      throw ArgumentError('未知套餐: $plan');
    }
    final payCfg = store.read('payconfig.json');
    final cfg = payCfg[plan] as Map<String, dynamic>?;
    if (cfg == null || (cfg['qrUrl'] as String? ?? '').isEmpty) {
      throw StateError('该套餐尚未配置收款码，请联系管理员');
    }
    final orderId = 'XD${DateTime.now().millisecondsSinceEpoch}'
        '${Random().nextInt(900) + 100}';
    final order = {
      'orderId': orderId,
      'email': email,
      'plan': plan,
      'amount': payAmounts[plan],
      'status': 'pending',
      'createdAt': DateTime.now().toIso8601String(),
      'expireAt': DateTime.now()
          .add(const Duration(minutes: orderTtlMinutes))
          .toIso8601String(),
      'paidAt': null,
    };
    await store.withLock('orders.json', () async {
      final orders = store.read('orders.json');
      orders[orderId] = order;
      store.write('orders.json', orders);
    });
    return {
      'orderId': orderId,
      'plan': plan,
      'amount': payAmounts[plan],
      'qrUrl': cfg['qrUrl'],
      'expireAt': order['expireAt'],
    };
  }

  /// 查询订单状态；过期订单顺带标记
  Map<String, dynamic>? status(String orderId) {
    final orders = store.read('orders.json');
    final o = orders[orderId] as Map<String, dynamic>?;
    if (o == null) return null;
    if (o['status'] == 'pending') {
      final exp = DateTime.tryParse(o['expireAt'] as String? ?? '');
      if (exp != null && exp.isBefore(DateTime.now())) {
        o['status'] = 'expired';
        store.write('orders.json', orders);
      }
    }
    return o;
  }

  /// 确认订单并自动开通会员（时长与激活码一致，未到期叠加）。
  /// 返回 (ok, 原因/邮箱)。幂等：已支付订单重复确认返回 ok=true。
  Future<(bool, String)> confirmAndGrant(String orderId) async {
    late String email;
    late String plan;
    final marked = await store.withLock('orders.json', () async {
      final orders = store.read('orders.json');
      final o = orders[orderId] as Map<String, dynamic>?;
      if (o == null) return (false, '订单不存在');
      if (o['status'] == 'paid') {
        email = o['email'] as String;
        plan = o['plan'] as String;
        return (true, 'already');
      }
      o['status'] = 'paid';
      o['paidAt'] = DateTime.now().toIso8601String();
      store.write('orders.json', orders);
      email = o['email'] as String;
      plan = o['plan'] as String;
      return (true, 'granted');
    });
    if (!marked.$1) return marked;

    final dur = kPlans[plan];
    if (dur == null) return (true, email);

    await store.withLock('accounts.json', () async {
      final accounts = store.read('accounts.json');
      final acc = accounts[email] as Map<String, dynamic>?;
      if (acc == null) return;
      final current = acc['vipExpire'] as String?;
      final base = (current != null &&
              DateTime.tryParse(current)?.isAfter(DateTime.now()) == true)
          ? DateTime.parse(current)
          : DateTime.now();
      acc['vipExpire'] = base.add(dur).toIso8601String();
      store.write('accounts.json', accounts);
    });
    return (true, email);
  }

  /// 按「金额+时间窗」匹配最早的待支付订单（个人收款码监听模式）
  Future<String?> matchPendingByAmount(int price) async {
    final orders = store.read('orders.json');
    String? best;
    var bestTime = '';
    orders.forEach((id, o) {
      final order = o as Map<String, dynamic>;
      if (order['status'] != 'pending') return;
      if ((order['amount'] as num).toInt() != price) return;
      final exp = DateTime.tryParse(order['expireAt'] as String? ?? '');
      if (exp == null || exp.isBefore(DateTime.now())) return;
      final created = order['createdAt'] as String? ?? '';
      if (best == null || created.compareTo(bestTime) < 0) {
        best = id;
        bestTime = created;
      }
    });
    return best;
  }
}
