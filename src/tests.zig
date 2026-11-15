//! Every test of datapad, run by `bay dev test`.
test {
    _ = @import("datapad.zig");
    _ = @import("scan/entities_test.zig");
    _ = @import("scan/scan_test.zig");
    _ = @import("block/blocks_test.zig");
    _ = @import("block/properties_test.zig");
    _ = @import("inline/inlines_test.zig");
    _ = @import("inline/properties_test.zig");
    _ = @import("spec_test.zig");
}
