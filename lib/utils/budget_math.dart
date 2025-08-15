// Cálculo do "mínimo esperado" hoje baseado no ciclo mensal.
// Assume que no DIA do pagamento o mínimo = valorMensal,
// e vai decrescendo linearmente até 0 no próximo dia de pagamento.

class BudgetStatus {
  final DateTime lastRefill;
  final DateTime nextRefill;
  final double expectedMin; // mínimo esperado hoje
  final double progress;    // [0..1] quanto do período já passou

  BudgetStatus({
    required this.lastRefill,
    required this.nextRefill,
    required this.expectedMin,
    required this.progress,
  });
}

DateTime _refillDateForMonth(int year, int month, int dayOfMonth) {
  // clamp simples: garantimos 1..30 (já vem assim da UI)
  final d = dayOfMonth.clamp(1, 30);
  return DateTime(year, month, d);
}

BudgetStatus computeBudgetStatus({
  required DateTime now,
  required int dayOfMonth,     // 1..30
  required double monthlyAmount,
}) {
  // Regras para achar "último" e "próximo" pagamento
  final thisMonthRefill = _refillDateForMonth(now.year, now.month, dayOfMonth);
  late DateTime lastRefill;
  late DateTime nextRefill;

  if (!now.isBefore(thisMonthRefill)) {
    // hoje >= refill deste mês → último = este mês; próximo = mês que vem
    final y = (now.month == 12) ? now.year + 1 : now.year;
    final m = (now.month == 12) ? 1 : now.month + 1;
    lastRefill = thisMonthRefill;
    nextRefill = _refillDateForMonth(y, m, dayOfMonth);
  } else {
    // hoje < refill deste mês → último = mês passado; próximo = este mês
    final y = (now.month == 1) ? now.year - 1 : now.year;
    final m = (now.month == 1) ? 12 : now.month - 1;
    lastRefill = _refillDateForMonth(y, m, dayOfMonth);
    nextRefill = thisMonthRefill;
  }

  final totalSecs = nextRefill.difference(lastRefill).inSeconds;
  final elapsedSecs = now.difference(lastRefill).inSeconds.clamp(0, totalSecs);
  final progress = totalSecs > 0 ? (elapsedSecs / totalSecs) : 1.0;

  final expectedMin = (monthlyAmount * (1.0 - progress)).clamp(0.0, monthlyAmount);

  return BudgetStatus(
    lastRefill: lastRefill,
    nextRefill: nextRefill,
    expectedMin: expectedMin,
    progress: progress,
  );
}
