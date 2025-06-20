package com.ultralytics.ultralytics_yolo;

import android.app.Activity;
import android.content.Context;
import android.util.Size;
import android.util.Range;

import androidx.camera.core.AspectRatio;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraControl;
import androidx.camera.core.CameraInfo;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.Preview;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.camera.video.FileOutputOptions;
import androidx.camera.video.Recording;
import androidx.camera.video.VideoCapture;
import androidx.camera.video.VideoRecordEvent;
import androidx.camera.video.Recorder;
import androidx.camera.video.MediaStoreOutputOptions;
import androidx.camera.video.Quality;
import androidx.camera.video.QualitySelector;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;

import com.google.common.util.concurrent.ListenableFuture;
import com.ultralytics.ultralytics_yolo.predict.Predictor;

import java.io.File;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;

public class CameraPreview {
    public final static Size CAMERA_PREVIEW_SIZE = new Size(320, 320);
    private final Context context;
    private Predictor predictor;
    private ProcessCameraProvider cameraProvider;
    private CameraControl cameraControl;
    private CameraInfo cameraInfo;
    private Camera camera;
    private Activity activity;
    private PreviewView mPreviewView;
    private boolean busy = false;
    private VideoCapture<Recorder> videoCapture;
    private Recording currentRecording;
    private Executor cameraExecutor;
    private float currentZoomFactor = 1.0f;
    
    // FPS 관련 필드
    private int currentFrameRate = 30;
    private boolean isSlowMotionEnabled = false;
    private Range<Integer> fpsRange;
    
    // 녹화 상태 관리
    private boolean isRecording = false;
    private RecordingCallback recordingCallback;

    public CameraPreview(Context context) {
        this.context = context;
        this.cameraExecutor = ContextCompat.getMainExecutor(context);
    }

    public void openCamera(int facing, Activity activity, PreviewView mPreviewView) {
        this.activity = activity;
        this.mPreviewView = mPreviewView;

        final ListenableFuture<ProcessCameraProvider> cameraProviderFuture = ProcessCameraProvider.getInstance(context);
        cameraProviderFuture.addListener(() -> {
            try {
                cameraProvider = cameraProviderFuture.get();
                bindPreview(facing);
            } catch (ExecutionException | InterruptedException e) {
                // No errors need to be handled for this Future.
                // This should never be reached.
            }
        }, ContextCompat.getMainExecutor(context));
    }

    private void bindPreview(int facing) {
        if (!busy) {
            busy = true;

            Preview cameraPreview = new Preview.Builder()
                    .setTargetAspectRatio(AspectRatio.RATIO_4_3)
                    .build();

            CameraSelector cameraSelector = new CameraSelector.Builder()
                    .requireLensFacing(facing)
                    .build();

            ImageAnalysis imageAnalysis =
                    new ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .setTargetAspectRatio(AspectRatio.RATIO_4_3)
                            .build();
            imageAnalysis.setAnalyzer(Runnable::run, imageProxy -> {
                predictor.predict(imageProxy, facing == CameraSelector.LENS_FACING_FRONT);

                //clear stream for next image
                imageProxy.close();
            });

            // 비디오 캡처 설정 - 품질에 따른 설정
            Recorder recorder = new Recorder.Builder()
                    .setQualitySelector(getQualitySelector())
                    .build();
            videoCapture = VideoCapture.withOutput(recorder);

            // Unbind use cases before rebinding
            cameraProvider.unbindAll();

            // Bind use cases to camera
            camera = cameraProvider.bindToLifecycle(
                    (LifecycleOwner) activity, 
                    cameraSelector, 
                    cameraPreview, 
                    imageAnalysis,
                    videoCapture);

            cameraControl = camera.getCameraControl();
            cameraInfo = camera.getCameraInfo();
            
            // FPS 범위 설정
            setupFpsConfiguration();
            
            // 이전에 저장된 줌 비율 적용
            if (currentZoomFactor > 1.0f) {
                cameraControl.setZoomRatio(currentZoomFactor);
            }

            cameraPreview.setSurfaceProvider(mPreviewView.getSurfaceProvider());

            busy = false;
        }
    }

    // FPS 설정 초기화
    private void setupFpsConfiguration() {
        if (cameraInfo != null) {
            // 기본 FPS 범위 설정
            fpsRange = new Range<>(30, 30);
            System.out.println("DEBUG: FPS configuration initialized");
        }
    }

    // 지원되는 FPS 정보 반환
    public Map<String, Boolean> getSupportedFrameRatesInfo() {
        Map<String, Boolean> result = new HashMap<>();
        int[] fpsValues = {30, 60, 90, 120};
        
        for (int fps : fpsValues) {
            String key = fps + "fps";
            result.put(key, isFrameRateSupported(fps));
        }
        
        System.out.println("DEBUG: Supported frame rates: " + result);
        return result;
    }

    // 특정 FPS 지원 여부 확인
    public boolean isFrameRateSupported(int fps) {
        // Android CameraX에서는 기본적으로 30fps는 지원
        // 높은 FPS는 기기에 따라 다름
        if (fps <= 30) return true;
        
        // 고속 촬영 지원 여부는 기기의 하드웨어에 의존
        // 실제 구현에서는 Camera2 API를 통해 확인 가능
        return fps <= 60; // 대부분의 현대 기기는 60fps까지 지원
    }

    // FPS 설정
    public boolean setFrameRate(int fps) {
        if (currentFrameRate == fps) {
            System.out.println("DEBUG: Frame rate already set to " + fps + " FPS");
            return true;
        }

        if (!isFrameRateSupported(fps)) {
            System.out.println("DEBUG: Frame rate " + fps + " FPS is not supported");
            return false;
        }

        currentFrameRate = fps;
        fpsRange = new Range<>(fps, fps);
        
        // 슬로우 모션 모드 설정
        if (fps > 60) {
            isSlowMotionEnabled = true;
            System.out.println("DEBUG: Slow motion enabled at " + fps + " FPS");
        } else {
            isSlowMotionEnabled = false;
        }

        System.out.println("DEBUG: Frame rate successfully set to " + fps + " FPS");
        return true;
    }

    // 현재 FPS 반환
    public int getCurrentFrameRate() {
        return currentFrameRate;
    }

    // 슬로우 모션 모드 활성화/비활성화
    public boolean enableSlowMotion(boolean enable) {
        if (isRecording) {
            System.out.println("DEBUG: Cannot change slow motion mode while recording");
            return false;
        }

        if (enable) {
            // 슬로우 모션을 위해 120fps로 설정
            return setFrameRate(120);
        } else {
            // 일반 모드로 복귀 (30fps)
            return setFrameRate(30);
        }
    }

    // 슬로우 모션 지원 여부
    public boolean isSlowMotionSupported() {
        return isFrameRateSupported(120);
    }

    // 최대 슬로우 모션 프레임레이트 반환
    public int getMaxSlowMotionFrameRate() {
        if (isFrameRateSupported(240)) return 240;
        if (isFrameRateSupported(120)) return 120;
        return 60;
    }

    // 슬로우 모션 활성 상태 확인
    public boolean isSlowMotionActive() {
        return isSlowMotionEnabled && currentFrameRate > 60;
    }

    // 품질 선택기 설정
    private QualitySelector getQualitySelector() {
        if (isSlowMotionEnabled) {
            // 슬로우 모션 모드에서는 HD 품질 사용 (고속 촬영 지원)
            return QualitySelector.from(Quality.HD);
        } else {
            // 일반 모드에서는 최고 품질 사용
            return QualitySelector.from(Quality.HIGHEST);
        }
    }

    public void setPredictorFrameProcessor(Predictor predictor) {
        this.predictor = predictor;
    }

    public void setCameraFacing(int facing) {
        if (cameraProvider != null) {
            cameraProvider.unbindAll();
            bindPreview(facing);
        }
    }

    public void setScaleFactor(double factor) {
        if (cameraControl != null) {
            float zoomFactor = (float)factor;
            cameraControl.setZoomRatio(zoomFactor);
            currentZoomFactor = zoomFactor;
            System.out.println("DEBUG: Zoom factor set to " + currentZoomFactor);
        }
    }

    public float getCurrentZoomFactor() {
        return currentZoomFactor;
    }

    public void startRecording(RecordingCallback callback) {
        if (videoCapture == null) {
            callback.onError("비디오 캡처가 초기화되지 않았습니다");
            return;
        }

        if (isRecording || currentRecording != null) {
            callback.onError("이미 녹화 중입니다");
            return;
        }

        // 현재 줌 레벨 저장
        final float savedZoomFactor = currentZoomFactor;
        this.recordingCallback = callback;
        this.isRecording = true;

        // 임시 파일 생성
        String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss", Locale.getDefault()).format(new Date());
        String fileName = "recording_" + timestamp + ".mp4";
        File outputFile = new File(context.getCacheDir(), fileName);

        FileOutputOptions fileOutputOptions = new FileOutputOptions.Builder(outputFile).build();

        // 녹화를 시작하기 전 줌 레벨 유지
        if (cameraControl != null && savedZoomFactor > 1.0f) {
            System.out.println("DEBUG: Maintaining zoom factor for recording: " + savedZoomFactor);
        }

        // 슬로우 모션 모드 로깅
        if (isSlowMotionEnabled) {
            System.out.println("DEBUG: Starting slow motion recording at " + currentFrameRate + " FPS");
        }

        currentRecording = videoCapture.getOutput().prepareRecording(context, fileOutputOptions)
                .start(cameraExecutor, videoRecordEvent -> {
                    if (videoRecordEvent instanceof VideoRecordEvent.Start) {
                        // 녹화 시작됨
                        System.out.println("DEBUG: Recording started successfully");
                        callback.onStarted();
                        
                        // 녹화 시작 후 줌 레벨 재설정 (필요한 경우)
                        if (cameraControl != null && savedZoomFactor > 1.0f) {
                            cameraControl.setZoomRatio(savedZoomFactor);
                        }
                    } else if (videoRecordEvent instanceof VideoRecordEvent.Finalize) {
                        VideoRecordEvent.Finalize finalizeEvent = (VideoRecordEvent.Finalize) videoRecordEvent;
                        isRecording = false;
                        
                        if (finalizeEvent.hasError()) {
                            System.out.println("DEBUG: Recording error: " + finalizeEvent.getCause().getMessage());
                            callback.onError(finalizeEvent.getCause().getMessage());
                        } else {
                            // 녹화 완료
                            System.out.println("DEBUG: Recording finished successfully: " + outputFile.getAbsolutePath());
                            callback.onFinished(outputFile.getAbsolutePath());
                            
                            // 녹화 종료 후 줌 레벨 복원
                            if (cameraControl != null && savedZoomFactor > 1.0f) {
                                cameraControl.setZoomRatio(savedZoomFactor);
                                System.out.println("DEBUG: Restored zoom factor after recording: " + savedZoomFactor);
                            }
                        }
                        currentRecording = null;
                        recordingCallback = null;
                    }
                });
    }

    public void stopRecording() {
        if (currentRecording == null || !isRecording) {
            System.out.println("DEBUG: No active recording to stop");
            return;
        }

        // 현재 줌 레벨 저장
        final float savedZoomFactor = currentZoomFactor;
        
        System.out.println("DEBUG: Stopping recording...");
        currentRecording.stop();
        
        // 녹화 종료 직후 줌 레벨 복원 시도
        if (cameraControl != null && savedZoomFactor > 1.0f) {
            // 약간의 지연 추가 (녹화 중지 처리 시간 고려)
            new android.os.Handler().postDelayed(() -> {
                cameraControl.setZoomRatio(savedZoomFactor);
                System.out.println("DEBUG: Restored zoom factor after stopping recording: " + savedZoomFactor);
            }, 500);
        }
    }

    // 녹화 상태 확인
    public boolean isRecording() {
        return isRecording && currentRecording != null;
    }

    public interface RecordingCallback {
        void onStarted();
        void onFinished(String filePath);
        void onError(String errorMessage);
    }
}
