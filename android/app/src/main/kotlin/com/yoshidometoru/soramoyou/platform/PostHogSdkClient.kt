// ☁️ PostHog の SDK を呼ぶ薄い窓口（タスク 4.1）
package com.yoshidometoru.soramoyou.platform

import com.posthog.PostHog

/**
 * [PostHogClient] の本物。`com.posthog.PostHog` の静的 API をそのまま呼ぶだけで、判断は持たない。
 * SDK の初期化（[PostHogSetup.setUp]）より前に呼ばれた場合、SDK は何も送らない。
 * 単体テストの対象外（本番の送信はタスク 11.3 で PostHog のライブイベントを見て確かめる）。
 */
class PostHogSdkClient : PostHogClient {
    override fun capture(event: String, properties: Map<String, Any>) {
        PostHog.capture(event = event, properties = properties)
    }

    override fun screen(title: String) {
        PostHog.screen(screenTitle = title)
    }

    override fun identify(distinctId: String) {
        // uid だけで識別する。メールアドレス・表示名は渡さない（要件 15.5。iOS: LoggingService.swift:219-220）
        PostHog.identify(distinctId = distinctId)
    }

    override fun reset() {
        PostHog.reset()
    }
}
