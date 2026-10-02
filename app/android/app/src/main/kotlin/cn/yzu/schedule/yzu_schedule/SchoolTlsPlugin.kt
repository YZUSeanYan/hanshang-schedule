package cn.yzu.schedule.yzu_schedule

import android.net.http.X509TrustManagerExtensions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/**
 * 教务导入 WebView 的证书链补全校验。
 * Dart 侧契约（school_tls.dart）：仅在 UNTRUSTED + https + 443 时调用，
 * 方法 verifyCompletedChain，参数 { host, leaf(DER), intermediates(List<DER>) }；
 * 用系统信任库验证「叶子证书 + 内置/运行时中间证书」拼出的链，通过返回 true。
 *
 * 主机名也必须核对（review R14）：链补全通过 ≠ 证书属于目标域名——WebView
 * 的 SslError.getPrimaryError 只报"最严重"的错误，UNTRUSTED 可能同时叠加
 * SAN 不匹配，链修好后放行就会放行一次主机名冒充。这里用平台的
 * X509TrustManagerExtensions.checkServerTrusted(chain, authType, host)，
 * 它在链校验之外同时执行主机名（SAN/CN）校验，任一失败即抛异常。
 */
class SchoolTlsPlugin {

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "verifyCompletedChain") {
            result.notImplemented()
            return
        }
        val host = call.argument<String>("host")
        val leaf = call.argument<ByteArray>("leaf")
        val intermediates =
            call.argument<List<ByteArray>>("intermediates") ?: emptyList()
        if (host.isNullOrEmpty() || leaf == null || leaf.isEmpty()) {
            result.success(false)
            return
        }
        try {
            val factory = CertificateFactory.getInstance("X.509")
            val chain = mutableListOf<X509Certificate>()
            chain.add(
                factory.generateCertificate(ByteArrayInputStream(leaf)) as X509Certificate
            )
            for (bytes in intermediates) {
                try {
                    chain.add(
                        factory.generateCertificate(ByteArrayInputStream(bytes))
                            as X509Certificate
                    )
                } catch (_: Exception) {
                    // 单个中间证书损坏不致命，跳过继续尝试
                }
            }
            val tmf =
                TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(null as KeyStore?)
            val trustManager =
                tmf.trustManagers.filterIsInstance<X509TrustManager>().firstOrNull()
            if (trustManager == null) {
                result.success(false)
                return
            }
            val authType = chain[0].publicKey?.algorithm ?: "RSA"
            // 链 + 主机名一起校验；checkServerTrusted 返回受信链（本处只关心是否抛异常）
            val extensions = X509TrustManagerExtensions(trustManager)
            extensions.checkServerTrusted(chain.toTypedArray(), authType, host)
            result.success(true)
        } catch (_: Exception) {
            // 链不可信、主机名不匹配、证书过期等一律拒绝
            result.success(false)
        }
    }
}
