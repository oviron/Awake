import AwakeCore
import Testing

@testable import AwakeApp

@Test @MainActor func thermalCutoffExplainsWhyProtectionEnded() {
    let model = AppModel.preview("thermal")
    #expect(model.presentation == .cooling)
    #expect(model.status?.sessions.isEmpty == true)
    #expect(model.status?.sleep.ownsGlobalHold == false)
    #expect(model.thermalNotice?.contains("will not restart automatically") == true)
    model.reportOperationError(ServiceError.thermalPressure)
    #expect(model.message?.contains("cool down") == true)
}
