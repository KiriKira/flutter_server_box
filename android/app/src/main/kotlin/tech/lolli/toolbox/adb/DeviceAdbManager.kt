package tech.lolli.toolbox.adb

import android.content.Context
import android.os.Build
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.concurrent.TimeUnit

class DeviceAdbManager(context: Context) : AbsAdbConnectionManager() {
    private val material = KeyMaterial.loadOrCreate(context.applicationContext)

    init {
        setApi(Build.VERSION.SDK_INT)
        setHostAddress("127.0.0.1")
        setTimeout(12, TimeUnit.SECONDS)
        setThrowOnUnauthorised(true)
    }

    override fun getPrivateKey(): PrivateKey = material.privateKey

    override fun getCertificate(): Certificate = material.certificate

    override fun getDeviceName(): String = "ServerBox"


}

private data class KeyMaterial(
    val privateKey: PrivateKey,
    val certificate: Certificate,
) {
    companion object {
        private const val PRIVATE_KEY_FILE = "adb_private.key"
        private const val CERT_FILE = "adb_cert.der"

        @Synchronized
        fun loadOrCreate(context: Context): KeyMaterial {
            val privateFile = File(context.noBackupFilesDir, PRIVATE_KEY_FILE)
            val certFile = File(context.noBackupFilesDir, CERT_FILE)

            if (privateFile.isFile && certFile.isFile) {
                runCatching {
                    val privateKey = KeyFactory.getInstance("RSA")
                        .generatePrivate(PKCS8EncodedKeySpec(privateFile.readBytes()))
                    val certificate = certFile.inputStream().use {
                        CertificateFactory.getInstance("X.509").generateCertificate(it)
                    }
                    check((privateKey as java.security.interfaces.RSAPrivateKey).modulus ==
                        (certificate.publicKey as java.security.interfaces.RSAPublicKey).modulus) { "Incomplete ADB identity" }
                    return KeyMaterial(privateKey, certificate)
                }
            }

            val generator = KeyPairGenerator.getInstance("RSA")
            generator.initialize(2048, SecureRandom())
            val pair = generator.generateKeyPair()

            val now = System.currentTimeMillis()
            val subject = X500Name("CN=ServerBox")
            val builder = JcaX509v3CertificateBuilder(
                subject,
                BigInteger(64, SecureRandom()).abs().add(BigInteger.ONE),
                Date(now - 60_000),
                Date(now + TimeUnit.DAYS.toMillis(3650)),
                subject,
                pair.public,
            )
            val signer = JcaContentSignerBuilder("SHA256withRSA").build(pair.private)
            val certificate = JcaX509CertificateConverter().getCertificate(builder.build(signer))

            privateFile.writeBytes(pair.private.encoded)
            certFile.writeBytes(certificate.encoded)
            return KeyMaterial(pair.private, certificate)
        }
    }
}
