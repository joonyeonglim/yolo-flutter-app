package com.ultralytics.ultralytics_yolo;

import static com.ultralytics.ultralytics_yolo.CameraPreview.CAMERA_PREVIEW_SIZE;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.util.DisplayMetrics;

import androidx.annotation.NonNull;

import com.ultralytics.ultralytics_yolo.models.LocalYoloModel;
import com.ultralytics.ultralytics_yolo.models.RemoteYoloModel;
import com.ultralytics.ultralytics_yolo.models.YoloModel;
import com.ultralytics.ultralytics_yolo.predict.Predictor;
import com.ultralytics.ultralytics_yolo.predict.classify.ClassificationResult;
import com.ultralytics.ultralytics_yolo.predict.classify.Classifier;
import com.ultralytics.ultralytics_yolo.predict.classify.TfliteClassifier;
import com.ultralytics.ultralytics_yolo.predict.detect.Detector;
import com.ultralytics.ultralytics_yolo.predict.detect.TfliteDetector;

import java.io.File;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

public class MethodCallHandler implements MethodChannel.MethodCallHandler {
    private final Context context;
    private final CameraPreview cameraPreview;
    private Predictor predictor;
    private final ResultStreamHandler resultStreamHandler;
    private final InferenceTimeStreamHandler inferenceTimeStreamHandler;
    private final FpsRateStreamHandler fpsRateStreamHandler;
    private final float widthDp;
    private final float density;
    private final float heightDp;

    public MethodCallHandler(BinaryMessenger binaryMessenger, Context context, CameraPreview cameraPreview) {
        this.context = context;

        this.cameraPreview = cameraPreview;

        EventChannel predictionResultEventChannel = new EventChannel(binaryMessenger, "ultralytics_yolo_prediction_results");
        resultStreamHandler = new ResultStreamHandler();
        predictionResultEventChannel.setStreamHandler(resultStreamHandler);

        EventChannel inferenceTimeEventChannel = new EventChannel(binaryMessenger, "ultralytics_yolo_inference_time");
        inferenceTimeStreamHandler = new InferenceTimeStreamHandler();
        inferenceTimeEventChannel.setStreamHandler(inferenceTimeStreamHandler);

        EventChannel fpsRateEventChannel = new EventChannel(binaryMessenger, "ultralytics_yolo_fps_rate");
        fpsRateStreamHandler = new FpsRateStreamHandler();
        fpsRateEventChannel.setStreamHandler(fpsRateStreamHandler);


        DisplayMetrics displayMetrics = context.getResources().getDisplayMetrics();
        int widthPixels = displayMetrics.widthPixels;
        int heightPixels = displayMetrics.heightPixels;
        density = displayMetrics.density;
        widthDp = widthPixels / density;
        // Add 40dp to resolve the discrepancy between Flutter screen and AndroidView
        // caused by the presence of the navigation bar
        heightDp = heightPixels / density + 40;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        String method = call.method;
        switch (method) {
            case "loadModel":
                loadModel(call, result);
                break;
            case "setConfidenceThreshold":
                setConfidenceThreshold(call, result);
                break;
            case "setIouThreshold":
                setIouThreshold(call, result);
                break;
            case "setNumItemsThreshold":
                setNumItemsThreshold(call, result);
                break;
            case "detectImage":
                detectImage(call, result);
                break;
            case "classifyImage":
                classifyImage(call, result);
                break;
            case "setLensDirection":
                setLensDirection(call, result);
                break;
            case "closeCamera":
                closeCamera(call, result);
                break;
            case "startCamera":
                startCamera(call, result);
                break;
            case "pauseLivePrediction":
                pauseLivePrediction(call, result);
                break;
            case "resumeLivePrediction":
                resumeLivePrediction(call, result);
                break;
            case "setZoomRatio":
                setScaleFactor(call, result);
                break;
            case "startRecording":
                startRecording(result);
                break;
            case "stopRecording":
                stopRecording(result);
                break;
            case "getSupportedFrameRatesInfo":
                getSupportedFrameRatesInfo(result);
                break;
            case "isFrameRateSupported":
                isFrameRateSupported(call, result);
                break;
            case "setFrameRate":
                setFrameRate(call, result);
                break;
            case "getCurrentFrameRate":
                getCurrentFrameRate(result);
                break;
            case "enableSlowMotion":
                enableSlowMotion(call, result);
                break;
            case "isSlowMotionSupported":
                isSlowMotionSupported(result);
                break;
            case "getMaxSlowMotionFrameRate":
                getMaxSlowMotionFrameRate(result);
                break;
            case "isSlowMotionActive":
                isSlowMotionActive(result);
                break;
            case "isRecording":
                isRecording(result);
                break;
            default:
                result.notImplemented();
                break;
        }
    }

    private void loadModel(MethodCall call, MethodChannel.Result result) {
        Map<String, Object> model = call.argument("model");
        if (model == null) {
            result.error("PredictorError", "Invalid model", null);
            return;
        }

        YoloModel yoloModel = null;
        String type = (String) model.get("type");
        String task = (String) model.get("task");
        String format = (String) model.get("format");
        if (Objects.equals(task, "detect")) {
            if (Objects.equals(format, "tflite")) {
                predictor = new TfliteDetector(context);
            }
        } else if (Objects.equals(task, "classify")) {
            if (Objects.equals(format, "tflite")) {
                predictor = new TfliteClassifier(context);
            }
        } else {
            return;
        }

        switch (Objects.requireNonNull(type)) {
            case "local":
                String modelPath = (String) model.get("modelPath");
                String metadataPath = (String) model.get("metadataPath");

                yoloModel = new LocalYoloModel(task, format, modelPath, metadataPath);
                break;
            case "remote":
                String modelUrl = (String) model.get("modelUrl");

                yoloModel = new RemoteYoloModel(modelUrl, task);
                break;
        }

        try {
            Object useGpuObject = call.argument("useGpu");
            boolean useGpu = false;
            if (useGpuObject != null) {
                useGpu = (boolean) useGpuObject;
            }

            predictor.loadModel(yoloModel, true);

            setPredictorFrameProcessor();
            setPredictorCallbacks();

            result.success("Success");
        } catch (Exception e) {
            result.error("PredictorError", "Invalid model", null);
        }
    }

    private void setPredictorFrameProcessor() {
        cameraPreview.setPredictorFrameProcessor(predictor);
    }

    private void setPredictorCallbacks() {
        if (predictor instanceof Detector) {
            // Multiply by 3/4 instead of 4/3 because the camera preview frame is rotated -90°
            // float newWidth = heightDp * 3 / 4;
            float newWidth = heightDp * CAMERA_PREVIEW_SIZE.getHeight() / CAMERA_PREVIEW_SIZE.getWidth();
            final float offsetX = (widthDp - newWidth) / 2;

            ((Detector) predictor).setObjectDetectionResultCallback(result -> {
                List<Map<String, Object>> objects = new ArrayList<>();

                for (float[] obj : result) {
                    Map<String, Object> objectMap = new HashMap<>();

                    float x = obj[0] * newWidth + offsetX;
                    float y = obj[1] * heightDp;
                    float width = obj[2] * newWidth;
                    float height = obj[3] * heightDp;
                    float confidence = obj[4];
                    int index = (int) obj[5];
                    String label = index < predictor.labels.size() ? predictor.labels.get(index) : "";

                    objectMap.put("x", x);
                    objectMap.put("y", y);
                    objectMap.put("width", width);
                    objectMap.put("height", height);
                    objectMap.put("confidence", confidence);
                    objectMap.put("index", index);
                    objectMap.put("label", label);

                    objects.add(objectMap);
                }

                resultStreamHandler.sink(objects);
            });
        } else if (predictor instanceof Classifier) {
            ((Classifier) predictor).setClassificationResultCallback(result -> {
                List<Map<String, Object>> objects = new ArrayList<>();

                for (ClassificationResult classificationResult : result) {
                    Map<String, Object> objectMap = new HashMap<>();

                    objectMap.put("confidence", classificationResult.confidence);
                    objectMap.put("index", classificationResult.index);
                    objectMap.put("label", classificationResult.label);
                    objects.add(objectMap);
                }

                resultStreamHandler.sink(objects);
            });
        }

        predictor.setFpsRateCallback(fpsRateStreamHandler::sink);
        predictor.setInferenceTimeCallback(inferenceTimeStreamHandler::sink);
    }

    private void setConfidenceThreshold(MethodCall call, MethodChannel.Result result) {
        Object confidenceObject = call.argument("confidence");
        if (confidenceObject != null) {
            final double confidence = (double) confidenceObject;
            predictor.setConfidenceThreshold((float) confidence);
        }
    }

    private void setIouThreshold(MethodCall call, MethodChannel.Result result) {
        Object iouObject = call.argument("iou");
        if (iouObject != null) {
            final double iou = (double) iouObject;
            ((Detector) predictor).setIouThreshold((float) iou);
        }
    }

    private void setNumItemsThreshold(MethodCall call, MethodChannel.Result result) {
        Object numItemsObject = call.argument("numItems");
        if (numItemsObject != null) {
            final int numItems = (int) numItemsObject;
            ((Detector) predictor).setNumItemsThreshold(numItems);
        }
    }

    private void setLensDirection(MethodCall call, MethodChannel.Result result) {
        Object directionObject = call.argument("direction");
        if (directionObject != null) {
            final int direction = (int) directionObject;
            cameraPreview.setCameraFacing(direction);
        }
    }

    private void closeCamera(MethodCall call, MethodChannel.Result result) {
//        ncnnCameraPreview.closeCamera();
    }

    private void startCamera(MethodCall call, MethodChannel.Result result) {
        // TODO: Resume detector
        // startCamera(0);
    }

    private void pauseLivePrediction(MethodCall call, MethodChannel.Result result) {
//        ncnnCameraPreview.pauseLivePrediction();
    }

    private void resumeLivePrediction(MethodCall call, MethodChannel.Result result) {
//        ncnnCameraPreview.resumeLivePrediction();
    }

    private void detectImage(MethodCall call, MethodChannel.Result result) {
        if (predictor != null) {
            Object imagePathObject = call.argument("imagePath");
            if (imagePathObject != null) {
                final String imagePath = (String) imagePathObject;
                Bitmap bitmap = BitmapFactory.decodeFile(imagePath);
                final float[][] res = (float[][]) predictor.predict(bitmap);

                float scaleFactor = widthDp / bitmap.getWidth();
                float newHeight = bitmap.getHeight() * scaleFactor;
                List<Map<String, Object>> objects = new ArrayList<>();
                for (float[] obj : res) {
                    Map<String, Object> objectMap = new HashMap<>();

                    float x = obj[0] * widthDp;
                    float y = obj[1] * newHeight;
                    float width = obj[2] * widthDp;
                    float height = obj[3] * newHeight;
                    float confidence = obj[4];
                    int index = (int) obj[5];
                    String label = index < predictor.labels.size() ? predictor.labels.get(index) : "";

                    objectMap.put("x", x);
                    objectMap.put("y", y);
                    objectMap.put("width", width);
                    objectMap.put("height", height);
                    objectMap.put("confidence", confidence);
                    objectMap.put("index", index);
                    objectMap.put("label", label);

                    objects.add(objectMap);
                }

                result.success(objects);
            }
        }
    }

    private void classifyImage(MethodCall call, MethodChannel.Result result) {
        if (predictor != null) {
            Object imagePathObject = call.argument("imagePath");
            if (imagePathObject != null) {
                final String imagePath = (String) imagePathObject;
                Bitmap bitmap = BitmapFactory.decodeFile(imagePath);
                final List<ClassificationResult> res = (List<ClassificationResult>) predictor.predict(bitmap);

                List<Map<String, Object>> objects = new ArrayList<>();
                for (ClassificationResult classificationResult : res) {
                    Map<String, Object> objectMap = new HashMap<>();

                    objectMap.put("confidence", classificationResult.confidence);
                    objectMap.put("index", classificationResult.index);
                    objectMap.put("label", classificationResult.label);
                    objects.add(objectMap);
                }

                result.success(objects);
            }
        }
    }


    private void setScaleFactor(MethodCall call, MethodChannel.Result result) {
        Object factorObject = call.argument("ratio");
        if (factorObject != null) {
            final double factor = (double) factorObject;
            cameraPreview.setScaleFactor(factor);
            result.success("Success");
        } else {
            result.error("INVALID_ARGS", "Invalid zoom ratio", null);
        }
    }

    private void startRecording(MethodChannel.Result result) {
        // 현재 줌 레벨 저장
        final float currentZoom = cameraPreview.getCurrentZoomFactor();
        
        // 즉시 성공 응답을 전송 (비동기 작업 시작을 알림)
        result.success("Started");
        
        cameraPreview.startRecording(new CameraPreview.RecordingCallback() {
            @Override
            public void onStarted() {
                // 녹화가 시작됨 - 이미 결과를 반환했으므로 로그만 기록
                System.out.println("DEBUG: Recording started successfully");
                
                // 약간의 지연 후 줌 레벨 재설정 (필요한 경우)
                if (currentZoom > 1.0f) {
                    new android.os.Handler().postDelayed(() -> {
                        cameraPreview.setScaleFactor(currentZoom);
                        System.out.println("DEBUG: Reapplied zoom factor after recording started: " + currentZoom);
                    }, 300);
                }
            }

            @Override
            public void onFinished(String filePath) {
                // 녹화가 완료됨 - 이미 결과를 반환했으므로 로그만 기록
                System.out.println("DEBUG: Recording finished successfully: " + filePath);
            }

            @Override
            public void onError(String errorMessage) {
                // 오류 발생 - 이미 결과를 반환했으므로 로그만 기록
                System.out.println("DEBUG: Recording error occurred: " + errorMessage);
            }
        });
    }

    private void stopRecording(MethodChannel.Result result) {
        // 현재 줌 레벨 저장
        final float currentZoom = cameraPreview.getCurrentZoomFactor();
        
        cameraPreview.stopRecording();
        
        // 녹화 종료 후 약간의 지연을 두고 줌 레벨 재설정 (필요한 경우)
        if (currentZoom > 1.0f) {
            new android.os.Handler().postDelayed(() -> {
                cameraPreview.setScaleFactor(currentZoom);
                System.out.println("DEBUG: Reapplied zoom factor after recording stopped: " + currentZoom);
            }, 800);
        }
        
        // 임시 파일 경로를 찾아 반환
        File cacheDir = context.getCacheDir();
        File[] files = cacheDir.listFiles((dir, name) -> name.startsWith("recording_") && name.endsWith(".mp4"));
        
        if (files != null && files.length > 0) {
            // 가장 최근 파일 찾기
            File latestFile = files[0];
            for (File file : files) {
                if (file.lastModified() > latestFile.lastModified()) {
                    latestFile = file;
                }
            }
            result.success(latestFile.getAbsolutePath());
        } else {
            result.error("RECORDING_ERROR", "녹화 파일을 찾을 수 없습니다", null);
        }
    }

    // FPS 관련 메서드들
    private void getSupportedFrameRatesInfo(MethodChannel.Result result) {
        Map<String, Boolean> supportedFrameRates = cameraPreview.getSupportedFrameRatesInfo();
        result.success(supportedFrameRates);
    }

    private void isFrameRateSupported(MethodCall call, MethodChannel.Result result) {
        Object fpsObject = call.argument("fps");
        if (fpsObject != null) {
            final int fps = (int) fpsObject;
            boolean isSupported = cameraPreview.isFrameRateSupported(fps);
            result.success(isSupported);
        } else {
            result.error("INVALID_ARGS", "Invalid fps parameter", null);
        }
    }

    private void setFrameRate(MethodCall call, MethodChannel.Result result) {
        Object fpsObject = call.argument("fps");
        if (fpsObject != null) {
            final int fps = (int) fpsObject;
            boolean success = cameraPreview.setFrameRate(fps);
            if (success) {
                result.success("Frame rate set to " + fps + " FPS");
            } else {
                result.error("FPS_ERROR", "Failed to set frame rate to " + fps + " FPS", null);
            }
        } else {
            result.error("INVALID_ARGS", "Invalid fps parameter", null);
        }
    }

    private void getCurrentFrameRate(MethodChannel.Result result) {
        int currentFps = cameraPreview.getCurrentFrameRate();
        result.success(currentFps);
    }

    private void enableSlowMotion(MethodCall call, MethodChannel.Result result) {
        Object enableObject = call.argument("enable");
        if (enableObject != null) {
            final boolean enable = (boolean) enableObject;
            boolean success = cameraPreview.enableSlowMotion(enable);
            if (success) {
                result.success("Slow motion " + (enable ? "enabled" : "disabled"));
            } else {
                result.error("SLOW_MOTION_ERROR", "Failed to " + (enable ? "enable" : "disable") + " slow motion", null);
            }
        } else {
            result.error("INVALID_ARGS", "Invalid enable parameter", null);
        }
    }

    private void isSlowMotionSupported(MethodChannel.Result result) {
        boolean isSupported = cameraPreview.isSlowMotionSupported();
        result.success(isSupported);
    }

    private void getMaxSlowMotionFrameRate(MethodChannel.Result result) {
        int maxFps = cameraPreview.getMaxSlowMotionFrameRate();
        result.success(maxFps);
    }

    private void isSlowMotionActive(MethodChannel.Result result) {
        boolean isActive = cameraPreview.isSlowMotionActive();
        result.success(isActive);
    }

    private void isRecording(MethodChannel.Result result) {
        boolean recording = cameraPreview.isRecording();
        result.success(recording);
    }
}
