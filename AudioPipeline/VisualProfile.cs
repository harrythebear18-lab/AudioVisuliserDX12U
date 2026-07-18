using System;

namespace StageSimWASAPI
{
    // VisualProfile — accumulates song-specific statistics from the brain
    // to build a unique visualization personality per song.
    // Resets on silence so every song starts fresh.
    public class VisualProfile
    {
        // Accumulated song stats (running averages/min/max)
        public float AvgEnergy { get; private set; }
        public float PeakEnergy { get; private set; }
        public float AvgBPM { get; private set; }
        public float AvgClarity { get; private set; }      // 0=noisy, 1=tonal
        public float AvgStereoWidth { get; private set; }
        public float AvgBassRatio { get; private set; }    // bass / total energy
        public float AvgTrebleRatio { get; private set; }  // treble / total energy
        public float DynamicRange { get; private set; }    // peak - min energy
        public float SongDuration { get; private set; }    // seconds of audio

        // Derived visual personality (0-1 each)
        public float EnergyLevel { get; private set; }     // overall song energy
        public float BassHeaviness { get; private set; }   // how bass-dominated
        public float TrebleBrightness { get; private set; } // how treble-dominated
        public float TempoFast { get; private set; }       // 0=slow, 1=fast
        public float TonalPunch { get; private set; }      // clarity → punchy vs diffuse
        public float StereoSpread { get; private set; }    // stereo width
        public float DynamicVariation { get; private set; } // dynamic range → quiet/loud contrast

        // Visual style parameters derived from profile
        public float BarHeightScale { get; private set; }   // 0.8-1.2 multiplier
        public float GlowIntensity { get; private set; }    // 0-1 bloom/glow amount
        public float MotionSpeed { get; private set; }      // 0.5-2.0 animation speed
        public float ColorSaturation { get; private set; }  // 0.5-1.0
        public float HueShift { get; private set; }         // base hue offset for this song
        public float ParticleDensity { get; private set; }  // 0-1
        public float PerspectiveDepth { get; private set; } // 0-1 depth effect strength

        // Dominant section — which section appears most
        public int DominantSection { get; private set; }
        private float[] _sectionTime = new float[11]; // matches Section enum count

        // Internal accumulation state
        private float _energySum, _energyCount;
        private float _bpmSum, _bpmCount;
        private float _claritySum, _clarityCount;
        private float _stereoSum, _stereoCount;
        private float _bassSum, _trebleSum, _totalSum;
        private float _minEnergy = float.MaxValue;
        private float _maxEnergy;
        private bool _active;

        // Unique seed for this song — drives per-song variation
        public int SongSeed { get; private set; }

        public void Reset()
        {
            AvgEnergy = 0; PeakEnergy = 0; AvgBPM = 0; AvgClarity = 0;
            AvgStereoWidth = 0; AvgBassRatio = 0; AvgTrebleRatio = 0;
            DynamicRange = 0; SongDuration = 0;
            EnergyLevel = 0.5f; BassHeaviness = 0.5f; TrebleBrightness = 0.5f;
            TempoFast = 0.5f; TonalPunch = 0.5f; StereoSpread = 0.5f; DynamicVariation = 0.5f;
            BarHeightScale = 1.0f; GlowIntensity = 0.3f; MotionSpeed = 1.0f;
            ColorSaturation = 0.85f; HueShift = 0f; ParticleDensity = 0.5f;
            PerspectiveDepth = 0.5f; DominantSection = 0;
            _sectionTime = new float[11];
            _energySum = _energyCount = _bpmSum = _bpmCount = 0;
            _claritySum = _clarityCount = _stereoSum = _stereoCount = 0;
            _bassSum = _trebleSum = _totalSum = 0;
            _minEnergy = float.MaxValue; _maxEnergy = 0;
            _active = false;
            SongSeed = 0;
        }

        // Called every frame from the audio pipeline with brain data
        public void Update(float energy, float bpm, float clarity, float stereoWidth,
                          float bass, float treble, float total, int section, float dt, bool isSilent)
        {
            if (isSilent)
            {
                if (_active)
                    Reset();
                return;
            }

            if (!_active)
            {
                _active = true;
                SongSeed = unchecked((int)(DateTime.Now.Ticks & 0x7FFFFFFF));
            }

            SongDuration += dt;

            // Accumulate running averages
            _energySum += energy; _energyCount++;
            _bpmSum += bpm; _bpmCount++;
            _claritySum += clarity; _clarityCount++;
            _stereoSum += stereoWidth; _stereoCount++;
            _bassSum += bass; _trebleSum += treble; _totalSum += total;

            // Track min/max energy for dynamic range
            if (energy < _minEnergy) _minEnergy = energy;
            if (energy > _maxEnergy) _maxEnergy = energy;
            if (energy > PeakEnergy) PeakEnergy = energy;

            // Track section dominance
            if (section >= 0 && section < _sectionTime.Length)
                _sectionTime[section] += dt;

            // Update derived stats (smoothed — gradual convergence)
            AvgEnergy = _energyCount > 0 ? _energySum / _energyCount : 0;
            AvgBPM = _bpmCount > 0 ? _bpmSum / _bpmCount : 120;
            AvgClarity = _clarityCount > 0 ? _claritySum / _clarityCount : 0.5f;
            AvgStereoWidth = _stereoCount > 0 ? _stereoSum / _stereoCount : 0.5f;
            AvgBassRatio = _totalSum > 0 ? _bassSum / _totalSum : 0.3f;
            AvgTrebleRatio = _totalSum > 0 ? _trebleSum / _totalSum : 0.2f;
            DynamicRange = _maxEnergy - Math.Max(0, _minEnergy);

            // Find dominant section
            float maxTime = 0;
            for (int i = 0; i < _sectionTime.Length; i++)
            {
                if (_sectionTime[i] > maxTime) { maxTime = _sectionTime[i]; DominantSection = i; }
            }

            // Derive visual personality (smoothed convergence)
            EnergyLevel = Mathf.Lerp(EnergyLevel, Mathf.Clamp01(AvgEnergy * 2f), 0.02f);
            BassHeaviness = Mathf.Lerp(BassHeaviness, Mathf.Clamp01(AvgBassRatio * 3f), 0.02f);
            TrebleBrightness = Mathf.Lerp(TrebleBrightness, Mathf.Clamp01(AvgTrebleRatio * 4f), 0.02f);
            TempoFast = Mathf.Lerp(TempoFast, Mathf.Clamp01((AvgBPM - 60f) / 140f), 0.02f);
            TonalPunch = Mathf.Lerp(TonalPunch, AvgClarity, 0.02f);
            StereoSpread = Mathf.Lerp(StereoSpread, AvgStereoWidth, 0.02f);
            DynamicVariation = Mathf.Lerp(DynamicVariation, Mathf.Clamp01(DynamicRange * 3f), 0.02f);

            // Derive visual style parameters from personality
            // Bass-heavy songs: taller bars, more glow, slower motion
            BarHeightScale = Mathf.Lerp(BarHeightScale, 0.8f + BassHeaviness * 0.4f + EnergyLevel * 0.2f, 0.01f);
            GlowIntensity = Mathf.Lerp(GlowIntensity, 0.15f + BassHeaviness * 0.4f + EnergyLevel * 0.3f, 0.01f);
            MotionSpeed = Mathf.Lerp(MotionSpeed, 0.6f + TempoFast * 1.2f, 0.01f);
            ColorSaturation = Mathf.Lerp(ColorSaturation, 0.6f + TonalPunch * 0.35f, 0.01f);
            HueShift = Mathf.Lerp(HueShift, (SongSeed % 1000) / 1000f * 0.3f, 0.01f);
            ParticleDensity = Mathf.Lerp(ParticleDensity, 0.2f + EnergyLevel * 0.5f + DynamicVariation * 0.2f, 0.01f);
            PerspectiveDepth = Mathf.Lerp(PerspectiveDepth, 0.3f + DynamicVariation * 0.4f + TonalPunch * 0.2f, 0.01f);
        }

        // Pack profile into a Vector4 for shader consumption
        public System.Numerics.Vector4 PackProfile1()
        {
            return new System.Numerics.Vector4(EnergyLevel, BassHeaviness, TrebleBrightness, TempoFast);
        }
        public System.Numerics.Vector4 PackProfile2()
        {
            return new System.Numerics.Vector4(TonalPunch, StereoSpread, DynamicVariation, GlowIntensity);
        }
        public System.Numerics.Vector4 PackProfile3()
        {
            return new System.Numerics.Vector4(BarHeightScale, MotionSpeed, ColorSaturation, PerspectiveDepth);
        }
    }
}
