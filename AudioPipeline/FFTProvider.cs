using System;

namespace StageSimWASAPI
{
    // Simple radix-2 FFT implementation for real-valued input
    public static class FFTProvider
    {
        private static float[] _window;
        private static int _windowSize;

        // Compute FFT of real-valued data (length must be power of 2)
        // Returns magnitude spectrum in output array (same length as input)
        public static void ComputeMagnitudeSpectrum(float[] input, float[] output, int size)
        {
            if (size <= 0 || (size & (size - 1)) != 0)
                return;

            EnsureWindow(size);

            // Copy to complex arrays with window applied (don't mutate input)
            float[] real = new float[size];
            float[] imag = new float[size];
            for (int i = 0; i < size; i++)
            {
                real[i] = input[i] * _window[i];
                imag[i] = 0f;
            }

            // In-place FFT
            FFT(real, imag, size);

            // Compute magnitude for first half (unique bins)
            int half = size / 2;
            for (int i = 0; i < half; i++)
            {
                output[i] = (float)Math.Sqrt(real[i] * real[i] + imag[i] * imag[i]);
            }

            // Mirror for second half (real FFT symmetry: bin k = bin N-k)
            for (int i = half; i < size; i++)
            {
                output[i] = output[size - i];
            }

            // Normalize similar to Unity's GetSpectrumData
            float norm = 2f / size;
            for (int i = 0; i < size; i++)
            {
                output[i] *= norm;
            }
        }

        private static void EnsureWindow(int size)
        {
            if (_window == null || _windowSize != size)
            {
                _window = new float[size];
                _windowSize = size;
                for (int i = 0; i < size; i++)
                {
                    _window[i] = (float)(0.54 - 0.46 * Math.Cos(2.0 * Math.PI * i / (size - 1)));
                }
            }
        }

        // In-place radix-2 Cooley-Tukey FFT
        private static void FFT(float[] real, float[] imag, int n)
        {
            // Bit reversal
            int j = 0;
            for (int i = 0; i < n - 1; i++)
            {
                if (i < j)
                {
                    float tr = real[i]; real[i] = real[j]; real[j] = tr;
                    float ti = imag[i]; imag[i] = imag[j]; imag[j] = ti;
                }
                int k = n >> 1;
                while (k <= j)
                {
                    j -= k;
                    k >>= 1;
                }
                j += k;
            }

            // Butterfly operations
            for (int len = 2; len <= n; len <<= 1)
            {
                float angle = (float)(-2.0 * Math.PI / len);
                float wReal = (float)Math.Cos(angle);
                float wImag = (float)Math.Sin(angle);

                int halfLen = len >> 1;
                for (int i = 0; i < n; i += len)
                {
                    float curReal = 1f, curImag = 0f;
                    for (int k = 0; k < halfLen; k++)
                    {
                        int idx1 = i + k;
                        int idx2 = i + k + halfLen;

                        float tReal = curReal * real[idx2] - curImag * imag[idx2];
                        float tImag = curReal * imag[idx2] + curImag * real[idx2];

                        real[idx2] = real[idx1] - tReal;
                        imag[idx2] = imag[idx1] - tImag;
                        real[idx1] += tReal;
                        imag[idx1] += tImag;

                        float newReal = curReal * wReal - curImag * wImag;
                        curImag = curReal * wImag + curImag * wReal;
                        curReal = newReal;
                    }
                }
            }
        }
    }
}
