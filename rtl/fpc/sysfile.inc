{
  Low level file routines of the FreePascalOS System unit, used by typed,
  untyped and text files (file.inc, typefile.inc, text.inc).

  Each sets InOutRes: 0 on success, else the error mapped by
  ErrorToInOutRes (sysos.inc).
}

procedure Do_Close(Handle: THandle);
begin
  if not FailedCall(SystemCall(CallClose, QWord(Int64(Handle)), 0, 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_Erase(P: PChar; PChangeable: Boolean);
var
  Information: TAbiFileInformation;
begin
  if FailedCall(SystemCall(CallGetPathInformation, QWord(P), QWord(@Information), 0, 0, 0, 0)) then
    Exit;
  { Erase removes files only. }
  if Information.Kind = KindDirectory then
  begin
    InOutRes := 2;
    Exit;
  end;
  if not FailedCall(SystemCall(CallRemove, QWord(P), 0, 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_Truncate(Handle: THandle; FPos: Int64);
begin
  if not FailedCall(SystemCall(CallSetFileSize, QWord(Int64(Handle)), QWord(FPos), 0, 0, 0, 0)) then
    InOutRes := 0;
end;

procedure Do_Rename(P1, P2: PChar; P1Changeable, P2Changeable: Boolean);
begin
  if not FailedCall(SystemCall(CallRename, QWord(P1), QWord(P2), 0, 0, 0, 0)) then
    InOutRes := 0;
end;

function Do_Write(Handle: THandle; Addr: Pointer; Len: LongInt): LongInt;
var
  CallResult: Int64;
begin
  repeat
    CallResult := SystemCall(CallWrite, QWord(Int64(Handle)), QWord(Addr), QWord(Int64(Len)), 0, 0, 0);
  until CallResult <> -ErrorInterrupted;
  if FailedCall(CallResult) then
    Do_Write := 0
  else
  begin
    Do_Write := LongInt(CallResult);
    InOutRes := 0;
  end;
end;

function Do_Read(Handle: THandle; Addr: Pointer; Len: LongInt): LongInt;
var
  CallResult: Int64;
begin
  repeat
    CallResult := SystemCall(CallRead, QWord(Int64(Handle)), QWord(Addr), QWord(Int64(Len)), 0, 0, 0);
  until CallResult <> -ErrorInterrupted;
  if FailedCall(CallResult) then
    Do_Read := 0
  else
  begin
    Do_Read := LongInt(CallResult);
    InOutRes := 0;
  end;
end;

function SeekHandle(Handle: THandle; Offset: Int64; Origin: LongWord): Int64;
begin
  SeekHandle := SystemCall(CallSeek, QWord(Int64(Handle)), QWord(Offset), Origin, 0, 0, 0);
  if not FailedCall(SeekHandle) then
    InOutRes := 0;
end;

function Do_FilePos(Handle: THandle): Int64;
begin
  Do_FilePos := SeekHandle(Handle, 0, SeekFromCurrent);
end;

procedure Do_Seek(Handle: THandle; Pos: Int64);
begin
  SeekHandle(Handle, Pos, SeekFromStart);
end;

function Do_SeekEnd(Handle: THandle): Int64;
begin
  Do_SeekEnd := SeekHandle(Handle, 0, SeekFromEnd);
end;

function Do_FileSize(Handle: THandle): Int64;
var
  Information: TAbiFileInformation;
begin
  Do_FileSize := 0;
  if FailedCall(SystemCall(CallGetHandleInformation, QWord(Int64(Handle)), QWord(@Information), 0, 0, 0, 0)) then
    Exit;
  Do_FileSize := Int64(Information.SizeInBytes);
  InOutRes := 0;
end;

{ Flags: the access in the low two bits (0 read, 1 write, 2 both), $100
  append, $1000 create or truncate, $10000 do not close the file first
  (text files). FileRec and TextRec both start with Handle and Mode. }
procedure Do_Open(var F; P: PChar; Flags: LongInt; PChangeable: Boolean);
var
  OpenFlags: LongWord;
  CallResult: Int64;
begin
  if (Flags and $10000) = 0 then
    case FileRec(F).Mode of
      fmInput, fmOutput, fmInOut: Do_Close(FileRec(F).Handle);
      fmClosed: ;
    else
      begin
        InOutRes := 102;
        Exit;
      end;
    end;
  FileRec(F).Handle := UnusedHandle;
  case Flags and 3 of
    0:
      begin
        OpenFlags := OpenRead;
        FileRec(F).Mode := fmInput;
      end;
    1:
      begin
        OpenFlags := OpenWrite;
        FileRec(F).Mode := fmOutput;
      end;
  else
    begin
      OpenFlags := OpenRead or OpenWrite;
      FileRec(F).Mode := fmInOut;
    end;
  end;
  if (Flags and $1000) <> 0 then
    OpenFlags := OpenFlags or OpenCreate or OpenTruncate
  else if (Flags and $100) <> 0 then
    OpenFlags := OpenFlags or OpenAppend;

  { An empty name means the standard handles. }
  if P[0] = #0 then
  begin
    case FileRec(F).Mode of
      fmInput: FileRec(F).Handle := StdInputHandle;
      fmInOut, fmOutput: FileRec(F).Handle := StdOutputHandle;
      fmAppend:
        begin
          FileRec(F).Handle := StdOutputHandle;
          FileRec(F).Mode := fmOutput;
        end;
    end;
    Exit;
  end;

  CallResult := SystemCall(CallOpen, QWord(P), OpenFlags, 0, 0, 0, 0);
  { A read-only volume still lets Reset open the file for reading. }
  if (CallResult = -ErrorReadOnly) and ((OpenFlags and OpenWrite) <> 0) and
     ((Flags and $1000) = 0) then
  begin
    OpenFlags := OpenFlags and not OpenWrite;
    FileRec(F).Mode := fmInput;
    CallResult := SystemCall(CallOpen, QWord(P), OpenFlags, 0, 0, 0, 0);
  end;
  if FailedCall(CallResult) then
    FileRec(F).Mode := fmClosed
  else
  begin
    FileRec(F).Handle := THandle(CallResult);
    InOutRes := 0;
  end;
end;
