const codegen_core = @import("codegen/core.zig");
const codegen_primary = @import("codegen/primary.zig");

pub const Codegen = codegen_core.Codegen;
pub const BindingTypeInfo = codegen_core.BindingTypeInfo;
pub const TemplateCtx = codegen_primary.TemplateCtx;
