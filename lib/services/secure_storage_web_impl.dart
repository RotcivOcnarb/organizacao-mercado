// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import '../config.dart';

class SecureStorageService {
  final html.Storage _ls = html.window.localStorage;

  // itemId (Pluggy)
  Future<void> saveItemId(String itemId) async { _ls[kItemKey] = itemId; }
  Future<String?> readItemId() async => _ls[kItemKey];
  Future<void> deleteItemId() async { _ls.remove(kItemKey); }

  // Dia do mês
  Future<void> saveDayOfMonth(int day) async { _ls[kCfgDayKey] = day.toString(); }
  Future<int> readDayOfMonth() async {
    final s = _ls[kCfgDayKey];
    final d = int.tryParse(s ?? '');
    if (d != null && d >= 1 && d <= 30) return d;
    return 1;
  }

  // Valor mensal (como string "br")
  Future<void> saveMonthlyAmountRaw(String raw) async { _ls[kCfgAmountKey] = raw; }
  Future<String> readMonthlyAmountRaw() async => _ls[kCfgAmountKey] ?? '';

  // NOVO: modo de comparação ('debit' | 'credit' | 'both')
  Future<void> saveCompareMode(String mode) async { _ls[kCfgCompareMode] = mode; }
  Future<String> readCompareMode() async => _ls[kCfgCompareMode] ?? 'debit';

  // (legado – manter por compatibilidade, não usado)
  Future<void> saveUseCreditMode(bool useCredit) async {
    _ls[kCfgUseCreditMode] = useCredit ? '1' : '0';
  }
  Future<bool> readUseCreditMode() async => _ls[kCfgUseCreditMode] == '1';
}
