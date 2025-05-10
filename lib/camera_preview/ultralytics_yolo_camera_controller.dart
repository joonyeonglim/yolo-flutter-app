import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo_platform_interface.dart';

/// The state of the camera
class UltralyticsYoloCameraValue {
  /// Constructor to create an instance of [UltralyticsYoloCameraValue]
  UltralyticsYoloCameraValue({
    required this.lensDirection,
    required this.strokeWidth,
    required this.zoomRatio,
    this.frameRate = 30,
    this.isSlowMotionEnabled = false,
  });

  /// The direction of the camera lens
  final int lensDirection;

  /// The width of the stroke used to draw the bounding boxes
  final double strokeWidth;
  
  /// The current zoom ratio
  final double zoomRatio;
  
  /// The current frame rate (FPS)
  final int frameRate;
  
  /// Whether slow motion is enabled
  final bool isSlowMotionEnabled;

  /// Creates a copy of this [UltralyticsYoloCameraValue] but with
  /// the given fields
  UltralyticsYoloCameraValue copyWith({
    int? lensDirection,
    double? strokeWidth,
    double? zoomRatio,
    int? frameRate,
    bool? isSlowMotionEnabled,
  }) =>
      UltralyticsYoloCameraValue(
        lensDirection: lensDirection ?? this.lensDirection,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        zoomRatio: zoomRatio ?? this.zoomRatio,
        frameRate: frameRate ?? this.frameRate,
        isSlowMotionEnabled: isSlowMotionEnabled ?? this.isSlowMotionEnabled,
      );
}

/// ValueNotifier that holds the state of the camera
class UltralyticsYoloCameraController
    extends ValueNotifier<UltralyticsYoloCameraValue> {
  /// Constructor to create an instance of [UltralyticsYoloCameraController]
  UltralyticsYoloCameraController()
      : super(
          UltralyticsYoloCameraValue(
            lensDirection: 1,
            strokeWidth: 2.5,
            zoomRatio: 1.0,
            frameRate: 30,
            isSlowMotionEnabled: false,
          ),
        );

  final _ultralyticsYoloPlatform = UltralyticsYoloPlatform.instance;

  /// Toggles the direction of the camera lens
  Future<void> toggleLensDirection() async {
    try {
      // Update state first to show loading state if needed
      final newLensDirection = value.lensDirection == 0 ? 1 : 0;
      value = value.copyWith(lensDirection: newLensDirection);
      
      // Request camera switch
      final result = await _ultralyticsYoloPlatform.setLensDirection(newLensDirection);
      
      if (result != "Success") {
        // Revert state if failed
        value = value.copyWith(lensDirection: value.lensDirection == 0 ? 1 : 0);
        throw Exception("Failed to switch camera: $result");
      }
    } catch (e) {
      // Handle errors and revert state
      value = value.copyWith(lensDirection: value.lensDirection == 0 ? 1 : 0);
      rethrow;
    }
  }

  /// Sets the width of the stroke used to draw the bounding boxes
  void setStrokeWidth(double strokeWidth) {
    value = value.copyWith(strokeWidth: strokeWidth);
  }
  
  /// Sets the zoom ratio for the camera
  Future<void> setZoomRatio(double zoomRatio) async {
    if (zoomRatio < 1.0 || zoomRatio > 5.0) {
      throw ArgumentError('Zoom ratio must be between 1.0 and 5.0');
    }
    
    try {
      // Update state first
      value = value.copyWith(zoomRatio: zoomRatio);
      
      // Apply zoom through platform channel
      final result = await _ultralyticsYoloPlatform.setZoomRatio(zoomRatio);
      
      if (result != "Success") {
        // Revert state if failed
        value = value.copyWith(zoomRatio: value.zoomRatio);
        throw Exception("Failed to set zoom ratio: $result");
      }
    } catch (e) {
      // Revert state if error occurs
      rethrow;
    }
  }
  
  /// Resets the zoom ratio to 1.0
  Future<void> resetZoom() async {
    return setZoomRatio(1.0);
  }

  /// Get the supported frame rates for the current camera
  Future<Map<String, bool>> getSupportedFrameRates() async {
    return await _ultralyticsYoloPlatform.getSupportedFrameRates();
  }
  
  /// Set the frame rate (FPS) for the camera
  Future<void> setFrameRate(int fps) async {
    if (fps < 30 || fps > 120 || fps % 30 != 0) {
      throw ArgumentError('Frame rate must be 30, 60, 90, or 120');
    }
    
    try {
      // 먼저 지원하는 FPS 확인
      final supportedRates = await getSupportedFrameRates();
      final fpsKey = '${fps}fps';
      
      // 요청한 FPS가 지원되지 않는 경우 경고 로그 출력
      if (supportedRates[fpsKey] == false) {
        print('⚠️ Warning: $fps FPS is not directly supported by this device.');
        print('The camera will use the closest supported FPS or switch formats if possible.');
      }
      
      // Update state first
      value = value.copyWith(frameRate: fps);
      
      // Apply frame rate through platform channel
      final result = await _ultralyticsYoloPlatform.setFrameRate(fps);
      
      if (result != "Success") {
        // Revert state if failed
        value = value.copyWith(frameRate: value.frameRate);
        throw Exception("Failed to set frame rate: $result");
      }
    } catch (e) {
      // 상태를 원래대로 되돌림
      print('Error setting frame rate: $e');
      rethrow;
    }
  }

  /// Check if slow motion recording is supported on the current device
  Future<bool> isSlowMotionSupported() async {
    return await _ultralyticsYoloPlatform.isSlowMotionSupported();
  }
  
  /// Get the maximum supported frame rate for slow motion on the current device
  Future<int> getMaxSlowMotionFrameRate() async {
    return await _ultralyticsYoloPlatform.getMaxSlowMotionFrameRate();
  }
  
  /// Toggle between normal recording and slow motion recording
  Future<void> toggleSlowMotion() async {
    final isCurrentlyEnabled = value.isSlowMotionEnabled;
    return enableSlowMotion(!isCurrentlyEnabled);
  }
  
  /// Enable or disable slow motion recording
  Future<void> enableSlowMotion(bool enable) async {
    // 현재 상태와 같으면 아무 작업도 하지 않음
    if (value.isSlowMotionEnabled == enable) {
      return;
    }
    
    try {
      // 먼저 슬로우 모션이 지원되는지 확인
      if (enable && !(await isSlowMotionSupported())) {
        throw UnsupportedError('Slow motion is not supported on this device');
      }
      
      // 상태 업데이트
      value = value.copyWith(isSlowMotionEnabled: enable);
      
      // 슬로우 모션 모드 변경
      final result = await _ultralyticsYoloPlatform.enableSlowMotion(enable);
      
      if (result != "Success") {
        // 실패한 경우 상태 되돌리기
        value = value.copyWith(isSlowMotionEnabled: !enable);
        throw Exception("Failed to ${enable ? 'enable' : 'disable'} slow motion: $result");
      }
      
      // 성공한 경우 프레임레이트 업데이트
      if (enable) {
        // 슬로우 모션이 활성화된 경우 최대 프레임레이트 가져오기
        final maxFps = await getMaxSlowMotionFrameRate();
        if (maxFps > 0) {
          value = value.copyWith(frameRate: maxFps);
        }
      } else {
        // 슬로우 모션이 비활성화된 경우 30fps로 복귀
        value = value.copyWith(frameRate: 30);
      }
    } catch (e) {
      print('Error toggling slow motion: $e');
      rethrow;
    }
  }
  
  /// Check if slow motion recording is currently active
  Future<bool> isSlowMotionActive() async {
    return await _ultralyticsYoloPlatform.isSlowMotionActive();
  }

  /// Closes the camera
  Future<void> closeCamera() async {
    await _ultralyticsYoloPlatform.closeCamera();
  }

  /// Starts the camera
  Future<void> startCamera() async {
    await _ultralyticsYoloPlatform.startCamera();
  }

  /// Stops the camera
  Future<void> pauseLivePrediction() async {
    await _ultralyticsYoloPlatform.pauseLivePrediction();
  }

  /// Starts the recording
  Future<void> startRecording() async {
    await _ultralyticsYoloPlatform.startRecording();
  }

  /// Stops the recording
  Future<String?> stopRecording() async {
    final result = await _ultralyticsYoloPlatform.stopRecording();
    return result;
  }
}
