import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../config.dart';
import '../models/account.dart';
import '../services/backend_api.dart';
import '../services/secure_storage.dart';
import '../utils/budget_math.dart';

// Atualiza o widget Android (guardado por kIsWeb ao usar)
import '../services/widget_updater.dart';

// Conexão Pluggy: nativo no mobile e JS no Web (import condicional)
import 'connect_screen.dart';
import '../web/pluggy_web_stub.dart'
  if (dart.library.html) '../web/pluggy_web.dart' as pluggy_web;

// ===== NOVO: enum do modo de comparação =====
enum CompareMode { debit, credit, both }
String compareModeToStr(CompareMode m) {
  switch (m) {
    case CompareMode.debit: return 'debit';
    case CompareMode.credit: return 'credit';
    case CompareMode.both: return 'both';
  }
}
CompareMode strToCompareMode(String s) {
  switch (s) {
    case 'credit': return CompareMode.credit;
    case 'both': return CompareMode.both;
    case 'debit':
    default: return CompareMode.debit;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = BackendApi();
  final _storage = SecureStorageService();

  // Conexão/Saldo
  String? _itemId;
  bool _loading = false;
  String? _error;
  double? _totalBalance;
  List<Account> _accounts = [];

  // Configurações
  int _dayOfMonth = 1; // 1..30
  final TextEditingController _amountCtrl = TextEditingController();

  // NOVO: modo de comparação (default: débito)
  CompareMode _compareMode = CompareMode.debit;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() { _loading = true; _error = null; });
    try {
      // Restaurar config
      _dayOfMonth = await _storage.readDayOfMonth();
      _amountCtrl.text = await _storage.readMonthlyAmountRaw();

      final modeStr = await _storage.readCompareMode();
      _compareMode = strToCompareMode(modeStr);

      // Restaurar itemId e tentar saldo
      _itemId = await _storage.readItemId();
      if (_itemId != null) {
        await _fetchBalance();
      } else {
        if (!mounted) return;
        setState(() { _loading = false; });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Erro ao iniciar: $e'; _loading = false; });
    }
  }

  Future<void> _connect() async {
    final navigator = Navigator.of(context);
    setState(() { _error = null; _loading = true; });

    try {
      // 1) Pega o token no backend
      final token = await _api.createConnectToken(clientUserId: 'user-123');
      final preview = token.length > 8
          ? '${token.substring(0, 4)}…${token.substring(token.length - 4)}'
          : token;
      debugPrint('[connect] token len=${token.length} preview=$preview');

      // 2) Web vs Mobile
      String? itemId;
      if (kIsWeb) {
        itemId = await pluggy_web.openPluggyConnectWeb(token);
      } else {
        itemId = await navigator.push<String?>(
          MaterialPageRoute(builder: (_) => ConnectScreen(connectToken: token)),
        );
      }

      if (itemId == null || itemId.isEmpty) {
        throw Exception('Conexão cancelada');
      }

      // 3) Persiste e busca saldo
      await _storage.saveItemId(itemId);
      if (!mounted) return;
      setState(() { _itemId = itemId; });

      await _fetchBalance();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _fetchBalance() async {
    if (_itemId == null) {
      if (!mounted) return;
      setState(() { _loading = false; });
      return;
    }
    try {
      final res = await _api.fetchBalance(_itemId!);
      if (!mounted) return;
      setState(() {
        _totalBalance = res.totalBalance;
        _accounts = res.accounts;
        _loading = false;
        _error = null;
      });

      // Atualiza o widget Android com o valor de comparação atual
      if (!kIsWeb) {
        await WidgetUpdater.update(
          balance: _currentComparableAmount(),
          dayOfMonth: _dayOfMonth,
          monthlyAmount: _parseMonthlyAmount(),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _disconnect() async {
    await _storage.deleteItemId();
    if (!mounted) return;
    setState(() {
      _itemId = null;
      _totalBalance = null;
      _accounts = [];
      _error = null;
    });
  }

  Future<void> _saveSettings({bool showSnack = true}) async {
    final day = (_dayOfMonth < 1 || _dayOfMonth > 30) ? 1 : _dayOfMonth;

    // normaliza "1.234,56" => "1234.56"
    final raw = _amountCtrl.text.trim();
    final normalized = raw.replaceAll('.', '').replaceAll(',', '.');
    final parsed = double.tryParse(normalized);
    if (raw.isNotEmpty && parsed == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Valor mensal inválido')),
      );
      return;
    }

    await _storage.saveDayOfMonth(day);
    await _storage.saveMonthlyAmountRaw(raw);
    await _storage.saveCompareMode(compareModeToStr(_compareMode));

    if (showSnack && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configurações salvas')),
      );
    }

    // Atualiza widget Android com a nova preferência
    if (!kIsWeb) {
      await WidgetUpdater.update(
        balance: _currentComparableAmount(),
        dayOfMonth: _dayOfMonth,
        monthlyAmount: _parseMonthlyAmount(),
      );
    }

    if (mounted) setState(() {});
  }

  // ===== Helpers =====

  double _parseMonthlyAmount() {
    final raw = _amountCtrl.text.trim();
    if (raw.isEmpty) return 0.0;
    final normalized = raw.replaceAll('.', '').replaceAll(',', '.');
    return double.tryParse(normalized) ?? 0.0;
  }

  // Crédito = soma do disponível (limite - usado) das contas de crédito
  double _sumAvailableCredit(List<Account> accs) {
    double total = 0.0;
    for (final a in accs) {
      if (_isCreditAccount(a)) {
        total += a.availableCredit();
      }
    }
    return total;
  }


  /// Retorna o valor base atual para comparação, conforme modo selecionado
  double _currentComparableAmount() {
    final debit = _sumDebitBalances(_accounts);
    final creditAvail = _sumAvailableCredit(_accounts);
    switch (_compareMode) {
      case CompareMode.debit:
        return debit;               // apenas saldo das contas de depósito
      case CompareMode.credit:
        return creditAvail;         // limite disponível (limite - usado)
      case CompareMode.both:
        return debit + creditAvail; // soma dos dois
    }
  }


  bool _isCreditAccount(Account a) {
    final t = a.type.toUpperCase();
    return t.contains('CREDIT') || t.contains('CARD') || a.creditLimit != null || (a.available != null);
  }

  // SOMENTE contas não-crédito entram no "débito"
  double _sumDebitBalances(List<Account> accs) {
    double total = 0.0;
    for (final a in accs) {
      if (!_isCreditAccount(a)) {
        total += a.balance;
      }
    }
    return total;
  }

  String _fmtMoney(double v) => 'R\$ ${v.toStringAsFixed(2)}';
  String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yyyy = d.year.toString();
    return '$dd/$mm/$yyyy';
  }

  @override
  Widget build(BuildContext context) {
    final hasItem = _itemId != null;
    final hasBalance = _totalBalance != null;

    final monthlyAmount = _parseMonthlyAmount();
    final budget = (monthlyAmount > 0)
        ? computeBudgetStatus(
            now: DateTime.now(),
            dayOfMonth: _dayOfMonth,
            monthlyAmount: monthlyAmount,
          )
        : null;

    final comparableNow = _currentComparableAmount();
    final expectedMin = budget?.expectedMin ?? 0.0;
    final diff = comparableNow - expectedMin;
    final isPositive = diff >= 0;

    String headerTitle() {
      switch (_compareMode) {
        case CompareMode.debit:
          return 'Saldo em conta (comparação)';
        case CompareMode.credit:
          return 'Limite de crédito disponível (comparação)';
        case CompareMode.both:
          return 'Saldo + Crédito disponível (comparação)';
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Saldo via Pluggy — $APP_VERSION'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : hasItem
                  ? SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasBalance) ...[
                            Text(
                              headerTitle(),
                              style: Theme.of(context).textTheme.titleLarge,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _fmtMoney(comparableNow),
                              style: Theme.of(context).textTheme.displaySmall,
                              textAlign: TextAlign.center,
                            ),
                          ] else ...[
                            const Text(
                              'Conectado. Carregando valores…',
                              textAlign: TextAlign.center,
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                _error!,
                                style: const TextStyle(color: Colors.red),
                                textAlign: TextAlign.center,
                              ),
                            ]
                          ],
                          const SizedBox(height: 16),

                          if (_accounts.isNotEmpty) ...[
                            const Text('Contas'),
                            const SizedBox(height: 8),
                            ..._accounts.map((a) {
                              final isCredit = a.type.toUpperCase().contains('CREDIT');
                              return ListTile(
                                leading: Icon(
                                  isCredit ? Icons.credit_card : Icons.account_balance_wallet,
                                ),
                                title: Text(a.name),
                                subtitle: Text(isCredit
                                    ? 'Crédito — Limite disp.: ${_fmtMoney(a.availableCredit())}'
                                    : a.currency),
                                trailing: Text(
                                  a.type.toUpperCase().contains('CREDIT') || a.creditLimit != null || a.available != null
                                    ? 'Usado: ${_fmtMoney(a.creditUsed())}'
                                    : _fmtMoney(a.balance),
                                ),
                              );
                            }),
                            const SizedBox(height: 8),
                          ],

                          const Divider(height: 32),

                          // ====== Orçamento ======
                          Text('Orçamento mensal',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Card(
                            elevation: 0.5,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: (monthlyAmount <= 0 || budget == null)
                                  ? const Text(
                                      'Defina o "Valor mensal" nas Configurações para ver a projeção.',
                                    )
                                  : Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.payments, size: 20),
                                            const SizedBox(width: 8),
                                            Text('Valor mensal: ${_fmtMoney(monthlyAmount)}'),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            const Icon(Icons.event, size: 20),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Ciclo: ${_fmtDate(budget.lastRefill)} → ${_fmtDate(budget.nextRefill)}',
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            const Icon(Icons.timeline, size: 20),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: ClipRRect(
                                                borderRadius: BorderRadius.circular(6),
                                                child: LinearProgressIndicator(
                                                  value: budget.progress,
                                                  minHeight: 8,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text('${(budget.progress * 100).toStringAsFixed(0)}%'),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            const Icon(Icons.flag, size: 20),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Mínimo esperado hoje: ${_fmtMoney(expectedMin)}',
                                              style: const TextStyle(fontWeight: FontWeight.w600),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: isPositive
                                                ? Colors.green.withOpacity(0.10)
                                                : Colors.red.withOpacity(0.10),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(
                                              color: isPositive ? Colors.green : Colors.red,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                isPositive ? Icons.check_circle : Icons.error,
                                                color: isPositive ? Colors.green : Colors.red,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  isPositive
                                                      ? 'Você pode gastar: ${_fmtMoney(diff)}'
                                                      : 'Você gastou a mais: ${_fmtMoney(diff.abs())}',
                                                  style: TextStyle(
                                                    color: isPositive ? Colors.green : Colors.red,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                            ),
                          ),

                          const SizedBox(height: 16),

                          // ====== Configurações ======
                          Text('Configurações',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          Card(
                            elevation: 0.5,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // NOVO: option box de modo de comparação
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Icon(Icons.swap_horiz, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: DropdownButtonFormField<CompareMode>(
                                          value: _compareMode,
                                          isExpanded: true, // evita overflow
                                          decoration: const InputDecoration(
                                            labelText: 'Modo de comparação',
                                            border: OutlineInputBorder(),
                                            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          ),
                                          items: const [
                                            DropdownMenuItem(
                                              value: CompareMode.debit,
                                              child: Text('Apenas débito (saldo)'),
                                            ),
                                            DropdownMenuItem(
                                              value: CompareMode.credit,
                                              child: Text('Apenas limite do crédito'),
                                            ),
                                            DropdownMenuItem(
                                              value: CompareMode.both,
                                              child: Text('Débito + Crédito (somados)'),
                                            ),
                                          ],
                                          onChanged: (v) async {
                                            if (v == null) return;
                                            setState(() => _compareMode = v);
                                            await _saveSettings(showSnack: false);
                                            setState(() {}); // re-render projeção
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      const Icon(Icons.calendar_today, size: 20),
                                      const SizedBox(width: 8),
                                      const Text('Dia do mês:'),
                                      const SizedBox(width: 12),
                                      DropdownButton<int>(
                                        value: _dayOfMonth,
                                        items: List.generate(30, (i) => i + 1)
                                            .map((d) => DropdownMenuItem<int>(
                                                  value: d,
                                                  child: Text(d.toString()),
                                                ))
                                            .toList(),
                                        onChanged: (v) async {
                                          if (v == null) return;
                                          setState(() { _dayOfMonth = v; });
                                          await _saveSettings(showSnack: false);
                                          setState(() {}); // re-render orçamento
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  TextField(
                                    controller: _amountCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Valor mensal (R\$)',
                                      hintText: 'Ex.: 250,00',
                                      prefixIcon: Icon(Icons.payments),
                                      border: OutlineInputBorder(),
                                    ),
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    inputFormatters: [
                                      FilteringTextInputFormatter.allow(RegExp(r'[0-9,.\s]')),
                                    ],
                                    onSubmitted: (_) async {
                                      await _saveSettings(showSnack: true);
                                      setState(() {});
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: ElevatedButton.icon(
                                      onPressed: () async {
                                        await _saveSettings();
                                        setState(() {});
                                      },
                                      icon: const Icon(Icons.save),
                                      label: const Text('Salvar configurações'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              TextButton(onPressed: _fetchBalance, child: const Text('Atualizar valores')),
                              const SizedBox(width: 8),
                              OutlinedButton(onPressed: _disconnect, child: const Text('Desconectar')),
                            ],
                          ),
                        ],
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Conecte sua conta uma única vez'),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          onPressed: _connect,
                          icon: const Icon(Icons.link),
                          label: const Text('Conectar com Pluggy'),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          Text(_error!, style: const TextStyle(color: Colors.red)),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _connect, child: const Text('Reconectar agora')),
                        ],
                        const SizedBox(height: 24),

                        // Configurações mesmo sem conexão
                        Text('Configurações',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Card(
                          elevation: 0.5,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.swap_horiz, size: 20),
                                    const SizedBox(width: 8),
                                    const Text('Modo de comparação:'),
                                    const SizedBox(width: 12),
                                    DropdownButton<CompareMode>(
                                      value: _compareMode,
                                      items: const [
                                        DropdownMenuItem(
                                          value: CompareMode.debit,
                                          child: Text('Apenas débito (saldo)'),
                                        ),
                                        DropdownMenuItem(
                                          value: CompareMode.credit,
                                          child: Text('Apenas limite do crédito'),
                                        ),
                                        DropdownMenuItem(
                                          value: CompareMode.both,
                                          child: Text('Débito + Crédito (somados)'),
                                        ),
                                      ],
                                      onChanged: (v) async {
                                        if (v == null) return;
                                        setState(() { _compareMode = v; });
                                        await _saveSettings(showSnack: false);
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    const Icon(Icons.calendar_today, size: 20),
                                    const SizedBox(width: 8),
                                    const Text('Dia do mês:'),
                                    const SizedBox(width: 12),
                                    DropdownButton<int>(
                                      value: _dayOfMonth,
                                      items: List.generate(30, (i) => i + 1)
                                          .map((d) => DropdownMenuItem<int>(
                                                value: d,
                                                child: Text(d.toString()),
                                              ))
                                          .toList(),
                                      onChanged: (v) async {
                                        if (v == null) return;
                                        setState(() { _dayOfMonth = v; });
                                        await _saveSettings(showSnack: false);
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _amountCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Valor mensal (R\$)',
                                    hintText: 'Ex.: 250,00',
                                    prefixIcon: Icon(Icons.payments),
                                    border: OutlineInputBorder(),
                                  ),
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  inputFormatters: [
                                    FilteringTextInputFormatter.allow(RegExp(r'[0-9,.\s]')),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: ElevatedButton.icon(
                                    onPressed: () async { await _saveSettings(); setState(() {}); },
                                    icon: const Icon(Icons.save),
                                    label: const Text('Salvar configurações'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
