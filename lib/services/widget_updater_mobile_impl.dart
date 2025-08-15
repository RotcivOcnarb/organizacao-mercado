import 'package:home_widget/home_widget.dart';
import '../config.dart';
import '../utils/budget_math.dart';

String _fmt(double v) => v.toStringAsFixed(2).replaceAll('.', ',');

class WidgetUpdater {
  static Future<void> update({
    required double balance,
    required int dayOfMonth,
    required double monthlyAmount,
    DateTime? now,
  }) async {
    final _now = now ?? DateTime.now();
    final budget = (monthlyAmount > 0)
        ? computeBudgetStatus(now: _now, dayOfMonth: dayOfMonth, monthlyAmount: monthlyAmount)
        : null;

    final expectedMin = budget?.expectedMin ?? 0.0;
    final diff = balance - expectedMin;
    final isPositive = diff >= 0;

    await HomeWidget.saveWidgetData('title', 'Saldo via Pluggy — $APP_VERSION');
    await HomeWidget.saveWidgetData('balance', _fmt(balance));
    await HomeWidget.saveWidgetData('label', isPositive ? 'Pode gastar' : 'Gastou a mais');
    await HomeWidget.saveWidgetData('diff', _fmt(isPositive ? diff : diff.abs()));
    await HomeWidget.saveWidgetData('isPositive', isPositive ? '1' : '0');

    await HomeWidget.updateWidget(name: 'MyAppWidgetProvider');
  }
}
