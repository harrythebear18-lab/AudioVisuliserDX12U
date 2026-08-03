// RS by Resonance — RapidSpectrum Visualizer
// HUD Mode 48: Sonic Sphereworld — Resonance Orbital Sphere
// VR Layer mode.
//
// Concept: A living plasma sphere with 8 orbital energy rings. The sphere
// surface is a swirling plasma storm — 8 band-driven angular sectors create
// flowing surface patterns using layered trig (no FBM). Rings orbit at
// different inclinations and speeds, with wave-modulated profiles (not flat
// ellipses — the ring radius varies along its circumference). Energy
// filaments connect intersection hotspots. Gravitational lensing distorts
// the starfield near the sphere. Pulsar beams sweep on kick. Corona
// discharges on transient. The sphere breathes with the envelope.
//
// ALL AudioData fields used — see field comments inline.
//
// No seComputeEmitters, no seEmitGlowDepth/VR, no seLinkLR, no softReinhard.
// No SDF raymarching, no seWorldEnvironment, no seListener.
// HDR output to Layer 0. No local postfx.

#include "include/spatial_encoder.hlsl"
#include "include/layers.hlsl"
#include "include/noise.hlsl"

#define PI 3.14159265

// Project a 3D point to 2D screen space
float2 project2D(float3 worldPos, float3 camPos, float3 camFwd, float3 camRight, float3 camUp, float camFov)
{
    float3 toP = worldPos - camPos;
    float depth = dot(toP, camFwd);
    if (depth < 0.1) return float2(999, 999);
    return float2(dot(toP, camRight) / (depth * camFov), dot(toP, camUp) / (depth * camFov));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target
{
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    p += vrParallax(2.0);
    float r = length(p);
    float ang = atan2(p.y, p.x);
    float silence = 1.0 - a.isSilent;
    float flashScale = vrFlashScale();

    // ── DSP ──
    float lufs = lufsNormalized();
    float crest = crestFactorNormalized();
    float thd = thdNormalized();
    float phaseCoh = phaseCoherence();

    // ── Audio dynamics ──
    float beatPulse = a.beat * a.tempoConf;
    float kickSurge = a.kick * a.kickConf * exp(-a.beatPhase * 3.0);
    float transientAmt = a.transient;
    float envelope = a.envelope;
    float bassEnergy = (a.b0 + a.b1) * 0.5;
    float trebEnergy = (a.b6 + a.b7) * 0.5;

    float bands[8] = { a.b0, a.b1, a.b2, a.b3, a.b4, a.b5, a.b6, a.b7 };

    // ── Camera — orbit the sphere ──
    float camAng = a.section * 0.3 + a.stereoBal * 0.15 + Time * vrMotionScale(0.02) * a.motSpeed;
    float3 camPos = float3(sin(camAng) * 1.2, 0.3 + a.stereoDiff * 0.08, cos(camAng) * 1.2);
    float3 camFwd = normalize(-camPos);
    float3 camRight = normalize(cross(camFwd, float3(0, 1, 0)));
    float3 camUp = cross(camRight, camFwd);
    float camFov = 0.9;

    // ── Gravitational lensing — distort starfield near sphere ──
    // Bass energy = lensing strength. Distorts p for background only.
    float sphereR = 0.18 * a.barScale;
    float lensStrength = bassEnergy * 0.15 + a.energy * 0.05;
    float2 lensDir = normalize(p + 0.001);
    float lensR = length(p);
    float lensFactor = lensStrength * sphereR * sphereR / (lensR * lensR + 0.01);
    float2 lensP = p - lensDir * lensFactor;
    float lensR2 = length(lensP);

    // ── Background — lensed starfield + dark space ──
    float3 col = float3(0.002, 0.003, 0.006);
    // Starfield using lensed coordinates
    float starN = hash21(floor(lensP * 200.0));
    if (starN > 0.98) {
        float twinkle = sin(Time * 3.0 + starN * 100.0) * 0.5 + 0.5;
        col += float3(0.8, 0.85, 1.0) * (starN - 0.98) * 50.0 * twinkle * 0.003;
    }
    // Nebula clouds — lensed
    float nebula = sin(lensP.x * 3.0 + Time * 0.1) * sin(lensP.y * 2.5 - Time * 0.08) * 0.5 + 0.5;
    col += a.brainCol * nebula * 0.003 * a.ambient * a.ambActive;
    col += a.brainCol3 * sin(lensP.x * 5.0 - Time * 0.15) * 0.002 * a.ambient * a.ambActive;

    // ── Sphere surface — plasma storm ──
    // Render as a 2D disc with angular plasma patterns
    float sphereDist = r - sphereR;
    float sphereMask = smoothstep(0.02, -0.02, sphereDist);  // 1 inside, 0 outside

    if (sphereMask > 0.01) {
        // Angular position on sphere surface
        float sphAng = ang + Time * 0.1 * a.motSpeed + a.section * 0.5;
        float sphLat = p.y / sphereR;  // -1 to 1 (top to bottom)

        // 8 sector plasma — each band creates swirling surface pattern
        float plasma = 0.0;
        [unroll] for (int i = 0; i < 8; i++) {
            float bandVal = bands[i] * a.gated;
            if (bandVal < 0.005) continue;

            // Each band creates a flowing wave pattern at different frequency
            float freq = 2.0 + float(i) * 1.5;
            freq *= (1.0 + a.specSpread * 0.3);
            float phase = sphAng * freq + Time * (0.5 + float(i) * 0.2) * a.motSpeed;
            phase += a.stereoBal * float(i) * 0.3;
            phase += a.phraseBeat * PI * float(i) * 0.5;

            // Wave amplitude — L/R modulated
            float waveAmp = bandVal * (1.0 + lufs * 0.3);
            waveAmp *= (0.8 + envelope * 0.4);
            waveAmp *= (1.0 - a.calmMode * 0.4);

            // Vocal band boost
            float vocalW = smoothstep(2.5, 3.5, float(i)) * (1.0 - smoothstep(5.0, 6.0, float(i)));
            waveAmp += a.speechMode * vocalW * bandVal * 0.4 * a.gated;
            waveAmp += a.voiceActivity * vocalW * 0.15 * a.gated;

            // Prof bass/treble
            waveAmp *= (1.0 + a.profBass * 0.1 * (1.0 - float(i) / 7.0));
            waveAmp *= (1.0 + a.profTreb * 0.1 * (float(i) / 7.0));

            // Dominant band highlight
            if (abs(float(i) - a.domBand) < 0.5 && a.domBand > 0.01) waveAmp *= 1.4;

            // Layered waves — sin for flow, cos for cross-pattern
            float wave1 = sin(phase + sphLat * freq * 0.5);
            float wave2 = cos(phase * 1.3 - sphLat * freq * 0.7);
            plasma += waveAmp * (wave1 * 0.6 + wave2 * 0.4);
        }

        // Beat — surface pulse wave
        plasma += beatPulse * 0.3 * sin(sphAng * 6.0 - a.beatPhase * PI * 4.0);
        plasma += a.beatDet * 0.15 * sin(sphAng * 10.0 - a.beatPhase * PI * 8.0);

        // Kick — crater impact
        plasma -= kickSurge * 0.4 * exp(-r * r * 20.0);
        plasma += a.punch * 0.2 * sin(sphAng * 8.0 + Time * 10.0) * exp(-r * r * 10.0) * a.gated;

        // Transient — surface rupture
        if (transientAmt > 0.02) {
            plasma += transientAmt * 0.2 * sin(sphAng * 15.0 + Time * 25.0) * exp(-r * r * 8.0);
        }
        plasma += a.dynamic * 0.1 * sin(sphAng * 12.0 + Time * 15.0);

        // Envelope breathing
        plasma += envelope * 0.15 * sin(sphLat * 4.0 + Time * 1.5);

        // Tempo pulse
        plasma += a.tempoPulse * 0.1 * sin(sphAng * 3.0 - Time * 2.0);

        // Phrase drift
        plasma += sin(a.phraseBeat * PI * 2.0) * 0.12 * a.gated * sin(sphAng * 2.0);

        // Burst event
        if (a.burstTrig > 0.5) {
            float burstAng = a.burstType * PI * 0.5 + Time;
            float burstD = abs(sphAng - burstAng);
            plasma += a.burstInt * 0.4 * exp(-burstD * burstD * 5.0) * a.gated;
        }

        // Effect intensity
        plasma += a.effectInt * 0.08 * sin(sphAng * 5.0 + sphLat * 4.0 + Time * 6.0);

        // THD surface roughness
        plasma += thd * 0.06 * sin(sphAng * 30.0 + Time * 12.0) * vrFlickerScale();
        plasma += thd * 0.04 * sin(sphLat * 25.0 - Time * 10.0) * vrFlickerScale();
        plasma *= (1.0 - a.calmMode * 0.6);

        // Phase coherence — surface smoothness
        plasma *= (0.6 + phaseCoh * 0.4);
        plasma *= (1.0 + crest * 0.2);
        plasma *= (1.0 + lufs * 0.15);
        plasma *= a.barScale;

        // ── Surface coloring — plasma zones ──
        float pNorm = saturate(plasma * 0.5 + 0.5);
        float3 surfaceCol;
        if (pNorm < 0.33) {
            surfaceCol = lerp(float3(0.02, 0.01, 0.05), a.brainCol * 0.5, pNorm * 3.0);
        } else if (pNorm < 0.66) {
            surfaceCol = lerp(a.brainCol * 0.5, a.brainCol2, (pNorm - 0.33) * 3.0);
        } else {
            surfaceCol = lerp(a.brainCol2, a.brainCol3, (pNorm - 0.66) * 3.0);
        }
        // Spectral centroid color shift
        surfaceCol = lerp(surfaceCol, hsv(a.hueBase + a.specCent * a.hueRange, a.satur, 1.0), 0.12);
        // Color pulse
        surfaceCol = lerp(surfaceCol, surfaceCol.bgr, a.colorPulse * 0.04);

        // Brightness modifiers
        float surfInt = a.gated;
        surfInt *= (0.7 + a.brightness * 0.3);
        surfInt *= (1.0 - a.calmMode * 0.3);
        surfInt *= (1.0 + lufs * 0.3);
        surfInt += a.glow * 0.05 * a.gated;
        surfInt *= (1.0 + a.bloom * 0.2);

        // Limb darkening — edges of sphere are darker
        float limb = 1.0 - smoothstep(0.7, 1.0, r / sphereR);
        limb = max(limb, 0.3);

        // Apply surface
        col = lerp(col, surfaceCol * abs(plasma) * surfInt * limb * 0.4, sphereMask * silence);

        // Hot plasma filaments — bright streaks on positive plasma
        float filament = max(plasma, 0.0);
        col += surfaceCol * filament * filament * surfInt * limb * 0.15 * sphereMask * silence;

        // Kick crater glow — bright impact point
        col += float3(1.0, 0.5, 0.2) * kickSurge * exp(-r * r * 25.0) * sphereMask * 0.3 * flashScale * silence;
        col += float3(1.0, 0.6, 0.3) * a.punch * exp(-r * r * 15.0) * sphereMask * 0.1 * flashScale * silence;

        // Transient crackle
        if (transientAmt > 0.02) {
            float crackle = hash21(p * 100.0 + Time * 50.0) * transientAmt;
            col += float3(0.9, 0.8, 1.0) * crackle * sphereMask * 0.05 * silence;
        }

        // Section change — surface flash
        if (a.shouldChg > 0.5) {
            col += hsv(a.hueCenter, 0.3, 1.0) * sphereMask * 0.08 * silence;
        }

        // Burst — surface flare
        if (a.burstTrig > 0.5) {
            col += hsv(a.hueCenter + 0.1, 0.5, 1.0) * a.burstInt * sphereMask * 0.1 * silence;
        }
    }

    // ── Sphere corona — atmospheric ring outside sphere ──
    float coronaDist = abs(sphereDist);
    float coronaWidth = 0.04 + envelope * 0.02 + a.energy * 0.02;
    float corona = exp(-coronaDist * coronaDist / (coronaWidth * coronaWidth));
    float3 coronaCol = lerp(a.brainCol, a.brainCol2, 0.5);
    coronaCol = lerp(coronaCol, a.brainCol3, trebEnergy * 0.3);
    col += coronaCol * corona * (0.05 + a.energy * 0.08) * a.gated * silence;
    col += float3(1.0, 0.5, 0.2) * corona * kickSurge * 0.06 * flashScale * silence;

    // ── Corona discharges — transient-driven radial spikes ──
    if (transientAmt > 0.02 && sphereDist > 0.0 && sphereDist < 0.15) {
        float dischargeAng = ang + Time * 5.0;
        float spike = abs(sin(dischargeAng * 12.0)) * transientAmt;
        spike = pow(spike, 8.0);  // sharpen to thin spikes
        col += a.brainCol3 * spike * exp(-sphereDist * sphereDist * 50.0) * 0.15 * silence;
    }

    // ── Pulsar beams — kick-driven sweeping searchlights ──
    if (kickSurge > 0.02) {
        float beamAng1 = Time * 2.0 + a.section * PI;
        float beamAng2 = beamAng1 + PI;
        [unroll] for (int bi = 0; bi < 2; bi++) {
            float bAng = (bi == 0) ? beamAng1 : beamAng2;
            float beamDot = cos(ang - bAng);
            float beam = pow(max(beamDot, 0.0), 80.0);
            float beamFade = exp(-r * r * 0.5) * (1.0 - sphereMask);
            col += a.brainCol2 * beam * beamFade * kickSurge * 0.08 * flashScale * silence;
        }
    }

    // ── 8 orbital rings — wave-modulated profiles ──
    float3 ringColors[8];
    ringColors[0] = a.brainCol;
    ringColors[1] = lerp(a.brainCol, a.brainCol2, 0.15);
    ringColors[2] = lerp(a.brainCol, a.brainCol2, 0.3);
    ringColors[3] = lerp(a.brainCol, a.brainCol2, 0.45);
    ringColors[4] = lerp(a.brainCol2, a.brainCol3, 0.3);
    ringColors[5] = lerp(a.brainCol2, a.brainCol3, 0.5);
    ringColors[6] = lerp(a.brainCol2, a.brainCol3, 0.7);
    ringColors[7] = a.brainCol3;

    float4 ringScreen[8];
    float ringBright[8];
    float3 ringNorms[8];

    [unroll] for (int i = 0; i < 8; i++) {
        float bandVal = bands[i];
        if (bandVal < 0.005) { ringScreen[i] = float4(999, 999, 0, 0); ringBright[i] = 0; ringNorms[i] = 0; continue; }

        // Ring radius
        float ringR = 0.25 + float(i) * 0.07;
        ringR *= a.barScale;
        ringR += a.profBass * 0.03 * (1.0 - float(i) / 7.0);
        ringR += a.profTreb * 0.03 * (float(i) / 7.0);
        ringR += a.beatAnt * 0.02 * a.gated;

        // Ring inclination
        float tilt1 = float(i) * 0.35 + a.section * 0.2 + a.stereoBal * 0.3;
        float tilt2 = float(i) * 0.5 + a.stereoDiff * 0.2 + a.section * 0.15;
        float3 ringNormal = normalize(float3(sin(tilt1) * cos(tilt2), cos(tilt1), sin(tilt1) * sin(tilt2)));
        ringNorms[i] = ringNormal;

        // Orbit
        float orbitSpeed = (0.3 + float(i) * 0.08) * a.motSpeed;
        float orbitAng = Time * orbitSpeed + float(i) * 0.7 + a.section * 0.5;
        float3 ringCenter = float3(
            cos(orbitAng) * 0.05 * bandVal,
            sin(orbitAng * 1.3) * 0.05 * bandVal,
            sin(orbitAng) * 0.05 * bandVal
        );

        // Project ring center
        float3 toC = ringCenter - camPos;
        float depth = dot(toC, camFwd);
        if (depth < 0.1) { ringScreen[i] = float4(999, 999, 0, 0); ringBright[i] = 0; continue; }
        float2 scrCenter = float2(dot(toC, camRight) / (depth * camFov), dot(toC, camUp) / (depth * camFov));
        float scrR = ringR / (depth * camFov);
        float nProj = max(abs(dot(ringNormal, camFwd)), 0.05);
        float scrRy = scrR * nProj;
        ringScreen[i] = float4(scrCenter.x, scrCenter.y, scrR, scrRy);

        // Brightness
        float bright = bandVal * a.gated;
        bright *= (1.0 + lufs * 0.3);
        bright *= (0.8 + envelope * 0.4);
        bright *= (1.0 - a.calmMode * 0.4);
        float lrWeight = sin(orbitAng);
        bright *= (1.0 + lrWeight * (a.leftEn - a.rightEn) / max(a.overall, 0.01) * 0.2);
        float vocalW = smoothstep(2.5, 3.5, float(i)) * (1.0 - smoothstep(5.0, 6.0, float(i)));
        bright += a.speechMode * vocalW * bandVal * 0.3 * a.gated;
        bright += a.voiceActivity * vocalW * 0.1 * a.gated;
        if (abs(float(i) - a.domBand) < 0.5 && a.domBand > 0.01) bright *= 1.4;
        ringBright[i] = bright;

        // ── Render ring with wave-modulated profile ──
        float2 toRing = p - scrCenter;
        float ringAng = atan2(toRing.y, toRing.x);
        // Modulate radius along circumference — wave pattern
        float waveMod = sin(ringAng * (3.0 + float(i)) + Time * (2.0 + float(i) * 0.5) * a.motSpeed) * bandVal * 0.15;
        waveMod += cos(ringAng * (5.0 + float(i) * 0.7) - Time * 1.5) * bandVal * 0.08;
        waveMod += beatPulse * 0.05 * sin(ringAng * 8.0 - a.beatPhase * PI * 4.0);
        waveMod += a.tempoPulse * 0.03 * sin(ringAng * 4.0);
        if (transientAmt > 0.02) waveMod += transientAmt * 0.04 * sin(ringAng * 20.0 + Time * 40.0);
        if (kickSurge > 0.05) waveMod += kickSurge * 0.06 * sin(ringAng * 6.0 + Time * 15.0);
        waveMod *= (1.0 + a.specSpread * 0.2);
        waveMod *= (1.0 - a.calmMode * 0.5);

        float rx = scrR * (1.0 + waveMod);
        float ry = scrRy * (1.0 + waveMod);
        float2 d2 = toRing / float2(rx, ry);
        float ellipseDist = length(d2);
        float ringDist = abs(ellipseDist - 1.0);

        // Thickness
        float ringWidth = 0.006 / (1.0 + crest * 1.5);
        ringWidth *= (1.0 + a.specSpread * 0.15);
        ringWidth += thd * 0.002 * sin(p.x * 50.0 + Time * 20.0 + float(i)) * vrFlickerScale();
        ringWidth *= (1.0 - beatPulse * 0.3 * exp(-a.beatPhase * 4.0));

        // Glow layers
        float ringCore = exp(-ringDist * ringDist / (ringWidth * ringWidth * 0.08));
        float ringGlow = exp(-ringDist * ringDist / (ringWidth * ringWidth));
        float ringHalo = exp(-ringDist * ringDist / (ringWidth * ringWidth * 8.0));

        // Color
        float3 ringCol = ringColors[i];
        ringCol = lerp(ringCol, hsv(a.hueBase + float(i) / 7.0 * a.hueRange, a.satur, 1.0), 0.15);
        ringCol = lerp(ringCol, ringCol.bgr, a.colorPulse * 0.03);
        ringCol = lerp(ringCol, hsv(a.hueBase + a.specCent * a.hueRange, a.satur, 1.0), 0.1);

        // Intensity
        float ringInt = bright;
        ringInt *= (0.7 + a.brightness * 0.3);
        ringInt += a.glow * 0.05 * a.gated;
        ringInt *= (1.0 + a.bloom * 0.2);
        float depthFade = 1.0 / (1.0 + depth * 0.05);

        // Render
        col += ringCol * (ringCore * 0.35 + ringGlow * 0.12) * ringInt * depthFade * silence;
        col += ringCol * ringHalo * ringInt * 0.05 * depthFade * silence;

        // Beat pulse
        col += ringCol * ringCore * beatPulse * 0.18 * exp(-a.beatPhase * 4.0) * depthFade * silence;
        col += ringCol * ringCore * a.beatAnt * 0.1 * a.gated * depthFade * silence;

        // Kick flash + shatter
        col += float3(1.0, 0.5, 0.2) * ringCore * kickSurge * 0.15 * flashScale * depthFade * silence;
        col += float3(1.0, 0.6, 0.3) * ringHalo * a.punch * 0.05 * flashScale * depthFade * silence;

        // Tempo + effect
        col += ringCol * ringCore * a.tempoPulse * 0.06 * depthFade * silence;
        col += ringCol * ringGlow * a.effectInt * 0.05 * depthFade * silence;
        col += ringCol * ringCore * a.dynLight * 0.04 * depthFade * silence;

        // Burst
        if (a.burstTrig > 0.5) {
            col += hsv(a.hueCenter + 0.1, 0.4, 1.0) * ringCore * a.burstInt * 0.12 * depthFade * silence;
        }

        // Section flash
        if (a.shouldChg > 0.5) {
            col += hsv(a.hueCenter, 0.2, 1.0) * ringCore * 0.04 * depthFade * silence;
        }

        // Beam alignment
        if (a.beamActive > 0.5) {
            float beamAlign = abs(dot(ringNormal, float3(cos(a.hueCenter * PI * 2.0), 0, sin(a.hueCenter * PI * 2.0))));
            col += ringCol * ringCore * beamAlign * a.beam * 0.06 * depthFade * silence;
        }
    }

    // ── Intersection hotspots — energy filaments between ring pairs ──
    [unroll] for (int j = 0; j < 7; j++) {
        if (ringBright[j] < 0.01 || ringBright[j + 1] < 0.01) continue;
        float4 r0 = ringScreen[j];
        float4 r1 = ringScreen[j + 1];
        if (r0.z < 0.001 || r1.z < 0.001) continue;

        float2 mid = (r0.xy + r1.xy) * 0.5;
        float2 toP = p - mid;
        float hotspotDist = length(toP);

        float hotInt = (ringBright[j] + ringBright[j + 1]) * 0.5;
        float hotR = min(r0.z, r1.z) * 0.12;
        float hotGlow = exp(-hotspotDist * hotspotDist / (hotR * hotR));

        float3 hotCol = lerp(ringColors[j], ringColors[j + 1], 0.5);
        col += hotCol * hotGlow * hotInt * 0.1 * silence;
        col += hotCol * hotGlow * beatPulse * 0.06 * exp(-a.beatPhase * 4.0) * silence;
        col += float3(1.0, 0.8, 0.5) * hotGlow * kickSurge * 0.04 * flashScale * silence;

        // Energy filament — line between hotspot and center
        if (hotInt > 0.1) {
            float2 filDir = normalize(mid + 0.001);
            float filT = clamp(dot(p, filDir) / dot(filDir, filDir), 0.0, length(mid));
            float2 filClosest = filDir * filT;
            float filDist = length(p - filClosest);
            float filWidth = 0.003 + hotInt * 0.002;
            float filGlow = exp(-filDist * filDist / (filWidth * filWidth));
            col += hotCol * filGlow * hotInt * 0.03 * silence;
        }
    }

    // ── Central core — pulsing heart of the sphere ──
    float coreGlow = exp(-r * r * 100.0);
    float3 coreCol = lerp(float3(1.0, 0.4, 0.1), a.brainCol, 0.3);
    coreCol = lerp(coreCol, a.brainCol3, bassEnergy * 0.3);
    col += coreCol * coreGlow * (0.2 + bassEnergy * 0.4 + envelope * 0.15) * a.gated * silence;
    col += float3(1.0, 0.6, 0.3) * coreGlow * kickSurge * 0.1 * flashScale * silence;

    // ── Beat ring — expanding from sphere ──
    float beatRingDist = abs(r - sphereR - a.beatPhase * 0.3);
    col += a.brainCol * exp(-beatRingDist * beatRingDist * 50.0) * beatPulse * 0.025 * silence;

    // ── Kick shockwave ──
    if (kickSurge > 0.05) {
        float kickR = sphereR + a.beatPhase * 0.25;
        float kickDist = abs(r - kickR);
        col += a.brainCol * exp(-kickDist * kickDist * 40.0) * kickSurge * 0.04 * silence;
    }

    // ── Meteor trails — kick-driven radial streaks ──
    if (kickSurge > 0.01) {
        float meteorAng = ang;
        float meteorStreak = sin(meteorAng * 7.0 + Time * 20.0) * kickSurge * 0.02;
        col += float3(1.0, 0.6, 0.3) * abs(meteorStreak) * exp(-r * r * 0.2) * (1.0 - sphereMask) * silence;
    }

    // ── Phrase breathing ──
    col += a.brainCol * sin(a.phraseBeat * PI * 2.0) * 0.02 * a.gated * silence;

    // ── Ambient glow ──
    col += ambientGlow(r, a) * 0.4 * silence;
    col += a.brainCol3 * a.ambient * 0.03 * a.ambActive * exp(-r * r * 2.0) * silence;

    // ── THD noise ──
    if (thd > 0.02) {
        float thdStatic = sin(p.x * 40.0 + Time * 15.0) * thd * 0.008 * vrFlickerScale();
        thdStatic += sin(p.y * 35.0 - Time * 12.0) * thd * 0.006 * vrFlickerScale();
        col += a.brainCol3 * thdStatic * (1.0 - sphereMask) * silence;
    }

    // ── Motion persistence ──
    col *= (1.0 + a.motionPers * 0.05);

    // ── Dynamic range ──
    col *= (0.3 + a.gated * 0.7);

    // ── Standard overlays ──
    col += standardOverlays(p, r, a) * 0.012;

    // ── Dynamic HDR limiter ──
    col = hdrLimiter(col);

    col *= silence;

    return float4(col, 1.0);
}
