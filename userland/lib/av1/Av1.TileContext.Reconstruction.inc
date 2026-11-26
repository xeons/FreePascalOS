{ Fields of TTileContext for the Reconstruction processes (Av1.Reconstruction). }
    { Dequant[ i ][ j ] of the reconstruct process: Min(32, h) rows of Min(32, w). }
    ReconstructionDequant: array[0..1023] of Integer;
    { Residual[ i ][ j ] of the 2D inverse transform: h rows of w. }
    ReconstructionResidual: array[0..4095] of Integer;
