import Foundation
import Testing

@testable import AwakeSystem

@Test func macOSThermalPressureKeepsAllFourKnownLevelsDistinct() {
    #expect(PowerSourceReader.thermalReading(.nominal) == .nominal)
    #expect(PowerSourceReader.thermalReading(.fair) == .fair)
    #expect(PowerSourceReader.thermalReading(.serious) == .serious)
    #expect(PowerSourceReader.thermalReading(.critical) == .critical)
}
