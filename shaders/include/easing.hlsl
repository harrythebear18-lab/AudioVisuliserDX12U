// Easing functions — smoothstep, exponential ease, audio-driven easing

float easeOutCubic(float t) {
    float p = 1.0 - t;
    return 1.0 - p * p * p;
}

float easeInCubic(float t) {
    return t * t * t;
}

float easeInOutCubic(float t) {
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) / 2.0;
}

float easeOutExpo(float t) {
    return t >= 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * t);
}

float easeInExpo(float t) {
    return t <= 0.0 ? 0.0 : pow(2.0, 10.0 * t - 10.0);
}

float easeOutBack(float t) {
    float c1 = 1.70158;
    float c3 = c1 + 1.0;
    return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0);
}

float easeOutElastic(float t) {
    float c4 = (2.0 * 3.14159) / 3.0;
    return t == 0.0 ? 0.0 : t == 1.0 ? 1.0 :
        pow(2.0, -10.0 * t) * sin((t * 10.0 - 0.75) * c4) + 1.0;
}

// Audio-driven easing — maps beat phase to smooth pulse
float beatEase(float time, float bpm, float tempoConf) {
    float period = bpm > 1.0 ? 60.0 / bpm : 0.5;
    float phase = bpm > 1.0 ? frac(time / period) : 0.0;
    return exp(-phase * 6.0) * tempoConf;
}

// Smoothstep with adjustable range
float smoothstepRange(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// Exponential decay — for transient-driven effects
float expDecay(float trigger, float time, float rate) {
    return trigger * exp(-frac(time * rate) * 8.0);
}

// Damped spring — for oscillating audio responses
float dampedSpring(float target, float current, float velocity, float stiffness, float damping) {
    float force = -stiffness * (current - target) - damping * velocity;
    return velocity + force;
}
