// GPU PARTICLE COMPUTE SHADER — 65536 particles simulated on GPU.
// Particles spawn from spectrum energy, explode on beats, flow with audio.
// Multiple spawn modes: spectrum bars, center burst, ring explosion.
// Forces: gravity, turbulence, attractors, audio-driven velocity.
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
    float2 pos;       // position in NDC (-1..1)
    float2 vel;       // velocity
    float  life;      // remaining life (seconds)
    float  maxLife;   // initial life
    float  size;      // particle size
    float  hue;       // color hue
    float  bandIdx;   // which frequency band (0..127)
    float  energy;    // spectrum energy at spawn
    float2 padding;   // align to 32 bytes
};

RWStructuredBuffer<Particle> Particles : register(u0);
RWByteAddressBuffer AliveCount : register(u1);

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

// Sample spectrum at a given band index
float sampleBand(uint bandIdx)
{
    float freq = 20.0 * pow(1200.0, float(bandIdx) / 128.0);
    float samplePos = saturate(freq / 24000.0);
    float specVal = u_spectrum.SampleLevel(u_sampler, float2(samplePos, 0.5), 0).r;
    return saturate(specVal * 0.25) * 0.9;
}

[numthreads(64, 1, 1)]
void CSMain(uint3 dtid : SV_DispatchThreadID, uint3 gtid : SV_GroupThreadID, uint3 gid : SV_GroupID)
{
    uint idx = dtid.x;
    if (idx >= MaxParticles) return;

    Particle p = Particles[idx];
    float dt = DeltaTime;
    float beat = Dynamics.x;
    float kick = Rhythm.z * Rhythm.w;
    float burst = VisualTriggers.x;
    float burstAge = VisualTriggers.z;
    float bpmFlow = Time * (Rhythm.x / 60.0) * 0.1 * Profile3.y;

    if (p.life <= 0 || p.life > 100.0 || isnan(p.life) || isinf(p.life))
    {
        // ── Respawn — pick spawn mode based on audio state ──
        float spawnRoll = hash12(float2(idx, FrameSeed));

        uint bandIdx = (FrameSeed + idx * 7919) % 128;
        float specVal = sampleBand(bandIdx);

        // Always spawn ambient particles even without audio
        bool forceSpawn = (spawnRoll < 0.4);  // 40% chance to spawn ambient

        // Boost spawn rate on beat
        float spawnThreshold = 0.02;
        if (beat > 0.3) spawnThreshold = 0.005;
        if (burst > 0.5) spawnThreshold = 0.001;

        if (specVal > spawnThreshold || forceSpawn || (kick > 0.3 && spawnRoll < 0.3) || (burst > 0.5 && spawnRoll < 0.4))
        {
            if (spawnRoll < 0.6 && specVal > spawnThreshold)
            {
                // ── Spectrum bar spawn ──
                float barArea = Aspect * 1.9;
                float barW = barArea / 128.0;
                float barCenter = (float(bandIdx) + 0.5) * barW - barArea * 0.5;

                p.pos = float2(barCenter, -0.9 + hash12(float2(idx * 7, FrameSeed)) * 0.1);
                // Launch upward with energy-based velocity
                p.vel = float2(
                    (hash12(float2(idx, FrameSeed)) - 0.5) * 0.3,
                    0.4 + specVal * 2.5 + hash12(float2(idx * 3, FrameSeed)) * 0.3
                );
                p.life = 2.0 + specVal * 4.0;
                p.maxLife = p.life;
                p.size = 0.003 + specVal * 0.015;
                p.hue = ColorHue.x + float(bandIdx) / 128.0 * ColorHue.z;
                p.bandIdx = float(bandIdx);
                p.energy = specVal;
            }
            else if (spawnRoll < 0.8 && kick > 0.2)
            {
                // ── Center burst — kick-driven explosion from center ──
                float angle = hash12(float2(idx * 2, FrameSeed)) * 6.283;
                float speed = 0.5 + kick * 2.0 + hash12(float2(idx * 5, FrameSeed)) * 0.5;
                p.pos = float2(0, 0);
                p.vel = float2(cos(angle) * speed, sin(angle) * speed);
                p.life = 1.5 + kick * 2.0;
                p.maxLife = p.life;
                p.size = 0.004 + kick * 0.02;
                p.hue = ColorHue.y + 0.05;
                p.bandIdx = 0;
                p.energy = kick;
            }
            else if (burst > 0.5)
            {
                // ── Ring explosion — effect burst ──
                float angle = hash12(float2(idx * 11, FrameSeed)) * 6.283;
                float ringR = 0.1 + burstAge * 0.3;
                float speed = 0.8 + burstAge * 1.5;
                p.pos = float2(cos(angle) * ringR, sin(angle) * ringR);
                p.vel = float2(cos(angle) * speed, sin(angle) * speed);
                p.life = 1.0 + burstAge * 2.0;
                p.maxLife = p.life;
                p.size = 0.005 + burstAge * 0.015;
                p.hue = ColorHue.y + 0.1 + hash12(float2(idx, FrameSeed)) * 0.1;
                p.bandIdx = float((uint)(hash12(float2(idx * 3, FrameSeed)) * 128));
                p.energy = 0.5 + burstAge * 0.5;
            }
            else
            {
                // Fallback — ambient drift particles (always visible even without audio)
                p.pos = float2(
                    (hash12(float2(idx, FrameSeed)) - 0.5) * Aspect * 1.8,
                    (hash12(float2(idx * 2, FrameSeed)) - 0.5) * 1.8
                );
                p.vel = float2(
                    (hash12(float2(idx * 3, FrameSeed)) - 0.5) * 0.15,
                    (hash12(float2(idx * 5, FrameSeed)) - 0.5) * 0.15
                );
                p.life = 4.0 + hash12(float2(idx * 7, FrameSeed)) * 3.0;
                p.maxLife = p.life;
                p.size = 0.008 + hash12(float2(idx * 9, FrameSeed)) * 0.01;
                p.hue = ColorHue.y + hash12(float2(idx * 11, FrameSeed)) * 0.15;
                p.bandIdx = float((uint)(hash12(float2(idx * 13, FrameSeed)) * 128));
                p.energy = 0.3 + hash12(float2(idx * 17, FrameSeed)) * 0.2;
            }
        }
        else
        {
            p.life = 0;
            p.energy = 0;
        }
    }
    else
    {
        // ── Update existing particle ──
        float lifeFrac = p.life / p.maxLife;

        // Gravity — pulls down, but weaker for high-energy particles
        p.vel.y -= (0.3 + (1.0 - p.energy) * 0.3) * dt;

        // Turbulence — audio-driven swirl
        float turbStrength = 0.05 + Dynamics.x * 0.15 + VisualIntensities2.y * 0.1;
        float turbAngle = Time * 1.5 + idx * 0.07 + p.pos.x * 3.0;
        p.vel.x += cos(turbAngle) * turbStrength * dt;
        p.vel.y += sin(turbAngle * 0.7) * turbStrength * 0.5 * dt;

        // Attractor — pull toward center on calm sections, push away on intense
        float2 toCenter = -p.pos;
        float centerDist = length(p.pos);
        if (SectionInfo.z > 0.3) {
            // Intense section — swirl around center
            float2 swirl = float2(-p.pos.y, p.pos.x) * 0.3 / max(centerDist, 0.1);
            p.vel += swirl * dt * SectionInfo.z;
        } else {
            // Calm section — gentle pull toward center
            p.vel += toCenter * 0.1 * dt * (1.0 - SectionInfo.z);
        }

        // Beat shockwave — push particles outward on beat
        if (beat > 0.3 && centerDist < 0.8) {
            float2 outward = p.pos / max(centerDist, 0.01);
            float shockForce = beat * (1.0 - centerDist / 0.8) * 1.5;
            p.vel += outward * shockForce * dt;
        }

        // Kick upward boost
        if (kick > 0.3 && p.pos.y < 0) {
            p.vel.y += kick * 0.5 * dt;
        }

        // Damping
        p.vel *= (1.0 - 0.5 * dt);

        // Update position
        p.pos += p.vel * dt;

        // Update life
        p.life -= dt;

        // Size fade — shrink as life decreases
        p.size *= (0.99 + 0.01 * lifeFrac);

        // Energy decay
        p.energy *= (1.0 - 0.3 * dt);
    }

    Particles[idx] = p;
}
