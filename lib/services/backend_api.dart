import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/account.dart';

class BackendApi {
  // Usando um novo cliente HTTP para cada solicitação para evitar problemas de cache
  http.Client _createClient() => http.Client();
  
  BackendApi();

  Future<String> createConnectToken({required String clientUserId}) async {
    final client = _createClient();
    try {
      final r = await client.post(
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
    } finally {
      client.close();
    }
  }

  Future<({double totalBalance, List<Account> accounts})> fetchBalance(String itemId, {bool forceRefresh = true, int retryCount = 0}) async {
    final client = _createClient();
    try {
      // Construir a URL base (já inclui refresh=1 e timestamp na configuração)
      final baseUrl = balanceUrl(itemId);
      
      // Adicionar um cabeçalho com timestamp único para evitar cache em qualquer nível
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      
      print('[API] Buscando saldo para itemId=$itemId, forceRefresh=$forceRefresh, retryCount=$retryCount');
      print('[API] URL: $baseUrl');
      
      final r = await client.get(
        baseUrl,
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
          'X-Request-Time': timestamp.toString(), // Cabeçalho único para cada requisição
          'X-Retry-Count': retryCount.toString(), // Para diagnóstico
        },
      );
      
      print('[API] Status: ${r.statusCode}');
      print('[API] Headers recebidos: ${r.headers}');
      print('[API] Corpo da resposta (primeiros 200 caracteres): ${r.body.substring(0, r.body.length > 200 ? 200 : r.body.length)}');
      
      // Verificar se o status é 202 (sincronização em andamento)
      if (r.statusCode == 202) {
        print('[API] Sincronização em andamento, aguardando 3 segundos para tentar novamente...');
        // Aguardar um pouco e tentar novamente
        await Future.delayed(const Duration(seconds: 3));
        return fetchBalance(itemId, forceRefresh: true, retryCount: retryCount + 1);
      }
      
      // Tratamento especial para erro 500 (Internal Server Error)
      if (r.statusCode == 500 && retryCount < 2) {
        print('[API] Erro 500 do servidor, aguardando 5 segundos para tentar novamente...');
        print('[API] Detalhes do erro 500: ${r.body}');
        // Tentar extrair mais informações do erro
        try {
          final errorData = jsonDecode(r.body) as Map<String, dynamic>;
          print('[API] Mensagem de erro do servidor: ${errorData['message']}');
          print('[API] Erro detalhado: ${errorData['error']}');
          print('[API] Tipo de erro: ${errorData['errorType'] ?? 'não especificado'}');
        } catch (e) {
          print('[API] Não foi possível decodificar detalhes do erro: $e');
        }
        // Aguardar um pouco mais e tentar novamente
        await Future.delayed(const Duration(seconds: 5));
        return fetchBalance(itemId, forceRefresh: true, retryCount: retryCount + 1);
      }
      
      if (r.statusCode != 200) {
        print('[API] Erro ao buscar saldo: ${r.statusCode} - ${r.body}');
        throw Exception('Falha ao buscar saldo: ${r.statusCode} - ${r.body}');
      }
      
      print('[API] Decodificando resposta JSON...');
      Map<String, dynamic> data;
      try {
        data = jsonDecode(r.body) as Map<String, dynamic>;
        print('[API] Campos disponíveis na resposta: ${data.keys.join(', ')}');
      } catch (e) {
        print('[API] ERRO ao decodificar JSON: $e');
        print('[API] Corpo da resposta problemático: ${r.body}');
        rethrow;
      }
      
      print('[API] Extraindo lista de contas...');
      final results = (data['accounts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      print('[API] Número de contas no JSON: ${results.length}');
      
      print('[API] Convertendo para objetos Account...');
      final accounts = results.map(Account.fromMap).toList();
      
      print('[API] Extraindo saldo total...');
      final total = (data['totalBalance'] is num) ? (data['totalBalance'] as num).toDouble() : 0.0;
      print('[API] Valor do saldo total extraído: $total');
      
      // Verificar totais adicionais se disponíveis
      if (data.containsKey('totals')) {
        final totals = data['totals'] as Map<String, dynamic>?;
        if (totals != null) {
          print('[API] Totais adicionais: deposits=${totals['deposits']}, ' +
                'creditAvailable=${totals['creditAvailable']}, ' +
                'allAccountsBalanceSum=${totals['allAccountsBalanceSum']}');
        }
      }
      
      print('[API] Contas encontradas: ${accounts.length}, saldo total: $total');
      if (accounts.isEmpty) {
        print('[API] ALERTA: Nenhuma conta encontrada!');
      }
      
      // Se não temos contas ou o saldo total é zero, e ainda não tentamos muitas vezes,
      // podemos tentar novamente para garantir que temos dados atualizados
      if (forceRefresh && retryCount < 3 && (accounts.isEmpty || total == 0.0)) {
        print('[API] Dados vazios ou zerados, aguardando 3 segundos para tentar novamente...');
        await Future.delayed(const Duration(seconds: 3));
        return fetchBalance(itemId, forceRefresh: true, retryCount: retryCount + 1);
      }
      
      return (totalBalance: total, accounts: accounts);
    } catch (e, stackTrace) {
      print('[API] Exceção ao buscar saldo: $e');
      print('[API] Stack trace: $stackTrace');
      rethrow;
    } finally {
      client.close();
    }
  }
}
