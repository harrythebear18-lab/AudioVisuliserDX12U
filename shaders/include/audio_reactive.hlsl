// Audio-reactive utilities — spectrum sampling, band extraction, beat smoothing

// Sample spectrum at arbitrary position
float sampleSpectrum(float u) {
    return u_spectrum.SampleLevel(u_sampler, float2(u, 0.5), 0).r;
}

// Sample stereo L/R
float sampleSpectrumL(float u) {
    return u_spectrum.SampleLevel(u_sampler, float2(u, 0.166), 0).r;
}

float sampleSpectrumR(float u) {
    return u_spectrum.SampleLevel(u_sampler, float2(u, 0.833), 0).r;
}

// 8-band extraction (cached in AudioData, but available standalone)
void getBands(out float b[8]) {
    b[0] = sampleSpectrum(0.02);
    b[1] = sampleSpectrum(0.06);
    b[2] = sampleSpectrum(0.12);
    b[3] = sampleSpectrum(0.20);
    b[4] = sampleSpectrum(0.30);
    b[5] = sampleSpectrum(0.42);
    b[6] = sampleSpectrum(0.55);
    b[7] = sampleSpectrum(0.70);
}

// Smoothed beat — exponential decay
float beatSmooth(float beat, float time, float decayRate) {
    return beat * exp(-frac(time * decayRate) * 8.0);
}

// Beat shockwave — expanding ring
float beatShockwave(float r, float time, float speed, float decay, AudioData a) {
    float swR = frac(time * speed) * 1.8;
    return exp(-abs(r - swR) * decay) * a.beat * 0.22 * a.tempoConf;
}

// Kick flash — radial burst
float kickFlash(float r, AudioData a) {
    return exp(-r * r * 5.0) * a.kick * 0.2 * a.kickConf;
}

// Effect burst — type-dispatched
float3 effectBurst(float2 p, float r, AudioData a) {
    float3 col = float3(0,0,0);
    if (a.burstTrig > 0.5) {
        if (a.burstType < 0.5)
            col += hsv(a.hueCenter + 0.1, 0.4, 1.0) * smoothstep(0.8, 0.0, r) * a.burstInt * 0.2;
        else if (a.burstType < 1.5)
            col += hsv(a.hueCenter, 0.3, 1.0) * smoothstep(0.05, 0.0, abs(r - a.burstInt * 1.5)) * (1.0 - a.burstInt) * 0.25;
        else if (a.burstType < 2.5)
            col = lerp(col, hsv(a.hueCenter + 0.15, 0.6, 0.8), a.burstInt * 0.12);
        else {
            float spark = hash21(p * 300.0 + Time);
            col += hsv(a.hueCenter + spark * 0.3, 0.3, 1.0) * step(0.98, spark) * a.burstInt * 0.4;
        }
    }
    return col;
}

// Section change flash
float3 sectionFlash(float r, AudioData a) {
    if (a.shouldChg > 0.5)
        return hsv(a.hueCenter, 0.2, 1.0) * smoothstep(1.0, 0.0, r) * 0.1;
    return float3(0,0,0);
}

// Phrase pulse — 16-beat cycle
float phrasePulse(AudioData a) {
    return 1.0 + sin(a.phraseBeat / 16.0 * 3.14159) * 0.06 * a.energy;
}

// Global brightness modulation — speech-aware
float globalBrightness(AudioData a) {
    float musicBright = 0.2 + a.gated * 0.8 + a.brightness * 0.15;
    float speechBright = a.ambientLevel + a.voiceActivity * 0.3;
    float bright = lerp(musicBright, speechBright, a.speechMode);
    return bright * (1.0 - a.isSilent * 0.98);
}

// ── Audio Simulation System ──
// The "dolby method": each visual element samples its own frequency bin,
// with L/R stereo separation, transient scatter, and phase-linked intensity.
// This replaces time-driven animation with true audio-driven simulation.

struct AudioElement {
    float amplitude;        // mono amplitude at this element's frequency
    float ampL;             // left channel amplitude
    float ampR;             // right channel amplitude
    float pan;              // stereo pan (-1 = full left, +1 = full right)
    float2 panOffset;       // stereo-panned position offset
    float intensity;        // combined intensity with envelope
    float transientScatter; // transient-based random displacement
    float freqFrac;         // normalized frequency position (0=bass, 1=treble)
};

// Get per-element audio data — idx is the element index, total is the count
AudioElement audioSimElement(int idx, int total, AudioData a) {
    AudioElement e;
    e.freqFrac = float(idx) / float(max(total - 1, 1));

    // Sample spectrum at this element's frequency — 3-row texture: row 0=L (V=0), row 1=mono (V=0.5), row 2=R (V=1)
    e.ampL = u_spectrum.SampleLevel(u_sampler, float2(e.freqFrac, 0.0), 0).r;
    e.ampR = u_spectrum.SampleLevel(u_sampler, float2(e.freqFrac, 1.0), 0).r;
    e.amplitude = u_spectrum.SampleLevel(u_sampler, float2(e.freqFrac, 0.5), 0).r;
    e.amplitude = max(e.amplitude, (e.ampL + e.ampR) * 0.5);

    // Stereo pan — derived from L/R difference
    e.pan = (e.ampR - e.ampL) / max(e.ampL + e.ampR, 0.01);
    e.panOffset = float2(e.pan * a.stereoWid * 0.5, 0.0);

    // Intensity — amplitude boosted by envelope and overall energy
    e.intensity = e.amplitude * (0.3 + a.envelope * 0.7) * (0.5 + a.overall * 0.5);

    // Transient scatter — random displacement on transient hits
    e.transientScatter = (hash11(float(idx) * 0.137 + floor(Time * 30.0)) - 0.5) * a.transient * 0.12;

    return e;
}

// Phase-linked intensity between two elements — for connection lines
float audioSimLink(AudioElement a, AudioElement b, float phaseCorr) {
    return phaseCorr * a.intensity * b.intensity;
}

// Kick impulse — radial displacement from center
float2 audioSimKick(float2 pos, AudioData a) {
    float dist = length(pos);
    if (dist < 0.01) return float2(0, 0);
    return normalize(pos) * a.kick * 0.15 * a.kickConf / (1.0 + dist);
}

// Beat ring — expanding circle at given radius
float audioSimBeatRing(float dist, AudioData a, float time) {
    float ringR = a.beat * 0.3 * a.tempoConf;
    return exp(-abs(dist - ringR) * 20.0) * a.beat * 0.2;
}
