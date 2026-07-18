using System;
using System.Runtime.InteropServices;

namespace StageSimWASAPI
{
    public class WASAPICapture : IDisposable
    {
        private const string DLL = "WASAPINative";

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int WASAPI_StartCapture();

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int WASAPI_GetSampleRate();

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int WASAPI_GetChannels();

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int WASAPI_GetBitsPerSample();

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern int WASAPI_ReadData(byte[] buffer, int maxSize);

        [DllImport(DLL, CallingConvention = CallingConvention.Cdecl)]
        private static extern void WASAPI_StopCapture();

        public int Channels { get; private set; } = 2;
        public int SampleRate { get; private set; } = 44100;
        public int BitsPerSample { get; private set; } = 32;

        public event Action<byte[], int> DataAvailable;

        private System.Threading.Thread _captureThread;
        private volatile bool _running;
        private byte[] _readBuffer = new byte[192000];

        public void Start()
        {
            int hr = WASAPI_StartCapture();
            if (hr != 0)
                throw new Exception("WASAPI_StartCapture failed: " + hr);

            Channels = WASAPI_GetChannels();
            if (Channels > 2) Channels = 2;
            SampleRate = WASAPI_GetSampleRate();
            BitsPerSample = WASAPI_GetBitsPerSample();

            _running = true;
            _captureThread = new System.Threading.Thread(CaptureLoop) { IsBackground = true };
            _captureThread.Start();
        }

        private void CaptureLoop()
        {
            while (_running)
            {
                try
                {
                    int bytesRead = WASAPI_ReadData(_readBuffer, _readBuffer.Length);
                    if (bytesRead > 0)
                    {
                        DataAvailable?.Invoke(_readBuffer, bytesRead);
                    }
                }
                catch { }

                System.Threading.Thread.Sleep(1);
            }
        }

        public void Stop()
        {
            _running = false;
            try { _captureThread?.Join(500); } catch { }
            WASAPI_StopCapture();
        }

        public void Dispose()
        {
            Stop();
        }
    }
}
