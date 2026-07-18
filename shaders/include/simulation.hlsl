// Simulation utilities — feedback texture sampling and evolution helpers
// All modes can use these to create living simulations with frame-to-frame memory
#ifndef SIMULATION_INCLUDED
#define SIMULATION_INCLUDED

#include "audio_cb.hlsl"

// Sample previous frame at current pixel
float3 sampleFeedback(float2 uv) {
    return u_feedback.Sample(u_feedbackSampler, uv).rgb;
}

// Sample previous frame with offset
float3 sampleFeedbackOffset(float2 uv, float2 offset) {
    return u_feedback.Sample(u_feedbackSampler, uv + offset).rgb;
}

// Feedback decay — blend previous frame with new content
// decay = how much of the previous frame to keep (0=none, 1=full persistence)
float3 feedbackDecay(float2 uv, float decay) {
    float3 prev = sampleFeedback(uv);
    return prev * decay;
}

// Trail effect — blur previous frame slightly and decay
float3 feedbackTrail(float2 uv, float decay, float blurAmt) {
    float2 px = 1.0 / RenderResolution;
    float3 blur = float3(0,0,0);
    blur += sampleFeedbackOffset(uv, float2(blurAmt, 0) * px);
    blur += sampleFeedbackOffset(uv, float2(-blurAmt, 0) * px);
    blur += sampleFeedbackOffset(uv, float2(0, blurAmt) * px);
    blur += sampleFeedbackOffset(uv, float2(0, -blurAmt) * px);
    blur *= 0.25;
    return blur * decay;
}

// Ripple propagation — wave equation step on feedback
// Uses neighboring pixels to propagate waves at a speed
float3 feedbackRipple(float2 uv, float speed, float damping) {
    float2 px = 1.0 / RenderResolution;
    float3 center = sampleFeedback(uv);
    float3 n = sampleFeedbackOffset(uv, float2(0, speed) * px);
    float3 s = sampleFeedbackOffset(uv, float2(0, -speed) * px);
    float3 e = sampleFeedbackOffset(uv, float2(speed, 0) * px);
    float3 w = sampleFeedbackOffset(uv, float2(-speed, 0) * px);
    // Discrete wave equation: new = (n+s+e+w)/2 - center, then damp
    float3 wave = (n + s + e + w) * 0.5 - center;
    return wave * damping;
}

// Audio-driven impulse — inject energy at a position based on audio
float audioImpulse(float2 uv, float2 center, float radius, float audioLevel) {
    float d = length(uv - center);
    return exp(-d * d / (radius * radius)) * audioLevel;
}

// Radial wave from a point — for beat shockwaves that propagate over frames
float radialWave(float2 uv, float2 center, float time, float speed, float wavelength) {
    float d = length(uv - center);
    float phase = d - time * speed;
    return sin(phase * 6.2831853 / wavelength) * exp(-d * 0.5);
}

// Persistence glow — accumulate brightness from previous frame with decay
float3 persistenceGlow(float2 uv, float decayRate, float3 newLight) {
    float3 prev = sampleFeedback(uv);
    // Exponential decay toward new content
    return prev * decayRate + newLight * (1.0 - decayRate);
}

// Motion blur feedback — sample previous frame with directional offset
float3 motionFeedback(float2 uv, float2 velocity, float decay) {
    float3 prev = sampleFeedbackOffset(uv, velocity / RenderResolution);
    return prev * decay;
}

// Chromatic feedback — sample R, G, B channels with different offsets
float3 chromaticFeedback(float2 uv, float2 offsetR, float2 offsetG, float2 offsetB, float decay) {
    float2 px = 1.0 / RenderResolution;
    float r = u_feedback.Sample(u_feedbackSampler, uv + offsetR * px).r;
    float g = u_feedback.Sample(u_feedbackSampler, uv + offsetG * px).g;
    float b = u_feedback.Sample(u_feedbackSampler, uv + offsetB * px).b;
    return float3(r, g, b) * decay;
}

// Erosion — eat away at bright areas over time (dissolve effect)
float3 erodeFeedback(float2 uv, float threshold, float rate) {
    float3 prev = sampleFeedback(uv);
    float lum = dot(prev, float3(0.299, 0.587, 0.114));
    float mask = smoothstep(threshold, threshold + 0.1, lum);
    return prev * mask * (1.0 - rate);
}

// Simulation step helper — combines new content with feedback
// newContent: what the mode generates this frame
// feedbackWeight: how much previous frame to blend in (0=fresh, 1=persistent)
// blurAmount: how much to blur the feedback (0=sharp, 1=very blurry)
float3 simStep(float2 uv, float3 newContent, float feedbackWeight, float blurAmount) {
    if (feedbackWeight < 0.01) return newContent;
    float3 prev = feedbackTrail(uv, feedbackWeight, blurAmount);
    return lerp(newContent, prev, feedbackWeight);
}

#endif
