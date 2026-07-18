using System;
using System.Threading;

namespace StageSimWASAPI
{
    /// <summary>
    /// Abstraction boundary for the audio transport layer.
    ///
    /// Sources (below the boundary) produce audio frames.
    /// Consumers (above the boundary) consume them.
    /// Neither knows about the other — the transport is the only coupling point.
    ///
    /// Sources: WASAPI capture, ASIO, file playback, network stream, etc.
    /// Consumers: Visualizer, Python bridge, web UI, OSC bridge, recording, etc.
    ///
    /// The transport is zero-copy shared memory (RDMA) or in-process lock-free buffers.
    /// </summary>

    /// <summary>
    /// Something that produces audio frames into the transport.
    /// A source owns the capture/calculation pipeline and publishes frames.
    /// </summary>
    public interface IAudioSource : IDisposable
    {
        /// <summary>Start capturing/producing audio.</summary>
        bool Start();

        /// <summary>Stop capturing.</summary>
        void Stop();

        /// <summary>Whether the source is currently running.</summary>
        bool IsRunning { get; }

        /// <summary>Sample rate of the captured audio (Hz).</summary>
        int SampleRate { get; }

        /// <summary>FFT size used for spectrum analysis.</summary>
        int FFTSize { get; }
    }

    /// <summary>
    /// Something that consumes audio frames from the transport.
    /// A reader connects to shared memory or an in-process buffer and pulls frames.
    /// </summary>
    public interface ITransportConsumer : IDisposable
    {
        /// <summary>Connect to the transport (shared memory map or in-process buffer).</summary>
        bool Connect();

        /// <summary>Whether the consumer is connected and receiving data.</summary>
        bool IsConnected { get; }

        /// <summary>Try to consume the latest frame. Returns false if no new data.</summary>
        bool TryConsumeFrame(out QuadBufferedVisuals.VisualFrame frame, out float[] spectrum);
    }

    /// <summary>
    /// A transport channel — defines what kind of data flows through it.
    /// Multiple channels can share the same memory map or use separate ones.
    /// </summary>
    public enum TransportChannel
    {
        /// <summary>Primary audio analysis frame (spectrum, beat, energy, brain state).</summary>
        AudioFrame,

        /// <summary>Raw PCM audio samples (for recording, waveform display).</summary>
        RawPCM,

        /// <summary>Control messages (consumer → source: mode changes, parameter tweaks).</summary>
        Control,

        /// <summary>AI/analysis metadata (observations, suggestions, adaptive state).</summary>
        AIMetadata
    }

    /// <summary>
    /// Transport configuration — defines the memory map and buffer sizes.
    /// Passed to both sources and consumers so they agree on the format.
    /// </summary>
    public class TransportConfig
    {
        /// <summary>Name of the shared memory map.</summary>
        public string MapName { get; set; } = RDMASharedTransport.DefaultMapName;

        /// <summary>Number of spectrum bins per frame.</summary>
        public int SpectrumBins { get; set; } = 1024;

        /// <summary>Number of ring-buffer frames for the RDMA transport.</summary>
        public int RDMAFrameCount { get; set; } = 4;

        /// <summary>Number of quad-buffer slots for in-process transport.</summary>
        public int QuadBufferSlots { get; set; } = 4;

        /// <summary>Number of triple-buffer slots for FFT data.</summary>
        public int TripleBufferSlots { get; set; } = 3;

        /// <summary>
        /// Default config matching the existing pipeline.
        /// </summary>
        public static TransportConfig Default => new();
    }
}
