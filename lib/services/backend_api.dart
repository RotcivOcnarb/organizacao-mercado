import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/account.dart';

class BackendApi {
  final http.Client _client;
  BackendApi({http.Client? client}) : _client = client ?? http.Client();

  Future<String> createConnectToken({required String clientUserId}) async {
    final r = await _client.post(
      connectTokenUrl(),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'clientUserId': clientUserId}),
    );
    if (r.statusCode != 200) {
      throw Exception('Connect token falhou: ${r.body}');
    }
    final map = jsonDecode(r.body) as Map<String, dynamic>;
    final token = (map['connectToken'] ?? map['accessToken'])?.toString();
    if (token == null) throw Exception('Token ausente na resposta');
    return token;
  }

  Future<({double totalBalance, List<Account> accounts})> fetchBalance(String itemId) async {
    final r = await _client.get(
      balanceUrl(itemId),
      headers: {'Content-Type': 'application/json'},
    );
    if (r.statusCode != 200) {
      throw Exception('Falha ao buscar saldo: ${r.body}');
    }
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final results = (data['accounts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final accounts = results.map(Account.fromMap).toList();
    final total = (data['totalBalance'] is num) ? (data['totalBalance'] as num).toDouble() : 0.0;
    return (totalBalance: total, accounts: accounts);
  }
}
