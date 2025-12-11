
proc addOTAMethods*(rt: var FastRpcRouter, otaValidationCb = proc(
    ): bool {.gcsafe, nimcall.} = true) =
  discard

