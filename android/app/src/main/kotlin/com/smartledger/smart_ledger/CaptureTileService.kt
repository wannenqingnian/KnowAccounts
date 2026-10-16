package com.smartledger.smart_ledger

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Each tap delegates to the connected accessibility one-frame screenshot. */
class CaptureTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply { label = "截图记账"; state = Tile.STATE_INACTIVE; updateTile() }
    }
    override fun onClick() {
        super.onClick()
        val open = Runnable {
            val intent = Intent(this, CaptureActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
            if (Build.VERSION.SDK_INT >= 34) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            } else {
                @Suppress("DEPRECATION")
                startActivityAndCollapse(intent)
            }
        }
        if (isLocked) unlockAndRun(open) else open.run()
    }
}
