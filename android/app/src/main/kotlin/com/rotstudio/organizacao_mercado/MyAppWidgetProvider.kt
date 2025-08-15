package com.rotstudio.organizacao_mercado  // <-- tem que bater com a pasta

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Color
import android.widget.RemoteViews
import com.rotstudio.organizacao_mercado.R   // <-- importa o R do seu pacote
import es.antonborri.home_widget.HomeWidgetProvider

class MyAppWidgetProvider : HomeWidgetProvider() {

    // Assinatura correta do plugin: inclui SharedPreferences (widgetData)
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { appWidgetId ->
            val views = RemoteViews(context.packageName, R.layout.home_widget)

            val title = widgetData.getString("title", "Saldo via Pluggy") ?: "Saldo via Pluggy"
            val balance = widgetData.getString("balance", "0,00") ?: "0,00"
            val label = widgetData.getString("label", "Pode gastar") ?: "Pode gastar"
            val diff = widgetData.getString("diff", "0,00") ?: "0,00"
            val isPositive = (widgetData.getString("isPositive", "1") ?: "1") == "1"

            views.setTextViewText(R.id.text_title, title)
            views.setTextViewText(R.id.text_balance, "Saldo: R$ $balance")
            views.setTextViewText(R.id.text_diff_chip, "$label: R$ $diff")

            // Cor do texto do chip
            views.setTextColor(
                R.id.text_diff_chip,
                if (isPositive) android.graphics.Color.parseColor("#FF2E7D32")
                else android.graphics.Color.parseColor("#FFB00020")
            )
            // Fundo do chip (pill)
            views.setInt(
                R.id.text_diff_chip,
                "setBackgroundResource",
                if (isPositive) R.drawable.chip_positive else R.drawable.chip_negative
            )

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }

}
