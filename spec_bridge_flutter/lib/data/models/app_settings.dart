import 'package:equatable/equatable.dart';

enum JitsiMode {
  sdk,      // Native SDK with socket injection (higher quality)
  webview,  // WebView fallback with screen capture
}

class AppSettings extends Equatable {
  final JitsiMode jitsiMode;
  final String defaultServer;
  final String? displayName;

  const AppSettings({
    this.jitsiMode = JitsiMode.sdk,
    this.defaultServer = 'https://meet.jit.si',
    this.displayName,
  });

  AppSettings copyWith({
    JitsiMode? jitsiMode,
    String? defaultServer,
    String? displayName,
  }) {
    return AppSettings(
      jitsiMode: jitsiMode ?? this.jitsiMode,
      defaultServer: defaultServer ?? this.defaultServer,
      displayName: displayName ?? this.displayName,
    );
  }

  @override
  List<Object?> get props => [jitsiMode, defaultServer, displayName];
}
