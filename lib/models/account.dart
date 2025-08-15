class Account {
  final String id;
  final String name;
  final String currency;
  final double balance;       // p/ crédito, muitos conectores usam como "usado"
  final String type;
  final double? creditLimit;  // vamos tentar achar em várias chaves, inclusive aninhadas
  final double? available;

  Account({
    required this.id,
    required this.name,
    required this.currency,
    required this.balance,
    required this.type,
    this.creditLimit,
    this.available,
  });

  factory Account.fromMap(Map<String, dynamic> a) {
    double _toDouble(dynamic v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v.replaceAll(',', '.')) ?? 0.0;
      return 0.0;
    }

    String _toStr(dynamic v) => (v ?? '').toString();

    double? _pickDouble(List<String> keys) {
      for (final k in keys) {
        if (a.containsKey(k) && a[k] != null) {
          final v = a[k];
          if (v is num) return v.toDouble();
          if (v is String) {
            final p = double.tryParse(v.replaceAll(',', '.'));
            if (p != null) return p;
          }
        }
      }
      return null;
    }

    // NOVO: busca aninhada (ex.: creditData.limit)
    double? _pickDoubleNested(List<List<String>> paths) {
      for (final path in paths) {
        dynamic cur = a;
        bool ok = true;
        for (final key in path) {
          if (cur is Map && cur.containsKey(key) && cur[key] != null) {
            cur = cur[key];
          } else {
            ok = false;
            break;
          }
        }
        if (ok) {
          if (cur is num) return cur.toDouble();
          if (cur is String) {
            final p = double.tryParse(cur.replaceAll(',', '.'));
            if (p != null) return p;
          }
        }
      }
      return null;
    }

    final type = _toStr(a['type'] ?? a['accountType']).trim();

    // tenta várias possibilidades
    final creditLimit = _pickDouble([
          'creditLimit', 'limit', 'credit_line', 'credit_line_amount',
          'creditLimitLocalCurrency'
        ]) ??
        _pickDoubleNested([
          ['creditData', 'creditLimit'],
          ['creditData', 'limit'],
          ['credit_card', 'limit'],
          ['card', 'creditLimit'],
          ['card', 'limit'],
        ]);

    final available = _pickDouble([
          'available', 'availableBalance', 'availableCredit',
          'available_amount', 'available_limit'
        ]) ??
        _pickDoubleNested([
          ['creditData', 'available'],
          ['card', 'available'],
        ]);

    return Account(
      id: _toStr(a['id']),
      name: _toStr(a['name'] ?? a['marketingName'] ?? 'Conta'),
      currency: _toStr(a['currencyCode'] ?? 'BRL'),
      balance: _toDouble(a['balance']),
      type: type,
      creditLimit: creditLimit,
      available: available,
    );
  }

  bool get _isCredit {
    final t = type.toUpperCase();
    return t.contains('CREDIT') || t.contains('CARD') || creditLimit != null || (available != null);
  }

  double creditUsed() {
    if (!_isCredit) return 0.0;
    if (creditLimit != null && available != null) {
      final used = creditLimit! - available!;
      return used.isFinite ? used.clamp(0.0, creditLimit!) : 0.0;
    }
    // fallback: muitos conectores reportam balance = usado (às vezes negativo)
    final used = balance.abs();
    if (creditLimit != null) return used.clamp(0.0, creditLimit!);
    return used;
  }

  /// DISPONÍVEL = limite - usado (ou 'available' se existir). Nunca negativo.
  double availableCredit() {
    if (!_isCredit) return 0.0;

    if (available != null) {
      if (creditLimit != null) return available!.clamp(0.0, creditLimit!);
      return available!.clamp(0.0, double.infinity);
    }
    if (creditLimit == null) return 0.0;

    final used = creditUsed();
    final avail = creditLimit! - used;
    return avail.isFinite ? (avail < 0 ? 0.0 : avail) : 0.0;
  }
}
