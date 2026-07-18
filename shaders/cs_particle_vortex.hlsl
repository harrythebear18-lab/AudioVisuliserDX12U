// GPU PARTICLE COMPUTE SHADER — 3D Vortex.
// 65536 particles in 3D space forming a spiral galaxy/vortex.
// Audio drives rotation speed, spawn rate, expansion, color.
// Beats cause explosions. Kicks pulse the core. Calm = gentle drift.
cbuffer AudioCB : register(b0)
{
    float4 Bands; float4 Bands2; float4 Dynamics; float4 Rhythm;
    float4 Stereo; float4 ColorHue; float4 VisualIntensities;
    float4 VisualIntensities2; float4 VisualTriggers; float4 VisualActive;
    float4 Group; float4 SectionInfo;
    float4 Profile1; float4 Profile2; float4 Profile3;
};
cbuffer TimeCB : register(b1) { float Time; float Width; float Height; float Aspect; };
cbuffer ParticleCB : register(b2) { uint MaxParticles; float DeltaTime; uint FrameSeed; float Padding; };

Texture2D<float> u_spectrum : register(t0);
SamplerState u_sampler : register(s0);

struct Particle
{
    float4 pos;      // xyz position, w = size
    float4 vel;      // xyz velocity, w = energy
    float4 data;     // x = life, y = maxLife, z = hue, w = bandIdx
};

RWStructuredBuffer<Particle> Particles : register(u0);

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float sampleBand(uint bandIdx)
{
    float freq = 20.0 * pow(1200.0, float(bandIdx) / 128.0);
    float samplePos = saturate(freq / 24000.0);
    return u_spectrum.SampleLevel(u_sampler, float2(samplePos, 0.5), 0).r * 0.25;
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID)
{
    uint idx = dtid.x;
    if (idx >= MaxParticles) return;

    Particle p = Particles[idx];
    float dt = DeltaTime;
    float beat = Dynamics.x;
    float kick = Rhythm.z * Rhythm.w;
    float burst = VisualTriggers.x;
    float burstAge = VisualTriggers.z;
    float bass = (Bands.y + Bands.z) * 0.5;
    float mid = (Bands.w + Bands2.x) * 0.5;
    float treble = (Bands2.y + Bands2.w) * 0.5;

    // Vortex rotation speed — audio driven
    float rotSpeed = 0.3 + mid * 1.5 + beat * 2.0;

    if (p.data.x <= 0 || p.data.x > 100.0 || isnan(p.data.x) || isinf(p.data.x))
    {
        // ── Respawn as vortex particle ──
        float roll = hash12(float2(idx, FrameSeed));
        uint bandIdx = (FrameSeed + idx * 7919) % 128;
        float specVal = sampleBand(bandIdx);

        // Vortex arm — spiral galaxy with 2-3 arms
        float arm = (roll > 0.5) ? 0.0 : 2.094;  // 2 arms, 120deg apart
        float armOffset = arm + roll * 0.5;

        // Radius — denser at center, spread out. Audio expands.
        float radius = 0.1 + roll * (1.5 + bass * 0.8);
        // Spiral twist — tighter with treble
        float angle = armOffset + radius * (2.0 + treble * 3.0) + Time * rotSpeed * 0.3;

        // Vertical spread — thin disk with some thickness
        float height = (hash12(float2(idx * 3, FrameSeed)) - 0.5) * 0.15 * (1.0 + mid);

        p.pos = float4(
            cos(angle) * radius,
            height,
            sin(angle) * radius,
            0.004 + specVal * 0.02 + roll * 0.003
        );

        // Orbital velocity — tangent to circle
        float orbitSpeed = rotSpeed * (1.0 / max(radius, 0.1));
        p.vel = float4(
            -sin(angle) * orbitSpeed,
            (hash12(float2(idx * 5, FrameSeed)) - 0.5) * 0.05,
            cos(angle) * orbitSpeed,
            0.2 + specVal * 0.8
        );

        // Kick burst — particles launch outward from core
        if (kick > 0.3 && roll < 0.3) {
            float3 burstDir = normalize(p.pos.xyz + float3(0.01, 0.01, 0.01));
            p.vel.xyz += burstDir * kick * 3.0;
            p.pos.w = 0.008 + kick * 0.02;
        }

        // Effect burst — explosion
        if (burst > 0.5 && roll < 0.4) {
            float3 burstDir = normalize(float3(
                hash12(float2(idx * 7, FrameSeed)) - 0.5,
                hash12(float2(idx * 9, FrameSeed)) - 0.5,
                hash12(float2(idx * 11, FrameSeed)) - 0.5
            ));
            p.vel.xyz += burstDir * (1.5 + burstAge * 2.0);
            p.pos.w = 0.01 + burstAge * 0.02;
        }

        p.data = float4(
            3.0 + specVal * 4.0 + roll * 2.0,  // life
            3.0 + specVal * 4.0 + roll * 2.0,  // maxLife
            ColorHue.x + float(bandIdx) / 128.0 * ColorHue.z + roll * 0.05,  // hue
            float(bandIdx)  // bandIdx
        );
    }
    else
    {
        // ── Update existing particle ──
        float3 pos = p.pos.xyz;
        float3 vel = p.vel.xyz;
        float lifeFrac = p.data.x / p.data.y;
        float radius = length(pos.xz);

        // Vortex rotation — orbital motion
        float angle = atan2(pos.z, pos.x);
        float orbitSpeed = rotSpeed * (1.0 / max(radius, 0.15));
        vel.x += -sin(angle) * orbitSpeed * 0.5 * dt;
        vel.z += cos(angle) * orbitSpeed * 0.5 * dt;

        // Inward pull — keeps the vortex cohesive
        float3 toCenter = float3(-pos.x, 0, -pos.z);
        vel += toCenter * 0.15 * dt;

        // Vertical damping — keep disk shape
        vel.y *= (1.0 - 0.8 * dt);

        // Turbulence — audio-driven swirl
        float turb = 0.02 + beat * 0.1;
        vel.x += cos(Time * 2.0 + idx * 0.05) * turb * dt;
        vel.y += sin(Time * 1.7 + idx * 0.03) * turb * 0.3 * dt;
        vel.z += sin(Time * 1.3 + idx * 0.07) * turb * dt;

        // Beat shockwave — push outward radially
        if (beat > 0.3 && radius < 1.5) {
            float3 outward = float3(pos.x, 0, pos.z) / max(radius, 0.01);
            vel += outward * beat * (1.5 - radius) * 1.0 * dt;
        }

        // Kick — pulse core particles
        if (kick > 0.3 && radius < 0.5) {
            float3 outward = normalize(pos + float3(0.01, 0.01, 0.01));
            vel += outward * kick * 2.0 * dt;
        }

        // Damping
        vel *= (1.0 - 0.3 * dt);

        // Update position
        pos += vel * dt;

        // Update life and energy
        p.data.x -= dt;
        p.vel.w *= (1.0 - 0.2 * dt);  // energy decay

        // Size fade
        p.pos.w *= (0.995 + 0.005 * lifeFrac);

        p.pos = float4(pos, p.pos.w);
        p.vel = float4(vel, p.vel.w);
    }

    Particles[idx] = p;
}
