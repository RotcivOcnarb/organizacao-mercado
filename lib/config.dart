// Versão do app
const String APP_VERSION = 'v0.1.21';

// Backend
const String BACKEND_BASE_URL = 'https://qt7sd1anga.execute-api.us-east-1.amazonaws.com/default';
const String CONNECT_TOKEN_PATH = '/pluggyAuth';
const String BALANCE_PATH = '/pluggyBalance';

Uri connectTokenUrl() => Uri.parse('$BACKEND_BASE_URL$CONNECT_TOKEN_PATH');
Uri balanceUrl(String itemId) {
  // Adicionando timestamp para evitar cache da resposta
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  // Adicionando parâmetro refresh=1 para forçar atualização no backend
  return Uri.parse('$BACKEND_BASE_URL$BALANCE_PATH?itemId=${Uri.encodeComponent(itemId)}&refresh=1&_t=$timestamp');
}

// Storage keys
const String kItemKey = 'pluggy_item_id';
const String kCfgDayKey = 'cfg_day';
const String kCfgAmountKey = 'cfg_amount';

// NOVO: preferência de modo de comparação
// valores possíveis: 'debit' | 'credit' | 'both'
const String kCfgCompareMode = 'cfg_compare_mode';

// (legado – pode manter, não será mais usado, mas deixamos se você já tiver esse dado salvo)
const String kCfgUseCreditMode = 'cfg_use_credit_mode';