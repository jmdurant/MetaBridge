package com.specbridge.app

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private lateinit var metaWearablesPlugin: MetaWearablesPlugin

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Initialize Meta Wearables Plugin
        metaWearablesPlugin = MetaWearablesPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Handle initial deep link
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        intent?.data?.let { uri ->
            if (uri.scheme == "specbridge") {
                metaWearablesPlugin.handleIncomingUrl(uri.toString())
            }
        }
    }

    override fun onDestroy() {
        metaWearablesPlugin.dispose()
        super.onDestroy()
    }
}
