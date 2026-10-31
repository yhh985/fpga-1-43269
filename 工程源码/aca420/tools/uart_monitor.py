"""Display FPGA telemetry only; no host-side sound detection or processing."""
import argparse
import functools
import operator
import struct
import sys


def packets(buffer):
    """Yield validated packets while retaining partial bytes for the next read."""
    while len(buffer) >= 3:
        start = buffer.find(b"\xa5\x5a\x01")
        if start < 0:
            del buffer[:-2]
            return
        del buffer[:start]
        if len(buffer) < 16:
            return
        frame = bytes(buffer[:16])
        if functools.reduce(operator.xor, frame[:15], 0) != frame[15]:
            del buffer[0]
            continue
        del buffer[:16]
        yield (frame[3], frame[4], *struct.unpack("<5H", frame[5:15]))


def main():
    parser = argparse.ArgumentParser(description="ACA420 115200-baud telemetry viewer")
    parser.add_argument("--port", required=True, help="e.g. COM5")
    args = parser.parse_args()
    try:
        import serial
    except ImportError:
        sys.exit("Missing pyserial. Install with: python -m pip install pyserial")
    labels = ("configured", "config_error", "pll_locked", "pcm_alive", "clipped",
              "candidate_active", "calibrated", "monitor")
    buffer = bytearray()
    try:
        with serial.Serial(args.port, 115200, timeout=0.2) as port:
            print("Connected. Ctrl+C to stop.")
            while True:
                buffer.extend(port.read(max(1, port.in_waiting)))
                for seq, flags, count, peak, noise, threshold, samples in packets(buffer):
                    states = ",".join(name for bit, name in enumerate(labels) if flags & (1 << bit))
                    print(f"seq={seq:3} candidates={count:5} peak={peak:5} "
                          f"noise={noise:5} threshold={threshold:5} samples={samples:5} [{states}]")
    except KeyboardInterrupt:
        pass
    except serial.SerialException as exc:
        sys.exit(str(exc))


if __name__ == "__main__":
    main()
