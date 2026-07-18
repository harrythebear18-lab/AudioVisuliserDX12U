using System.Collections.Generic;
// UnityEngine and HarmonyLib replaced by UnityStubs.cs in same namespace

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

        // Genre types — detected from audio characteristics over time
        public enum Genre { Unknown, Electronic, Rock, HipHop, Pop, Ambient, Classical, Jazz, LoFi, Trap, Dubstep, House, Techno, DrumAndBass }

        // Visualization mode names — DX12U premium modes
        public enum VisMode { Spectrum3D, CosmicFractal, ChromaticWindow, ParticleNebula, NeonTunnel }

        // Current state
        public Section CurrentSection { get; private set; } = Section.Unknown;
        public float SectionConfidence { get; private set; } = 0f;
        public Genre CurrentGenre { get; private set; } = Genre.Unknown;
        public float GenreConfidence { get; private set; } = 0f;
        public VisMode RecommendedMode { get; private set; } = VisMode.Spectrum3D;
        public bool ShouldChangeMode { get; private set; } = false;
        public int BeatCount { get; private set; } = 0;
        public int PhraseBeat { get; private set; } = 0; // 0-15 within a 16-beat phrase
        public int PhraseCount { get; private set; } = 0;

        // Energy tracking for section detection
        private float _energyHistory = 0f;
        private float _energyTrend = 0f; // positive = rising, negative = falling
        private float _peakEnergyRecent = 0f;
        private float _avgEnergy = 0f;
        private float _energySmoothed = 0f;      // fast smoothed — for trend
        private float _energyLP = 0f;            // low-pass filtered — for section detection (jitter-free)
        private float _sectionTimer = 0f;
        private float _lastBeatTime = 0f;
        // Song-relative dynamic range tracking
        private float _songMinEnergy = -1f;  // -1 = not yet initialized
        private float _songMaxEnergy = -1f;
        private float _energyRange = 0f;  // max - min, used for relative thresholds
        private float _trendAccum = 0f;   // accumulated trend over ~2s for stable direction
        private float _trendTimer = 0f;

        // Genre detection tracking — analyzes audio characteristics over time
        private float _genreDetectionTimer = 0f;
        private float _bpmHistory = 0f;
        private float _avgBPM = 0f;
        private float _bpmVariance = 0f;
        private float _avgSpectralClarity = 0f;
        private float _avgStereoWidth = 0f;
        private float _avgPhaseCorrelation = 0f;
        private float _avgTransient = 0f;
        private float _dynamicRange = 0f;
        private float _lowMidRatio = 0f;  // bass/mid ratio for genre clues
        private int _genreSampleCount = 0;
        private VisMode _prevRecommendedMode = VisMode.Spectrum3D;
        private float _modeChangeTimer = 0f;

        // Silence detection for GPU reset
        private float _silenceTimer = 0f;
        private float _silenceTimeout = 30f; // 30 seconds of silence before GPU reset
        public bool ShouldResetGPU { get; private set; } = false;

        // Ollama vision feedback integration
        private float _visualEnergy = 0.5f;
        private float _visualMood = 0.5f;
        private float _colorBalance = 0.5f;
        private float _complexity = 0.5f;
        private float _visualFeedbackWeight = 0.3f; // How much vision feedback influences decisions

        // Color palette per section
        public Color32 CurrentColor { get; private set; }
        public Color32 SecondaryColor { get; private set; }
        private int _colorPairIndex = 0;

        // Effect decisions — visualizer-native triggers (replaces stage-sim pyro/smoke/flash)
        public bool TriggerEffectBurst { get; private set; }    // one-shot visual effect
        public int EffectBurstType { get; private set; }         // 0=radial, 1=shockwave, 2=colorwave, 3=sparkle
        public float EffectBurstIntensity { get; private set; }  // 0-1 scale of burst
        public float AtmosphereDensity { get; private set; }     // 0-1 haze/fog density (replaces smoke)
        public float ColorPulse { get; private set; }            // 0-1 smooth color pulse (replaces flash)

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
        public float BeatAnticipation { get; private set; }  // 0-1, ramps up before beat
        public float PhaseCorrelation { get; private set; }  // 0-1 (0.5=uncorrelated)
        public float SpectralClarity { get; private set; }   // 0=noise, 1=tonal
        public float MotionPersistence { get; private set; } // 0-1, trail/decay length driven by crest factor, BPM, energy, section

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
        public float BaseHue => _baseHue;
        private float _sectionHueCenter = 0f;   // center hue for current section
        private float _sectionHueRange = 0.3f;   // how wide the hue range is for current section
        public float SectionHueCenter => _sectionHueCenter;
        public float SectionHueRange => _sectionHueRange;
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

        // Effect burst cooldowns and state
        private float _lastBurstTime = -10f;
        private float _lastAtmosphereShift = -10f;
        private int _burstTypeCounter = 0;  // cycles through effect types for variety
        private Section _prevSection = Section.Unknown;

        public void Reset()
        {
            CurrentSection = Section.Unknown;
            SectionConfidence = 0f;
            CurrentGenre = Genre.Unknown;
            GenreConfidence = 0f;
            BeatCount = 0;
            PhraseBeat = 0;
            PhraseCount = 0;
            _energyHistory = 0f;
            _energyTrend = 0f;
            _peakEnergyRecent = 0f;
            _avgEnergy = 0f;
            _energySmoothed = 0f;
            _energyLP = 0f;
            _sectionTimer = 0f;
            _songMinEnergy = -1f;
            _songMaxEnergy = -1f;
            _energyRange = 0f;
            _colorPairIndex = 0;
            CurrentColor = ColorPairs[0][0];
            SecondaryColor = ColorPairs[0][1];
            TriggerEffectBurst = false;
            EffectBurstType = 0;
            EffectBurstIntensity = 0f;
            AtmosphereDensity = 0f;
            ColorPulse = 0f;
            LasersOn = false;
            MovingLightsOn = false;
            StaticLightsOn = false;
            BlindersOn = false;
            StrobeOn = false;
            LaserIntensity = 0f;
            MovingLightIntensity = 0f;
            StaticLightIntensity = 0f;
            BlinderIntensity = 0f;
            DesiredEffectMode = 0;
            ShouldChangeEffectMode = false;
            TriggerRandomFlash = false;
            RandomFlashIntensity = 0f;
            _lastRandomFlashTime = -10f;
            MotionPersistence = 0f;
            // Reset genre detection
            _genreDetectionTimer = 0f;
            _bpmHistory = 0f;
            _avgBPM = 0f;
            _bpmVariance = 0f;
            _avgSpectralClarity = 0f;
            _avgStereoWidth = 0f;
            _avgPhaseCorrelation = 0f;
            _avgTransient = 0f;
            _dynamicRange = 0f;
            _lowMidRatio = 0f;
            _genreSampleCount = 0;
        }

        // Called every frame with current analyzer state
        public void Update(AudioAnalyzer analyzer, float dt)
        {
            TriggerEffectBurst = false;
            EffectBurstIntensity = 0f;
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

                // Track silence duration for GPU reset
                _silenceTimer += dt;
                if (_silenceTimer >= _silenceTimeout)
                {
                    ShouldResetGPU = true;
                    _silenceTimer = 0f; // Reset timer after triggering
                }
                return;
            }

            // Audio detected - reset silence timer
            _silenceTimer = 0f;
            ShouldResetGPU = false;

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

            // --- Color wheel rotation ---
            // Slowly rotate the base hue for continuous color movement
            _baseHue = Mathf.Repeat(_baseHue + _hueRotationSpeed * dt, 1f);

            // --- Energy smoothing for section detection ---
            // Fast smoothed for trend detection
            _energySmoothed = Mathf.Lerp(_energySmoothed, energy, 1f - Mathf.Exp(-dt * 10f));
            // Low-pass filter: ~1.5Hz cutoff — removes per-beat jitter, preserves musical section changes
            // This is the uniform smoother that gives coherent section tracking
            _energyLP = Mathf.Lerp(_energyLP, energy, 1f - Mathf.Exp(-dt * 1.5f));
            
            _trendTimer += dt;
            if (_trendTimer >= 0.3f)
            {
                _energyTrend = (_energyLP - _energyHistory) / _trendTimer;
                _energyHistory = _energyLP;
                _trendTimer = 0f;
            }

            // Track song-relative dynamic range using the low-pass filtered energy
            if (_songMinEnergy < 0f || _songMaxEnergy < 0f)
            {
                _songMinEnergy = _energyLP;
                _songMaxEnergy = _energyLP * 1.5f + 0.01f;
            }
            float adaptRate = 1.0f;
            _songMinEnergy = Mathf.Lerp(_songMinEnergy, Mathf.Min(_songMinEnergy, _energyLP), 1f - Mathf.Exp(-dt * adaptRate));
            _songMaxEnergy = Mathf.Lerp(_songMaxEnergy, Mathf.Max(_songMaxEnergy, _energyLP), 1f - Mathf.Exp(-dt * adaptRate));
            _energyRange = Mathf.Max(0.05f, _songMaxEnergy - _songMinEnergy);

            // Track recent peak and average using low-pass energy
            _peakEnergyRecent = Mathf.Max(_peakEnergyRecent * 0.96f, _energyLP);
            _avgEnergy = Mathf.Lerp(_avgEnergy, _energyLP, 1f - Mathf.Exp(-dt * 0.5f));

            _sectionTimer += dt;

            // --- Section detection ---
            Section prevSection = CurrentSection;
            DetectSection(_energyLP, transient, dt);
            if (prevSection != CurrentSection)
            {
                OnSectionChanged();
            }

            // --- Genre detection ---
            // Sample audio characteristics every 0.5s and classify genre after 5 samples (~2.5s)
            _genreDetectionTimer += dt;
            if (_genreDetectionTimer >= 0.5f)
            {
                SampleGenreCharacteristics(analyzer);
                _genreDetectionTimer = 0f;
            }
            if (_genreSampleCount >= 5)
            {
                DetectGenre();
            }

            // --- Beat anticipation (lookahead) ---
            // Uses tempo tracker's predicted next beat time to pre-swell intensity
            // Creates a smooth ramp-up in the ~250ms before a predicted beat
            float nextBeat = analyzer.Tempo?.NextBeatTime ?? -1f;
            float tempoConf = analyzer.Tempo?.Confidence ?? 0f;
            float nowReal = Time.realtimeSinceStartup;
            if (nextBeat > 0f && tempoConf > 0.3f)
            {
                float timeToBeat = nextBeat - nowReal;
                // Ramp up in the last 250ms before beat, peak at beat time
                if (timeToBeat > 0f && timeToBeat < 0.25f)
                {
                    float t = 1f - timeToBeat / 0.25f;  // 0→1 as we approach beat
                    BeatAnticipation = Mathf.Lerp(BeatAnticipation, t * tempoConf, 1f - Mathf.Exp(-dt * 20f));
                }
                else if (timeToBeat <= 0f)
                {
                    // Beat just hit — decay anticipation
                    BeatAnticipation = Mathf.Lerp(BeatAnticipation, 0f, 1f - Mathf.Exp(-dt * 8f));
                }
                else
                {
                    // Far from beat — slow decay
                    BeatAnticipation = Mathf.Lerp(BeatAnticipation, 0f, 1f - Mathf.Exp(-dt * 3f));
                }
            }
            else
            {
                BeatAnticipation = Mathf.Lerp(BeatAnticipation, 0f, 1f - Mathf.Exp(-dt * 5f));
            }

            // Pull advanced analysis from analyzer
            SpectralClarity = analyzer.SpectralClarity;
            PhaseCorrelation = WASAPIPlugin.Instance.GetPhaseCorrelation();

            // --- Effect intensity curves — optimized for visualization ---
            // Core energy curve with mild expansion for wide dynamic range
            float energyCurve = Mathf.Pow(_energySmoothed, 1.2f);
            
            // Spectral clarity sharpens visuals: tonal music = punchier, noisy = softer/diffuse
            float clarityBoost = Mathf.Lerp(0.85f, 1.15f, SpectralClarity);
            
            // Beat anticipation pre-swells intensity before predicted beats
            EffectIntensity = Mathf.Clamp01(energyCurve * clarityBoost + BeatAnticipation * 0.15f);
            
            // Brightness: 0 at silence, 1 at peak — clarity adds punch, anticipation adds pre-glow
            DimmerIntensity = Mathf.Clamp01(EffectIntensity + BeatAnticipation * 0.1f);
            
            // Movement: transient-driven with BPM factor, clarity makes movement sharper
            float bpmFactor = Mathf.Clamp01((BPM - 60f) / 140f);
            MovementIntensity = Mathf.Clamp01(
                transient * 1.5f * clarityBoost + 
                EffectIntensity * 0.15f + 
                bpmFactor * 0.1f
            );

            // --- Fixture on/off decisions ---
            // Like a real lighting console: different fixture types have different roles
            float relEnergy = Mathf.Clamp01((_energySmoothed - _songMinEnergy) / _energyRange);
            float now = Time.realtimeSinceStartup;

            // Moving lights: on whenever there's audio, intensity follows energy + clarity
            MovingLightsOn = relEnergy > 0.05f;
            MovingLightIntensity = Mathf.Clamp01(EffectIntensity * clarityBoost);

            // Static lights: on during verse/intro/breakdown for wash, off during drops for contrast
            StaticLightsOn = (CurrentSection == Section.Verse || CurrentSection == Section.Intro ||
                             CurrentSection == Section.Breakdown || CurrentSection == Section.Outro) &&
                             relEnergy > 0.05f;
            // Ambient fill is softer when clarity is high (tonal = less fill needed)
            StaticLightIntensity = Mathf.Clamp01(EffectIntensity * 0.6f * Mathf.Lerp(1.2f, 0.7f, SpectralClarity));

            // Lasers/beams: phase correlation drives stereo spread, clarity drives sharpness
            if (CurrentSection == Section.BuildUp || CurrentSection == Section.Drop)
            {
                LasersOn = relEnergy > 0.05f;
            }
            else if (CurrentSection == Section.Breakdown)
            {
                LasersOn = relEnergy > 0.15f && (BeatCount % 2 == 0 || beatIntensity > 0.2f);
            }
            else
            {
                LasersOn = relEnergy > 0.25f;
            }
            // Beam intensity: energy + beat pulse, clarity sharpens, phase correlation widens
            LaserIntensity = Mathf.Clamp01(
                EffectIntensity * 0.6f * clarityBoost + 
                (beatIntensity > 0.1f ? beatIntensity * 0.4f : 0f)
            );

            // Bloom: smooth glow that swells with energy, kick, beat + anticipation
            // Clarity makes bloom tighter/brighter, noise makes it diffuse
            float bloomTarget = Mathf.Clamp01(
                EffectIntensity * 0.4f + 
                KickLevel * 0.5f + 
                beatIntensity * 0.3f + 
                BeatAnticipation * 0.2f
            ) * clarityBoost;
            BlinderIntensity = Mathf.Lerp(BlinderIntensity, bloomTarget, 1f - Mathf.Exp(-dt * 8f));
            BlindersOn = BlinderIntensity > 0.02f;

            // Strobe: disabled — replaced by smooth bloom
            StrobeOn = false;

            // --- Group behavior variation ---
            // Change behavior mode every 4 beats
            if (BeatCount > 0 && BeatCount % 4 == 0)
            {
                GroupBehaviorMode = (GroupBehaviorMode + 1) % 4;
            }
            GroupBehaviorPhase = (Time.realtimeSinceStartup * MovementIntensity) % 1f;

            // --- Random flash triggers --- disabled, replaced by smooth bloom
            TriggerRandomFlash = false;
            RandomFlashIntensity = 0f;

            // --- Atmosphere density (replaces smoke) ---
            // Continuous haze that thickens during build-ups and drops, thins during quiet sections
            // Noisy music (low clarity) = more atmosphere, tonal music = cleaner
            float atmoTarget = 0f;
            if (CurrentSection == Section.BuildUp) atmoTarget = 0.4f + BeatAnticipation * 0.3f;
            else if (CurrentSection == Section.Drop) atmoTarget = 0.6f;
            else if (CurrentSection == Section.Chorus) atmoTarget = 0.3f;
            else if (CurrentSection == Section.Breakdown) atmoTarget = 0.2f;
            // Low clarity (noisy/diffuse) adds atmosphere, high clarity (tonal) keeps it clean
            atmoTarget *= EffectIntensity * Mathf.Lerp(1.3f, 0.7f, SpectralClarity);
            AtmosphereDensity = Mathf.Lerp(AtmosphereDensity, atmoTarget, 1f - Mathf.Exp(-dt * 4f));

            // --- Color pulse (replaces flash) ---
            // Smooth color intensity swell on beats — clarity makes it punchier
            float pulseTarget = (beatIntensity * 0.3f + BeatAnticipation * 0.15f) * clarityBoost;
            ColorPulse = Mathf.Lerp(ColorPulse, pulseTarget, 1f - Mathf.Exp(-dt * 8f));

            // --- Effect burst triggers (replaces pyro) ---
            // Sparse, varied visual effects on section changes and phrase boundaries
            // Different effect types cycle for variety: radial, shockwave, colorwave, sparkle
            bool sectionChanged = (CurrentSection != _prevSection);
            float burstCooldown = 12f;  // minimum seconds between bursts

            // Fire on section transitions (especially into drops/choruses)
            if (sectionChanged && (CurrentSection == Section.Drop || CurrentSection == Section.Chorus))
            {
                TriggerEffectBurst = true;
                EffectBurstType = CurrentSection == Section.Drop ? 1 : 2;  // shockwave for drop, colorwave for chorus
                EffectBurstIntensity = 0.8f + BeatAnticipation * 0.2f;
                _lastBurstTime = now;
                _burstTypeCounter++;
            }
            // Fire on phrase boundaries during high-energy sections
            else if ((CurrentSection == Section.Drop || CurrentSection == Section.Chorus) &&
                     BeatCount > 0 && BeatCount % 32 == 0 &&
                     (now - _lastBurstTime) > burstCooldown)
            {
                TriggerEffectBurst = true;
                EffectBurstType = _burstTypeCounter % 4;  // cycle through types
                EffectBurstIntensity = 0.5f + EffectIntensity * 0.3f;
                _lastBurstTime = now;
                _burstTypeCounter++;
            }
            // Occasional sparkle bursts during build-ups at 16-beat boundaries
            else if (CurrentSection == Section.BuildUp &&
                     BeatCount > 0 && BeatCount % 16 == 0 &&
                     (now - _lastBurstTime) > burstCooldown)
            {
                TriggerEffectBurst = true;
                EffectBurstType = 3;  // sparkle shower
                EffectBurstIntensity = 0.4f + BeatAnticipation * 0.3f;
                _lastBurstTime = now;
                _burstTypeCounter++;
            }

            // --- Motion persistence (trail/decay length) ---
            // Combines crest factor (spectral clarity), BPM, energy, and section to determine
            // how long visual trails persist. Punchy tonal music with high tempo confidence
            // gets long trails; diffuse/noisy music gets short trails.
            float crestFactor = SpectralClarity;  // 0=noise/diffuse, 1=tonal/punchy
            float tempoStability = TempoConfidence;  // 0=unknown, 1=locked
            float bpmFactorPersist = Mathf.Clamp01((BPM - 60f) / 140f);  // 0=slow, 1=fast
            float relEnergyPersist = Mathf.Clamp01((_energyLP - _songMinEnergy) / _energyRange);

            // Base persistence: crest factor drives core trail length
            // Tonal/punchy music (high crest) = long trails; noisy/diffuse = short
            float persistenceBase = Mathf.Lerp(0.15f, 0.7f, crestFactor);

            // Tempo stability boosts persistence — locked beat grid = consistent trails
            persistenceBase *= Mathf.Lerp(0.6f, 1.15f, tempoStability);

            // Energy adds to persistence — more energy = more to see in trails
            persistenceBase += relEnergyPersist * 0.15f;

            // BPM factor: faster music = slightly shorter trails (too fast = visual mush)
            // But moderate-fast with high clarity = nice motion blur effect
            persistenceBase *= Mathf.Lerp(1.1f, 0.85f, bpmFactorPersist * (1f - crestFactor * 0.5f));

            // Section modifiers
            float sectionMod = 0f;
            if (CurrentSection == Section.Drop) sectionMod = 0.2f;       // drops = maximum trails
            else if (CurrentSection == Section.BuildUp) sectionMod = 0.15f; // build-ups = growing trails
            else if (CurrentSection == Section.Chorus) sectionMod = 0.1f;   // chorus = moderate trails
            else if (CurrentSection == Section.Breakdown) sectionMod = -0.1f; // breakdown = clean
            else if (CurrentSection == Section.Intro) sectionMod = -0.15f;    // intro = minimal
            else if (CurrentSection == Section.Outro) sectionMod = 0.05f;     // outro = lingering

            float persistenceTarget = Mathf.Clamp01(persistenceBase + sectionMod);
            // Smooth the persistence value — slow Lerp so it doesn't flicker
            MotionPersistence = Mathf.Lerp(MotionPersistence, persistenceTarget, 1f - Mathf.Exp(-dt * 1.5f));

            _prevSection = CurrentSection;
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
            // Musical section detection using relative energy + trend + transient.
            // Responsive but coherent — sections switch within 2-4s of actual musical change.
            // Uses beat count for phrase-aware switching.

            float relEnergy = Mathf.Clamp01((energy - _songMinEnergy) / _energyRange);
            float relPeak = Mathf.Clamp01((_peakEnergyRecent - _songMinEnergy) / _energyRange);
            float relAvg = Mathf.Clamp01((_avgEnergy - _songMinEnergy) / _energyRange);

            Section prevSection = CurrentSection;

            // Drop: high energy, near peak, stable or rising
            // Musical cue: the big moment — everything hits
            if (relEnergy > 0.55f && relPeak > 0.6f)
            {
                if (CurrentSection != Section.Drop || _sectionTimer > 8f)
                {
                    CurrentSection = Section.Drop;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.15f);
                    _sectionTimer = 0f;
                }
            }
            // BuildUp: energy rising, transient activity increasing
            // Musical cue: tension building toward drop
            else if (_energyTrend > 0.01f && relEnergy > 0.15f)
            {
                if (CurrentSection != Section.BuildUp || _sectionTimer > 6f)
                {
                    CurrentSection = Section.BuildUp;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.12f);
                    _sectionTimer = 0f;
                }
            }
            // Breakdown: energy falling from high, transient dropping
            // Musical cue: post-drop pullback
            else if (_energyTrend < -0.01f && relAvg > 0.15f)
            {
                if (CurrentSection != Section.Breakdown || _sectionTimer > 6f)
                {
                    CurrentSection = Section.Breakdown;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.12f);
                    _sectionTimer = 0f;
                }
            }
            // Verse: moderate energy, relatively stable
            // Musical cue: the groove — main section
            else if (relEnergy > 0.08f && relEnergy < 0.55f)
            {
                if (_sectionTimer > 4f)
                {
                    CurrentSection = Section.Verse;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.08f);
                }
            }
            // Intro: low energy, stable or slowly rising
            // Musical cue: song just started
            else if (relEnergy < 0.12f && _energyTrend < 0.01f)
            {
                if (_sectionTimer > 3f)
                {
                    CurrentSection = Section.Intro;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.06f);
                }
            }
            // Outro: low energy, falling
            // Musical cue: song winding down
            else if (relEnergy < 0.12f && _energyTrend < -0.01f)
            {
                if (_sectionTimer > 3f)
                {
                    CurrentSection = Section.Outro;
                    SectionConfidence = Mathf.Min(1f, SectionConfidence + 0.06f);
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

        // Randomize effect modes across groups — different groups get different modes
        // (Stage scanning removed for visualizer — no fixtures to scan)
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

        // --- Genre Detection ---

        // Sample audio characteristics for genre analysis
        private void SampleGenreCharacteristics(AudioAnalyzer analyzer)
        {
            // Accumulate running averages of key characteristics
            _avgBPM = Mathf.Lerp(_avgBPM, BPM, 1f / (_genreSampleCount + 1));
            _avgSpectralClarity = Mathf.Lerp(_avgSpectralClarity, SpectralClarity, 1f / (_genreSampleCount + 1));
            _avgStereoWidth = Mathf.Lerp(_avgStereoWidth, StereoWidth, 1f / (_genreSampleCount + 1));
            _avgPhaseCorrelation = Mathf.Lerp(_avgPhaseCorrelation, PhaseCorrelation, 1f / (_genreSampleCount + 1));
            _avgTransient = Mathf.Lerp(_avgTransient, analyzer.Transient, 1f / (_genreSampleCount + 1));

            // Track BPM variance
            if (_bpmHistory > 0f)
            {
                float diff = BPM - _bpmHistory;
                _bpmVariance = Mathf.Lerp(_bpmVariance, diff * diff, 1f / (_genreSampleCount + 1));
            }
            _bpmHistory = BPM;

            // Track dynamic range (peak vs average energy)
            float relPeak = Mathf.Clamp01((_peakEnergyRecent - _songMinEnergy) / _energyRange);
            float relAvg = Mathf.Clamp01((_avgEnergy - _songMinEnergy) / _energyRange);
            _dynamicRange = Mathf.Lerp(_dynamicRange, relPeak - relAvg, 1f / (_genreSampleCount + 1));

            // Track bass/mid ratio for genre clues
            float bass = analyzer.Bands[1]; // Bass band
            float mid = analyzer.Bands[3];   // Mid band
            _lowMidRatio = Mathf.Lerp(_lowMidRatio, bass / (mid + 0.001f), 1f / (_genreSampleCount + 1));

            _genreSampleCount++;
        }

        // Classify genre based on accumulated characteristics
        private void DetectGenre()
        {
            // Genre classification using rule-based decision tree
            // Uses BPM, spectral clarity, stereo characteristics, dynamic range, and frequency balance

            Genre detectedGenre = Genre.Unknown;
            float confidence = 0f;

            // Electronic subgenres — high tempo confidence, synthetic characteristics
            if (TempoConfidence > 0.6f)
            {
                if (_avgBPM > 140f && _avgSpectralClarity > 0.6f && _dynamicRange > 0.4f)
                {
                    // Fast, punchy, high dynamic range
                    if (_lowMidRatio > 1.2f)
                    {
                        detectedGenre = Genre.DrumAndBass; // Fast + bass-heavy
                        confidence = 0.8f;
                    }
                    else if (_avgBPM > 160f)
                    {
                        detectedGenre = Genre.Techno; // Very fast
                        confidence = 0.75f;
                    }
                    else
                    {
                        detectedGenre = Genre.House; // Fast house
                        confidence = 0.7f;
                    }
                }
                else if (_avgBPM > 120f && _avgBPM < 150f && _lowMidRatio > 1.0f)
                {
                    detectedGenre = Genre.Dubstep; // Mid-tempo, bass-heavy
                    confidence = 0.75f;
                }
                else if (_avgBPM > 130f && _avgBPM < 145f && _avgStereoWidth > 0.5f)
                {
                    detectedGenre = Genre.Trap; // Mid-tempo, wide stereo
                    confidence = 0.7f;
                }
                else if (_avgBPM > 110f && _avgBPM < 130f)
                {
                    detectedGenre = Genre.Electronic; // General electronic
                    confidence = 0.65f;
                }
            }

            // Hip-hop — moderate tempo, bass-heavy, wide stereo
            if (detectedGenre == Genre.Unknown && _avgBPM > 80f && _avgBPM < 110f)
            {
                if (_lowMidRatio > 1.3f && _avgStereoWidth > 0.4f)
                {
                    detectedGenre = Genre.HipHop;
                    confidence = 0.75f;
                }
            }

            // Rock — moderate tempo, lower spectral clarity (distorted), moderate dynamic range
            if (detectedGenre == Genre.Unknown && _avgBPM > 100f && _avgBPM < 140f)
            {
                if (_avgSpectralClarity < 0.5f && _dynamicRange > 0.3f && _avgTransient > 0.3f)
                {
                    detectedGenre = Genre.Rock;
                    confidence = 0.7f;
                }
            }

            // Pop — moderate tempo, high spectral clarity (clean), moderate dynamic range
            if (detectedGenre == Genre.Unknown && _avgBPM > 90f && _avgBPM < 130f)
            {
                if (_avgSpectralClarity > 0.6f && _dynamicRange < 0.4f && _avgStereoWidth > 0.3f)
                {
                    detectedGenre = Genre.Pop;
                    confidence = 0.7f;
                }
            }

            // Ambient — slow tempo, low transient, high phase correlation (spacious)
            if (detectedGenre == Genre.Unknown && _avgBPM < 100f)
            {
                if (_avgTransient < 0.2f && _avgPhaseCorrelation > 0.6f && _dynamicRange < 0.3f)
                {
                    detectedGenre = Genre.Ambient;
                    confidence = 0.75f;
                }
            }

            // Lo-fi — slow tempo, low spectral clarity (noisy), low dynamic range
            if (detectedGenre == Genre.Unknown && _avgBPM < 100f)
            {
                if (_avgSpectralClarity < 0.4f && _dynamicRange < 0.25f && _avgTransient < 0.25f)
                {
                    detectedGenre = Genre.LoFi;
                    confidence = 0.7f;
                }
            }

            // Jazz — variable tempo, moderate clarity, moderate stereo
            if (detectedGenre == Genre.Unknown)
            {
                if (_avgSpectralClarity > 0.4f && _avgSpectralClarity < 0.7f && _bpmVariance > 100f)
                {
                    detectedGenre = Genre.Jazz;
                    confidence = 0.6f;
                }
            }

            // Classical — variable tempo, high clarity, wide stereo
            if (detectedGenre == Genre.Unknown)
            {
                if (_avgSpectralClarity > 0.7f && _avgStereoWidth > 0.6f && _bpmVariance > 200f)
                {
                    detectedGenre = Genre.Classical;
                    confidence = 0.65f;
                }
            }

            // Update genre if confidence is high enough
            if (confidence > 0.4f) // Lowered threshold from 0.5f to 0.4f for more responsive detection
            {
                CurrentGenre = detectedGenre;
                GenreConfidence = confidence;
                // Update recommended mode when genre changes
                UpdateRecommendedMode();
            }

            // Reset sampling for continuous adaptation
            _genreSampleCount = 0;
            _bpmHistory = 0f;
            _avgSpectralClarity = 0f;
            _avgStereoWidth = 0f;
            _avgPhaseCorrelation = 0f;
            _avgTransient = 0f;
        }

        // Map genre + section to recommended visualization mode
        private void UpdateRecommendedMode()
        {
            VisMode newMode = RecommendedMode;

            // Advanced DX12U mode selection based on genre and section
            if (CurrentGenre == Genre.Electronic || CurrentGenre == Genre.House || CurrentGenre == Genre.Techno)
            {
                switch (CurrentSection)
                {
                    case Section.Drop: newMode = VisMode.CosmicFractal; break;
                    case Section.BuildUp: newMode = VisMode.ParticleNebula; break;
                    case Section.Breakdown: newMode = VisMode.NeonTunnel; break;
                    case Section.Chorus: newMode = VisMode.ChromaticWindow; break;
                    default: newMode = VisMode.Spectrum3D; break;
                }
            }
            else if (CurrentGenre == Genre.DrumAndBass || CurrentGenre == Genre.Dubstep)
            {
                switch (CurrentSection)
                {
                    case Section.Drop: newMode = VisMode.ParticleNebula; break;
                    case Section.BuildUp: newMode = VisMode.NeonTunnel; break;
                    case Section.Breakdown: newMode = VisMode.CosmicFractal; break;
                    default: newMode = VisMode.ChromaticWindow; break;
                }
            }
            else if (CurrentGenre == Genre.HipHop || CurrentGenre == Genre.Trap)
            {
                switch (CurrentSection)
                {
                    case Section.Drop: newMode = VisMode.NeonTunnel; break;
                    case Section.BuildUp: newMode = VisMode.ChromaticWindow; break;
                    case Section.Breakdown: newMode = VisMode.ParticleNebula; break;
                    default: newMode = VisMode.Spectrum3D; break;
                }
            }
            else
            {
                // Default for other genres
                switch (CurrentSection)
                {
                    case Section.Drop: newMode = VisMode.ChromaticWindow; break;
                    case Section.BuildUp: newMode = VisMode.CosmicFractal; break;
                    case Section.Breakdown: newMode = VisMode.ParticleNebula; break;
                    default: newMode = VisMode.Spectrum3D; break;
                }
            }

            // Only trigger mode change if different and enough time has passed
            if (newMode != _prevRecommendedMode && _modeChangeTimer > 2f)
            {
                RecommendedMode = newMode;
                ShouldChangeMode = true;
                _prevRecommendedMode = newMode;
                _modeChangeTimer = 0f;
            }
        }

        // Call this when section changes to update mode recommendation
        private void OnSectionChanged()
        {
            UpdateRecommendedMode();
        }

        public string GetGenreName()
        {
            return CurrentGenre.ToString();
        }

        // --- Ollama Vision Feedback Integration ---

        /// <summary>
        /// Update visual feedback from Ollama vision model.
        /// Called periodically by the main loop to incorporate AI visual assessment.
        /// </summary>
        public void UpdateVisionFeedback(float visualEnergy, float visualMood, float colorBalance, float complexity)
        {
            _visualEnergy = visualEnergy;
            _visualMood = visualMood;
            _colorBalance = colorBalance;
            _complexity = complexity;

            // Adjust genre confidence based on visual-audio alignment
            // If visual energy doesn't match audio energy, reduce genre confidence
            float audioEnergy = OverallNormalized;
            float energyMismatch = Mathf.Abs(visualEnergy - audioEnergy);
            if (energyMismatch > 0.3f)
            {
                GenreConfidence = Mathf.Max(0f, GenreConfidence - 0.1f * _visualFeedbackWeight);
            }

            // Mood influences hue rotation speed — high mood = faster color movement
            _hueRotationSpeed = Mathf.Lerp(_hueRotationSpeed, 0.04f + (visualMood - 0.5f) * 0.06f * _visualFeedbackWeight, 0.1f);

            // Complexity nudges atmosphere density — high visual complexity = slightly more haze for depth
            AtmosphereDensity = Mathf.Lerp(AtmosphereDensity,
                AtmosphereDensity + (complexity - 0.5f) * 0.1f * _visualFeedbackWeight, 0.1f);
        }

        public float GetVisualEnergy() => _visualEnergy;
        public float GetVisualMood() => _visualMood;
        public float GetColorBalance() => _colorBalance;
        public float GetComplexity() => _complexity;
    }
}
