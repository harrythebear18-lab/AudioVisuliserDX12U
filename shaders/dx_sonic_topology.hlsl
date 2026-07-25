// Mode 45: Sonic Topology Mapper — 4D topological manifold from audio
// A morphing 3D surface whose genus and curvature change with spectral energy.
// Bass = global shape (sphere→torus→double-torus), mids = surface displacement,
// highs = surface texture detail. Section = topological transformation event.
// Beat = surface ripple. Kick = curvature spike. Transient = topology shift.
// LUFS = surface brightness. Crest = ridge sharpness. THD = surface roughness.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define GRID_N 12

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

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
    // Spectrum L/R — augment brain bands with stereo spectrum data
    float specL[8]; float specR[8];
    [unroll] for (int sb = 0; sb < 8; sb++) {
        specL[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.166), 0).r;
        specR[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.833), 0).r;
        bands[sb] = max(bands[sb], max(specL[sb], specR[sb]) * 0.5);
    }
    float panMod = (specL[0] + specL[1] - specR[0] - specR[1]) * 0.25; // bass pan for camera
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    // ── Camera — orbit the manifold ──
    float FOV = 0.6;
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + panMod * 0.3 + Time * 0.03 * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 3.5, 1.5 + a.stereoDiff * 0.1, cos(camAng) * 3.5);
    float3 camTarget = float3(0, 0, 0);
    float3 fwd = normalize(camTarget - camPos);
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);

    // ── Background — dark topological space ──
    float3 col = float3(0.001, 0.001, 0.005) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Manifold surface — parametric grid ──
    // Topology: bass energy controls genus (sphere→torus→double torus)
    float genus = bands[0] * 2.0 + bands[1] * 1.0;  // 0=sphere, 1=torus, 2=double
    float globalScale = 1.0 + bands[0] * 0.3;

    [loop] for (int gu = 0; gu <= GRID_N; gu++) {
        [loop] for (int gv = 0; gv <= GRID_N; gv++) {
            float u = float(gu) / float(GRID_N) * PI * 2.0;
            float v = float(gv) / float(GRID_N) * PI;

            // Base sphere
            float3 sphPos = float3(sin(v) * cos(u), cos(v), sin(v) * sin(u)) * globalScale;

            // Torus transformation — genus >= 1
            float torusBlend = smoothstep(0.5, 1.5, genus);
            float R = 1.2, r2 = 0.5;
            float3 torusPos = float3(
                (R + r2 * cos(v)) * cos(u),
                r2 * sin(v),
                (R + r2 * cos(v)) * sin(u)
            );
            float3 manifoldPos = lerp(sphPos, torusPos, torusBlend);

            // Double torus — genus >= 2
            float doubleBlend = smoothstep(1.5, 2.5, genus);
            float3 dTorusPos = torusPos;
            dTorusPos.x += sin(u * 2.0) * 0.5 * doubleBlend;
            dTorusPos.y += cos(u * 2.0) * 0.3 * doubleBlend;
            manifoldPos = lerp(manifoldPos, dTorusPos, doubleBlend);

            // Mid-band surface displacement
            float disp = bands[2] * 0.15 * sin(u * 4.0 + Time * 1.5) * sin(v * 3.0);
            disp += bands[3] * 0.12 * fbm2_4(float2(u * 2.0, v * 2.0) + Time * 0.3);
            disp += bands[4] * 0.08 * sin(u * 8.0 + Time * 3.0) * cos(v * 6.0);

            // High-band detail
            disp += bands[5] * 0.04 * fbm2_4(float2(u * 5.0, v * 5.0) + Time * 1.0);
            disp += bands[6] * 0.02 * sin(u * 16.0 + Time * 5.0);
            disp += bands[7] * 0.01 * hash21(float2(u * 30.0, v * 30.0));

            // Beat ripple
            disp += beatPulse * 0.05 * sin(v * 5.0 - a.beatPhase * 8.0);

            // Kick curvature spike
            disp += kickSurge * 0.08 * exp(-length(manifoldPos) * 2.0) * sin(length(manifoldPos) * 10.0);

            // Transient — topology shift jitter
            disp += transientAmt * 0.03 * sin(u * 20.0 + v * 18.0 + Time * 20.0);

            // THD roughness
            disp += thd * 0.02 * hash21(float2(u * 50.0 + Time * 10.0, v * 50.0));

            // Envelope breathing
            disp += envelope * 0.02 * sin(u * 2.0 + Time);

            // Apply displacement along normal (approximate as radial)
            float3 normalDir = normalize(manifoldPos);
            manifoldPos += normalDir * disp;

            // Project to screen
            float3 toMP = manifoldPos - camPos;
            float mpDepth = dot(toMP, fwd);
            if (mpDepth < 0.1) continue;
            float2 scrMP = float2(dot(toMP, right) / (mpDepth * FOV), dot(toMP, up) / (mpDepth * FOV));
            float scrDist = length(p - scrMP);

            // Color — frequency-positioned by displacement magnitude
            float freqFrac = clamp(abs(disp) * 3.0, 0.0, 1.0);
            float3 ptCol = hsv(a.hueBase + freqFrac * a.hueRange, 0.6 * a.satur, 0.9);
            ptCol = lerp(ptCol, lerp(a.brainCol, a.brainCol2, freqFrac), 0.3);
            // Crest sharpens ridges
            ptCol = lerp(ptCol, a.brainCol3, pow(abs(disp) * 2.0, 2.0) * crest * 0.3);

            // Point glow — tight core + crisp mid, minimal halo
            float ptSize = 0.006 / max(mpDepth * 0.15, 0.3);
            float coreGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.05));
            float midGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 0.3));
            float haloGlow = exp(-scrDist * scrDist / (ptSize * ptSize * 1.5));

            float intensity = (abs(disp) * 2.0 + 0.2) * (1.0 + lufs * 0.3);
            float depthFade = exp(-mpDepth * 0.06);

            col += ptCol * coreGlow * intensity * depthFade * 1.5 * silence;
            col += ptCol * midGlow * intensity * depthFade * 0.5 * silence;
            col += ptCol * haloGlow * intensity * depthFade * 0.08 * silence;

            // Wireframe to neighbors
            if (gu < GRID_N) {
                float u2 = float(gu + 1) / float(GRID_N) * PI * 2.0;
                float3 pos2 = float3(sin(v) * cos(u2), cos(v), sin(v) * sin(u2)) * globalScale;
                float3 torusPos2 = float3((R + r2 * cos(v)) * cos(u2), r2 * sin(v), (R + r2 * cos(v)) * sin(u2));
                pos2 = lerp(pos2, torusPos2, torusBlend);
                pos2 = lerp(pos2, torusPos2 + float3(sin(u2 * 2.0) * 0.5, cos(u2 * 2.0) * 0.3, 0) * doubleBlend, doubleBlend);
                pos2 += normalize(pos2) * disp * 0.7;

                float3 toP2 = pos2 - camPos;
                float d2 = dot(toP2, fwd);
                if (d2 > 0.1) {
                    float2 s2 = float2(dot(toP2, right) / (d2 * FOV), dot(toP2, up) / (d2 * FOV));
                    float2 ab = s2 - scrMP;
                    float t2 = clamp(dot(p - scrMP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                    float2 cl = scrMP + ab * t2;
                    float wd = length(p - cl);
                    col += ptCol * exp(-wd * wd * 500.0) * intensity * depthFade * 0.15 * silence;
                }
            }
            if (gv < GRID_N) {
                float v2 = float(gv + 1) / float(GRID_N) * PI;
                float3 pos2 = float3(sin(v2) * cos(u), cos(v2), sin(v2) * sin(u)) * globalScale;
                float3 torusPos2 = float3((R + r2 * cos(v2)) * cos(u), r2 * sin(v2), (R + r2 * cos(v2)) * sin(u));
                pos2 = lerp(pos2, torusPos2, torusBlend);
                pos2 = lerp(pos2, torusPos2 + float3(sin(u * 2.0) * 0.5, cos(u * 2.0) * 0.3, 0) * doubleBlend, doubleBlend);
                pos2 += normalize(pos2) * disp * 0.7;

                float3 toP2 = pos2 - camPos;
                float d2 = dot(toP2, fwd);
                if (d2 > 0.1) {
                    float2 s2 = float2(dot(toP2, right) / (d2 * FOV), dot(toP2, up) / (d2 * FOV));
                    float2 ab = s2 - scrMP;
                    float t2 = clamp(dot(p - scrMP, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
                    float2 cl = scrMP + ab * t2;
                    float wd = length(p - cl);
                    col += ptCol * exp(-wd * wd * 500.0) * intensity * depthFade * 0.15 * silence;
                }
            }
        }
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
