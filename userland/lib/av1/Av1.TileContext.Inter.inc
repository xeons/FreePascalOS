{ Fields of TTileContext for the inter prediction processes (Av1.InterPrediction). }
    { The warp estimation process's result (section 7.11.3.8), set for
      plane 0 and used for the chroma planes of the same block. }
    LocalWarpParams: array[0..5] of Integer;
    LocalValid: Boolean;
    { The rounding variables (section 7.11.3.2). }
    InterRound0, InterRound1, InterPostRound: Integer;
    { The distance weights (section 7.11.3.15). }
    FwdWeight, BckWeight: Integer;
    { preds[ refList ][ i ][ j ] at InterPredStride entries per row. }
    InterPreds: array[0..1, 0..MAX_SB_SIZE * MAX_SB_SIZE - 1] of Integer;
    { Mask[ i ][ j ]: kept from the luma plane for the chroma planes. }
    InterMask: array[0..MAX_SB_SIZE * MAX_SB_SIZE - 1] of Byte;
    { The intermediate array of the block inter prediction process: up to
      ((h - 1) * yStep + 1023 >> 10) + 8 rows of up to 128 samples. }
    InterIntermediate: array[0..(2 * MAX_SB_SIZE + 16) * MAX_SB_SIZE - 1] of Integer;
    { obmcPred of the overlapped motion compensation process. }
    ObmcPred: array[0..MAX_SB_SIZE * MAX_SB_SIZE - 1] of Integer;
