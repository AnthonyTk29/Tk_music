package com.tkmusic.app

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin

/// FFT real (radix-2, tamaño potencia de 2) y agrupado en bandas
/// logarítmicas — usado para el espectro en vivo del Ecualizador. A
/// diferencia del efecto Visualizer del sistema (que algunos fabricantes
/// rechazan a nivel de AudioFlinger para la sesión de una app puntual), esto
/// opera sobre PCM que decodificamos nosotros mismos con
/// MediaExtractor/MediaCodec — el mismo mecanismo que ya usa la forma de
/// onda, que sí funciona en cualquier dispositivo porque no depende de un
/// efecto de audio del sistema.
object SpectrumMath {
    /// Ventana de Hann + FFT sobre [samples] (tamaño potencia de 2), y
    /// devuelve la magnitud de cada bin de 0 a size/2 (Nyquist).
    fun magnitudes(samples: ShortArray): DoubleArray {
        val n = samples.size
        val re = DoubleArray(n)
        val im = DoubleArray(n)
        for (i in 0 until n) {
            val w = 0.5 - 0.5 * cos(2.0 * PI * i / (n - 1))
            re[i] = samples[i] * w
        }
        fft(re, im)
        val bins = n / 2
        val mags = DoubleArray(bins)
        for (i in 0 until bins) mags[i] = hypot(re[i], im[i])
        return mags
    }

    /// Agrupa [magnitudes] en [bandCount] bandas con escala logarítmica de
    /// frecuencia (los graves ocupan proporcionalmente más bandas, igual
    /// que el oído los distingue más fino) y normaliza cada una a 0.0-1.0.
    fun toBands(magnitudes: DoubleArray, bandCount: Int, fftSize: Int): FloatArray {
        val binCount = magnitudes.size
        val bands = FloatArray(bandCount)
        if (binCount <= 1) return bands
        // Referencia real de 0dB: la magnitud máxima teórica de un bin para
        // una onda senoidal a escala completa (amplitud 32768 en PCM de 16
        // bits) después de la ventana de Hann. La ganancia coherente de Hann
        // es ~0.5, y el pico de magnitud de una sola frecuencia en un
        // espectro de un solo lado queda en ~fftSize/2 * esa ganancia, o
        // sea fftSize/4. La primera versión de esto dividía por [fftSize]
        // a secas (sin relación con una escala 0dBFS real), lo que daba
        // valores de dB muy por encima del rango asumido más abajo — con
        // eso, casi cualquier volumen normal saturaba las barras arriba del
        // todo y nunca bajaban. Con la referencia correcta, la música
        // típica (que reparte su energía entre muchas bandas, no la
        // concentra en una sola) cae en un rango de dB bastante más bajo
        // que 0, y las barras sí tienen recorrido real de arriba a abajo.
        val maxMagnitude = 32768.0 * fftSize / 4.0
        for (b in 0 until bandCount) {
            val start = binCount.toDouble().pow(b.toDouble() / bandCount)
                .toInt().coerceIn(1, binCount - 1)
            val end = binCount.toDouble().pow((b + 1).toDouble() / bandCount)
                .toInt().coerceIn(start + 1, binCount)
            var peak = 0.0
            for (i in start until end) if (magnitudes[i] > peak) peak = magnitudes[i]
            // -55dB a -5dB mapeado a 0.0-1.0: 0dBFS pleno es un caso raro
            // (implicaría toda la energía de la ventana concentrada en una
            // sola frecuencia), así que el techo se deja unos dB por debajo
            // para que la música fuerte de verdad llegue arriba. Sigue
            // siendo una estimación — el ajuste fino real solo se puede
            // hacer escuchando música de verdad en el equipo.
            val db = if (peak > 0) 20 * log10(peak / maxMagnitude) else -100.0
            bands[b] = ((db + 55) / 50).toFloat().coerceIn(0f, 1f)
        }
        return bands
    }

    private fun fft(re: DoubleArray, im: DoubleArray) {
        val n = re.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j or bit
            if (i < j) {
                val tr = re[i]; re[i] = re[j]; re[j] = tr
                val ti = im[i]; im[i] = im[j]; im[j] = ti
            }
        }
        var len = 2
        while (len <= n) {
            val ang = -2.0 * PI / len
            val wr = cos(ang)
            val wi = sin(ang)
            var i = 0
            while (i < n) {
                var curWr = 1.0
                var curWi = 0.0
                val half = len / 2
                for (k in 0 until half) {
                    val uRe = re[i + k]
                    val uIm = im[i + k]
                    val vRe = re[i + k + half] * curWr - im[i + k + half] * curWi
                    val vIm = re[i + k + half] * curWi + im[i + k + half] * curWr
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + half] = uRe - vRe
                    im[i + k + half] = uIm - vIm
                    val nextWr = curWr * wr - curWi * wi
                    val nextWi = curWr * wi + curWi * wr
                    curWr = nextWr
                    curWi = nextWi
                }
                i += len
            }
            len = len shl 1
        }
    }
}
