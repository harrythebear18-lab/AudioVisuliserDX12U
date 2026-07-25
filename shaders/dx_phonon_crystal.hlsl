// Mode 43: Phonon Crystal Lattice — 3D phononic crystal wave propagation
// You are inside a crystal lattice. Sound waves propagate through it.
// Each band excites different phonon modes (longitudinal/transverse).
// Beat = wave packet injection. Kick = lattice compression wave.
// Transient = defect scattering. LUFS = wave amplitude. Crest = lattice stiffness.
// THD = lattice disorder. Phase = wave coherence. Stereo = L/R wave direction.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define LATTICE_NX 3
#define LATTICE_NY 3
#define LATTICE_NZ 3
#define N_ATOMS 27

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

struct LatticeAtom {
    float3 restPos;
    float3 displ;
    float energy;
    float gate;
    float freqFrac;
    float3 color;
};

void computeLattice(out LatticeAtom atoms[N_ATOMS], out int atomCount,
                    float bands[8], float dspBands[8], float kickSurge, float beatPulse,
                    float stereoBal, float stereoWid, float crest, float thd,
                    float transient, float envelope, float section, float phaseCoh, AudioData a)
{
    atomCount = 0;
    float spacing = 0.8;

    [unroll] for (int ix = 0; ix < LATTICE_NX; ix++) {
        [unroll] for (int iy = 0; iy < LATTICE_NY; iy++) {
            [unroll] for (int iz = 0; iz < LATTICE_NZ; iz++) {
                if (atomCount >= N_ATOMS) break;
                int n = atomCount;

                // Rest position
                float3 rest = float3(
                    (float(ix) - float(LATTICE_NX - 1) * 0.5) * spacing,
                    (float(iy) - float(LATTICE_NY - 1) * 0.5) * spacing,
                    (float(iz) - float(LATTICE_NZ - 1) * 0.5) * spacing
                );
                atoms[n].restPos = rest;

                // Band assignment by position
                float posFrac = length(rest) / 4.0;
                int band = clamp(int(posFrac * 8.0), 0, 7);
                float bt = float(band) / float(N_COMP - 1);

                float rawEnergy = bands[band] + dspBands[band] * 0.12;
                float energy = (band < 4) ? pow(rawEnergy, 0.5) : rawEnergy;
                float gate = smoothstep(0.02, 0.08, rawEnergy);

                // Spectrum L/R — stereo spatial positioning
                float freqU = bandFreq[band];
                float lE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.166), 0).r;
                float rE = u_spectrum.SampleLevel(u_sampler, float2(freqU, 0.833), 0).r;
                float stereoEnergy = max(lE, rE);
                energy = max(energy, stereoEnergy * 0.5);
                gate = max(gate, smoothstep(0.02, 0.08, stereoEnergy));
                float panMod = (lE - rE) * 0.5;

                // Phonon displacement — longitudinal wave from stereo direction
                float2 waveDir = normalize(float2(stereoBal + 0.01 + panMod * 0.3, 0.5));
                float wavePhase = dot(rest.xz, waveDir) * 3.0 - Time * 4.0 * (1.0 + bt);
                float longWave = sin(wavePhase) * energy * 0.15;

                // Transverse wave — perpendicular
                float transWave = cos(wavePhase + PI * 0.5) * energy * 0.1 * (1.0 - phaseCoh * 0.5);

                // Beat — wave packet
                float beatWave = beatPulse * sin(length(rest) * 4.0 - a.beatPhase * 8.0) * 0.08;

                // Kick — compression wave from center
                float kickWave = kickSurge * exp(-length(rest) * 0.5) * sin(length(rest) * 6.0 - a.beatPhase * 10.0) * 0.1;

                // THD — lattice disorder
                float disorder = thd * hash11(float(n) * 7.3 + Time * 5.0) * 0.05;

                // Transient — defect scattering
                float scatter = transient * fbm2_4(rest.xz * 3.0 + Time * 8.0) * 0.06;

                atoms[n].displ = float3(
                    longWave * waveDir.x + transWave * waveDir.y + beatWave + kickWave + disorder + scatter,
                    sin(wavePhase * 1.3 + Time) * energy * 0.05 + beatWave * 0.5,
                    longWave * waveDir.y - transWave * waveDir.x + beatWave + kickWave + disorder + scatter
                );

                // Staggered breathing
                float h = energy * (0.3 + beatPulse * 0.7 * (0.5 + bt * 0.5));
                h += transient * lerp(0.05, 0.2, bt) * gate;
                h += envelope * lerp(0.08, 0.03, bt) * gate;
                h += section * 0.05 * gate;
                h += (band < 2) ? kickSurge * kickSurge * lerp(0.4, 0.1, bt) : 0.0;
                h *= gate;

                atoms[n].energy = clamp(h, 0.0, 1.5);
                atoms[n].gate = gate;
                atoms[n].freqFrac = bt;

                float3 c = hsv(a.hueBase + bt * a.hueRange, 0.6 * a.satur, 0.9);
                c = lerp(c, lerp(a.brainCol, a.brainCol2, bt), 0.3);
                atoms[n].color = c;

                atomCount++;
            }
        }
    }
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);
    float silence = 1.0 - a.isSilent;

    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    LatticeAtom atoms[N_ATOMS];
    int atomCount;
    computeLattice(atoms, atomCount, bands, dspBands, kickSurge, beatPulse,
                   a.stereoBal, a.stereoWid, crest, thd, transientAmt, envelope,
                   a.section, phaseCoh, a);

    // ── Camera — inside the crystal ──
    float FOV = 0.7;
    float camAng = a.section * 0.5 + a.stereoBal * 0.2 + Time * 0.02 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 3.0, 1.0 + a.stereoDiff * 0.1, cos(camAng) * 3.0);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark crystal void ──
    float3 col = float3(0.001, 0.002, 0.006) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Lattice bonds — connect adjacent atoms ──
    [loop] for (int i = 0; i < N_ATOMS; i++) {
        if (atoms[i].gate < 0.01) continue;
        float3 posI = atoms[i].restPos + atoms[i].displ;
        float3 toI = posI - camPos;
        float depthI = dot(toI, fwd);
        if (depthI < 0.1) continue;
        float2 scrI = float2(dot(toI, right) / (depthI * FOV), dot(toI, up) / (depthI * FOV));

        // Check neighbors
        [loop] for (int j = i + 1; j < N_ATOMS; j++) {
            if (atoms[j].gate < 0.01) continue;
            float3 restDelta = atoms[j].restPos - atoms[i].restPos;
            float restDist = length(restDelta);
            if (restDist > 1.1) continue;  // only nearest neighbors

            float3 posJ = atoms[j].restPos + atoms[j].displ;
            float3 toJ = posJ - camPos;
            float depthJ = dot(toJ, fwd);
            if (depthJ < 0.1) continue;
            float2 scrJ = float2(dot(toJ, right) / (depthJ * FOV), dot(toJ, up) / (depthJ * FOV));

            // Bond color — strain-based
            float strain = length(posJ - posI) / max(restDist, 0.1) - 1.0;
            float3 bondCol = lerp(atoms[i].color, atoms[j].color, 0.5);
            bondCol = lerp(bondCol, float3(1.0, 0.3, 0.1), abs(strain) * 2.0);

            // Bond line
            float2 ab = scrJ - scrI;
            float t = clamp(dot(p - scrI, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
            float2 closest = scrI + ab * t;
            float bondDist = length(p - closest);
            float bondWidth = 0.0015;
            float bondGlow = exp(-bondDist * bondDist / (bondWidth * bondWidth));

            float avgDepth = (depthI + depthJ) * 0.5;
            float depthFade = exp(-avgDepth * 0.08);
            float bondInt = (atoms[i].energy + atoms[j].energy) * 0.5 * (1.0 + lufs * 0.15);

            col += bondCol * bondGlow * bondInt * depthFade * 0.1 * silence;
        }
    }

    // ── Atoms — glowing lattice points ──
    [loop] for (int k = 0; k < N_ATOMS; k++) {
        if (atoms[k].gate < 0.01) continue;
        float3 atomPos = atoms[k].restPos + atoms[k].displ;
        float3 toAtom = atomPos - camPos;
        float atomDepth = dot(toAtom, fwd);
        if (atomDepth < 0.1) continue;
        float2 scrAtom = float2(dot(toAtom, right) / (atomDepth * FOV), dot(toAtom, up) / (atomDepth * FOV));
        float scrDist = length(p - scrAtom);

        float sz = (0.012 + atoms[k].energy * 0.03) / max(atomDepth * 0.15, 0.3) * 3.0;
        float coreGlow = exp(-scrDist * scrDist / (sz * sz * 0.1));
        float midGlow = exp(-scrDist * scrDist / (sz * sz * 0.8));
        float haloGlow = exp(-scrDist * scrDist / (sz * sz * 5.0));

        float intensity = atoms[k].energy * (1.0 + lufs * 0.2);
        float depthFade = exp(-atomDepth * 0.08);

        col += float3(0.9, 0.95, 1.0) * coreGlow * intensity * depthFade * 1.5 * silence;
        col += atoms[k].color * midGlow * intensity * depthFade * 0.6 * silence;
        col += atoms[k].color * haloGlow * intensity * depthFade * 0.15 * silence;
    }

    // ── Beat ring ──
    float ringDist = abs(r - a.beatPhase * 0.7);
    col += a.brainCol * exp(-ringDist * ringDist * 40.0) * beatPulse * 0.025 * silence;

    // ── Kick flash ──
    col += a.brainCol3 * kickSurge * 0.05 * exp(-r * r * 5.0) * silence;

    // ── Transient pop ──
    col += float3(1.0, 0.8, 0.5) * transientAmt * 0.025 * silence;

    // ── ColorPulse ──
    col += a.brainCol3 * a.colorPulse * 0.02 * silence;

    // ── Energy + punch ──
    col += a.brainCol2 * a.energy * 0.015 * silence;
    col += a.brainCol * a.punch * 0.015 * silence;

    // ── Beat anticipation ──
    col += a.brainCol * a.beatAnt * 0.01 * exp(-r * 2.0) * silence;

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.02;

    // ── HDR limiter ──
    float maxC = max(col.r, max(col.g, col.b));
    if (maxC > 1.14) col *= 1.14 / maxC;

    col *= silence;

    return float4(col, 1.0);
}
