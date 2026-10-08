import 'dart:io';

/// Hardware and OS Performance Telemetry for Android ARM devices.
///
/// Reads Linux `/proc` and `/sys` virtual files directly without requiring root:
/// - CPU frequencies for Big and Little core clusters (thermal throttling detection)
/// - Kernel thread context switches (voluntary vs involuntary/preempted)
/// - Process RSS, Peak HWM, and thread count
/// - System load average and thermal zone temperatures
class DeviceTelemetry {
  /// Little core (Cluster 0) frequency path
  static const String _cpu0FreqPath = '/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq';

  /// Big core (Cluster 1) frequency path
  static const String _cpu4FreqPath = '/sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq';

  /// Process status path
  static const String _procStatusPath = '/proc/self/status';

  /// System loadavg path
  static const String _loadAvgPath = '/proc/loadavg';

  /// Thermal zone temp path
  static const String _thermalPath = '/sys/class/thermal/thermal_zone0/temp';

  /// Captures an instantaneous snapshot of system and process health.
  static DeviceTelemetrySnapshot capture() {
    int littleFreqMhz = 0;
    int bigFreqMhz = 0;
    double tempC = 0.0;
    String loadAvg = 'N/A';

    int rssKb = 0;
    int peakKb = 0;
    int threads = 0;
    int volCtxtSwitches = 0;
    int nonvolCtxtSwitches = 0;

    // 1. CPU Frequencies
    try {
      final f0 = File(_cpu0FreqPath);
      if (f0.existsSync()) {
        final khz = int.tryParse(f0.readAsStringSync().trim()) ?? 0;
        littleFreqMhz = khz ~/ 1000;
      }
    } catch (_) {}

    try {
      final f4 = File(_cpu4FreqPath);
      if (f4.existsSync()) {
        final khz = int.tryParse(f4.readAsStringSync().trim()) ?? 0;
        bigFreqMhz = khz ~/ 1000;
      }
    } catch (_) {}

    // 2. Thermal
    try {
      final th = File(_thermalPath);
      if (th.existsSync()) {
        final raw = int.tryParse(th.readAsStringSync().trim()) ?? 0;
        tempC = raw > 1000 ? raw / 1000.0 : raw.toDouble();
      }
    } catch (_) {}

    // 3. Load Avg
    try {
      final la = File(_loadAvgPath);
      if (la.existsSync()) {
        final parts = la.readAsStringSync().trim().split(RegExp(r'\s+'));
        if (parts.isNotEmpty) {
          loadAvg = parts.take(3).join(', ');
        }
      }
    } catch (_) {}

    // 4. Process Status & Context Switches
    try {
      final st = File(_procStatusPath);
      if (st.existsSync()) {
        final content = st.readAsStringSync();
        for (final line in content.split('\n')) {
          if (line.startsWith('VmRSS:')) {
            rssKb = _extractKb(line);
          } else if (line.startsWith('VmHWM:')) {
            peakKb = _extractKb(line);
          } else if (line.startsWith('Threads:')) {
            threads = int.tryParse(line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '0') ?? 0;
          } else if (line.startsWith('voluntary_ctxt_switches:')) {
            volCtxtSwitches = int.tryParse(line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '0') ?? 0;
          } else if (line.startsWith('nonvoluntary_ctxt_switches:')) {
            nonvolCtxtSwitches = int.tryParse(line.split(RegExp(r'\s+')).elementAtOrNull(1) ?? '0') ?? 0;
          }
        }
      }
    } catch (_) {}

    return DeviceTelemetrySnapshot(
      timestamp: DateTime.now(),
      littleFreqMhz: littleFreqMhz,
      bigFreqMhz: bigFreqMhz,
      tempC: tempC,
      loadAvg: loadAvg,
      rssKb: rssKb,
      peakKb: peakKb,
      threads: threads,
      volCtxtSwitches: volCtxtSwitches,
      nonvolCtxtSwitches: nonvolCtxtSwitches,
    );
  }

  static int _extractKb(String line) {
    final match = RegExp(r':\s+(\d+)').firstMatch(line);
    return match != null ? (int.tryParse(match.group(1)!) ?? 0) : 0;
  }
}

/// An immutable point-in-time record of device performance.
class DeviceTelemetrySnapshot {
  final DateTime timestamp;
  final int littleFreqMhz;
  final int bigFreqMhz;
  final double tempC;
  final String loadAvg;
  final int rssKb;
  final int peakKb;
  final int threads;
  final int volCtxtSwitches;
  final int nonvolCtxtSwitches;

  DeviceTelemetrySnapshot({
    required this.timestamp,
    required this.littleFreqMhz,
    required this.bigFreqMhz,
    required this.tempC,
    required this.loadAvg,
    required this.rssKb,
    required this.peakKb,
    required this.threads,
    required this.volCtxtSwitches,
    required this.nonvolCtxtSwitches,
  });

  /// Formatted single-line performance string.
  String get formattedSummary {
    final ramRssMb = (rssKb / 1024).toStringAsFixed(1);
    final ramPeakMb = (peakKb / 1024).toStringAsFixed(1);
    final tempStr = tempC > 0 ? '${tempC.toStringAsFixed(1)}°C' : 'N/A';
    final cpuStr = 'Big=${bigFreqMhz}MHz / Little=${littleFreqMhz}MHz';
    return 'CPU: [$cpuStr] | Temp: $tempStr | Load: [$loadAvg] | '
        'Threads: $threads | RAM: ${ramRssMb}MB (Peak: ${ramPeakMb}MB) | '
        'CtxtSwitches: vol=$volCtxtSwitches, nonvol=$nonvolCtxtSwitches';
  }

  /// Calculates the delta between this snapshot and a subsequent one.
  TelemetryDelta diff(DeviceTelemetrySnapshot after) {
    return TelemetryDelta(
      durationMs: after.timestamp.difference(timestamp).inMilliseconds,
      deltaVolCtxtSwitches: after.volCtxtSwitches - volCtxtSwitches,
      deltaNonvolCtxtSwitches: after.nonvolCtxtSwitches - nonvolCtxtSwitches,
      deltaRssKb: after.rssKb - rssKb,
      startFreqMhz: bigFreqMhz,
      endFreqMhz: after.bigFreqMhz,
    );
  }
}

/// Difference metrics over an execution interval.
class TelemetryDelta {
  final int durationMs;
  final int deltaVolCtxtSwitches;
  final int deltaNonvolCtxtSwitches;
  final int deltaRssKb;
  final int startFreqMhz;
  final int endFreqMhz;

  TelemetryDelta({
    required this.durationMs,
    required this.deltaVolCtxtSwitches,
    required this.deltaNonvolCtxtSwitches,
    required this.deltaRssKb,
    required this.startFreqMhz,
    required this.endFreqMhz,
  });

  String get formattedSummary {
    final preemptionRate = durationMs > 0 ? (deltaNonvolCtxtSwitches * 1000 / durationMs).toStringAsFixed(1) : '0';
    return 'ΔTime: ${durationMs}ms | '
        'Involuntary Preemptions: $deltaNonvolCtxtSwitches ($preemptionRate/s) | '
        'Voluntary Yields: $deltaVolCtxtSwitches | '
        'Freq: ${startFreqMhz}MHz -> ${endFreqMhz}MHz';
  }
}
