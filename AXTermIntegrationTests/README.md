# AXTerm Integration Tests

This directory contains integration tests that verify AXTerm's packet radio functionality using a Direwolf simulation environment.

## Prerequisites

1. The Vagrant/Docker simulation environment must be running
2. The `AXTermIntegrationTests` target must be added to the Xcode project

## Setting Up the Xcode Test Target

Since the integration test target isn't automatically created, you need to add it manually in Xcode:

### Step 1: Add New Test Target

1. Open `AXTerm.xcodeproj` in Xcode
2. Select the project in the navigator (top-left, blue icon)
3. Click the **+** button at the bottom of the targets list
4. Choose **macOS** → **Unit Testing Bundle**
5. Name it: `AXTermIntegrationTests`
6. Ensure "Target to be Tested" is set to `AXTerm`
7. Click **Finish**

### Step 2: Add Source Files

1. In the project navigator, right-click on the new `AXTermIntegrationTests` folder
2. Choose **Add Files to "AXTerm"...**
3. Navigate to `AXTermIntegrationTests/` directory
4. Select all `.swift` files in `Support/` and `Tests/`
5. Ensure "Copy items if needed" is **unchecked**
6. Ensure `AXTermIntegrationTests` target is checked
7. Click **Add**

### Step 3: Configure Build Settings

1. Select the `AXTermIntegrationTests` target
2. Go to **Build Settings**
3. Search for "Host Application"
4. Set it to `AXTerm`

### Step 4: Create Integration Scheme (Optional)

1. Go to **Product** → **Scheme** → **New Scheme...**
2. Name it: `AXTerm-Integration`
3. Edit the scheme:
   - **Test** action: Check only `AXTermIntegrationTests`
   - **Pre-actions** (optional): Add script to run `Scripts/sim-start.sh`
   - **Post-actions** (optional): Add script to run `Scripts/sim-stop.sh`

## Running the Tests

### From Command Line

```bash
# Start simulation and run tests
./Scripts/run-integration-tests.sh

# Run with verbose output
./Scripts/run-integration-tests.sh --verbose

# Run specific test
./Scripts/run-integration-tests.sh --filter BasicConnectivity
```

### From Xcode

1. Ensure simulation is running: `./Scripts/sim-start.sh`
2. Select the `AXTerm-Integration` scheme (or `AXTerm` scheme)
3. Press **Cmd+U** to run tests
4. Or right-click a specific test and choose **Run**

## Test Files

### Support/

- **SimulatorClient.swift** - Bidirectional KISS TCP client for tests
- **TestFixtures.swift** - Pre-built AX.25 and AXDP test frames

### Tests/

- **BasicConnectivityTests.swift** - Verifies simulation environment is working
- **AX25TransmissionTests.swift** - Tests plain AX.25 UI frame transmission
- **FX25TransmissionTests.swift** - Tests FX.25 (Forward Error Correction)
- **AXDPProtocolTests.swift** - Tests AXDP extension protocol
- **BackwardsCompatibilityIntegrationTests.swift** - Tests mixed AXDP/standard traffic

## Test Timeouts

Integration tests use longer timeouts than unit tests because:
- Audio simulation introduces latency (~200-500ms per frame)
- FX.25 encoding/decoding adds processing time
- Direwolf uses carrier sense before transmitting

Default timeout is 10 seconds per frame. Adjust in individual tests if needed.

## Troubleshooting

### Tests Fail Immediately

Check that simulation is running:
```bash
./Scripts/sim-status.sh
```

### Timeout Errors

1. Increase timeout in failing test
2. Check Direwolf logs for errors:
   ```bash
   vagrant ssh -c "docker logs axterm-direwolf-a"
   ```
3. Try restarting simulation:
   ```bash
   ./Scripts/sim-stop.sh --halt
   ./Scripts/sim-start.sh
   ```

### "No such module 'AXTerm'" Error

Ensure the test target is properly linked:
1. Select `AXTermIntegrationTests` target
2. Go to **Build Phases** → **Dependencies**
3. Add `AXTerm` if not present

### Frame Not Received

The RF simulation can occasionally drop frames (like real radio). If a single test fails but others pass, try running it again.
