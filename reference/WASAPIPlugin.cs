using System;
using BepInEx;
using BepInEx.Configuration;
using BepInEx.Logging;
using HarmonyLib;
using UnityEngine;
using UnityEngine.UI;

namespace StageSimWASAPI
{
    [BepInPlugin("com.stagesim.wasapi", "Stage Sim WASAPI Loopback", "1.3.0")]
    public class WASAPIPlugin : BaseUnityPlugin
    {
        internal static ManualLogSource Log;
        internal static WASAPIPlugin Instance;

        internal static ConfigEntry<bool> EnableLoopback;
        internal static ConfigEntry<bool> AutoLighting;
        internal static ConfigEntry<int> CircularBufferSeconds;
        internal static ConfigEntry<float> EnergyThreshold;
        internal static ConfigEntry<float> BeatCooldown;
        internal static ConfigEntry<KeyCode> ToggleKey;
        internal static ConfigEntry<KeyCode> AutoLightKey;
        internal static ConfigEntry<KeyCode> AdvancedModeKey;
        internal static ConfigEntry<bool> AdvancedMode;

        private WASAPICapture _capture;
        private CircularAudioBuffer _circularBuffer;
        private bool _loopbackActive;
        private float[] _conversionBuffer;
        private float _retryCooldown = 0f;
        private float _keyCooldown = 0f;
        private float _toggleKeyCooldown = 0f;
        private float _autoLightKeyCooldown = 0f;
        private float _advancedKeyCooldown = 0f;
        private float _lastDataTime = 0f;
        private float _smoothedEnergy = 0f;
        private float _smoothedBass = 0f;
        private float _smoothedMid = 0f;
        private float _smoothedTreble = 0f;
        private float _peakEnergy = 0.001f;
        private float _peakBass = 0.001f;
        private float _peakMid = 0.001f;
        private float _peakTreble = 0.001f;
        private float _lastBeatTime = 0f;
        private int _captureSampleRate = 44100;
        private float[] _lastSpectrum = new float[1024];

        private float[] _fftBuffer = new float[1024];
        private float[] _fftOutput = new float[1024];
        private float[] _monoBuffer = new float[1024];  // mono-summed for FFT
        private AudioAnalyzer _analyzer;
        private LightingBrain _brain;

        // Stereo field tracking for spatial lighting
        private float _stereoBalance = 0f;    // -1 = full left, +1 = full right, 0 = centered
        private float _stereoWidth = 0f;      // 0 = mono, 1 = wide stereo
        private float _leftEnergy = 0f;
        private float _rightEnergy = 0f;

        private GameObject _hudObject;
        private Text _hudText;
        private float _hudUpdateTimer = 0f;

        // Live debug logger — writes to %TEMP%\StageSimWASAPI\debug.log
        private string _debugLogPath;
        private float _debugLogTimer = 0f;
        private const float DEBUG_LOG_INTERVAL = 0.1f; // 10 lines/sec
        private System.IO.StreamWriter _debugWriter;
        private bool _debugLogging = false;

        private void Awake()
        {
            Log = Logger;
            Instance = this;

            EnableLoopback = Config.Bind("General", "EnableLoopback", false,
                "Enable WASAPI loopback capture (toggled in-game)");
            AutoLighting = Config.Bind("General", "AutoLighting", false,
                "Enable musical auto-lighting mode (all lights follow audio)");
            CircularBufferSeconds = Config.Bind("General", "CircularBufferSeconds", 5,
                "Size of the circular audio buffer in seconds");
            EnergyThreshold = Config.Bind("Audio", "EnergyThreshold", 0.01f,
                "Minimum energy level to trigger light response (lower = more reactive)");
            BeatCooldown = Config.Bind("Audio", "BeatCooldown", 0.15f,
                "Minimum seconds between beat detections (higher = fewer false beats)");
            ToggleKey = Config.Bind("Controls", "ToggleKey", KeyCode.Insert,
                "Key to toggle WASAPI loopback on/off");
            AutoLightKey = Config.Bind("Controls", "AutoLightKey", KeyCode.Home,
                "Key to toggle musical auto-lighting mode");
            AdvancedModeKey = Config.Bind("Controls", "AdvancedModeKey", KeyCode.PageUp,
                "Key to toggle advanced audio analysis mode (8-band, spectral flux, envelope follower)");
            AdvancedMode = Config.Bind("General", "AdvancedMode", false,
                "Use advanced audio analysis (ported from GPU visualizer). Disable for classic 3-band mode.");

            Log.LogInfo("Stage Sim WASAPI Loopback v1.3.0 loaded");

            var harmony = new Harmony("com.stagesim.wasapi");
            harmony.PatchAll();

            CreateHUD();
        }

        private void Update()
        {
            _toggleKeyCooldown -= Time.deltaTime;
            _autoLightKeyCooldown -= Time.deltaTime;
            _advancedKeyCooldown -= Time.deltaTime;

            if (Input.GetKeyDown(ToggleKey.Value) && _toggleKeyCooldown <= 0f)
            {
                _toggleKeyCooldown = 0.5f;
                EnableLoopback.Value = !EnableLoopback.Value;
                Log.LogInfo(EnableLoopback.Value ? "Loopback enabled" : "Loopback disabled");
            }

            if (Input.GetKeyDown(AutoLightKey.Value) && _autoLightKeyCooldown <= 0f)
            {
                _autoLightKeyCooldown = 0.5f;
                AutoLighting.Value = !AutoLighting.Value;
                Log.LogInfo(AutoLighting.Value ? "Auto-lighting enabled" : "Auto-lighting disabled");
            }

            if (Input.GetKeyDown(AdvancedModeKey.Value) && _advancedKeyCooldown <= 0f)
            {
                _advancedKeyCooldown = 0.5f;
                AdvancedMode.Value = !AdvancedMode.Value;
                if (AdvancedMode.Value && _captureSampleRate > 0)
                {
                    _analyzer = new AudioAnalyzer(1024, _captureSampleRate);
                    _brain = new LightingBrain();
                }
                else
                {
                    if (_analyzer != null) _analyzer.Reset();
                    if (_brain != null) _brain.Reset();
                    _analyzer = null;
                    _brain = null;
                }
                Log.LogInfo(AdvancedMode.Value ? "Advanced analysis mode enabled" : "Advanced analysis mode disabled");
            }

            if (EnableLoopback.Value && !_loopbackActive)
                StartLoopback();
            else if (!EnableLoopback.Value && _loopbackActive)
                StopLoopback();

            _hudUpdateTimer -= Time.deltaTime;
            if (_hudUpdateTimer <= 0f)
            {
                _hudUpdateTimer = 0.05f;
                UpdateHUD();
            }

            // Toggle debug logging with F8
            if (Input.GetKeyDown(KeyCode.F8))
            {
                _debugLogging = !_debugLogging;
                if (_debugLogging)
                    StartDebugLog();
                else
                    StopDebugLog();
                Log.LogInfo(_debugLogging ? $"Debug logging ON -> {_debugLogPath}" : "Debug logging OFF");
            }

            if (_debugLogging)
            {
                _debugLogTimer -= Time.deltaTime;
                if (_debugLogTimer <= 0f)
                {
                    _debugLogTimer = DEBUG_LOG_INTERVAL;
                    WriteDebugLog();
                }
            }
        }

        private void StartDebugLog()
        {
            try
            {
                string dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "StageSimWASAPI");
                System.IO.Directory.CreateDirectory(dir);
                _debugLogPath = System.IO.Path.Combine(dir, "debug.log");
                _debugWriter = new System.IO.StreamWriter(_debugLogPath, false) { AutoFlush = true };
                _debugWriter.WriteLine("# StageSimWASAPI Debug Log");
                _debugWriter.WriteLine("# Format: time|env|trans|beatInt|beat|bpm|conf|kick|kickConf|sub|bass|lowmid|mid|hmid|pres|bril|air|overall|silent|dom|section|phrase|effIntensity|dimmInt|moveInt|smoke|pyro|flash|strobe|stereoBal|stereoW|leftE|rightE");
                _debugWriter.WriteLine("# Press F8 to toggle. This file is in %TEMP% so it won't clutter your system.");
            }
            catch (Exception ex)
            {
                Log.LogError($"Failed to start debug log: {ex.Message}");
                _debugLogging = false;
            }
        }

        private void StopDebugLog()
        {
            try
            {
                if (_debugWriter != null)
                {
                    _debugWriter.WriteLine("# Log ended");
                    _debugWriter.Close();
                    _debugWriter = null;
                }
            }
            catch { }
        }

        private void WriteDebugLog()
        {
            if (_debugWriter == null || _analyzer == null) return;
            try
            {
                var an = _analyzer;
                var brain = _brain;
                float t = Time.realtimeSinceStartup;

                string line = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                    "{0:F3}|{1:F4}|{2:F4}|{3:F4}|{4}|{5:F1}|{6:F3}|{7:F4}|{8:F3}|{9:F4}|{10:F4}|{11:F4}|{12:F4}|{13:F4}|{14:F4}|{15:F4}|{16:F4}|{17:F4}|{18}|{19}|{20}|{21}|{22:F3}|{23:F3}|{24:F3}|{25}|{26}|{27}|{28}|{29:F3}|{30:F3}|{31:F4}|{32:F4}",
                    t,
                    an.GetEnvelopeNormalized(),
                    an.Transient,
                    an.BeatIntensity,
                    an.BeatJustDetected ? "B" : "-",
                    an.BPM,
                    an.TempoConfidence,
                    an.KickLevel,
                    an.KickConfidence,
                    an.GetSubLevel(),
                    an.GetBassLevel(),
                    an.GetLowMidLevel(),
                    an.GetMidLevel(),
                    an.GetHighMidLevel(),
                    an.GetBandLevelNormalized(5),
                    an.GetTrebleLevel(),
                    an.GetBandLevelNormalized(7),
                    an.GetOverallNormalized(),
                    an.IsSilent ? "Y" : "N",
                    an.DominantBand,
                    brain != null ? brain.GetSectionName() : "-",
                    brain != null ? brain.PhraseBeat.ToString() : "-",
                    brain != null ? brain.EffectIntensity : 0f,
                    brain != null ? brain.DimmerIntensity : 0f,
                    brain != null ? brain.MovementIntensity : 0f,
                    brain != null && brain.TriggerSmoke ? "S" : "-",
                    brain != null && brain.TriggerPyro ? "P" : "-",
                    brain != null && brain.TriggerFlash ? "F" : "-",
                    brain != null && brain.TriggerStrobe ? "X" : "-",
                    _stereoBalance,
                    _stereoWidth,
                    _leftEnergy,
                    _rightEnergy);

                _debugWriter.WriteLine(line);
            }
            catch { }
        }

        private void StartLoopback()
        {
            if (_retryCooldown > 0f)
            {
                _retryCooldown -= Time.deltaTime;
                return;
            }

            try
            {
                _capture = new WASAPICapture();
                _capture.DataAvailable += OnCaptureDataAvailable;
                _capture.Start();

                int channels = _capture.Channels;
                if (channels <= 0) channels = 2;
                if (channels > 2) channels = 2;
                int sampleRate = _capture.SampleRate;
                if (sampleRate <= 0) sampleRate = 44100;
                _captureSampleRate = sampleRate;
                if (AdvancedMode.Value)
                {
                    _analyzer = new AudioAnalyzer(1024, sampleRate);
                    _brain = new LightingBrain();
                }

                int bufferSamples = sampleRate * CircularBufferSeconds.Value;
                _circularBuffer = new CircularAudioBuffer(bufferSamples * channels);
                _conversionBuffer = new float[8192];

                _loopbackActive = true;
                Log.LogInfo($"Loopback started: {channels}ch, {sampleRate}Hz, {_capture.BitsPerSample}bit");
            }
            catch (Exception ex)
            {
                Log.LogError($"Failed to start loopback: {ex.Message}");
                _retryCooldown = 5f;
                _loopbackActive = false;
                if (_capture != null)
                {
                    try { _capture.Dispose(); } catch { }
                    _capture = null;
                }
            }
        }

        private void StopLoopback()
        {
            try
            {
                if (_capture != null)
                {
                    _capture.Stop();
                    _capture.Dispose();
                    _capture = null;
                }
                _circularBuffer = null;
                _smoothedEnergy = 0f;
                _analyzer = null;
                _brain = null;
            }
            catch (Exception ex)
            {
                Log.LogError($"Error stopping loopback: {ex.Message}");
            }
            _loopbackActive = false;
        }

        private void OnCaptureDataAvailable(byte[] buffer, int length)
        {
            if (_circularBuffer == null || _capture == null) return;

            try
            {
                int bytesPerSample = _capture.BitsPerSample / 8;
                int sourceChannels = _capture.Channels;
                int channels = sourceChannels > 2 ? 2 : sourceChannels;

                int sampleFrames = length / (bytesPerSample * sourceChannels);
                int needed = sampleFrames * channels;

                if (needed > _conversionBuffer.Length)
                    _conversionBuffer = new float[needed];

                for (int i = 0; i < sampleFrames; i++)
                {
                    for (int c = 0; c < channels; c++)
                    {
                        int byteOffset = i * sourceChannels * bytesPerSample + c * bytesPerSample;
                        if (byteOffset + bytesPerSample > length) break;

                        if (bytesPerSample == 4)
                        {
                            float sample = BitConverter.ToSingle(buffer, byteOffset);
                            _conversionBuffer[i * channels + c] = Mathf.Clamp(sample, -1f, 1f);
                        }
                        else if (bytesPerSample == 2)
                        {
                            short s = BitConverter.ToInt16(buffer, byteOffset);
                            _conversionBuffer[i * channels + c] = s / 32768f;
                        }
                    }
                }

                _circularBuffer.Write(_conversionBuffer, 0, needed);
                _lastDataTime = Time.realtimeSinceStartup;
            }
            catch (Exception ex)
            {
                Log.LogError($"Capture data error: {ex.Message}");
            }
        }

        private void OnDestroy()
        {
            StopLoopback();
            if (_hudObject != null)
                Destroy(_hudObject);
        }

        private void CreateHUD()
        {
            var canvasObj = new GameObject("WASAPI_HUD_Canvas");
            var canvas = canvasObj.AddComponent<Canvas>();
            canvas.renderMode = RenderMode.ScreenSpaceOverlay;
            canvas.sortingOrder = 1000;

            canvasObj.AddComponent<CanvasScaler>();
            canvasObj.AddComponent<GraphicRaycaster>();

            var textObj = new GameObject("WASAPI_HUD_Text");
            textObj.transform.SetParent(canvasObj.transform, false);
            _hudText = textObj.AddComponent<Text>();
            _hudText.font = Resources.GetBuiltinResource<Font>("Arial.ttf");
            _hudText.fontSize = 14;
            _hudText.alignment = TextAnchor.UpperLeft;
            _hudText.color = new Color(1f, 1f, 1f, 0.85f);

            var rect = textObj.GetComponent<RectTransform>();
            rect.anchorMin = new Vector2(0f, 1f);
            rect.anchorMax = new Vector2(0f, 1f);
            rect.pivot = new Vector2(0f, 1f);
            rect.anchoredPosition = new Vector2(10f, -10f);
            rect.sizeDelta = new Vector2(500f, 260f);

            _hudObject = canvasObj;
            DontDestroyOnLoad(_hudObject);
        }

        private void UpdateHUD()
        {
            if (_hudText == null) return;

            string loopbackStatus = _loopbackActive ? "<color=#4FFF4F>ON</color>" : "<color=#FF4F4F>OFF</color>";
            string autoStatus = AutoLighting.Value ? "<color=#4FFF4F>ON</color>" : "<color=#FF4F4F>OFF</color>";

            string advStatus = AdvancedMode.Value ? "<color=#4FbFFF>ON</color>" : "<color=#FF4F4F>OFF</color>";

            string line = $"WASAPI Loopback: {loopbackStatus}  [{ToggleKey.Value}]\n";
            line += $"Auto-Lighting: {autoStatus}  [{AutoLightKey.Value}]\n";
            line += $"Advanced Mode: {advStatus}  [{AdvancedModeKey.Value}]\n";

            if (_loopbackActive)
            {
                if (AdvancedMode.Value && _analyzer != null)
                {
                    line += $"Beat:{_analyzer.BeatIntensity:F3} Trans:{_analyzer.Transient:F3} Env:{_analyzer.Envelope:F3}\n";
                    line += $"Sub:{_analyzer.GetSubLevel():F3} Bass:{_analyzer.GetBassLevel():F3} LMid:{_analyzer.GetLowMidLevel():F3}\n";
                    line += $"Mid:{_analyzer.GetMidLevel():F3} HMid:{_analyzer.GetHighMidLevel():F3}\n";
                    line += $"Pres:{_analyzer.GetBandLevelNormalized(5):F3} Bril:{_analyzer.GetTrebleLevel():F3} Air:{_analyzer.GetBandLevelNormalized(7):F3}\n";
                    line += $"Overall:{_analyzer.GetOverallNormalized():F3} Silent:{(_analyzer.IsSilent ? "Y" : "N")} Dom:{_analyzer.DominantBand} Beat!:{(_analyzer.BeatJustDetected ? "Y" : "N")}\n";
                    line += $"BPM:{_analyzer.BPM:F1} Conf:{_analyzer.TempoConfidence:F2} Kick:{_analyzer.KickConfidence:F2}\n";
                    line += $"Stereo: L{_leftEnergy:F3} R{_rightEnergy:F3} Bal:{_stereoBalance:F2} W:{_stereoWidth:F2}\n";
                    if (_brain != null)
                        line += $"Section:{_brain.GetSectionName()} Phrase:{_brain.PhraseBeat}/16 Eff:{_brain.EffectIntensity:F2}";
                }
                else
                {
                    line += $"Energy: {GetNormalizedEnergy():F2}  Bass: {GetNormalizedBass():F2}  Mid: {GetNormalizedMid():F2}  Treble: {GetNormalizedTreble():F2}";
                }
            }

            _hudText.text = line;
            _hudText.supportRichText = true;
        }

        public bool IsLoopbackActive() => _loopbackActive;

        public float GetLoopbackEnergy() => _smoothedEnergy;
        public float GetBassEnergy() => _smoothedBass;
        public float GetMidEnergy() => _smoothedMid;
        public float GetTrebleEnergy() => _smoothedTreble;
        public bool IsAutoLighting() => AutoLighting.Value;
        public bool IsAdvancedMode() => AdvancedMode.Value && _analyzer != null;
        public AudioAnalyzer GetAnalyzer() => _analyzer;
        public LightingBrain GetBrain() => _brain;
        public float[] GetLastSpectrum() => _lastSpectrum;
        public float GetStereoBalance() => _stereoBalance;
        public float GetStereoWidth() => _stereoWidth;
        public float GetLeftEnergy() => _leftEnergy;
        public float GetRightEnergy() => _rightEnergy;

        public bool GetSpectrumData(float[] output, int size)
        {
            if (_circularBuffer == null || !_loopbackActive) return false;
            if (size > _fftBuffer.Length)
            {
                _fftBuffer = new float[size];
                _fftOutput = new float[size];
            }

            if (Time.realtimeSinceStartup - _lastDataTime > 0.1f)
            {
                _smoothedEnergy = 0f;
                _smoothedBass = 0f;
                _smoothedMid = 0f;
                _smoothedTreble = 0f;
                return false;
            }

            // Read the LATEST samples, not old sequential data
            int available = _circularBuffer.ReadLatest(_fftBuffer, 0, size);
            if (available < size) return false;

            // Determine channel count — stereo data is interleaved L,R,L,R...
            int channels = _capture != null ? (_capture.Channels > 2 ? 2 : _capture.Channels) : 2;
            if (channels < 1) channels = 1;

            // Compute mono sum and stereo field metrics from raw time-domain samples
            float rms = 0f;
            float leftSum = 0f;
            float rightSum = 0f;
            int monoCount = 0;

            if (channels == 2)
            {
                // De-interleave: extract mono and track L/R energy
                int monoSize = size / 2;
                if (_monoBuffer.Length < monoSize)
                    _monoBuffer = new float[monoSize];

                for (int i = 0; i < monoSize && (i * 2 + 1) < size; i++)
                {
                    float l = _fftBuffer[i * 2];
                    float r = _fftBuffer[i * 2 + 1];
                    float mono = (l + r) * 0.5f;
                    _monoBuffer[i] = mono;
                    rms += mono * mono;
                    leftSum += l * l;
                    rightSum += r * r;
                    monoCount++;
                }
                rms = Mathf.Sqrt(rms / Mathf.Max(1, monoCount));
                _leftEnergy = Mathf.Sqrt(leftSum / Mathf.Max(1, monoCount));
                _rightEnergy = Mathf.Sqrt(rightSum / Mathf.Max(1, monoCount));

                // Use L/R energy for silence detection — game sound noise floor means we never hit true 0
                // If both L and R are below 0.016, consider it silence
                if (_analyzer != null)
                    _analyzer.ForceSilent = (_leftEnergy < 0.016f && _rightEnergy < 0.016f);

                // Stereo balance: -1 (left) to +1 (right)
                float totalEnergy = _leftEnergy + _rightEnergy;
                if (totalEnergy > 0.001f)
                {
                    float rawBalance = (_rightEnergy - _leftEnergy) / totalEnergy;
                    _stereoBalance = Mathf.Lerp(_stereoBalance, rawBalance, 1f - Mathf.Exp(-Time.deltaTime * 5f));
                    // Stereo width: how different L and R are
                    float rawWidth = Mathf.Abs(_rightEnergy - _leftEnergy) / totalEnergy;
                    _stereoWidth = Mathf.Lerp(_stereoWidth, rawWidth, 1f - Mathf.Exp(-Time.deltaTime * 3f));
                }

                // Copy mono data into fftBuffer for FFT
                Array.Copy(_monoBuffer, _fftBuffer, monoSize);
                // Zero out the rest
                for (int i = monoSize; i < size; i++)
                    _fftBuffer[i] = 0f;
            }
            else
            {
                // Mono source — just compute RMS
                for (int i = 0; i < size; i++)
                    rms += _fftBuffer[i] * _fftBuffer[i];
                rms = Mathf.Sqrt(rms / size);
                _stereoBalance = 0f;
                _stereoWidth = 0f;
            }

            // Frame-rate independent smoothing
            float smoothRate = 1f - Mathf.Exp(-Time.deltaTime * 10f);
            _smoothedEnergy = Mathf.Lerp(_smoothedEnergy, rms, smoothRate);

            // Track peak for normalization (auto-gain, decays slowly)
            _peakEnergy = Mathf.Max(_peakEnergy * 0.999f, rms);
            float normEnergy = Mathf.Clamp01(rms / (_peakEnergy * 1.2f));

            if (_smoothedEnergy < EnergyThreshold.Value)
            {
                Array.Clear(output, 0, size);
                _smoothedBass = Mathf.Lerp(_smoothedBass, 0f, smoothRate);
                _smoothedMid = Mathf.Lerp(_smoothedMid, 0f, smoothRate);
                _smoothedTreble = Mathf.Lerp(_smoothedTreble, 0f, smoothRate);
                return true;
            }

            FFTProvider.ComputeMagnitudeSpectrum(_fftBuffer, _fftOutput, size);
            Array.Copy(_fftOutput, output, size);
            Array.Copy(_fftOutput, _lastSpectrum, size);

            if (AdvancedMode.Value && _analyzer != null)
            {
                // Advanced mode: delegate to AudioAnalyzer (8-band, log-scaled, spectral flux)
                int validBins = size / 2;
                _analyzer.Process(_fftOutput, validBins);
                if (_brain != null)
                    _brain.Update(_analyzer, Time.deltaTime);
            }
            else
            {
                // Classic mode: 3-band linear analysis (original)
                float binHz = (float)_captureSampleRate / size;
                int bassEnd = Mathf.Max(1, Mathf.CeilToInt(250f / binHz));
                int midEnd = Mathf.Max(bassEnd + 1, Mathf.CeilToInt(4000f / binHz));
                int trebleEnd = Mathf.Min(size / 2, Mathf.CeilToInt(16000f / binHz));

                float bass = 0f, mid = 0f, treble = 0f;
                for (int i = 0; i < bassEnd; i++) bass += _fftOutput[i];
                for (int i = bassEnd; i < midEnd; i++) mid += _fftOutput[i];
                for (int i = midEnd; i < trebleEnd; i++) treble += _fftOutput[i];

                bass /= bassEnd;
                mid /= (midEnd - bassEnd);
                treble /= Mathf.Max(1, trebleEnd - midEnd);

                float bandSmooth = 1f - Mathf.Exp(-Time.deltaTime * 8f);
                _smoothedBass = Mathf.Lerp(_smoothedBass, bass, bandSmooth);
                _smoothedMid = Mathf.Lerp(_smoothedMid, mid, bandSmooth);
                _smoothedTreble = Mathf.Lerp(_smoothedTreble, treble, bandSmooth);

                _peakBass = Mathf.Max(_peakBass * 0.998f, bass);
                _peakMid = Mathf.Max(_peakMid * 0.998f, mid);
                _peakTreble = Mathf.Max(_peakTreble * 0.998f, treble);
            }

            return true;
        }

        public float GetNormalizedEnergy() => Mathf.Clamp01(_smoothedEnergy / Mathf.Max(0.001f, _peakEnergy * 1.2f));
        public float GetNormalizedBass() => Mathf.Clamp01(_smoothedBass / Mathf.Max(0.001f, _peakBass * 1.2f));
        public float GetNormalizedMid() => Mathf.Clamp01(_smoothedMid / Mathf.Max(0.001f, _peakMid * 1.2f));
        public float GetNormalizedTreble() => Mathf.Clamp01(_smoothedTreble / Mathf.Max(0.001f, _peakTreble * 1.2f));
        public bool CanBeat() => Time.realtimeSinceStartup - _lastBeatTime >= BeatCooldown.Value;
        public void RegisterBeat() => _lastBeatTime = Time.realtimeSinceStartup;
    }
}
