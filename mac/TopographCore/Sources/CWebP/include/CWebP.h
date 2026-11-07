// libwebp's encoder, built in here so that it's optimized in Debug builds too: a dependency
// can't be, and unoptimized it takes eight times as long to import anything.
#include "../src/webp/encode.h"
#include "../src/webp/types.h"
