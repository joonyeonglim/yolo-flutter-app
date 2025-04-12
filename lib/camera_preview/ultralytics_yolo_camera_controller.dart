import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo_platform_interface.dart';

/// The state of the camera
class UltralyticsYoloCameraValue {
  /// Constructor to create an instance of [UltralyticsYoloCameraValue]
  UltralyticsYoloCameraValue({
    required this.lensDirection,
    required this.strokeWidth,
    required this.zoomRatio,
  });

  /// The direction of the camera lens
  final int lensDirection;

  /// The width of the stroke used to draw the bounding boxes
  final double strokeWidth;
  
  /// The current zoom ratio
  final double zoomRatio;

  /// Creates a copy of this [UltralyticsYoloCameraValue] but with
  /// the given fields
  UltralyticsYoloCameraValue copyWith({
    int? lensDirection,
    double? strokeWidth,
    double? zoomRatio,
  }) =>
      UltralyticsYoloCameraValue(
        lensDirection: lensDirection ?? this.lensDirection,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        zoomRatio: zoomRatio ?? this.zoomRatio,
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
    // 녹화 시작 전에 현재 줌 레벨 저장
    final currentZoom = value.zoomRatio;
    await _ultralyticsYoloPlatform.startRecording();
    
    // iOS에서 줌 레벨 유지를 위해 줌 값을 다시 설정
    if (currentZoom > 1.0) {
      await Future.delayed(const Duration(milliseconds: 500));
      await _ultralyticsYoloPlatform.setZoomRatio(currentZoom);
    }
  }

  /// Stops the recording
  Future<String?> stopRecording() async {
    // 녹화 종료 전에 현재 줌 레벨 저장
    final currentZoom = value.zoomRatio;
    final result = await _ultralyticsYoloPlatform.stopRecording();
    
    // iOS에서 줌 레벨 유지를 위해 줌 값을 다시 설정
    if (currentZoom > 1.0) {
      await Future.delayed(const Duration(milliseconds: 500));
      await _ultralyticsYoloPlatform.setZoomRatio(currentZoom);
    }
    
    return result;
  }
}
