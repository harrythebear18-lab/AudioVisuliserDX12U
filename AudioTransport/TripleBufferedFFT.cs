using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace StageSimWASAPI
{
    /// <summary>
    /// Lock-free triple buffer for FFT data with event signaling.
    ///
    /// Three slots: Writer fills one, CPU reads the latest, third is ready for next write.
    /// Data is flagged for overwrite as soon as CPU consumes it — no stale reads.
    /// Writer signals via ManualResetEventSlim so consumer never polls — zero dwell time.
    ///
    /// Flow: WASAPI → [Slot A/B/C] → CPU brain consumes latest → slot marked dirty → writer reuses
    /// </summary>
    public class TripleBufferedFFT
    {
        private readonly float[][] _slots;       // 3 FFT buffers
        private readonly int[] _flags;           // 0=empty, 1=written, 2=reading, 3=dirty(consumed)
        private int _writeSlot;                  // next slot to write
        private int _latestSlot;                 // slot with most recent data (-1 if none)
        private readonly int _size;
        private readonly ManualResetEventSlim _dataReady = new ManualResetEventSlim(false, 0);
        private readonly GCHandle[] _pins;       // pinned handles for each slot

        public TripleBufferedFFT(int fftSize)
        {
            _size = fftSize;
            _slots = new float[3][];
            _flags = new int[3];
            _pins = new GCHandle[3];
            for (int i = 0; i < 3; i++)
            {
                _slots[i] = new float[fftSize];
                _pins[i] = GCHandle.Alloc(_slots[i], GCHandleType.Pinned); // pin for direct pointer access
                _flags[i] = 0; // empty
            }
            _writeSlot = 0;
            _latestSlot = -1;
        }

        /// <summary>
        /// Event that signals when new FFT data is published. Consumer waits on this.
        /// </summary>
        public WaitHandle DataReady => _dataReady.WaitHandle;

        /// <summary>
        /// Check if new data is available without consuming.
        /// </summary>
        public bool HasData => Interlocked.CompareExchange(ref _latestSlot, -1, -1) >= 0;

        /// <summary>
        /// Writer (WASAPI capture thread) publishes new FFT data.
        /// Finds an empty or dirty slot, fills it, marks as written.
        /// </summary>
        public void Publish(float[] fftData, int length)
        {
            int len = Math.Min(length, _size);

            // Try to find a slot that's empty or dirty (consumed)
            for (int attempt = 0; attempt < 3; attempt++)
            {
                int slot = (_writeSlot + attempt) % 3;
                int flag = Interlocked.CompareExchange(ref _flags[slot], 2, 0); // try to claim empty slot
                if (flag == 0)
                {
                    Array.Copy(fftData, _slots[slot], len);
                    Interlocked.Exchange(ref _flags[slot], 1); // mark as written
                    Interlocked.Exchange(ref _latestSlot, slot);
                    _writeSlot = (slot + 1) % 3;
                    _dataReady.Set(); // signal consumer immediately
                    return;
                }

                flag = Interlocked.CompareExchange(ref _flags[slot], 2, 3); // try to claim dirty slot
                if (flag == 3)
                {
                    Array.Copy(fftData, _slots[slot], len);
                    Interlocked.Exchange(ref _flags[slot], 1); // mark as written
                    Interlocked.Exchange(ref _latestSlot, slot);
                    _writeSlot = (slot + 1) % 3;
                    _dataReady.Set(); // signal consumer immediately
                    return;
                }
            }

            // All slots busy — overwrite oldest written slot
            int overwrite = _writeSlot;
            Interlocked.Exchange(ref _flags[overwrite], 2); // force claim
            Array.Copy(fftData, _slots[overwrite], len);
            Interlocked.Exchange(ref _flags[overwrite], 1);
            Interlocked.Exchange(ref _latestSlot, overwrite);
            _writeSlot = (overwrite + 1) % 3;
            _dataReady.Set(); // signal consumer immediately
        }

        /// <summary>
        /// CPU (brain) consumes the latest FFT data.
        /// Returns true if new data was available, copies into output buffer.
        /// Immediately marks the slot as dirty (ready for overwrite).
        /// </summary>
        public bool Consume(float[] output, int length)
        {
            int slot = Interlocked.Exchange(ref _latestSlot, -1);
            if (slot < 0) { _dataReady.Reset(); return false; }

            int flag = Interlocked.CompareExchange(ref _flags[slot], 2, 1); // claim for reading
            if (flag != 1) { _dataReady.Reset(); return false; }

            int len = Math.Min(length, _size);
            Array.Copy(_slots[slot], output, len);
            Interlocked.Exchange(ref _flags[slot], 3); // mark dirty — ready for overwrite
            _dataReady.Reset(); // consume the signal

            return true;
        }

        /// <summary>
        /// Wait for new data to be published. Returns false on timeout.
        /// </summary>
        public bool WaitForData(int timeoutMs = 100)
        {
            return _dataReady.Wait(timeoutMs);
        }

        public int Size => _size;

        ~TripleBufferedFFT()
        {
            for (int i = 0; i < _pins.Length; i++)
            {
                if (_pins[i].IsAllocated) _pins[i].Free();
            }
        }
    }
}
