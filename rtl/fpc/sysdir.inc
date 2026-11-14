{
  Directory routines of the FreePascalOS System unit (MkDir, RmDir,
  ChDir, GetDir).
}

procedure Do_MkDir(S: RawByteString);
begin
  if not FailedCall(SystemCall(CallCreateDirectory, QWord(PChar(S)), 0, 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_RmDir(S: RawByteString);
var
  Information: TAbiFileInformation;
begin
  if S = '.' then
  begin
    InOutRes := 16;
    Exit;
  end;
  if FailedCall(SystemCall(CallGetPathInformation, QWord(PChar(S)), QWord(@Information), 0, 0, 0, 0)) then
    Exit;
  { RmDir removes directories only. }
  if Information.Kind <> KindDirectory then
  begin
    InOutRes := 5;
    Exit;
  end;
  if not FailedCall(SystemCall(CallRemove, QWord(PChar(S)), 0, 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_ChDir(S: RawByteString);
begin
  if not FailedCall(SystemCall(CallSetCurrentDirectory, QWord(PChar(S)), 0, 0, 0, 0, 0)) then
    InOutRes := 0
  else if InOutRes = 2 then
    { A missing directory is "path not found", as in TP7. }
    InOutRes := 3;
end;

procedure Do_GetDir(DriveNr: Byte; var Dir: RawByteString);
var
  Buffer: array[0..4095] of Char;
begin
  Dir := '';
  if SystemCall(CallGetCurrentDirectory, QWord(@Buffer[0]), SizeOf(Buffer), 0, 0, 0, 0) >= 0 then
  begin
    Dir := Buffer;
    SetCodePage(Dir, DefaultFileSystemCodePage, False);
  end;
end;
