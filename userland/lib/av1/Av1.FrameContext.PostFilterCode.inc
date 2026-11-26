{ Methods of TFrameContext for the post filters (Av1.PostFilters). }

procedure TFrameContext.FreePostFilterPictures;
var
  Pictures: array[0..3] of TPicture;
  Index, Other: Integer;
  Shared: Boolean;
begin
  Pictures[0] := CdefFrame;
  Pictures[1] := UpscaledCdefFrame;
  Pictures[2] := UpscaledCurrFrame;
  Pictures[3] := LrFrame;
  for Index := 0 to 3 do
  begin
    if (Pictures[Index] = nil) or (Pictures[Index] = CurrFrame) then
      Continue;
    Shared := False;
    for Other := Index + 1 to 3 do
      if Pictures[Other] = Pictures[Index] then
        Shared := True;
    if not Shared then
      Pictures[Index].Free;
  end;
  CdefFrame := nil;
  UpscaledCdefFrame := nil;
  UpscaledCurrFrame := nil;
  LrFrame := nil;
end;
