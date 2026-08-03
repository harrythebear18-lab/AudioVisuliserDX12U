// Mode 49: Fractal Dimension Explorer — morphing 3D Mandelbulb with audio params
// You fly through a 3D Mandelbulb/Julia fractal that morphs with audio.
// Each band controls a different fractal parameter (power, twist, offset, rotation).
// Beat = parameter jump. Section = fractal type shift. Profile = exploration path.
// Kick = dimension spike. Transient = fractal glitch. LUFS = fractal brightness.
// Crest = edge sharpness. THD = fractal noise. Phase = symmetry. Stereo = orbit path.

#include "include/audio_cb.hlsl"
#include "include/dsp_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

#define PI 3.14159265
#define N_COMP 8
#define MARCH_STEPS 16  // was 24 — freed budget for reactivity

static const float bandFreq[8] = {
    0.02, 0.06, 0.12, 0.20, 0.30, 0.42, 0.55, 0.70
};

// Audio-driven Mandelbulb SDF — optimized: 4 iterations (was 5), atan2 instead of branchy atan
float audioMandelbulb(float3 p, float bands[8], float beatPulse, float kickSurge,
                      float transient, float envelope, float thd, float section,
                      float beatPhase, float stereoBal)
{
    // Audio-driven power — bass + beat + kick for sharp reactivity
    float power = 4.0 + bands[0] * 4.0 + bands[1] * 2.0 + beatPulse * 1.5;
    power += kickSurge * 3.0;  // was 2.0 — stronger kick response
    power = clamp(power, 2.0, 9.0);

    // Twist — mid-band + stereo for reactive rotation
    float twist = bands[2] * 0.5 + bands[3] * 0.3 + stereoBal * 0.2;
    float ang = twist * p.y + Time * 0.2 + beatPhase * twist * 2.0;  // beat-driven twist pulse
    float3 twisted = float3(
        p.x * cos(ang) - p.z * sin(ang),
        p.y,
        p.x * sin(ang) + p.z * cos(ang)
    );

    // Offset — high-band driven, beat-synced
    twisted += float3(
        bands[4] * 0.1 * sin(Time * 0.5),
        bands[5] * 0.08 * cos(Time * 0.7),
        bands[6] * 0.06 * sin(Time * 0.6)
    );

    // Kick-driven radial push — fractal bulges outward on kick
    float kickPush = kickSurge * 0.15 * normalize(twisted + 0.001);
    twisted -= kickPush;

    // THD noise
    twisted += float3(
        thd * (hash11(p.x * 50.0 + Time) - 0.5) * 0.05,
        thd * (hash11(p.y * 50.0 + Time) - 0.5) * 0.05,
        thd * (hash11(p.z * 50.0 + Time) - 0.5) * 0.05
    );

    // Mandelbulb distance — 4 iterations (was 5)
    float3 z = twisted;
    float dr = 1.0;
    float r = 0.0;

    [loop] for (int i = 0; i < 4; i++) {
        r = length(z);
        if (r > 2.0) break;

        float theta = acos(z.z / max(r, 0.001));
        float phi = atan2(z.y, z.x);  // branchless — was branchy atan
        dr = pow(r, power - 1.0) * power * dr + 1.0;

        float zr = pow(r, power);
        theta *= power;
        phi *= power * (1.0 + twist * 0.1);

        z = zr * float3(
            sin(theta) * cos(phi),
            sin(theta) * sin(phi),
            cos(theta)
        );

        z += twisted;
    }

    // Distance estimate
    float dist = 0.5 * log(max(r, 0.001)) * r / max(dr, 0.001);

    // Envelope breathing — scale fractal
    dist *= (1.0 - envelope * 0.05);

    // Transient — glitch displacement (stronger)
    if (transient > 0.02)
        dist += transient * sin(p.x * 20.0 + p.y * 18.0 + Time * 30.0) * 0.04;

    return dist;
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
    // Spectrum L/R — augment brain bands with stereo spectrum data
    float specL[8]; float specR[8];
    [unroll] for (int sb = 0; sb < 8; sb++) {
        specL[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.166), 0).r;
        specR[sb] = u_spectrum.SampleLevel(u_sampler, float2(bandFreq[sb], 0.833), 0).r;
        bands[sb] = max(bands[sb], max(specL[sb], specR[sb]) * 0.5);
    }
    float panMod = (specL[0] + specL[1] - specR[0] - specR[1]) * 0.25;
    float dspBands[8] = { DspBand0, DspBand1, DspBand2, DspBand3, DspBand4, DspBand5, DspBand6, DspBand7 };
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float phrase = phrasePulse(a);

    // ── Camera — fly through the fractal with kick shake + beat sway ──
    float FOV = 0.6 + kickSurge * 0.08;  // kick punches FOV wider
    float camAng = a.section * 0.8 + a.stereoBal * 0.2 + panMod * 0.3 + Time * 0.03 * a.motSpeed;
    float camDist = 3.0 - a.profBass * 0.5 - kickSurge * 0.4;  // kick dolly-in
    float3 camPos = float3(sin(camAng) * camDist, 1.0 + a.stereoDiff * 0.1, cos(camAng) * camDist);
    // Kick shake — immediate camera displacement
    camPos += float3(
        sin(Time * 47.0) * kickSurge * 0.08,
        cos(Time * 43.0) * kickSurge * 0.06,
        sin(Time * 51.0) * kickSurge * 0.05
    );
    // Beat sway — gentle camera bob on beat
    camPos.y += sin(a.beatPhase * PI * 2.0) * beatPulse * 0.05;
    float3 camTarget = float3(0, 0, 0);
    float3 rd = cameraRay(camPos, camTarget, float2(-p.x, -p.y), FOV);

    // ── Background — deep fractal void ──
    float3 col = float3(0.001, 0.001, 0.005) * silence;
    col += starfield(uv, a) * 0.005;

    // ── Raymarch the fractal ──
    float t = 0.05;
    float marchGlow = 0.0;
    bool hit = false;
    int hitIter = 0;

    [loop] for (int i = 0; i < MARCH_STEPS; i++) {
        float3 sp = camPos + rd * t;
        float d = audioMandelbulb(sp, bands, beatPulse, kickSurge, transientAmt, envelope, thd, a.section, a.beatPhase, a.stereoBal);
        marchGlow += 0.005 / (1.0 + d * d * 30.0);
        if (d < 0.003) { hit = true; hitIter = i; break; }
        t += d * 0.6;
        if (t > 6.0) break;
    }

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 vDir = normalize(camPos - hp);

        // Normal via finite differences
        float eps = 0.003;
        float3 n = normalize(float3(
            audioMandelbulb(hp + float3(eps, 0, 0), bands, beatPulse, kickSurge, transientAmt, envelope, thd, a.section, a.beatPhase, a.stereoBal)
          - audioMandelbulb(hp - float3(eps, 0, 0), bands, beatPulse, kickSurge, transientAmt, envelope, thd, a.section, a.beatPhase, a.stereoBal),
            2.0 * eps,
            audioMandelbulb(hp + float3(0, 0, eps), bands, beatPulse, kickSurge, transientAmt, envelope, thd, a.section, a.beatPhase, a.stereoBal)
          - audioMandelbulb(hp - float3(0, 0, eps), bands, beatPulse, kickSurge, transientAmt, envelope, thd, a.section, a.beatPhase, a.stereoBal)
        ));

        // Fresnel
        float fres = pow(1.0 - max(dot(n, vDir), 0.0), 5.0);

        // Lighting
        float3 lDir = normalize(float3(0.5, 0.7, 0.3));
        float3 lDir2 = normalize(float3(-0.3 + a.stereoBal * 0.2, 0.5, 0.4));
        float diff = max(dot(n, lDir), 0.0);
        float diff2 = max(dot(n, lDir2), 0.0) * 0.4;
        float spec = pow(max(dot(reflect(-lDir, n), vDir), 0.0), 60.0);

        // Color — iteration count + position + beat reactive hue shift
        float iterFrac = float(hitIter) / float(MARCH_STEPS);
        float hueShift = beatPulse * 0.1 + kickSurge * 0.15;  // beat/kick shift hue
        float3 fractalCol = hsv(a.hueBase + iterFrac * a.hueRange + hueShift, 0.6 * a.satur, 0.9);
        fractalCol = lerp(fractalCol, lerp(a.brainCol, a.brainCol2, iterFrac), 0.3);
        fractalCol = lerp(fractalCol, a.brainCol3, bands[7] * 0.2 + kickSurge * 0.15);

        // Crest sharpens edges
        float edge = pow(1.0 - max(dot(n, vDir), 0.0), 2.0) * crest;

        float3 litCol = fractalCol * (diff + diff2) * (0.3 + a.brightness * 0.3 + a.dynamic * 0.2);
        litCol += float3(0.9, 0.85, 0.8) * spec * (0.5 + a.dynLight * 0.7);
        litCol += fractalCol * fres * (0.4 + envelope * 0.4 + a.glow * 0.2);
        litCol += a.brainCol3 * edge * 0.1;

        // Beat — emissive pulse (stronger)
        litCol += fractalCol * beatPulse * 0.15 * silence;

        // Kick — hot spike (stronger)
        litCol += float3(1.0, 0.5, 0.1) * kickSurge * 0.25 * silence;

        // Transient — glitch color shift (stronger)
        if (transientAmt > 0.02)
            litCol = lerp(litCol, litCol.gbr, transientAmt * 0.5);

        // Dynamic light boost
        litCol *= (0.6 + a.dynamic * 0.4);
        litCol += fractalCol * a.punch * 0.05 * silence;

        col = blendScreen(col, litCol);
    }

    // ── Ambient fractal glow ──
    col += a.brainCol * marchGlow * (0.015 + a.glow * 0.02) * (0.5 + envelope * 0.5) * silence;

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

    // ── Dynamic HDR limiter ──
    col = hdrLimiter(col);

    col *= silence;

    return float4(col, 1.0);
}
