// VORTEX PARTICLES — compute-driven audio-reactive particle simulation.
// Each particle is a point in 3D space driven by vortex forces, turbulence,
// and audio features. Designed to push DX11/DX12 compute queues on RTX hardware.

// Particle data layout matches the render shader.
struct Particle {
    float3 position;
    float  life;      // 0..1
    float3 velocity;
    float  heat;      // color/brightness
    float2 extra;     // size, seed
};

RWStructuredBuffer<Particle> Particles : register(u0);

#define TAU 6.28318530718

// Audio CB
struct AudioCB {
    float4 Bands; float4 Bands2; float4 Dynamics; float4 Rhythm;
    float4 Stereo; float4 ColorHue; float4 VisualIntensities;
    float4 VisualIntensities2; float4 VisualTriggers; float4 VisualActive;
    float4 Group; float4 SectionInfo;
};

ConstantBuffer<AudioCB> Audio : register(b0);

cbuffer TimeCB : register(b1) {
    float Time;
    float Width;
    float Height;
    float Aspect;
};

// Hash functions
uint hash(uint x) {
    x += (x << 10u);
    x ^= (x >> 6u);
    x += (x << 3u);
    x ^= (x >> 11u);
    x += (x << 15u);
    return x;
}
float hashf(uint x) { return float(hash(x)) / 4294967295.0; }
float noise(float3 p) {
    return frac(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453);
}

[numthreads(256, 1, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    uint idx = id.x;
    uint count = 0;
    Particles.GetDimensions(count, uint(0));
    if (idx >= count) return;

    Particle p = Particles[idx];

    float bass = Audio.Bands.y;
    float mid = Audio.Bands.z + Audio.Bands.w;
    float high = Audio.Bands2.x + Audio.Bands2.y;
    float sub = Audio.Bands.x;
    float beat = Audio.Dynamics.x;
    float transient = Audio.Dynamics.y;
    float kick = Audio.Rhythm.z;
    float stereoBal = Audio.Stereo.x;
    float stereoWid = Audio.Stereo.y;
    float movement = Audio.Stereo.w;
    float bloom = Audio.VisualIntensities.z;
    float baseHue = Audio.ColorHue.x;
    float section = Audio.SectionInfo.x;
    float anticipation = Audio.SectionInfo.z;

    float t = Time * (0.5 + movement * 1.5);
    float dt = 1.0 / 60.0;

    // Vortex count driven by bass
    float vortexCount = 2.0 + floor(bass * 5.0);
    float3 force = 0.0;

    for (float v = 0.0; v < vortexCount; v += 1.0) {
        float angle = (v / vortexCount) * TAU + t * (0.15 + v * 0.08);
        float radius = 2.0 + v * 1.8 + bass * 2.5;
        float3 center = float3(cos(angle) * radius, sin(angle) * radius * 0.6, 0.0);
        float3 toCenter = center - p.position;
        float dist = length(toCenter);

        // Tangential swirl
        float3 axis = normalize(float3(0.0, 0.0, 1.0) + stereoBal * 0.3);
        float3 tangent = normalize(cross(normalize(toCenter + 0.001), axis));
        float swirl = (0.6 + bass * 2.0 + beat * 3.0 + kick * 4.0) / max(dist * 0.45, 0.35);
        force += tangent * swirl;

        // Inward suction
        force += normalize(toCenter) * (0.25 + mid * 1.2) * (1.0 - smoothstep(0.0, 10.0, dist));

        // Vertical lift from treble
        force.z += (high + Audio.Bands2.w) * 0.35 * exp(-dist * 0.25);
    }

    // Central attractor/repulsor
    float3 centerForce = -normalize(p.position) * (0.15 + transient * 7.0 + beat * 1.5 + anticipation * 2.0)
                         / (length(p.position) + 0.5);
    force += centerForce;

    // Curl-noise-ish turbulence
    float3 turb = float3(
        noise(p.position * 0.6 + t * 0.25),
        noise(p.position * 0.6 + t * 0.25 + 100.0),
        noise(p.position * 0.6 + t * 0.25 + 200.0)
    );
    force += (turb - 0.5) * (0.5 + high * 2.0 + Audio.VisualIntensities2.w) * 2.5;

    // Apply
    p.velocity += force * dt * 3.0;
    p.velocity *= 0.985; // damping
    p.position += p.velocity * dt * (1.0 + beat * 0.5);

    // Heat builds with beat/transient
    p.heat += (beat * 0.4 + transient * 0.8 + kick * 0.5) * dt * 5.0;
    p.heat = clamp(p.heat, 0.0, 1.0);
    p.heat *= 0.97;

    // Life decay
    p.life -= dt * (0.08 + 0.15 * (1.0 - Audio.VisualIntensities.x * 0.3));

    // Respawn
    if (p.life <= 0.0) {
        p.life = 0.7 + hashf(idx * 12345u) * 0.6;
        float spawnAngle = hashf(idx) * TAU + t * 0.1;
        float spawnRadius = 0.4 + bass * 2.0 + hashf(idx * 7u) * 3.5;
        p.position = float3(
            cos(spawnAngle) * spawnRadius,
            sin(spawnAngle) * spawnRadius * 0.6,
            (hashf(idx * 13u) - 0.5) * 8.0
        );
        p.velocity = 0.0;
        p.extra.x = 0.5 + hashf(idx * 19u) + bass * 1.5;
        p.heat = 0.0;
    }

    Particles[idx] = p;
}
