using System;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Threading;

namespace StageSimWASAPI
{
    /// <summary>
    /// RDMA shared memory transport — zero-copy cross-process frame delivery.
    ///
    /// Writer (audio source) publishes VisualFrame + spectrum into a memory-mapped ring buffer.
    /// Reader (visualizer, Python, web UI, etc.) consumes the latest frame.
    ///
    /// This is the cross-process transport. For in-process, use QuadBufferedVisuals directly.
    /// Both share the same VisualFrame struct so consumers don't care which transport they're on.
    ///
    /// The memory map is named so any process on the machine can connect.
    /// No network, no kernel transitions, no serialization — just shared memory.
    /// </summary>
    public class RDMASharedTransport : IDisposable
    {
        public const string DefaultMapName = "RTXAudioVisualizer_RDMA";
        private const int HeaderSize = 64;
        private const int MaxFrames = 4;

        private readonly MemoryMappedFile _mmf;
        private readonly MemoryMappedViewAccessor _accessor;
        private readonly int _frameStructSize;
        private readonly int _spectrumBytes;
        private readonly int _frameTotalSize;
        private readonly long _totalSize;

        private bool _isWriter;
        private bool _disposed;

        public int FrameCount => MaxFrames;
        public int SpectrumBins => _spectrumBytes / sizeof(float);

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct RDMAHeader
        {
            public int WriteIndex;
            public int ReadIndex;
            public long FrameCount;
            public int FrameTotalSize;
            public int SpectrumBins;
            public int Padding1;
            public long Padding2;
            public long Padding3;
        }

        /// <summary>
        /// Create or connect to a shared memory transport.
        /// Writer creates the map; reader opens existing.
        /// </summary>
        public RDMASharedTransport(string mapName = DefaultMapName, int spectrumBins = 1024, bool writer = false)
        {
            _isWriter = writer;
            _spectrumBytes = spectrumBins * sizeof(float);
            _frameStructSize = Marshal.SizeOf<QuadBufferedVisuals.VisualFrame>();
            _frameTotalSize = _frameStructSize + _spectrumBytes;
            _totalSize = HeaderSize + (MaxFrames * _frameTotalSize);

            if (writer)
            {
                _mmf = MemoryMappedFile.CreateOrOpen(mapName, _totalSize, MemoryMappedFileAccess.ReadWrite);
            }
            else
            {
                _mmf = MemoryMappedFile.OpenExisting(mapName, MemoryMappedFileRights.ReadWrite);
            }

            _accessor = _mmf.CreateViewAccessor(0, _totalSize, MemoryMappedFileAccess.ReadWrite);

            if (writer)
            {
                var header = new RDMAHeader
                {
                    WriteIndex = 0,
                    ReadIndex = 0,
                    FrameCount = 0,
                    FrameTotalSize = _frameTotalSize,
                    SpectrumBins = spectrumBins
                };
                _accessor.Write(0, ref header);
            }
        }

        /// <summary>
        /// Create using a TransportConfig.
        /// </summary>
        public RDMASharedTransport(TransportConfig config, bool writer = false)
            : this(config.MapName, config.SpectrumBins, writer)
        {
        }

        /// <summary>
        /// Writer publishes a frame + spectrum into the ring buffer.
        /// </summary>
        public void PublishFrame(ref QuadBufferedVisuals.VisualFrame frame, float[] spectrum)
        {
            if (!_isWriter) throw new InvalidOperationException("Only writer can publish");

            int writeIdx = _accessor.ReadInt32(0);
            long frameOffset = HeaderSize + (writeIdx * _frameTotalSize);

            _accessor.Write(frameOffset, ref frame);

            long specOffset = frameOffset + _frameStructSize;
            int bins = Math.Min(spectrum.Length, SpectrumBins);
            _accessor.WriteArray(specOffset, spectrum, 0, bins);

            int nextIdx = (writeIdx + 1) % MaxFrames;
            _accessor.Write(0, nextIdx);

            long count = _accessor.ReadInt64(8);
            _accessor.Write(8, count + 1);

            int readIdx = _accessor.ReadInt32(4);
            if (readIdx == nextIdx)
            {
                _accessor.Write(4, (nextIdx + 1) % MaxFrames);
            }
        }

        /// <summary>
        /// Reader consumes the latest frame + spectrum.
        /// Returns false if no new data is available.
        /// </summary>
        public bool ConsumeFrame(out QuadBufferedVisuals.VisualFrame frame, float[] outSpectrum)
        {
            frame = default;
            if (_isWriter) throw new InvalidOperationException("Only reader can consume");

            int writeIdx = _accessor.ReadInt32(0);
            int readIdx = _accessor.ReadInt32(4);

            if (writeIdx == readIdx)
                return false;

            int latestIdx = (writeIdx - 1 + MaxFrames) % MaxFrames;
            long frameOffset = HeaderSize + (latestIdx * _frameTotalSize);

            _accessor.Read(frameOffset, out frame);

            if (outSpectrum != null)
            {
                long specOffset = frameOffset + _frameStructSize;
                int bins = Math.Min(outSpectrum.Length, SpectrumBins);
                _accessor.ReadArray(specOffset, outSpectrum, 0, bins);
            }

            _accessor.Write(4, writeIdx);
            return true;
        }

        /// <summary>
        /// Peek at the header without consuming — useful for diagnostics.
        /// </summary>
        public RDMAHeader PeekHeader()
        {
            _accessor.Read(0, out RDMAHeader header);
            return header;
        }

        public void Dispose()
        {
            if (!_disposed)
            {
                _accessor?.Dispose();
                _mmf?.Dispose();
                _disposed = true;
            }
        }
    }
}
