using System;
using System.Text.Json;
using System.Threading;
using StageSimWASAPI;

Console.WriteLine("RDMA Reader Bridge started");

var rdma = new RDMASharedTransport(RDMASharedTransport.DefaultMapName, 1024, writer: false);
Console.WriteLine("Connected to RDMA shared memory");

float[] spectrum = new float[1024];
var frame = new QuadBufferedVisuals.VisualFrame();
var jsonOpts = new JsonSerializerOptions { IncludeFields = true };

while (true)
{
    if (rdma.ConsumeFrame(out frame, spectrum))
    {
        var payload = new
        {
            time = frame.Time,
            width = frame.Width,
            height = frame.Height,
            aspect = frame.Aspect,
            bands = new float[] { frame.Band0, frame.Band1, frame.Band2, frame.Band3, frame.Band4, frame.Band5, frame.Band6, frame.Band7 },
            beatIntensity = frame.BeatIntensity,
            beatDetected = frame.BeatDetected,
            transient = frame.Transient,
            envelope = frame.Envelope,
            overall = frame.Overall,
            bpm = frame.BPM,
            tempoConfidence = frame.TempoConfidence,
            kickLevel = frame.KickLevel,
            kickConfidence = frame.KickConfidence,
            stereoBalance = frame.StereoBalance,
            stereoWidth = frame.StereoWidth,
            leftEnergy = frame.LeftEnergy,
            rightEnergy = frame.RightEnergy,
            effectIntensity = frame.EffectIntensity,
            movementIntensity = frame.MovementIntensity,
            brightness = frame.Brightness,
            beamIntensity = frame.BeamIntensity,
            bloomIntensity = frame.BloomIntensity,
            dynamicLightIntensity = frame.DynamicLightIntensity,
            ambientLightIntensity = frame.AmbientLightIntensity,
            dynamicLightsActive = frame.DynamicLightsActive,
            beamsActive = frame.BeamsActive,
            ambientActive = frame.AmbientActive,
            bloomActive = frame.BloomActive,
            triggerEffectBurst = frame.TriggerEffectBurst,
            effectBurstType = frame.EffectBurstType,
            effectBurstIntensity = frame.EffectBurstIntensity,
            atmosphereDensity = frame.AtmosphereDensity,
            colorPulse = frame.ColorPulse,
            shouldChangeEffectMode = frame.ShouldChangeEffectMode,
            baseHue = frame.BaseHue,
            sectionHueCenter = frame.SectionHueCenter,
            sectionHueRange = frame.SectionHueRange,
            colorR = frame.ColorR, colorG = frame.ColorG, colorB = frame.ColorB,
            color2R = frame.Color2R, color2G = frame.Color2G, color2B = frame.Color2B,
            beatCount = frame.BeatCount,
            phraseBeat = frame.PhraseBeat,
            sectionConfidence = frame.SectionConfidence,
            section = frame.Section,
            isSilent = frame.IsSilent,
            dominantBand = frame.DominantBand,
            groupBehaviorMode = frame.GroupBehaviorMode,
            groupBehaviorPhase = frame.GroupBehaviorPhase,
            desiredEffectMode = frame.DesiredEffectMode,
            spectrum = spectrum
        };

        string json = JsonSerializer.Serialize(payload, jsonOpts);
        Console.WriteLine(json);
    }
    else
    {
        Thread.Sleep(8); // ~120fps poll
    }
}
