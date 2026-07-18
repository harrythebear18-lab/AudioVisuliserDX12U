using System.Collections.Generic;
using UnityEngine;
using HarmonyLib;

namespace StageSimWASAPI
{
    // "Brain" layer for auto-lighting — sits between the analyzer and the patches.
    // Provides intelligent, layered decisions that make the lighting feel alive:
    //   - Stage scanning: discovers all fixtures and creates virtual groups
    //   - Section detection (build-up, drop, breakdown, outro) from energy trends
    //   - Phrase-level color changes (every 8 or 16 beats)
    //   - Energy-driven effect intensity curves
    //   - Strobe/flash triggers on big drops
    //   - Smoke/pyro trigger decisions
    //   - Per-group behavior variation (some groups pulse, some sweep, some hold)
    public class LightingBrain
    {
        // --- Stage fixture inventory ---
        // The brain scans the stage and categorizes all fixtures into virtual groups
        public class FixtureGroup
        {
            public string Name;
            public List<MovingLight> Lights = new List<MovingLight>();
            public List<LaserContoller> Lasers = new List<LaserContoller>();
            public int GroupIndex;
            public int CurrentEffectMode;
            public Color32 CurrentColor;
        }

        public List<FixtureGroup> Groups { get; private set; } = new List<FixtureGroup>();
        public List<LaserContoller> AllLasers { get; private set; } = new List<LaserContoller>();
        public List<Blinders> AllBlinders { get; private set; } = new List<Blinders>();
        public int MovingLightCount { get; private set; }
        public int StaticLightCount { get; private set; }
        public int LaserCount { get; private set; }
        public int BlinderCount { get; private set; }
        private bool _stageScanned = false;
        private float _lastScanTime = -10f;
        // Section types
        public enum Section { Unknown, Intro, Verse, PreChorus, Chorus, BuildUp, Drop, Breakdown, Bridge, Interlude, Outro }

        // Current state
        public Section CurrentSection { get; private set; } = Section.Unknown;
        public float SectionConfidence { get; private set; } = 0f;
        public int BeatCount { get; private set; } = 0
;
        public int PhraseBeat { get; private set; } = 0; // 0-15 within a 16-beat phrase
        public int PhraseCount { get; private set; } = 0;

        // Energy tracking for section detection
        private float _energyHistory = 0f;
        private float _energyTrend = 0f; // positive = rising, negative = falling
        private float _peakEnergyRecent = 0f;
        private float _avgEnergy = 0f;
        private float _energySmoothed = 0f;
        private float _sectionTimer = 0f;
        private float _lastBeatTime = 0f;
        // Song-relative dynamic range tracking
        private float _songMinEnergy = -1f;  // -1 = not yet initialized
        private float _songMaxEnergy = -1f;
        private float _energyRange = 0f;  // max - min, used for relative thresholds
        private float _trendAccum = 0f;   // accumulated trend over ~2s for stable direction
        private float _trendTimer = 0f;

        // Color palette per section
        public Color32 CurrentColor { get; private set; }
        public Color32 SecondaryColor { get; private set; }
        private int _colorPairIndex = 0;

        // Effect decisions (one-shot triggers, consumed by patches)
        public bool TriggerFlash { get; private set; }
        public bool TriggerStrobe { get; private set; }
        public bool TriggerSmoke { get; private set; }
        public bool TriggerPyro { get; private set; }

        // Continuous intensity values (0-1)
        public float EffectIntensity { get; private set; }
        public float DimmerIntensity { get; private set; }
        public float MovementIntensity { get; private set; }

        // Fixture on/off decisions — like a real lighting console
        // The brain decides what should be on based on section, energy, and beat
        public bool LasersOn { get; private set; }
        public bool MovingLightsOn { get; private set; }
        public bool StaticLightsOn { get; private set; }
        public bool BlindersOn { get; private set; }
        public bool StrobeOn { get; private set; }

        // Per-fixture-type intensity (0-1) for fine control within on/off
        public float LaserIntensity { get; private set; }
        public float MovingLightIntensity { get; private set; }
        public float StaticLightIntensity { get; private set; }
        public float BlinderIntensity { get; private set; }

        // Audio-derived data driving brain decisions
        public float KickLevel { get; private set; }
        public float KickConfidence { get; private set; }
        public float BPM { get; private set; }
        public float TempoConfidence { get; private set; }
        public float StereoBalance { get; private set; }  // -1 = left, +1 = right
        public float StereoWidth { get; private set; }    // 0 = mono, 1 = full stereo
        public float OverallNormalized { get; private set; }

        // Per-group behavior mode (0=dimmer ride, 1=pulse, 2=sweep, 3=hold color)
        public int GroupBehaviorMode { get; private set; }
        public float GroupBehaviorPhase { get; private set; }

        // Random effect mode for groups — brain picks game effectmode (0-6) per phrase
        // Game modes: 0=on/off, 1=flash, 2=random single, 3=scatter, 4=chase, 5=snake, 6=center
        public int DesiredEffectMode { get; private set; } = 0;
        public bool ShouldChangeEffectMode { get; private set; }

        // Random flash trigger — separate from section-based flash
        public bool TriggerRandomFlash { get; private set; }
        public float RandomFlashIntensity { get; private set; }

        // Strobe state tracking
        private bool _strobing = false;
        private float _strobeEndTime = 0f;
        private float _lastRandomFlashTime = 0f;
        private System.Random _rng = new System.Random();

        // Color pairs — warm/cool contrasts that work for different sections
        private static readonly Color32[][] ColorPairs = {
            // Hot pair — drop
            new[] { new Color32(255, 60, 0, 255), new Color32(255, 0, 100, 255) },
            // Warm pair — build-up
            new[] { new Color32(255, 180, 0, 255), new Color32(255, 60, 0, 255) },
            // Cool pair — breakdown
            new[] { new Color32(0, 100, 255, 255), new Color32(100, 0, 255, 255) },
            // Fresh pair — verse
            new[] { new Color32(0, 255, 200, 255), new Color32(100, 255, 0, 255) },
            // White-out — outro/drop peak
            new[] { new Color32(255, 255, 255, 255), new Color32(200, 200, 255, 255) },
            // Purple pair — intro
            new[] { new Color32(180, 0, 255, 255), new Color32(80, 0, 200, 255) },
        };

        // --- Full color wheel (HSV) state ---
        // The brain generates colors dynamically from the full color wheel
        // Hue rotates over time, section constrains the hue range, energy modulates S/V
        private float _baseHue = 0f;          // 0-1, rotates slowly over time
        private float _hueRotationSpeed = 0.04f; // hue units per second — faster for more movement
        private float _sectionHueCenter = 0f;   // center hue for current section
        private float _sectionHueRange = 0.3f;   // how wide the hue range is for current section
        private bool _useColorWheel = true;      // toggle between color wheel and fixed pairs

        // Section hue centers (0-1 on the color wheel)
        // 0=red, 0.083=orange, 0.167=yellow, 0.25=green, 0.417=cyan, 0.5=blue, 0.667=purple, 0.833=pink
        private static readonly Dictionary<Section, float> SectionHueCenters = new Dictionary<Section, float>
        {
            { Section.Intro, 0.75f },      // purple
            { Section.Verse, 0.45f },      // teal/cyan
            { Section.PreChorus, 0.08f },  // orange — building warmth
            { Section.Chorus, 0.92f },     // pink/magenta — big hook
            { Section.BuildUp, 0.05f },    // orange/red
            { Section.Drop, 0.0f },        // red/hot
            { Section.Breakdown, 0.58f },  // blue
            { Section.Bridge, 0.33f },     // green — contrasting
            { Section.Interlude, 0.66f },  // purple-blue — ambient
            { Section.Outro, 0.08f },      // warm white (low sat)
            { Section.Unknown, 0.5f },     // default blue
        };
        private static readonly Dictionary<Section, float> SectionHueRanges = new Dictionary<Section, float>
        {
            { Section.Intro, 0.1f },
            { Section.Verse, 0.2f },
            { Section.PreChorus, 0.12f },
            { Section.Chorus, 0.2f },
            { Section.BuildUp, 0.15f },
            { Section.Drop, 0.25f },
            { Section.Breakdown, 0.15f },
            { Section.Bridge, 0.25f },
            { Section.Interlude, 0.15f },
            { Section.Outro, 0.05f },
            { Section.Unknown, 0.3f },
        };

        // Smoke/pyro cooldowns
        private float _lastSmokeTime = -10f;
        private float _lastPyroTime = -10f;
        private float _lastFlashTime = -10f;
        private float _lastStrobeTime = -10f;

        public void Reset()
        {
            CurrentSection = Section.Unknown;
            SectionConfidence = 0f;
            BeatCount = 0;
            PhraseBeat = 0;
            PhraseCount = 0;
            _energyHistory = 0f;
            _energyTrend = 0f;
            _peakEnergyRecent = 0f;
            _avgEnergy = 0f;
            _energySmoothed = 0f;
            _sectionTimer = 0f;
            _songMinEnergy = -1f;
            _songMaxEnergy = -1f;
            _energyRange = 0f;
            _colorPairIndex = 0;
            CurrentColor = ColorPairs[0][0];
            SecondaryColor = ColorPairs[0][1];
            TriggerFlash = false;
            TriggerStrobe = false;
            TriggerSmoke = false;
            TriggerPyro = false;
            LasersOn = false;
            MovingLightsOn = false;
            StaticLightsOn = false;
            BlindersOn = false;
            StrobeOn = false;
            LaserIntensity = 0f;
            MovingLightIntensity = 0f;
            StaticLightIntensity = 0f;
            BlinderIntensity = 0f;
            _strobing = false;
            _strobeEndTime = 0f;
            DesiredEffectMode = 0;
            ShouldChangeEffectMode = false;
            TriggerRandomFlash = false;
            RandomFlashIntensity = 0f;
            _lastRandomFlashTime = -10f;
        }

        // Called every frame with current analyzer state
        public void Update(AudioAnalyzer analyzer, float dt)
        {
            TriggerFlash = false;
            TriggerStrobe = false;
            TriggerSmoke = false;
            TriggerPyro = false;
            ShouldChangeEffectMode = false;
            TriggerRandomFlash = false;

            if (analyzer == null || analyzer.IsSilent)
            {
                // Full reset on silence — clears all state so brain starts fresh when audio returns
                if (CurrentSection != Section.Unknown || BeatCount > 0)
                {
                    Reset();
                }
                // Set to Intro so when audio returns, brain starts in Intro state
                CurrentSection = Section.Intro;
                LasersOn = false;
                MovingLightsOn = false;
                StaticLightsOn = false;
                BlindersOn = false;
                StrobeOn = false;
                EffectIntensity = 0f;
                DimmerIntensity = 0f;
                MovementIntensity = 0f;
                return;
            }

            float energy = analyzer.GetEnvelopeNormalized();
            float transient = analyzer.Transient;
            float beatIntensity = analyzer.BeatIntensity;

            // --- Pull all analyzer data into brain for decision-making ---
            KickLevel = analyzer.KickLevel;
            KickConfidence = analyzer.KickConfidence;
            BPM = analyzer.BPM;
            TempoConfidence = analyzer.TempoConfidence;
            OverallNormalized = analyzer.GetOverallNormalized();
            StereoBalance = WASAPIPlugin.Instance.GetStereoBalance();
            StereoWidth = WASAPIPlugin.Instance.GetStereoWidth();

            // Ensure stage has been scanned
            EnsureStageScanned();

            // --- Color wheel rotation ---
            // Slowly rotate the base hue for continuous color movement
            _baseHue = Mathf.Repeat(_baseHue + _hueRotationSpeed * dt, 1f);

            // --- Energy trend tracking ---
            // Use a slower, more stable trend: compare current smoothed to value ~2s ago
            _energySmoothed = Mathf.Lerp(_energySmoothed, energy, 1f - Mathf.Exp(-dt * 4f));
            _trendTimer += dt;
            if (_trendTimer >= 0.5f)
            {
                _energyTrend = (_energySmoothed - _energyHistory) / _trendTimer;
                _energyHistory = _energySmoothed;
                _trendTimer = 0f;
            }

            // Track song-relative dynamic range
            // Seed with first energy value on first update
            if (_songMinEnergy < 0f || _songMaxEnergy < 0f)
            {
                _songMinEnergy = energy;
                _songMaxEnergy = energy * 1.2f + 0.01f;
            }
            // Fast adaptation initially, slower once range is established
            float adaptRate = _energyRange < 0.05f ? 2f : 0.3f;
            _songMinEnergy = Mathf.Lerp(_songMinEnergy, Mathf.Min(_songMinEnergy, energy), 1f - Mathf.Exp(-dt * adaptRate));
            _songMaxEnergy = Mathf.Lerp(_songMaxEnergy, Mathf.Max(_songMaxEnergy, energy), 1f - Mathf.Exp(-dt * adaptRate));
            _energyRange = Mathf.Max(0.05f, _songMaxEnergy - _songMinEnergy);

            // Track recent peak and average
            _peakEnergyRecent = Mathf.Max(_peakEnergyRecent * 0.98f, energy);
            _avgEnergy = Mathf.Lerp(_avgEnergy, energy, 1f - Mathf.Exp(-dt * 0.3f));

            _sectionTimer += dt;

            // --- Section detection ---
            DetectSection(energy, transient, dt);

            // --- Effect intensity curves ---
            // Base intensity follows energy with amplification
            EffectIntensity = Mathf.Clamp01(Mathf.Pow(_energySmoothed, 0.5f));
            // Dimmer rides between 20% and 100% based on energy — more dynamic range
            DimmerIntensity = Mathf.Clamp(0.2f + EffectIntensity * 0.8f, 0f, 1f);
            // Movement intensity scales with transient energy and BPM
            // Faster songs get more movement; high tempo confidence means we trust the BPM
            float bpmFactor = Mathf.Clamp01((BPM - 60f) / 140f); // 0 at 60bpm, 1 at 200bpm
            MovementIntensity = Mathf.Clamp01(transient * 2f + EffectIntensity * 0.2f + bpmFactor * 0.15f);

            // --- Fixture on/off decisions ---
            // Like a real lighting console: different fixture types have different roles
            float relEnergy = Mathf.Clamp01((_energySmoothed - _songMinEnergy) / _energyRange);
            float now = Time.realtimeSinceStartup;

            // Moving lights: on whenever there's audio, intensity follows energy
            MovingLightsOn = relEnergy > 0.05f;
            MovingLightIntensity = EffectIntensity;

            // Static lights: on during verse/intro/breakdown for wash, off during drops for contrast
            StaticLightsOn = (CurrentSection == Section.Verse || CurrentSection == Section.Intro ||
                             CurrentSection == Section.Breakdown || CurrentSection == Section.Outro) &&
                             relEnergy > 0.05f;
            StaticLightIntensity = Mathf.Clamp01(0.3f + EffectIntensity * 0.5f);

            // Lasers: on when energy is high enough, regardless of section
            // Section modifies behavior: BuildUp/Drop = always on, Verse = off, Breakdown = flicker
            if (CurrentSection == Section.BuildUp || CurrentSection == Section.Drop)
            {
                LasersOn = relEnergy > 0.05f;
            }
            else if (CurrentSection == Section.Breakdown)
            {
                // Flicker during breakdowns — on ~50% of the time
                LasersOn = relEnergy > 0.15f && (BeatCount % 2 == 0 || beatIntensity > 0.2f);
            }
            else
            {
                // Verse/Intro/Outro: lasers on at moderate energy
                LasersOn = relEnergy > 0.25f;
            }
            // Beat pulse adds intensity
            LaserIntensity = Mathf.Clamp01(EffectIntensity * 0.6f + (beatIntensity > 0.1f ? beatIntensity * 0.4f : 0f));

            // Blinders: on big kick drums or bass hits during drops, very sparingly
            // Use kick level + beat intensity for more musical triggering
            BlindersOn = (CurrentSection == Section.Drop) && (beatIntensity > 0.5f || KickLevel > 0.7f) && relEnergy > 0.6f;
            BlinderIntensity = Mathf.Max(beatIntensity, KickLevel);

            // Strobe: time-limited bursts during build-ups and drop peaks
            if (_strobing && now > _strobeEndTime)
            {
                _strobing = false;
                StrobeOn = false;
            }
            if (!_strobing && (CurrentSection == Section.BuildUp || CurrentSection == Section.Drop) &&
                _peakEnergyRecent > 0.7f && (now - _lastStrobeTime) > 8f)
            {
                _strobing = true;
                _strobeEndTime = now + 2f;  // 2-second strobe burst
                _lastStrobeTime = now;
            }
            StrobeOn = _strobing;

            // --- Group behavior variation ---
            // Change behavior mode every 4 beats
            if (BeatCount > 0 && BeatCount % 4 == 0)
            {
                GroupBehaviorMode = (GroupBehaviorMode + 1) % 4;
            }
            GroupBehaviorPhase = (Time.realtimeSinceStartup * MovementIntensity) % 1f;

            // --- Random flash triggers ---
            // Random flashes on beats during drops and build-ups for excitement
            if (BeatCount > 0 && (CurrentSection == Section.Drop || CurrentSection == Section.BuildUp))
            {
                // ~20% chance per beat during drops, ~10% during build-ups
                float flashChance = CurrentSection == Section.Drop ? 0.2f : 0.1f;
                if ((float)_rng.NextDouble() < flashChance && (now - _lastRandomFlashTime) > 1.5f)
                {
                    TriggerRandomFlash = true;
                    RandomFlashIntensity = 0.5f + (float)_rng.NextDouble() * 0.5f;
                    _lastRandomFlashTime = now;
                }
            }

            // --- Smoke triggers ---
            // Smoke on build-ups every ~8 beats, or on drops
            // 'now' already declared above
            if (CurrentSection == Section.BuildUp && (now - _lastSmokeTime) > 8f && BeatCount % 8 == 0)
            {
                TriggerSmoke = true;
                _lastSmokeTime = now;
            }
            else if (CurrentSection == Section.Drop && (now - _lastSmokeTime) > 15f && BeatCount % 16 == 0)
            {
                TriggerSmoke = true;
                _lastSmokeTime = now;
            }

            // --- Pyro triggers ---
            // Pyro on big drops and every 32 beats during drops
            if (CurrentSection == Section.Drop && (now - _lastPyroTime) > 20f && BeatCount % 32 == 0)
            {
                TriggerPyro = true;
                _lastPyroTime = now;
            }

            // --- Flash triggers ---
            // Flash on sudden energy spikes (drops, big hits) or strong kick drums
            if ((transient > 0.7f || (KickLevel > 0.8f && KickConfidence > 0.5f)) && (now - _lastFlashTime) > 3f)
            {
                TriggerFlash = true;
                _lastFlashTime = now;
            }

            // --- Strobe triggers ---
            // Strobe during intense build-ups and drop peaks — longer cooldown
            if ((CurrentSection == Section.BuildUp || CurrentSection == Section.Drop) &&
                _peakEnergyRecent > 0.8f && (now - _lastStrobeTime) > 8f)
            {
                TriggerStrobe = true;
                _lastStrobeTime = now;
            }
        }

        // Called when a beat fires
        public void OnBeat(AudioAnalyzer analyzer)
        {
            BeatCount++;
            PhraseBeat = BeatCount % 16;

            // Phrase change every 16 beats
            if (PhraseBeat == 0)
            {
                PhraseCount++;
                // Change color pair on phrase boundary
                _colorPairIndex = (_colorPairIndex + 1) % ColorPairs.Length;
                CurrentColor = ColorPairs[_colorPairIndex][0];
                SecondaryColor = ColorPairs[_colorPairIndex][1];

                // Randomly change effect mode on phrase boundaries
                // Pick a mode that suits the current section
                ShouldChangeEffectMode = true;
                if (CurrentSection == Section.Drop)
                {
                    // Drops: chase, snake, center, scatter (high energy modes)
                    int[] dropModes = { 3, 4, 5, 6 };
                    DesiredEffectMode = dropModes[_rng.Next(dropModes.Length)];
                }
                else if (CurrentSection == Section.BuildUp)
                {
                    // Build-ups: chase, snake (building tension)
                    int[] buildModes = { 4, 5, 1 };
                    DesiredEffectMode = buildModes[_rng.Next(buildModes.Length)];
                }
                else if (CurrentSection == Section.Breakdown)
                {
                    // Breakdowns: on/off, flash (sparse)
                    int[] breakModes = { 0, 1, 2 };
                    DesiredEffectMode = breakModes[_rng.Next(breakModes.Length)];
                }
                else
                {
                    // Verse/Intro/Outro: on/off, random single, scatter (gentle)
                    int[] verseModes = { 0, 2, 3 };
                    DesiredEffectMode = verseModes[_rng.Next(verseModes.Length)];
                }

                // Also randomize per-group modes for variety across the stage
                RandomizeGroupModes();
            }

            // Also randomly swap primary/secondary color on odd phrases for variety
            if (PhraseBeat == 8 && PhraseCount % 2 == 1)
            {
                Color32 tmp = CurrentColor;
                CurrentColor = SecondaryColor;
                SecondaryColor = tmp;
            }

            _lastBeatTime = Time.realtimeSinceStartup;
        }

        private void DetectSection(float energy, float transient, float dt)
        {
            // Section detection using RELATIVE thresholds based on the song's own dynamic range.
            // This adapts to quiet songs, loud songs, and everything in between.
            //
            // Key insight: we compare energy to the song's min/max range, not absolute values.
            // normalizedEnergy = (energy - min) / (max - min)  -> 0 to 1 within this song

            float relEnergy = Mathf.Clamp01((energy - _songMinEnergy) / _energyRange);
            float relPeak = Mathf.Clamp01((_peakEnergyRecent - _songMinEnergy) / _energyRange);
            float relAvg = Mathf.Clamp01((_avgEnergy - _songMinEnergy) / _energyRange);

            Section prevSection = CurrentSection;

            // Hysteresis: require the section to be stable for a minimum time before switching
            // This prevents rapid flicker between sections

            // Drop: energy is near the song's peak AND has been for a while
            if (relEnergy > 0.7f && relPeak > 0.8f && _energyTrend > -0.05f)
            {
                if (CurrentSection != Section.Drop || _sectionTimer > 12f)
                {
                    CurrentSection = Section.Drop;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.1f);
                    _sectionTimer = 0f;
                }
            }
            // BuildUp: energy is rising significantly
            else if (_energyTrend > 0.03f && relEnergy > 0.3f)
            {
                if (CurrentSection != Section.BuildUp || _sectionTimer > 8f)
                {
                    CurrentSection = Section.BuildUp;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.1f);
                    _sectionTimer = 0f;
                }
            }
            // Breakdown: energy is falling from high
            else if (_energyTrend < -0.03f && relEnergy < 0.7f && relAvg > 0.3f)
            {
                if (CurrentSection != Section.Breakdown || _sectionTimer > 8f)
                {
                    CurrentSection = Section.Breakdown;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.1f);
                    _sectionTimer = 0f;
                }
            }
            // Verse: moderate energy, stable
            else if (relEnergy > 0.15f && relEnergy < 0.6f && Mathf.Abs(_energyTrend) < 0.03f)
            {
                if (_sectionTimer > 6f)
                {
                    CurrentSection = Section.Verse;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.05f);
                }
            }
            // Intro: low energy, slowly rising or stable
            else if (relEnergy < 0.2f && _energyTrend < 0.03f)
            {
                if (_sectionTimer > 6f)
                {
                    CurrentSection = Section.Intro;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.05f);
                }
            }
            // Outro: low energy, falling
            else if (relEnergy < 0.15f && _energyTrend < -0.02f)
            {
                if (_sectionTimer > 6f)
                {
                    CurrentSection = Section.Outro;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.05f);
                }
            }

            // Decay confidence slowly
            SectionConfidence = Mathf.Max(0f, SectionConfidence - dt * 0.02f);

            // Reset section timer on change
            if (prevSection != CurrentSection)
            {
                _sectionTimer = 0f;
                // Pick color pair appropriate for section
                switch (CurrentSection)
                {
                    case Section.Intro: _colorPairIndex = 5; break;     // purple
                    case Section.Verse: _colorPairIndex = 3; break;     // fresh
                    case Section.BuildUp: _colorPairIndex = 1; break;   // warm
                    case Section.Drop: _colorPairIndex = 0; break;      // hot
                    case Section.Breakdown: _colorPairIndex = 2; break; // cool
                    case Section.Outro: _colorPairIndex = 4; break;     // white-out
                }
                CurrentColor = ColorPairs[_colorPairIndex][0];
                SecondaryColor = ColorPairs[_colorPairIndex][1];

                // Update color wheel section center
                float hc, hr;
                if (SectionHueCenters.TryGetValue(CurrentSection, out hc))
                    _sectionHueCenter = hc;
                if (SectionHueRanges.TryGetValue(CurrentSection, out hr))
                    _sectionHueRange = hr;
            }
        }

        // Get a per-group color — subtle variation within the section's hue range
        public Color32 GetGroupColor(int groupIndex)
        {
            if (_useColorWheel)
            {
                // Each group gets a hue offset within the section's range
                int numGroups = Mathf.Max(2, Groups.Count);
                float hueOffset = ((float)groupIndex / numGroups - 0.5f) * _sectionHueRange;
                float hue = Mathf.Repeat(_baseHue + _sectionHueCenter + hueOffset, 1f);
                float sat = 1f;
                float val = 1f;
                // Odd groups slightly desaturated for subtle contrast
                if (groupIndex % 2 == 1)
                    sat = 0.85f;
                return ColorHSV(hue, sat, val);
            }
            return (groupIndex % 2 == 0) ? CurrentColor : SecondaryColor;
        }

        // Get a color modulated by energy — for continuous (non-beat) color updates
        // Includes per-call variation so different lights get different colors
        public Color32 GetEnergyColor(float energy01)
        {
            return GetEnergyColor(energy01, 0);
        }

        // Overload with lightIndex for per-light hue variation — different lights get different hues
        public Color32 GetEnergyColor(float energy01, int lightIndex)
        {
            if (_useColorWheel)
            {
                // Base hue from rotating wheel + section center
                float hue = Mathf.Repeat(_baseHue + _sectionHueCenter, 1f);

                // Per-light hue variation: subtle offsets within the section's range
                // Spread lights across the hue range so they're not all identical
                // but stay within the same color family
                float lightHueOffset = ((float)(lightIndex % 4) / 4f - 0.5f) * _sectionHueRange;
                hue = Mathf.Repeat(hue + lightHueOffset, 1f);

                // Energy shifts hue across the section's range — low energy = center, high energy = edges
                float energyHueShift = (energy01 - 0.5f) * _sectionHueRange;
                hue = Mathf.Repeat(hue + energyHueShift, 1f);

                // Stereo balance shifts hue: left = warmer, right = cooler
                hue = Mathf.Repeat(hue + StereoBalance * 0.08f, 1f);

                // Beat-synced hue wobble — moves color on every beat
                float beatWobble = Mathf.Sin(BeatCount * 0.7f) * _sectionHueRange * 0.15f;
                hue = Mathf.Repeat(hue + beatWobble, 1f);

                // Saturation: wider range — washed out at low energy, vivid at high
                float sat = Mathf.Lerp(0.2f, 1f, energy01);
                // Add stereo width influence — narrow stereo = more saturated
                sat = Mathf.Clamp01(sat + (1f - StereoWidth) * 0.1f);

                // Value: wider range — dim at low energy, blazing at high
                float val = Mathf.Lerp(0.15f, 1f, energy01);
                // Kick drums boost value for punch
                val = Mathf.Clamp01(val + KickLevel * 0.15f);

                return ColorHSV(hue, sat, val);
            }
            return CurrentColor;
        }

        // Get a beat-pulsed color — shifts hue per beat with more dramatic movement
        public Color32 GetBeatColor(int beatInPhrase)
        {
            if (_useColorWheel)
            {
                // Shift hue across full section range over a phrase
                float beatHueShift = (beatInPhrase / 16f) * _sectionHueRange;
                float hue = Mathf.Repeat(_baseHue + _sectionHueCenter + beatHueShift, 1f);
                // Alternate saturation on odd/even beats for pulse effect
                float sat = (beatInPhrase % 2 == 0) ? 1f : 0.7f;
                // Value pulses on beats 0, 4, 8, 12
                float val = (beatInPhrase % 4 == 0) ? 1f : 0.75f;
                return ColorHSV(hue, sat, val);
            }
            return CurrentColor;
        }

        // Convert HSV (0-1 each) to Color32
        private static Color32 ColorHSV(float h, float s, float v)
        {
            h = Mathf.Repeat(h, 1f);
            s = Mathf.Clamp01(s);
            v = Mathf.Clamp01(v);

            int hi = Mathf.FloorToInt(h * 6f);
            float f = h * 6f - hi;
            float p = v * (1f - s);
            float q = v * (1f - f * s);
            float t = v * (1f - (1f - f) * s);

            float r, g, b;
            switch (hi % 6)
            {
                case 0: r = v; g = t; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = t; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = t; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
            return new Color32((byte)(r * 255), (byte)(g * 255), (byte)(b * 255), 255);
        }

        // Get per-group dimmer offset — creates layering
        public float GetGroupDimmerOffset(int groupIndex)
        {
            switch (GroupBehaviorMode)
            {
                case 0: // Dimmer ride — groups offset in a wave
                    return Mathf.Sin((groupIndex + GroupBehaviorPhase) * Mathf.PI * 0.5f) * 0.2f;
                case 1: // Pulse — even groups bright, odd groups dim
                    return (groupIndex % 2 == 0) ? 0.1f : -0.15f;
                case 2: // Sweep — gradient across groups
                    return (groupIndex / 8f - 0.5f) * 0.3f;
                case 3: // Hold — all same
                    return 0f;
                default: return 0f;
            }
        }

        public string GetSectionName()
        {
            return CurrentSection.ToString();
        }

        // --- Stage scanning ---
        // Discovers all fixtures on the current stage and organizes them into virtual groups.
        // This lets the brain work with any stage setup without hardcoding.
        public void ScanStage()
        {
            Groups.Clear();
            AllLasers.Clear();
            AllBlinders.Clear();
            MovingLightCount = 0;
            StaticLightCount = 0;
            LaserCount = 0;
            BlinderCount = 0;

            // Find all laser controllers
            var lasers = Object.FindObjectsOfType<LaserContoller>();
            if (lasers != null)
            {
                foreach (var lc in lasers)
                {
                    if (lc != null)
                    {
                        AllLasers.Add(lc);
                        LaserCount++;
                    }
                }
            }

            // Find all blinders
            var blinders = Object.FindObjectsOfType<Blinders>();
            if (blinders != null)
            {
                foreach (var b in blinders)
                {
                    if (b != null)
                    {
                        AllBlinders.Add(b);
                        BlinderCount++;
                    }
                }
            }

            // Find all moving lights and categorize them
            var allLights = Object.FindObjectsOfType<MovingLight>();
            if (allLights != null)
            {
                // Separate into moving and static (non-laser)
                var movingLights = new List<MovingLight>();
                var staticLights = new List<MovingLight>();

                foreach (var ml in allLights)
                {
                    if (ml == null) continue;
                    var t = Traverse.Create(ml);
                    bool isLaser = t.Field("is_laser").GetValue<bool>();
                    bool isStatic = t.Field("is_static").GetValue<bool>();

                    // Skip Flashlight and GeneratorLights
                    string typeName = ml.GetType().Name;
                    if (typeName.Contains("Flashlight") || typeName.Contains("Generator"))
                        continue;

                    if (isLaser) continue; // lasers handled via LaserContoller

                    if (isStatic)
                    {
                        staticLights.Add(ml);
                        StaticLightCount++;
                    }
                    else
                    {
                        movingLights.Add(ml);
                        MovingLightCount++;
                    }
                }

                // Create virtual groups from moving lights
                // Group by spatial proximity (X position) for natural left/right/center splits
                movingLights.Sort((a, b) => a.transform.position.x.CompareTo(b.transform.position.x));

                int numMovingGroups = Mathf.Min(4, Mathf.Max(1, movingLights.Count / 2));
                int perGroup = Mathf.CeilToInt((float)movingLights.Count / numMovingGroups);

                for (int g = 0; g < numMovingGroups; g++)
                {
                    var grp = new FixtureGroup
                    {
                        Name = $"Moving-{g}",
                        GroupIndex = g,
                        CurrentEffectMode = 0
                    };
                    for (int i = g * perGroup; i < Mathf.Min((g + 1) * perGroup, movingLights.Count); i++)
                    {
                        grp.Lights.Add(movingLights[i]);
                    }
                    if (grp.Lights.Count > 0)
                        Groups.Add(grp);
                }

                // Static lights as one group
                if (staticLights.Count > 0)
                {
                    var staticGrp = new FixtureGroup
                    {
                        Name = "Static",
                        GroupIndex = Groups.Count,
                        CurrentEffectMode = 0
                    };
                    staticGrp.Lights.AddRange(staticLights);
                    Groups.Add(staticGrp);
                }
            }

            _stageScanned = true;
            _lastScanTime = Time.realtimeSinceStartup;

            Debug.Log($"[LightingBrain] Stage scan: {MovingLightCount} moving, {StaticLightCount} static, {LaserCount} lasers, {BlinderCount} blinders, {Groups.Count} groups");
        }

        // Ensure stage is scanned — rescan if lights appear/disappear
        public void EnsureStageScanned()
        {
            if (!_stageScanned || Time.realtimeSinceStartup - _lastScanTime > 10f)
            {
                ScanStage();
            }
        }

        // Get the effect mode for a specific group index
        public int GetGroupEffectMode(int groupIndex)
        {
            if (groupIndex >= 0 && groupIndex < Groups.Count)
                return Groups[groupIndex].CurrentEffectMode;
            return 0;
        }

        // Randomize effect modes across groups — different groups get different modes
        public void RandomizeGroupModes()
        {
            for (int i = 0; i < Groups.Count; i++)
            {
                int mode;
                if (CurrentSection == Section.Drop)
                {
                    int[] modes = { 3, 4, 5, 6 };
                    mode = modes[_rng.Next(modes.Length)];
                }
                else if (CurrentSection == Section.BuildUp)
                {
                    int[] modes = { 4, 5, 1 };
                    mode = modes[_rng.Next(modes.Length)];
                }
                else if (CurrentSection == Section.Breakdown)
                {
                    int[] modes = { 0, 1, 2 };
                    mode = modes[_rng.Next(modes.Length)];
                }
                else
                {
                    int[] modes = { 0, 2, 3 };
                    mode = modes[_rng.Next(modes.Length)];
                }
                Groups[i].CurrentEffectMode = mode;
            }
        }
    }
}
