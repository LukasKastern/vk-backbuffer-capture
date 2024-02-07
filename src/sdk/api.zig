const CaptureContext = struct {};

fn beginCapture(app_id: u64) *CaptureContext {
    _ = app_id; // autofix
}

fn endCapture() void {}

const Frame = struct {
    // format:
};

fn getNextFrame() void {}
