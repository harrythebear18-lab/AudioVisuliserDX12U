#version 460 core

// Scene: Spectrum Bars — high-fidelity frequency analyzer with 8-band brain.
// Uses the shared AudioBlock UBO (injected at compile time from audio_ubo.glsl).
//
// Features:
//   - 64 log-spaced spectrum bars sampled from the spectrum texture
//   - 8-band overlay bars driven by the UBO band levels
//   - Beat-reactive peak hold with gravity drop
//   - Brain-driven color gradient (HSV wheel per band)
//   - Kick drum radial pulse
//   - Reflection + glow + grid background

in vec2 v_uv;
out vec4 frag_color;

uniform float u_time;
uniform vec2 u_resolution;
uniform sampler2D u_spectrum;   // unit 0 — mono spectrum
uniform vec3 u_color;
uniform vec3 u_color2;
uniform int u_section;

#define PI 3.14159265359
#define NUM_BARS 256
#define NUM_BANDS 8

vec3 hsv2rgb(float h, float s, float v) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(h) + K.xyz) * 6.0 - K.www);
    return v * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), s);
}

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

// Smoothstep edge for bars
float barShape(float x, float center, float width) {
    float edge = width * 0.5;
    float d = abs(x - center);
    return smoothstep(edge, edge * 0.85, d);
}

void main() {
    vec2 uv = v_uv;
    vec2 p = (uv - 0.5) * 2.0;
    p.x *= u_resolution.x / u_resolution.y;

    // --- Background: dark gradient + grid ---
    vec3 bg = vec3(0.01, 0.01, 0.02);
    
    // Subtle grid
    vec2 grid = abs(fract(p * 8.0) - 0.5);
    float gridLine = smoothstep(0.48, 0.5, max(grid.x, grid.y));
    bg += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.3, 1.0) * gridLine * 0.03;

    // Horizon glow
    float horizonGlow = exp(-abs(p.y + 0.3) * 3.0) * (0.1 + OVERALL * 0.3);
    bg += hsv2rgb(BASE_HUE + SECTION_HUE_CTR, 0.5, 1.0) * horizonGlow;

    vec3 color = bg;

    // --- Main spectrum bars (256 bars from spectrum texture) ---
    float barAreaY = 0.7;  // bars occupy bottom 70% of screen
    float baselineY = -0.3;
    float barWidth = 1.8 / NUM_BARS;

    for (int i = 0; i < NUM_BARS; i++) {
        float fi = float(i);
        float t = fi / float(NUM_BARS - 1);
        
        // Linear frequency mapping — spectrum is already log-scaled in C#
        float specIdx = t;
        float specVal = texture(u_spectrum, vec2(specIdx, 0.5)).r;
        
        // Normalize and boost — spectrum already gain-staged in C#
        float barHeight = specVal * 2.5;
        barHeight = smoothstep(0.0, 1.5, barHeight) * 1.4;  // gentle peak rounding, preserves lows
        barHeight = clamp(barHeight, 0.0, 1.5);
        
        // Bar position — full width
        float barX = -0.9 + t * 1.8;
        float barTop = baselineY + barHeight * barAreaY;
        
        // Bar shape — thin bars with small gaps
        float barMask = barShape(p.x, barX, barWidth * 0.75);
        float yMask = smoothstep(baselineY, baselineY + 0.005, p.y) * 
                      (1.0 - smoothstep(barTop, barTop + 0.01, p.y));
        
        // Peak hold (simulated with time-based decay)
        float peakHold = barHeight * 1.1 + 0.01 + sin(u_time * 3.0 + fi * 0.5) * 0.003;
        float peakY = baselineY + peakHold * barAreaY;
        float peakMask = barShape(p.x, barX, barWidth * 0.75) *
                         smoothstep(peakY - 0.004, peakY, p.y) *
                         (1.0 - smoothstep(peakY, peakY + 0.004, p.y));
        
        // Color: hue varies across bars + brain hue
        float hue = BASE_HUE + SECTION_HUE_CTR + t * SECTION_HUE_RNG * 0.5;
        float sat = 0.7 + specVal * 0.3;
        float val = 0.3 + barHeight * 0.7;
        vec3 barColor = hsv2rgb(hue, sat, val);
        
        // Bar glow
        float glow = barMask * yMask;
        color += barColor * glow * 2.0;
        
        // Peak marker
        color += hsv2rgb(hue, 1.0, 1.0) * peakMask * 1.5;
        
        // Reflection below baseline
        float reflY = baselineY - (p.y - baselineY) * 0.5;
        if (p.y < baselineY && p.y > baselineY - barHeight * barAreaY * 0.4) {
            float reflMask = barShape(p.x, barX, barWidth * 0.8);
            float reflFade = 1.0 - abs(p.y - baselineY) / (barHeight * barAreaY * 0.4);
            color += barColor * reflMask * reflFade * 0.3;
        }
    }

    // --- 8-band overlay (brain band levels from UBO) ---
    float band[8];
    band[0] = BAND_SUB;
    band[1] = BAND_BASS;
    band[2] = BAND_LOW_MID;
    band[3] = BAND_MID;
    band[4] = BAND_HIGH_MID;
    band[5] = BAND_PRESENCE;
    band[6] = BAND_BRILLIANCE;
    band[7] = BAND_AIR;

    for (int i = 0; i < NUM_BANDS; i++) {
        float fi = float(i);
        float t = fi / float(NUM_BANDS - 1);
        
        float bandVal = band[i];
        float bandHeight = bandVal * 1.2;
        float bandX = -0.9 + t * 1.8;
        float bandTop = baselineY + bandHeight * barAreaY;
        
        // Wide translucent bars behind main bars
        float bandMask = barShape(p.x, bandX, 1.8 / NUM_BANDS);
        float bandYMask = smoothstep(baselineY, baselineY + 0.01, p.y) *
                          (1.0 - smoothstep(bandTop, bandTop + 0.03, p.y));
        
        float hue = BASE_HUE + SECTION_HUE_CTR + t * SECTION_HUE_RNG;
        vec3 bandColor = hsv2rgb(hue, 0.9, 1.0);
        
        color += bandColor * bandMask * bandYMask * 0.15;
        
        // Band label glow at top
        float topGlow = exp(-abs(p.y - bandTop) * 30.0) * bandMask;
        color += bandColor * topGlow * bandVal * 2.0;
    }

    // --- Kick drum radial pulse ---
    float kickPulse = exp(-length(p) * 2.0) * KICK_LEVEL * 0.5;
    color += u_color * kickPulse;

    // --- Beat flash on bars ---
    color += u_color * BEAT_INTENSITY * 0.05;

    // --- Vignette ---
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 0.8;
    color *= vig;

    // --- Top info area dim ---
    if (p.y > 0.5) {
        color *= smoothstep(0.7, 0.5, p.y);
    }

    frag_color = vec4(color, 1.0);
}
