# Saldo via Pluggy — Flutter + AWS Lambda

App Flutter (Android + Web) que conecta sua conta via **Pluggy Connect** e exibe:
- **Saldo** (apenas contas de depósito),
- **Limite de crédito disponível**,
- **Projeção de gasto** baseada em dia de aporte e valor mensal,
- **Modos de comparação**: **débito**, **crédito** ou **ambos**.

Backend serverless em **AWS Lambda** expõe:
- `POST /connect-token` → gera **connectToken** do Pluggy,
- `GET|POST /balance` → retorna contas + totais (com enriquecimento de limite do cartão).

Inclui **Widget Android** (4×1) mostrando saldo/folga e atalho para abrir o app.

---

## 📦 Stack

- **Frontend**: Flutter (Android + Web)
- **Backend**: AWS Lambda (Node.js ESM), API Gateway (HTTP), CloudWatch Logs
- **Agregador financeiro**: Pluggy (`/auth` com `clientId/secret` → usar `X-API-KEY` nas chamadas)
- **Persistência**:
  - Mobile: `flutter_secure_storage`
  - Web: `localStorage`

---

## ✨ Features

- Conexão única via Pluggy Connect (salva `itemId` para próximas aberturas)
- Tela de **Configurações**:
  - **Dia do mês** (1–30)
  - **Valor mensal** (R$)
  - **Modo de comparação**: Deb. / Cred. / Ambos (persistente)
- **Cálculo linear** do “mínimo esperado hoje” entre último e próximo aporte
- Card de status: **“pode gastar”** (verde) vs **“gastou a mais”** (vermelho)
- **Widget Android 4×1** com bordas/elevação e resize horizontal/vertical
- Suporte a **Web** (CORS, armazenamento compatível e Pluggy Connect web)

---

## 🗂 Estrutura (resumo)

```
lib/
  config.dart                 # APP_VERSION, BACKEND_BASE_URL, endpoints
  models/
    account.dart              # parsing + helpers (creditUsed/availableCredit)
  screens/
    home_screen.dart          # UI principal
    connect_screen.dart       # fluxo nativo do Pluggy (Android)
  services/
    backend_api.dart
    secure_storage.dart       # facade
    secure_storage_mobile_impl.dart
    secure_storage_web_impl.dart
    widget_updater.dart       # atualização do widget Android
  utils/
    budget_math.dart
  web/
    pluggy_web.dart           # Pluggy Connect Web
    pluggy_web_stub.dart
android/
  app/src/main/res/xml/home_widget_info.xml
  app/src/main/kotlin/.../MyAppWidgetProvider.kt
```

---

## ⚙️ Configuração

### 1) Backend (AWS)

Crie duas Lambdas e exponha via **API Gateway**:

- **`/connect-token`** (Lambda “pluggyAuth”)  
  Recebe `clientUserId` (opcional) e devolve `connectToken`.  
  *Env vars*:  
  - `PLUGGY_CLIENT_ID`  
  - `PLUGGY_CLIENT_SECRET`  
  - `PLUGGY_API_BASE` (opcional, padrão `https://api.pluggy.ai`)  
  - `CORS_ORIGINS` (ex.: `http://127.0.0.1:8080,https://seu-dominio.com`)

- **`/balance`** (Lambda “balance”)  
  Usa `POST /auth` no Pluggy para obter **apiKey**, e nas chamadas seguintes usa **`X-API-KEY`**.  
  Enriquecimento: se a conta de crédito não trouxer `creditLimit`/`available`, busca o **detalhe** da conta e tenta ler campos aninhados (`creditData.limit`, etc).  
  *Env vars*:  
  - `PLUGGY_CLIENT_ID`  
  - `PLUGGY_CLIENT_SECRET`  
  - `PLUGGY_API_BASE` (opcional)  
  - `CORS_ORIGINS`  
  - `DEBUG_RAW=1` (opcional; loga amostras cruas no CloudWatch)

> **CORS**: garanta CORS no API Gateway **e** no Lambda (cabeçalhos `Access-Control-*`).

**Exemplos de teste (curl)**

```bash
# CONNECT TOKEN
curl -X POST 'https://<api>/connect-token'   -H 'Content-Type: application/json'   -d '{"clientUserId":"user-123"}'

# BALANCE (via GET)
curl 'https://<api>/balance?itemId=<SEU_ITEM_ID>&debug=auth'

# BALANCE (via POST)
curl -X POST 'https://<api>/balance'   -H 'Content-Type: application/json'   -d '{"itemId":"<SEU_ITEM_ID>"}'
```

**Resposta /balance (ex.)**
```json
{
  "totalBalance": 200.00,
  "totals": {
    "deposits": 200.00,
    "creditAvailable": 32.41,
    "allAccountsBalanceSum": 1075.59
  },
  "accounts": [
    {
      "id": "...",
      "name": "Conta Corrente",
      "type": "DEPOSIT",
      "currency": "BRL",
      "balance": 200.00
    },
    {
      "id": "...",
      "name": "Cartão Santander",
      "type": "CREDIT_CARD",
      "balance": 1075.59,          // usado (heurística)
      "creditLimit": 1108.00,      // enriquecido via detalhe
      "available": 32.41
    }
  ]
}
```

> **Definições importantes**:  
> - **Débito** = soma de **contas não-crédito** (DEPOSIT, CHECKING, SAVINGS).  
> - **Crédito** = **limite disponível** (`creditLimit - usado`) **nunca negativo**.  
> - **Ambos** = Débito + Crédito disponível.

---

### 2) Frontend (Flutter)

Edite `lib/config.dart`:

```dart
const String APP_VERSION = 'v0.1.3'; // altere aqui
const String BACKEND_BASE_URL = 'https://<SEU_API_GATEWAY>';
const String CONNECT_TOKEN_PATH = '/connect-token';
const String BALANCE_PATH = '/balance';
```

- **Persistência**:
  - Mobile: `flutter_secure_storage` (itemId, configs)
  - Web: `localStorage` (mapeado na impl. web)

- **Pluggy Connect**:
  - Android: `ConnectScreen` (SDK nativo)
  - Web: `pluggy_web.dart` (iframe/modal do Pluggy)

- **Widget Android**:
  - Layout 4×1 configurado em `res/xml/home_widget_info.xml`
  - Provider em `MyAppWidgetProvider.kt`
  - Atualização via `WidgetUpdater.update(...)` quando saldo/config muda

---

## ▶️ Rodando

### Android (desenvolvimento)
```bash
flutter clean
flutter pub get
flutter run --no-fast-start
```

**VSCode Task (opcional)** – `.vscode/tasks.json`:
```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Flutter: Clean+Get+Run",
      "type": "shell",
      "command": "flutter clean && flutter pub get && flutter run --no-fast-start",
      "group": { "kind": "build", "isDefault": true },
      "problemMatcher": []
    }
  ]
}
```

Abra o **Command Palette → Run Task → Flutter: Clean+Get+Run**.

### Web (desenvolvimento)
```bash
flutter run -d chrome --web-renderer html
# se sua versão do Flutter não aceitar --web-renderer, use apenas:
# flutter run -d chrome
```

### Web (deploy em S3)
1. `flutter build web --web-renderer html`  
2. Habilite **Static website hosting** no S3 e suba a pasta `build/web`.  
3. **CORS** no API Gateway/Lambda para o domínio do S3 (ou CloudFront).  

---

## 🧭 UX/Layouts

- **Overflow à direita (dropdowns)**: usamos `DropdownButtonFormField` com `isExpanded: true` + `Expanded` no `Row`.
- **Safe area inferior**: o `Scaffold` envolve o body em `SafeArea` e soma `MediaQuery.padding.bottom` no padding para não “colar” nos gestos/barras do sistema.

---

## 🐞 Troubleshooting

- **403 em auth Pluggy**: usar `POST /auth` com `{clientId, clientSecret}` e, nas chamadas, **`X-API-KEY`** com a **apiKey** recebida.  
  Chame `/balance?itemId=...&debug=auth` para receber `_debug.auth` na resposta.
- **CORS (Web)**: configure `CORS_ORIGINS` no Lambda e habilite CORS no API Gateway.
- **Crédito vindo 0 (limit)**: o Lambda enriquece pelo **detalhe da conta** (paths aninhados como `creditData.limit`). Ative `DEBUG_RAW=1` e confira os logs.
- **App “não atualiza” após mudar código**: faça **clean + cold run** (`flutter clean && flutter pub get && flutter run --no-fast-start`).
- **Overflow no dropdown**: já mitigado com `isExpanded: true` (veja seção UX).
- **Botões “embaixo” do navbar**: já mitigado com `SafeArea` + padding extra.

---

## 🔒 Notas de segurança

- **Nunca** exponha `clientSecret` no app. Somente no **backend**.
- Em mobile, o `itemId` vai para **Keychain/Keystore** via `flutter_secure_storage`.  
  Em Web, usamos `localStorage` (limitações de segurança do browser).
- Revogue chaves/credenciais se publicar o repositório como **público**.

---

## 🗺 Roadmap (sugestões)

- Histórico e gráfico do “mínimo esperado” vs saldo real
- Suporte a múltiplos **itens** (bancos) e seleção por instituição
- Exportação CSV/Excel
- Tema escuro

---

## 📝 Licença

Defina a licença do projeto (ex.: MIT).
