//! Some ANSI escape codes for formatting

pub const reset = "\x1b[0m";

// styles
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";
pub const blink = "\x1b[5m";
pub const inverse = "\x1b[7m";
pub const hidden = "\x1b[8m";
pub const strikethrough = "\x1b[9m";

// fg colors
pub const black = "\x1b[30m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const white = "\x1b[37m";
pub const grey = "\x1b[90m";
pub const brightRed = "\x1b[91m";
pub const brightGreen = "\x1b[92m";
pub const brightYellow = "\x1b[93m";
pub const brightBlue = "\x1b[94m";
pub const brightMagenta = "\x1b[95m";
pub const brightCyan = "\x1b[96m";
pub const brightWhite = "\x1b[97m";

// bg colors
pub const bgBlack = "\x1b[40m";
pub const bgRed = "\x1b[41m";
pub const bgGreen = "\x1b[42m";
pub const bgYellow = "\x1b[43m";
pub const bgBlue = "\x1b[44m";
pub const bgMagenta = "\x1b[45m";
pub const bgCyan = "\x1b[46m";
pub const bgWhite = "\x1b[47m";
pub const bgGrey = "\x1b[100m";
pub const bgBrightRed = "\x1b[101m";
pub const bgBrightGreen = "\x1b[102m";
pub const bgBrightYellow = "\x1b[103m";
pub const bgBrightBlue = "\x1b[104m";
pub const bgBrightMagenta = "\x1b[105m";
pub const bgBrightCyan = "\x1b[106m";
pub const bgBrightWhite = "\x1b[107m";
