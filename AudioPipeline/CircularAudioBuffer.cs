using System;
using System.Threading;

namespace StageSimWASAPI
{
    public class CircularAudioBuffer
    {
        private readonly float[] _buffer;
        private int _writePos;
        private int _readPos;
        private readonly object _lock = new object();

        public CircularAudioBuffer(int capacity)
        {
            _buffer = new float[capacity];
            _writePos = 0;
            _readPos = 0;
        }

        public void Write(float[] data, int offset, int count)
        {
            lock (_lock)
            {
                for (int i = 0; i < count; i++)
                {
                    _buffer[_writePos] = data[offset + i];
                    _writePos = (_writePos + 1) % _buffer.Length;
                }
            }
        }

        public int Read(float[] data, int offset, int count)
        {
            lock (_lock)
            {
                int available = AvailableSamples();
                int toRead = Math.Min(count, available);
                for (int i = 0; i < toRead; i++)
                {
                    data[offset + i] = _buffer[_readPos];
                    _readPos = (_readPos + 1) % _buffer.Length;
                }
                return toRead;
            }
        }

        public int ReadLatest(float[] data, int offset, int count)
        {
            lock (_lock)
            {
                int available = AvailableSamples();
                if (available < count) return 0;

                // Advance read position to discard old data, keeping only latest 'count' samples
                int toSkip = available - count;
                _readPos = (_readPos + toSkip) % _buffer.Length;

                for (int i = 0; i < count; i++)
                {
                    data[offset + i] = _buffer[_readPos];
                    _readPos = (_readPos + 1) % _buffer.Length;
                }
                return count;
            }
        }

        private int AvailableSamples()
        {
            int diff = _writePos - _readPos;
            if (diff < 0) diff += _buffer.Length;
            return diff;
        }

        public void Reset()
        {
            lock (_lock)
            {
                _readPos = _writePos;
            }
        }
    }
}
