/// ADB addresses are configuration, not credentials: the host identity is held
/// in platform-private storage and never exported with this object.
class AdbCredential {
  const AdbCredential({
    this.host = '127.0.0.1',
    this.port = 0,
    this.localDevice = false,
    this.tls = true,
    this.deviceGuid,
  });

  final String host;
  final int port;
  final bool localDevice;
  final bool tls;
  final String? deviceGuid;

  factory AdbCredential.fromJson(Map<String, dynamic> json) => AdbCredential(
    host: json['host'] as String? ?? '127.0.0.1',
    port: (json['port'] as num?)?.toInt() ?? 0,
    localDevice: json['localDevice'] == true,
    tls: json['tls'] != false,
    deviceGuid: json['deviceGuid'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'host': host, 'port': port, 'localDevice': localDevice, 'tls': tls,
    if (deviceGuid != null) 'deviceGuid': deviceGuid,
  };

  bool get isValid => host.trim().isNotEmpty && port >= 0 && port <= 65535 &&
      (tls || port > 0) && (port > 0 || localDevice || deviceGuid != null);

  @override
  bool operator ==(Object other) => other is AdbCredential &&
      host == other.host && port == other.port && localDevice == other.localDevice &&
      tls == other.tls && deviceGuid == other.deviceGuid;
  @override
  int get hashCode => Object.hash(host, port, localDevice, tls, deviceGuid);
}
