import 'package:flutter_test/flutter_test.dart';
import 'package:server_box/core/adb/adb_screen.dart';

void main() {
  test('automatic screen quality keeps full quality for LAN addresses only', () {
    for (final host in ['192.168.1.20', '10.0.0.5', '172.20.3.4', '169.254.1.1', 'phone.local', 'fe80::1', '[fe80::1]']) {
      expect(AdbScreenQuality.auto.resolve(host), AdbScreenQuality.high, reason: host);
    }
    // Tailscale (CGNAT range, its IPv6 ULA, MagicDNS), other VPNs, public addresses, bare names.
    for (final host in ['100.101.102.103', 'fd7a:115c:a1e0::1234', 'pixel.tail1234.ts.net', 'pixel', '172.32.0.1', '8.8.8.8', '2001:db8::1']) {
      expect(AdbScreenQuality.auto.resolve(host), AdbScreenQuality.balanced, reason: host);
    }
  });

  test('a chosen quality is kept and presets step down to the saver floor', () {
    expect(AdbScreenQuality.smooth.resolve('192.168.1.20'), AdbScreenQuality.smooth);
    expect(AdbScreenQuality.high.lower, AdbScreenQuality.balanced);
    expect(AdbScreenQuality.balanced.lower, AdbScreenQuality.smooth);
    expect(AdbScreenQuality.smooth.lower, AdbScreenQuality.saver);
    expect(AdbScreenQuality.saver.lower, isNull);
  });
}
