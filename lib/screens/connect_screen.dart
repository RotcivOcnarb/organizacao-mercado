import 'package:flutter/material.dart';
import 'package:flutter_pluggy_connect/flutter_pluggy_connect.dart';

class ConnectScreen extends StatefulWidget {
  final String connectToken;
  const ConnectScreen({super.key, required this.connectToken});

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  String _status = 'Iniciando...';
  bool _isLoading = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conectar conta')),
      body: Stack(
        children: [
          PluggyConnect(
            connectToken: widget.connectToken,
            countries: const ['BR'],
            onOpen: () {
              debugPrint('Pluggy Connect aberto');
              setState(() {
                _status = 'Conectando à sua instituição financeira...';
                _isLoading = false;
              });
            },
            onClose: () {
              debugPrint('Pluggy Connect fechado pelo usuário');
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Conexão cancelada'),
                  backgroundColor: Colors.orange,
                ),
              );
              Navigator.maybePop(context);
            },
            onError: (err) {
              debugPrint('Erro no Connect: $err');
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Erro na conexão: $err'),
                  backgroundColor: Colors.red,
                ),
              );
              Navigator.maybePop(context);
            },
            onSuccess: (data) {
              try {
                debugPrint('Pluggy Connect sucesso: $data');
                final item = (data as Map)['item'] as Map?;
                final itemId = item?['id']?.toString();
                
                if (itemId != null && itemId.isNotEmpty) {
                  debugPrint('Item ID obtido com sucesso: $itemId');
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Conta conectada com sucesso!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                  Navigator.pop(context, itemId);
                } else {
                  debugPrint('Item ID não encontrado nos dados: $data');
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Não foi possível obter o ID da conta'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  Navigator.pop(context, null);
                }
              } catch (e) {
                debugPrint('Erro ao processar dados de sucesso: $e');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Erro ao processar dados: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
                Navigator.pop(context, null);
              }
            },
          ),
          if (_isLoading)
            Container(
              color: Colors.white,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(_status, style: const TextStyle(fontSize: 16)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
