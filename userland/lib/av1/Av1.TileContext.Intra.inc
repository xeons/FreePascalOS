{ Fields of TTileContext for the intra prediction processes (Av1.IntraPrediction,
  Av1.IntraEdges, Av1.ChromaFromLuma). }
    { AboveRow[ i ] and LeftCol[ i ] of the specification at index i + 16
      (IntraEdgeOrigin), so that entries -2 and -1 exist; up to 2 * 64 + 64
      entries are used past the origin. }
    IntraAboveRow, IntraLeftCol: array[0..287] of Integer;
    { L[ i ][ j ] of the chroma from luma process, w (up to 32) per row. }
    CflLuma: array[0..32 * 32 - 1] of Integer;
