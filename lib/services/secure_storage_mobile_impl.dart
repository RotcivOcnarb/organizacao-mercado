import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../config.dart';

class SecureStorageService {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  // itemId (Pluggy)
  Future<void> saveItemId(String itemId) => _storage.write(key: kItemKey, value: itemId);
  Future<String?> readItemId() => _storage.read(key: kItemKey);
  Future<void> deleteItemId() => _storage.delete(key: kItemKey);

  // Dia do mês
  Future<void> saveDayOfMonth(int day) =>
      _storage.write(key: kCfgDayKey, value: day.toString());
  Future<int> readDayOfMonth() async {
    final s = await _storage.read(key: kCfgDayKey);
    final d = int.tryParse(s ?? '');
    if (d != null && d >= 1 && d <= 30) return d;
    return 1;
  }

  // Valor mensal (como string "br")
  Future<void> saveMonthlyAmountRaw(String raw) =>
      _storage.write(key: kCfgAmountKey, value: raw);
  Future<String> readMonthlyAmountRaw() async =>
      (await _storage.read(key: kCfgAmountKey)) ?? '';

  // NOVO: modo de comparação ('debit' | 'credit' | 'both')
  Future<void> saveCompareMode(String mode) =>
      _storage.write(key: kCfgCompareMode, value: mode);
  Future<String> readCompareMode() async =>
      (await _storage.read(key: kCfgCompareMode)) ?? 'debit';

  // (legado – manter por compatibilidade, não usado)
  Future<void> saveUseCreditMode(bool useCredit) =>
      _storage.write(key: kCfgUseCreditMode, value: useCredit ? '1' : '0');
  Future<bool> readUseCreditMode() async =>
      (await _storage.read(key: kCfgUseCreditMode)) == '1';
}
