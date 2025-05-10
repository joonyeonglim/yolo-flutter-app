# VideoCapture 리팩토링

이 디렉토리는 기존 `VideoCapture.swift` 파일의 리팩토링 버전을 포함하고 있습니다. 원래 1000줄이 넘는 대형 파일을 기능별로 분리했습니다.

## 디렉토리 구조

```
VideoCapture/
├── VideoCapture.swift (메인 클래스, 간소화)
├── Extensions/
│   ├── FourCharCodeExtension.swift
│   └── AVCaptureDeviceExtension.swift
├── Protocols/
│   ├── VideoCaptureDelegate.swift
│   ├── CameraConfigurable.swift
│   ├── PhotoCapture.swift
│   ├── VideoRecordable.swift
│   └── FrameRateConfigurable.swift
├── Components/
│   ├── VideoCaptureSetup.swift (설정 관련)
│   ├── VideoRecordingManager.swift (녹화 관련)
│   ├── SlowMotionSupport.swift (슬로우 모션 기능)
│   └── FrameRateManager.swift (프레임 레이트 관리)
└── Delegates/
    └── VideoCaptureDelegates.swift (모든 델리게이트)
```

## 주요 개선 사항

1. **관심사 분리**: 기능별로 파일 분리
2. **코드 가독성**: 작은 단위의 파일로 분리하여 유지보수성 향상
3. **모듈화**: 확장과 프로토콜을 사용한 구조화
4. **재사용성**: 기능별 컴포넌트로 분리하여 재사용 가능성 향상

## 프로젝트 적용 방법

1. 디렉토리 전체를 Xcode 프로젝트에 추가 (그룹 생성 옵션 선택)
2. 기존 `VideoCapture.swift` 파일을 백업하고 제거하거나, import 구문을 수정
3. 프로젝트를 빌드하여 오류가 없는지 확인

## 참고사항

- 원래 기능을 모두 유지하면서 구조만 개선했습니다.
- 모든 public API는 그대로 유지되었습니다.
- 추가 개선 사항은 각 파일의 주석을 참고하세요. 