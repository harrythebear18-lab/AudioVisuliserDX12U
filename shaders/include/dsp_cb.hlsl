// Resonance DSP constant buffer — professional audio analysis data
// Bound at b2 — opt-in for shaders that want DSP-enhanced visuals
// Existing shaders that don't include this are completely unaffected

cbuffer DspCB : register(b2)
{
    // EBU R128 Loudness (LUFS)
    float DspMomentaryLUFS;     // momentary (400ms window)
    float DspShortTermLUFS;     // short-term (3s window)
    float DspIntegratedLUFS;    // integrated (since reset)
    float DspTHDPercentage;     // total harmonic distortion %

    // Phase + Level
    float DspPhaseCorrelation;  // -1 to +1 (L/R coherence)
    float DspPeakDbL;           // peak level left (dB)
    float DspPeakDbR;           // peak level right (dB)
    float DspCrestFactorDb;     // crest factor (dB) — headroom indicator

    // Biquad band-pass levels (8 bands, RMS)
    float DspBand0;             // sub
    float DspBand1;             // bass
    float DspBand2;             // low_mid
    float DspBand3;             // mid
    float DspBand4;             // high_mid
    float DspBand5;             // presence
    float DspBand6;             // brilliance
    float DspBand7;             // air
};

// Helper: normalized LUFS → 0..1 (maps -70..0 LUFS to 0..1)
float lufsNormalized()
{
    return saturate((DspMomentaryLUFS + 70.0) / 70.0);
}

// Helper: crest factor → dynamic range quality (0=compressed, 1=dynamic)
float crestFactorNormalized()
{
    return saturate(DspCrestFactorDb / 20.0);
}

// Helper: THD → warmth factor (0=clean, 1=distorted)
float thdNormalized()
{
    return saturate(DspTHDPercentage / 10.0);
}

// Helper: phase correlation → stereo coherence (0=out-of-phase, 1=mono)
float phaseCoherence()
{
    return DspPhaseCorrelation * 0.5 + 0.5;
}
