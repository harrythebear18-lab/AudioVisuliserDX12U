// Mode: Spectrum Terrain — cinematic flyover with ridged noise mountains
// Multi-octave ridged noise creates realistic mountain ranges
// Spectrum drives elevation across X axis — left = bass mountains, right = treble ridges
// Water level with reflective surface, snow caps, atmospheric perspective fog
// Camera banks through turns, 96 raymarch steps, brain-colored, applyPostFX
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/postfx.hlsl"
#include "include/layers.hlsl"

// Ridged noise — creates sharp mountain ridges
float ridgedNoise(float2 p, int octaves) {
    float v = 0.0, a = 0.5;
    [unroll] for (int i = 0; i < 4; i++) {
        if (i >= octaves) break;
        float n = vnoise2(p);
        v += a * (1.0 - abs(n * 2.0 - 1.0)); // ridge: 1-|2n-1|
        p = p * 2.03 + 0.3;
        a *= 0.5;
    }
    return v;
}

float terrainHeight(float2 xz, AudioData a, float time) {
    // Map X to spectrum — left = low freq, right = high freq
    float xNorm = saturate((xz.x + 4.0) / 8.0);
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(xNorm, 0.5), 0).r;
    float specL = u_spectrum.SampleLevel(u_sampler, float2(xNorm, 0.0), 0).r;
    float specR = u_spectrum.SampleLevel(u_sampler, float2(xNorm, 1.0), 0).r;
    specVal = max(max(specVal, specL), specR);

    // Large-scale ridged mountains — spectrum-driven elevation
    float h = ridgedNoise(xz * 0.5, 4) * 0.8;
    h *= (0.4 + specVal * 0.8 * a.barScale);

    // Bass creates massive peaks
    h += ridgedNoise(xz * 0.3 + 100.0, 3) * a.profBass * 0.3;

    // Mid frequencies — rolling hills
    h += fbm2_4(xz * 1.2 + time * 0.05 * a.motSpeed) * 0.15;

    // Treble — fine surface detail
    h += ridgedNoise(xz * 4.0, 3) * a.profTreb * 0.05;

    // Beat — gentle elevation pulse
    h += a.beat * 0.04 * a.tempoConf * exp(-xz.y * xz.y * 0.05);

    // Kick — earthquake ripple
    float kd = length(xz);
    h += a.kick * 0.06 * a.kickConf * sin(kd * 4.0 - time * 6.0) * exp(-kd * 0.2);

    // Transient — surface crackles
    h += a.transient * 0.015 * sin(xz.x * 25.0 + xz.y * 20.0 + time * 10.0);

    return h;
}

float sceneSDF(float3 p, AudioData a, float time) {
    return p.y - terrainHeight(p.xz, a, time);
}

float3 calcNormal(float3 p, AudioData a, float time) {
    float eps = 0.02;
    return normalize(float3(
        sceneSDF(p + float3(eps,0,0), a, time) - sceneSDF(p - float3(eps,0,0), a, time),
        2.0 * eps,
        sceneSDF(p + float3(0,0,eps), a, time) - sceneSDF(p - float3(0,0,eps), a, time)
    ));
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    uv = 1.0 - uv;
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    // ── Sky — atmospheric gradient ──
    float skyFrac = uv.y;
    float3 skyTop = a.brainCol * 0.15 + float3(0.02, 0.03, 0.06);
    float3 skyBot = a.brainCol2 * 0.08 + float3(0.04, 0.03, 0.02);
    float3 col = lerp(skyBot, skyTop, pow(skyFrac, 0.6)) * (1.0 - a.isSilent * 0.98);
    col += starfield(uv, a) * 0.2;

    // Atmospheric haze
    float haze = fbm2_4(p * 0.8 + Time * 0.02 * a.motSpeed);
    col += a.brainCol * haze * 0.02 * a.ambient * a.ambActive * (1.0 - a.isSilent);

    // ── Camera — cinematic flyover with banking ──
    float camSpeed = 2.0 * a.motSpeed;
    float camZ = -Time * camSpeed;
    float bankAngle = sin(Time * 0.15 * a.motSpeed) * 0.1 + a.stereoBal * 0.15;
    float camY = 2.5 + a.energy * 0.5 + a.stereoDiff * 0.3;
    float3 camPos = float3(sin(Time * 0.1 * a.motSpeed) * 1.0 + a.stereoBal * 0.8, camY, camZ + 4.0);
    float3 camTarget = float3(a.stereoBal * 0.6, 0.0 + a.envelope * 0.2, camZ - 8.0);
    float3 fwd = normalize(camTarget - camPos);
    // Apply banking
    float3 right = normalize(cross(fwd, float3(0, 1, 0)));
    float3 up = cross(right, fwd);
    fwd = normalize(fwd + right * sin(bankAngle) * 0.3);
    right = normalize(cross(fwd, float3(0, 1, 0)));
    up = cross(right, fwd);
    float3 rd = normalize(fwd + p.x * right + p.y * up);

    // ── Raymarch terrain ──
    float t = 0.05;
    float marchGlow = 0.0;
    float steps = 0.0;
    bool hit = false;

    [loop] for (int i = 0; i < 96; i++) {
        float3 sp = camPos + rd * t;
        float d = sceneSDF(sp, a, Time);
        marchGlow += 0.006 / (1.0 + d * d * 40.0);
        steps += 1.0;
        if (d < 0.002) { hit = true; break; }
        t += d * 0.4;
        if (t > 50.0) break;
    }
    float ao = 1.0 - steps / 96.0 * 0.4;

    // Water level
    float waterLevel = -0.15 + a.profBass * 0.03;

    if (hit) {
        float3 hp = camPos + rd * t;
        float3 n = calcNormal(hp, a, Time);

        // Lighting — sun + fill + ambient
        float3 sunDir = normalize(float3(0.4, 0.7, 0.5));
        float3 fillDir = normalize(float3(-0.5 + a.stereoBal, 0.4, -0.3));
        float diff = max(dot(n, sunDir), 0.0);
        float diff2 = max(dot(n, fillDir), 0.0) * 0.35;
        float spec = pow(max(dot(reflect(-sunDir, n), -rd), 0.0), 128.0);
        float fres = pow(1.0 - max(dot(n, -rd), 0.0), 4.0);

        // Height-based surface coloring
        float xNorm = saturate((hp.x + 4.0) / 8.0);
        float specAtPoint = u_spectrum.SampleLevel(u_sampler, float2(xNorm, 0.5), 0).r;
        float heightNorm = saturate(hp.y * 1.2);

        // Five-layer surface: water, beach, valley, slope, peak, snow
        float3 waterCol = a.brainCol * 0.1 + float3(0.01, 0.02, 0.04);
        float3 beachCol = lerp(a.brainCol, float3(0.3, 0.25, 0.15), 0.5) * 0.4;
        float3 valleyCol = a.brainCol * 0.2;
        float3 slopeCol = lerp(a.brainCol, a.brainCol2, xNorm) * 0.45;
        float3 peakCol = lerp(a.brainCol2, float3(0.6, 0.6, 0.7), 0.3) * 0.7;

        float3 baseCol;
        if (hp.y < waterLevel + 0.02) {
            baseCol = waterCol;
        } else if (hp.y < waterLevel + 0.08) {
            baseCol = lerp(waterCol, beachCol, smoothstep(waterLevel, waterLevel + 0.08, hp.y));
        } else {
            baseCol = lerp(valleyCol, slopeCol, smoothstep(0.0, 0.2, heightNorm));
            baseCol = lerp(baseCol, peakCol, smoothstep(0.2, 0.45, heightNorm));
        }

        // Snow caps
        float snow = smoothstep(0.35, 0.5, hp.y) * smoothstep(0.5, 0.3, 1.0 - n.y);
        baseCol = lerp(baseCol, float3(0.65, 0.7, 0.78), snow * 0.5);

        // Spectrum tinting
        float hue = a.hueBase + xNorm * a.hueRange;
        baseCol = lerp(baseCol, hsv(hue, 0.4 * a.satur, 0.5), 0.2);

        // Rock exposure on steep faces
        float rock = smoothstep(0.6, 0.9, 1.0 - n.y);
        baseCol = lerp(baseCol, a.brainCol * 0.15, rock * 0.4);

        float3 litCol = baseCol * (diff + diff2) * (0.4 + a.brightness * 0.5);
        litCol += float3(1.0, 0.95, 0.85) * spec * 0.15 * a.dynLight * a.dynActive;
        litCol += a.brainCol2 * fres * (0.1 + specAtPoint * 0.15);

        // Beat emission
        float beatEmit = a.beat * 0.04 * a.tempoConf * specAtPoint;
        litCol += hsv(a.hueCenter, 0.4, beatEmit) * (1.0 - a.isSilent);

        // Kick flash
        float kickFlash = a.kick * 0.04 * a.kickConf * exp(-hp.y * 2.0);
        litCol += a.brainCol2 * kickFlash * (1.0 - a.isSilent);

        litCol *= ao * (0.35 + a.ambient * 0.65) * a.ambActive;

        // Atmospheric perspective — distant terrain fades to sky
        float fogDist = t / 35.0;
        float3 fogCol = lerp(skyBot, skyTop, 0.4);
        litCol = lerp(litCol, fogCol, smoothstep(0.2, 1.0, fogDist) * 0.85);

        col = litCol * (1.0 - a.isSilent * 0.98);
    } else {
        // Sky haze
        col += a.brainCol2 * haze * 0.025 * a.ambient * a.ambActive * (1.0 - a.isSilent);
    }

    // ── Foreground overlays ──
    col += standardOverlays(p, r, a) * 0.025;

    // ── Post-processing ──
    // ── Brightness limiter — prevent bloom blowout ──
    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);
    return float4(col, 1.0);
}
