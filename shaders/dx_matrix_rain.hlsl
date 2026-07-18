// Mode 27: 3D Rain Particles — small defined falling streaks in depth layers
// Multiple parallax layers of rain particles, each with per-column speed variation
// Bass controls fall speed, highs control particle density, kick creates splash
#include "include/audio_cb.hlsl"
#include "include/color_utils.hlsl"
#include "include/noise.hlsl"
#include "include/sdf.hlsl"
#include "include/raymarch.hlsl"
#include "include/postfx.hlsl"
#include "include/audio_reactive.hlsl"
#include "include/layers.hlsl"

// Single rain particle as a vertical streak
// Returns brightness based on distance from streak center
float rainStreak(float2 uv, float2 streakPos, float streakLen, float streakWidth) {
    // Distance to the line segment (vertical streak)
    float2 d = uv - streakPos;
    // Vertical: streak extends downward from streakPos.y
    float vertDist = max(d.y, 0.0) - streakLen; // below the streak
    vertDist = max(vertDist, -min(d.y, 0.0));   // above the streak start
    float horizDist = abs(d.x);

    // Streak shape — thin vertical line with slight taper
    float dist = length(float2(horizDist, max(vertDist, 0.0)));
    float streak = exp(-dist * dist / (streakWidth * streakWidth));

    // Brighter at the top (leading edge) fading down
    float along = saturate(-d.y / streakLen);
    streak *= 0.3 + 0.7 * exp(-along * 2.0);

    return streak;
}

float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0) : SV_Target {
    AudioData a = extractAudio();
    float2 p = screenToAspect(uv);
    float r = length(p);

    float3 col = float3(0.002, 0.005, 0.012) * (1.0 - a.isSilent * 0.98);

    float t = Time * (1.0 + a.b0 * 5.0 + a.b1 * 2.5 + a.motSpeed * 0.5);
    float kickFlash = a.kick * a.kickConf;
    float transientBurst = a.transient;

    // Multiple depth layers — parallax rain
    [loop] for (int layer = 0; layer < 5; layer++) {
        float depth = 1.0 + layer * 1.5;
        float parallax = a.stereoBal * 0.02 * depth;
        float layerFade = 1.0 / (1.0 + layer * 0.35);

        // Grid for particle placement — denser for closer layers
        float density = 40.0 - layer * 5.0;
        float2 gridUV = (uv + parallax) * density;

        // Per-column properties
        float colId = floor(gridUV.x);
        float colSeed = hash11(colId + layer * 73.3);

        // Fall speed — bass drives speed hard, mids add variation
        float fallSpeed = (3.0 + colSeed * 4.0 + a.b0 * 4.0 + a.b1 * 2.0 + a.b2 * 1.0) * (1.0 - layer * 0.12);
        fallSpeed *= 1.0 + kickFlash * 2.0; // kick burst accelerates rain

        // Particle Y position — wraps around
        float partY = gridUV.y + t * fallSpeed + colSeed * 5.0;
        float cellY = floor(partY);
        float fracY = frac(partY);

        // Each column has one particle per cell
        float partSeed = hash11(colId * 31.7 + cellY * 13.3 + layer * 7.1);

        // Skip some particles — audio increases density (more particles when sound is active)
        float densityThreshold = 0.3 + a.b6 * 0.25 + a.b7 * 0.2 + a.b5 * 0.15 + transientBurst * 0.25 + a.b0 * 0.1;
        float skip = step(partSeed, densityThreshold); // 1 = show, 0 = skip

        // Particle position within the cell — slight x jitter
        float xJitter = (hash11(colId * 17.3 + cellY * 23.1) - 0.5) * 0.6;
        float2 streakPos = float2(xJitter, 1.0 - fracY); // top of streak

        // Streak length — bass/mids make longer streaks, kick makes them explode
        float streakLen = 0.15 + fallSpeed * 0.025 + a.b2 * 0.08 + a.b3 * 0.05 + a.b0 * 0.06 + kickFlash * 0.15;
        // Streak width — brightness and highs make thicker streaks
        float streakWidth = 0.012 + a.brightness * 0.006 + a.b4 * 0.008 + a.b6 * 0.005;

        // Render the streak
        float streak = rainStreak(float2(frac(gridUV.x), fracY), streakPos, streakLen, streakWidth) * skip;

        // Spectrum sampling — different freq per column
        float specU = saturate(colId / density * 0.5 + 0.3);
        float specVal = u_spectrum.SampleLevel(u_sampler, float2(specU, 0.5), 0).r;

        // Audio brightness — spectrum drives per-column intensity hard
        float bright = streak * (0.2 + specVal * 1.5 * a.barScale + a.brightness * 0.3) * layerFade;
        bright *= (1.0 - a.isSilent);

        // Kick: explosive flash on all particles
        bright += kickFlash * streak * 0.8 * layerFade * (1.0 - a.isSilent);
        // Transient: extra brightness pulse
        bright += transientBurst * streak * 0.4 * layerFade * (1.0 - a.isSilent);
        // Beat: subtle pulse
        bright += a.beat * streak * 0.2 * layerFade * (1.0 - a.isSilent);

        // Color — shifts with spectrum position, bass warms hue, highs cool it
        float hue = 0.5 + colSeed * 0.08 + a.section * 0.02 + specVal * 0.08 + a.b0 * 0.04 - a.b6 * 0.03;
        float3 partCol = hsv(hue, 0.5 * a.satur, bright);

        // Leading edge is brighter, slightly white — kick makes it explosive white
        float leadBoost = 0.15 + kickFlash * 0.5 + transientBurst * 0.2;
        partCol += float3(0.6, 0.8, 1.0) * streak * leadBoost * layerFade * (1.0 - a.isSilent);

        col = blendAdd(col, partCol);
    }

    // Ground splash — rain hits bottom and splashes, kick creates big splash
    float splashY = 1.0 - uv.y;
    if (splashY < 0.25) {
        // Splash rings from recent impacts
        [unroll] for (int s = 0; s < 6; s++) {
            float splashTime = floor(t * 2.0) - s * 0.5;
            float sage = frac(t * 2.0) + s * 0.25;
            float2 splashPos = float2(
                (hash11(splashTime * 1.7 + s * 2.3) - 0.5) * 0.8 + 0.5 + a.stereoBal * 0.05,
                0.95 - s * 0.02
            );
            float splashR = sage * (0.08 + a.b0 * 0.04 + kickFlash * 0.06);
            float splashRing = exp(-abs(length((uv - splashPos) * float2(1.0, 0.5)) - splashR) * 80.0);
            splashRing *= exp(-sage * 4.0) * (a.b0 * 0.4 + a.b1 * 0.2 + kickFlash * 0.8 + a.beat * 0.2);
            // Splash color shifts with audio
            float3 splashCol = lerp(float3(0.4, 0.7, 1.0), a.brainCol, 0.5);
            col += splashCol * splashRing * (1.0 - a.isSilent);
        }
    }

    // Kick: horizontal rain burst — streaks flash sideways on kick
    if (kickFlash > 0.05) {
        float burstAngle = Time * 1.7;
        float2 burstDir = float2(cos(burstAngle), sin(burstAngle * 0.3));
        float burstStreak = exp(-abs(dot(p, burstDir)) * 3.0) * exp(-r * 2.0);
        col += a.brainCol * burstStreak * kickFlash * 0.3 * (1.0 - a.isSilent);
    }

    // Bass: screen-wide subtle pulse
    col += a.brainCol * a.b0 * 0.02 * (1.0 - a.isSilent);

    // Atmospheric fog — depth haze
    col += float3(0.01, 0.02, 0.04) * (1.0 - uv.y) * 0.3 * (1.0 - a.isSilent);

    col += standardOverlays(p, r, a) * 0.2;

    float maxChannel = max(col.r, max(col.g, col.b));
    if (maxChannel > 1.2) col *= 1.2 / maxChannel;

    col = applyPostFX(col, uv, a);

    float centerDim = 0.7 + 0.3 * smoothstep(0.0, 0.6, r);
    col *= centerDim;

    return float4(col, 1.0);
}

