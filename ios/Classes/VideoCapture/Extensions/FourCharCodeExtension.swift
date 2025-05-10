import Foundation

// FourCharCode 확장 - 포맷 타입 코드를 문자열로 변환
extension FourCharCode {
  func toString() -> String {
    let bytes: [CChar] = [
      CChar((self >> 24) & 0xFF),
      CChar((self >> 16) & 0xFF),
      CChar((self >> 8) & 0xFF),
      CChar(self & 0xFF),
      0
    ]
    return String(cString: bytes)
  }
} 