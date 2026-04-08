// Wrapper for the Blackmagic RAW SDK dispatch file.
// The SDK's BlackmagicRawAPIDispatch.cpp provides runtime dynamic loading
// of the BRAW framework — no link-time dependency.
// Guarded by EMP_HAS_BRAW so the build succeeds without the SDK.

#ifdef EMP_HAS_BRAW
#include "braw_dispatch_sdk.cpp"
#endif
