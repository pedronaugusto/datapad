//! Every test of datapad, run by `bay dev test`.
test {
    _ = @import("datapad.zig");
    _ = @import("scan/entities_test.zig");
    _ = @import("scan/scan_test.zig");
}
