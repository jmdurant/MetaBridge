import 'package:equatable/equatable.dart';

enum JitsiMode {
  sdk,          // Native SDK with overlay + screen capture
  libJitsiMeet, // lib-jitsi-meet in WebView with direct frame injection
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
