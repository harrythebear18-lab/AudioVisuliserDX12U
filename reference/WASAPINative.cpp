#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>

#define REFTIMES_PER_SEC  10000000
#define REFTIMES_PER_MILLISEC  10000

static IMMDeviceEnumerator* g_pEnumerator = NULL;
static IMMDevice* g_pDevice = NULL;
static IAudioClient* g_pAudioClient = NULL;
static IAudioCaptureClient* g_pCaptureClient = NULL;
static WAVEFORMATEX* g_pMixFormat = NULL;

extern "C" {

// Returns: 0 = ok, negative = error code
__declspec(dllexport) int __cdecl WASAPI_StartCapture() {
    HRESULT hr;

    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) return -1;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&g_pEnumerator);
    if (FAILED(hr)) return -2;

    hr = g_pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &g_pDevice);
    if (FAILED(hr)) return -3;

    hr = g_pDevice->Activate(__uuidof(IAudioClient), CLSCTX_ALL, NULL, (void**)&g_pAudioClient);
    if (FAILED(hr)) return -4;

    hr = g_pAudioClient->GetMixFormat(&g_pMixFormat);
    if (FAILED(hr)) return -5;

    // Request minimal buffer (3ms = 30000 reftimes) for lowest capture latency
    // In shared mode, Windows uses the device's minimum period regardless
    hr = g_pAudioClient->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                    AUDCLNT_STREAMFLAGS_LOOPBACK,
                                    3 * REFTIMES_PER_MILLISEC, 0, g_pMixFormat, NULL);
    if (FAILED(hr)) return -6;

    UINT32 bufferFrames;
    hr = g_pAudioClient->GetBufferSize(&bufferFrames);
    if (FAILED(hr)) return -7;

    hr = g_pAudioClient->GetService(__uuidof(IAudioCaptureClient), (void**)&g_pCaptureClient);
    if (FAILED(hr)) return -8;

    hr = g_pAudioClient->Start();
    if (FAILED(hr)) return -9;

    return 0;
}

// Returns sample rate
__declspec(dllexport) int __cdecl WASAPI_GetSampleRate() {
    if (!g_pMixFormat) return 44100;
    return (int)g_pMixFormat->nSamplesPerSec;
}

// Returns channels
__declspec(dllexport) int __cdecl WASAPI_GetChannels() {
    if (!g_pMixFormat) return 2;
    return (int)g_pMixFormat->nChannels;
}

// Returns bits per sample
__declspec(dllexport) int __cdecl WASAPI_GetBitsPerSample() {
    if (!g_pMixFormat) return 32;
    return (int)g_pMixFormat->wBitsPerSample;
}

// Read captured audio data. Returns number of bytes written to buffer, 0 if no data, negative on error.
// buffer must be large enough. maxSize is the max bytes to write.
__declspec(dllexport) int __cdecl WASAPI_ReadData(unsigned char* buffer, int maxSize) {
    if (!g_pCaptureClient) return -1;

    UINT32 packetLength = 0;
    HRESULT hr = g_pCaptureClient->GetNextPacketSize(&packetLength);
    if (FAILED(hr)) return -2;

    int totalWritten = 0;

    while (packetLength > 0 && totalWritten < maxSize) {
        BYTE* pData = NULL;
        UINT32 numFramesAvailable = 0;
        DWORD flags = 0;

        hr = g_pCaptureClient->GetBuffer(&pData, &numFramesAvailable, &flags, NULL, NULL);
        if (FAILED(hr)) return -3;

        int frameBytes = (g_pMixFormat->wBitsPerSample / 8) * g_pMixFormat->nChannels;
        int dataBytes = (int)(numFramesAvailable * frameBytes);

        if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT) && dataBytes > 0) {
            int toCopy = dataBytes;
            if (totalWritten + toCopy > maxSize) {
                toCopy = maxSize - totalWritten;
            }
            if (toCopy > 0) {
                memcpy(buffer + totalWritten, pData, toCopy);
                totalWritten += toCopy;
            }
        }

        hr = g_pCaptureClient->ReleaseBuffer(numFramesAvailable);
        if (FAILED(hr)) return -4;

        hr = g_pCaptureClient->GetNextPacketSize(&packetLength);
        if (FAILED(hr)) break;
    }

    return totalWritten;
}

__declspec(dllexport) void __cdecl WASAPI_StopCapture() {
    if (g_pAudioClient) {
        g_pAudioClient->Stop();
        g_pAudioClient->Release();
        g_pAudioClient = NULL;
    }
    if (g_pCaptureClient) {
        g_pCaptureClient->Release();
        g_pCaptureClient = NULL;
    }
    if (g_pDevice) {
        g_pDevice->Release();
        g_pDevice = NULL;
    }
    if (g_pEnumerator) {
        g_pEnumerator->Release();
        g_pEnumerator = NULL;
    }
    if (g_pMixFormat) {
        CoTaskMemFree(g_pMixFormat);
        g_pMixFormat = NULL;
    }
}

} // extern "C"
