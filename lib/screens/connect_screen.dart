import 'package:flutter/material.dart';
import 'package:flutter_pluggy_connect/flutter_pluggy_connect.dart';

class ConnectScreen extends StatelessWidget {
  final String connectToken;
  const ConnectScreen({super.key, required this.connectToken});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Conectar conta')),
      body: PluggyConnect(
        connectToken: connectToken, // <-- usa o token recebido
        countries: const ['BR'],
        onOpen: () => debugPrint('Pluggy Connect aberto'),
        onClose: () => Navigator.maybePop(context),
        onError: (err) {
          debugPrint('Erro no Connect: $err');
          Navigator.maybePop(context);
        },
        onSuccess: (data) {
          try {
            final item = (data as Map)['item'] as Map?;
            final itemId = item?['id']?.toString();
            Navigator.pop(context, itemId);
          } catch (_) {
            Navigator.pop(context, null);
          }
        },
      ),
    );
  }
}
