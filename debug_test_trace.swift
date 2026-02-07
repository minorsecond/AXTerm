#!/usr/bin/env swift

// Quick test to verify I-frame ACK behavior
import Foundation

// Simulate the test scenario
print("Expected flow:")
print("1. Connect creates session")
print("2. Set onSendFrame callback")  
print("3. Send 5 I-frames")
print("4. Each I-frame should trigger 1 RR")
print("5. sentFrames should have count = 5")
print("")
print("Actual test:")
print("Line 549-550: Create manager, set localCallsign")
print("Line 552-553: var sentFrames = [], set callback")
print("Line 556: makeConnectedSession (sends SABM, but BEFORE callback is set)")
print("Line 564-574: Send 5 I-frames")
print("Line 577: Assert sentFrames.count == 5")
print("")
print("So sentFrames should start empty, then get 5 RR frames from the 5 I-frames.")
print("IF test is failing, either:")
print("  a) Not all I-frames are generating RR responses")
print("  b) Some extra frames are being sent")
print("  c) The callback isn't being invoked")
