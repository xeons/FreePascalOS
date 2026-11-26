{ Fields and methods of TFrameContext for the post filters (Av1.PostFilters). }
    { CdefFrame, UpscaledCdefFrame, UpscaledCurrFrame and LrFrame of the
      specification; any of them may be the same picture as the one it
      comes from when no filter changes it (LrFrame may be CurrFrame). }
    CdefFrame, UpscaledCdefFrame, UpscaledCurrFrame, LrFrame: TPicture;
    { Frees the post filter pictures that are not CurrFrame (nor each other). }
    procedure FreePostFilterPictures;
