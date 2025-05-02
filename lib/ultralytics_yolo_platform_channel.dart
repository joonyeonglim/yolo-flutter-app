import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/predict/classify/classification_result.dart';
import 'package:ultralytics_yolo/predict/detect/detected_object.dart';

import 'package:ultralytics_yolo/ultralytics_yolo_platform_interface.dart';

/// An implementation of [UltralyticsYoloPlatform] that uses method channels.
class PlatformChannelUltralyticsYolo implements UltralyticsYoloPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('ultralytics_yolo');

  /// The event channel used to stream the detection results
  @visibleForTesting
  final predictionResultsEventChannel =
      const EventChannel('ultralytics_yolo_prediction_results');

  /// The event channel used to stream the inference time
  @visibleForTesting
  final inferenceTimeEventChannel =
      const EventChannel('ultralytics_yolo_inference_time');

  /// The event channel used to stream the inference time
  @visibleForTesting
  final fpsRateEventChannel = const EventChannel('ultralytics_yolo_fps_rate');

  @override
  Future<String?> loadModel(
    Map<String, dynamic> model, {
    bool useGpu = false,
  }) =>
      methodChannel.invokeMethod<String>('loadModel', {
        'model': model,
        'useGpu': useGpu,
      }).catchError((dynamic e) => e.toString());

  @override
  Future<String?> setConfidenceThreshold(double confidence) =>
      methodChannel.invokeMethod<String>(
        'setConfidenceThreshold',
        {'confidence': confidence},
      );

  @override
  Future<String?> setIouThreshold(double iou) =>
      methodChannel.invokeMethod<String>('setIouThreshold', {'iou': iou});

  @override
  Future<String?> setNumItemsThreshold(int numItems) => methodChannel
      .invokeMethod<String>('setNumItemsThreshold', {'numItems': numItems});

  @override
  Future<String?> setZoomRatio(double ratio) =>
      methodChannel.invokeMethod<String>('setZoomRatio', {'ratio': ratio});

  @override
  Future<String?> setLensDirection(int direction) => methodChannel
      .invokeMethod<String>('setLensDirection', {'direction': direction});

  @override
  Future<String?> closeCamera() => methodChannel
      .invokeMethod<String>('closeCamera')
      .catchError((dynamic e) => e.toString());

  @override
  Future<String?> startCamera() => methodChannel
      .invokeMethod<String>('startCamera')
      .catchError((dynamic e) => e.toString());

  @override
  Future<String?> pauseLivePrediction() => methodChannel
      .invokeMethod<String>('pauseLivePrediction')
      .catchError((dynamic e) => e.toString());

  @override
  Future<String?> resumeLivePrediction() => methodChannel
      .invokeMethod<String>('resumeLivePrediction')
      .catchError((dynamic e) => e.toString());

  @override
  Future<String?> startRecording() => methodChannel
      .invokeMethod<String>('startRecording')
      .catchError((dynamic e) => e.toString());

  @override
  Future<String?> stopRecording() => methodChannel
      .invokeMethod<String>('stopRecording')
      .catchError((dynamic e) => e.toString());

  @override
  Future<Map<String, bool>> getSupportedFrameRates() async {
    final result = await methodChannel.invokeMethod<Map<Object?, Object?>>('getSupportedFrameRates');
    // Object 타입을 String과 bool로 변환
    return result?.map((key, value) => MapEntry(key.toString(), value as bool)) ?? {};
  }

  @override
  Future<String?> setFrameRate(int fps) => methodChannel
      .invokeMethod<String>('setFrameRate', {'fps': fps})
      .catchError((dynamic e) => e.toString());

  @override
  Future<bool> isSlowMotionSupported() async {
    final result = await methodChannel.invokeMethod<bool>('isSlowMotionSupported');
    return result ?? false;
  }

  @override
  Future<int> getMaxSlowMotionFrameRate() async {
    final result = await methodChannel.invokeMethod<int>('getMaxSlowMotionFrameRate');
    return result ?? 0;
  }

  @override
  Future<String?> enableSlowMotion(bool enable) => methodChannel
      .invokeMethod<String>('enableSlowMotion', {'enable': enable})
      .catchError((dynamic e) => e.toString());

  @override
  Future<bool> isSlowMotionActive() async {
    final result = await methodChannel.invokeMethod<bool>('isSlowMotionActive');
    return result ?? false;
  }

  @override
  Stream<List<DetectedObject?>?> get detectionResultStream =>
      predictionResultsEventChannel.receiveBroadcastStream().map(
        (result) {
          final objects = <DetectedObject>[];
          result = result as List;

          for (dynamic json in result) {
            json = json as Map;
            objects.add(DetectedObject.fromJson(json));
          }

          return objects;
        },
      );

  @override
  Stream<List<ClassificationResult?>?> get classificationResultStream =>
      predictionResultsEventChannel.receiveBroadcastStream().map(
        (result) {
          final objects = <ClassificationResult>[];
          result = result as List;

          for (final dynamic json in result) {
            objects.add(ClassificationResult.fromJson(
                Map<String, dynamic>.from(json as Map),),);
          }

          return objects;
        },
      );

  @override
  Stream<double>? get inferenceTimeStream => inferenceTimeEventChannel
      .receiveBroadcastStream()
      .map((time) => (time as num).toDouble());

  @override
  Stream<double>? get fpsRateStream => fpsRateEventChannel
      .receiveBroadcastStream()
      .map((rate) => (rate as num).toDouble());

  @override
  Future<List<ClassificationResult?>?> classifyImage(String imagePath) async {
    final result =
        await methodChannel.invokeMethod<List<Object?>>('classifyImage', {
      'imagePath': imagePath,
    }).catchError((_) {
      return <ClassificationResult?>[];
    });

    final objects = <ClassificationResult>[];

    result?.forEach((json) {
      objects.add(ClassificationResult.fromJson(
          Map<String, dynamic>.from(json! as Map),),);
    });

    return objects;
  }

  @override
  Future<List<DetectedObject?>?> detectImage(String imagePath) async {
    final result =
        await methodChannel.invokeMethod<List<Object?>>('detectImage', {
      'imagePath': imagePath,
    }).catchError((_) {
      return <DetectedObject?>[];
    });

    final objects = <DetectedObject>[];

    result?.forEach((json) {
      json = json as Map<dynamic, dynamic>?;
      if (json == null) return;
      objects.add(DetectedObject.fromJson(json));
    });

    return objects;
  }
}