{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  Positioned reads and writes and syncing one file (CallReadAt,
  CallWriteAt, CallSyncHandle): pread, pwrite, fsync and fdatasync.

  pread and pwrite never touch the handle's position, so threads
  sharing an open file (or processes sharing it after fork) each read
  and write where they say, without seeking around one another. Each
  piece (TransferChunkSize) is one VFS call under the volume's lock.
  The handle's object is referenced for the whole call.
}
unit Processes.PositionedFileCalls;

{$mode objfpc}
{$pointermath on}

interface

function PerformReadAt(Handle: Int64; BufferAddress, ByteCount, Offset: QWord): Int64;
function PerformWriteAt(Handle: Int64; BufferAddress, ByteCount, Offset: QWord): Int64;
function PerformSyncHandle(Handle: Int64; Flags: QWord): Int64;

implementation

uses
  Abi.SystemCalls,
  Objects.Manager,
  FileSystem.Types,
  FileSystem.Files,
  Io.Manager,
  Io.DeviceFiles,
  Processes.Handles,
  Processes.UserAccess,
  Processes.ObjectCalls;

const
  { The largest offset a file may be read or written at. }
  OffsetLimit = QWord(High(Int64));

function Failure(Error: LongInt): Int64;
begin
  Result := -Int64(Error);
end;

{ Reads one piece at Offset into Buffer: the bytes read or minus an
  error. }
function ReadPieceAt(Kind: THandleKind; ObjectBody: Pointer; Buffer: PByte; Piece, Offset: QWord): Int64;
var
  BytesRead: QWord;
  Status: TFileSystemStatus;
begin
  if Kind = HandleKindDevice then
    Exit(ReadDeviceAt(PDeviceFile(ObjectBody), Buffer, Piece, Offset));
  Status := ReadFromFileAtPosition(POpenFile(ObjectBody), Offset, Buffer, Piece, BytesRead);
  if Status <> StatusSuccess then
    Exit(Failure(ErrorFromStatus(Status)));
  Result := Int64(BytesRead);
end;

function WritePieceAt(Kind: THandleKind; ObjectBody: Pointer; Buffer: PByte; Piece, Offset: QWord): Int64;
var
  Written: QWord;
  Status: TFileSystemStatus;
begin
  if Kind = HandleKindDevice then
    Exit(WriteDeviceAt(PDeviceFile(ObjectBody), Buffer, Piece, Offset));
  Status := WriteToFileAtPosition(POpenFile(ObjectBody), Offset, Buffer, Piece, Written);
  if (Status <> StatusSuccess) and (Written = 0) then
    Exit(Failure(ErrorFromStatus(Status)));
  Result := Int64(Written);
end;

{ Only files and block devices have positions. }
function CheckPositionedKind(Kind: THandleKind): LongInt;
begin
  case Kind of
    HandleKindFile, HandleKindDevice: Result := ErrorNone;
    HandleKindPipeReadEnd, HandleKindPipeWriteEnd, HandleKindSocket, HandleKindLocalSocket:
      Result := ErrorIllegalSeek;
  else
    Result := ErrorBadHandle;
  end;
end;

function ReadInPiecesAt(Kind: THandleKind; ObjectBody: Pointer; BufferAddress, ByteCount, Offset: QWord): Int64;
var
  Buffer: PByte;
  BufferSize: QWord;
  Total: QWord;
  Piece: QWord;
  Count: Int64;
begin
  Buffer := PByte(AllocateTransferBuffer(ByteCount, BufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Total := 0;
  Result := 0;
  while Total < ByteCount do
  begin
    Piece := ByteCount - Total;
    if Piece > BufferSize then
      Piece := BufferSize;
    Count := ReadPieceAt(Kind, ObjectBody, Buffer, Piece, Offset + Total);
    if (Count > 0) and (CopyToUser(BufferAddress + Total, Buffer, QWord(Count)) <> ErrorNone) then
      Count := Failure(ErrorBadAddress);
    if Count < 0 then
    begin
      if Total = 0 then
        Result := Count;
      Break;
    end;
    Total := Total + QWord(Count);
    if QWord(Count) < Piece then
      Break;
  end;
  if Total > 0 then
    Result := Int64(Total);
  FreeTransferBuffer(Buffer);
end;

function WriteInPiecesAt(Kind: THandleKind; ObjectBody: Pointer; BufferAddress, ByteCount, Offset: QWord): Int64;
var
  Buffer: PByte;
  BufferSize: QWord;
  Total: QWord;
  Piece: QWord;
  Count: Int64;
begin
  Buffer := PByte(AllocateTransferBuffer(ByteCount, BufferSize));
  if Buffer = nil then
    Exit(Failure(ErrorOutOfMemory));
  Total := 0;
  Result := 0;
  while Total < ByteCount do
  begin
    Piece := ByteCount - Total;
    if Piece > BufferSize then
      Piece := BufferSize;
    if CopyFromUser(Buffer, BufferAddress + Total, Piece) <> ErrorNone then
      Count := Failure(ErrorBadAddress)
    else
      Count := WritePieceAt(Kind, ObjectBody, Buffer, Piece, Offset + Total);
    if Count < 0 then
    begin
      if Total = 0 then
        Result := Count;
      Break;
    end;
    Total := Total + QWord(Count);
    if QWord(Count) < Piece then
      Break;
  end;
  if Total > 0 then
    Result := Int64(Total);
  FreeTransferBuffer(Buffer);
end;

{ The checks both calls make; on success ObjectBody is referenced. }
function BeginPositioned(Handle: Int64; BufferAddress, ByteCount, Offset: QWord; NeedWrite: Boolean;
  out Kind: THandleKind; out ObjectBody: Pointer): LongInt;
begin
  ObjectBody := ReferenceHandle(Handle, Kind);
  if ObjectBody = nil then
    Exit(ErrorBadHandle);
  Result := CheckPositionedKind(Kind);
  if (Result = ErrorNone) and ((Offset > OffsetLimit) or (ByteCount > OffsetLimit - Offset)) then
    Result := ErrorInvalidArgument;
  if (Result = ErrorNone) and not UserRangeIsValid(BufferAddress, ByteCount, NeedWrite) then
    Result := ErrorBadAddress;
  if Result <> ErrorNone then
  begin
    DereferenceObject(ObjectBody);
    ObjectBody := nil;
  end;
end;

function PerformReadAt(Handle: Int64; BufferAddress, ByteCount, Offset: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Error: LongInt;
begin
  Error := BeginPositioned(Handle, BufferAddress, ByteCount, Offset, True, Kind, ObjectBody);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if ByteCount = 0 then
    Result := 0
  else
    Result := ReadInPiecesAt(Kind, ObjectBody, BufferAddress, ByteCount, Offset);
  DereferenceObject(ObjectBody);
end;

function PerformWriteAt(Handle: Int64; BufferAddress, ByteCount, Offset: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
  Error: LongInt;
begin
  Error := BeginPositioned(Handle, BufferAddress, ByteCount, Offset, False, Kind, ObjectBody);
  if Error <> ErrorNone then
    Exit(Failure(Error));
  if ByteCount = 0 then
    Result := 0
  else
    Result := WriteInPiecesAt(Kind, ObjectBody, BufferAddress, ByteCount, Offset);
  DereferenceObject(ObjectBody);
end;

function PerformSyncHandle(Handle: Int64; Flags: QWord): Int64;
var
  Kind: THandleKind;
  ObjectBody: Pointer;
begin
  if (Flags and not QWord(SyncHandleDataOnly)) <> 0 then
    Exit(Failure(ErrorInvalidArgument));
  ObjectBody := ReferenceHandle(Handle, Kind);
  if ObjectBody = nil then
    Exit(Failure(ErrorBadHandle));
  case Kind of
    HandleKindFile:
      Result := Failure(ErrorFromStatus(SyncFile(POpenFile(ObjectBody), (Flags and SyncHandleDataOnly) <> 0)));
    { Writes to a device go to its driver as they are made. }
    HandleKindDevice:
      Result := 0;
  else
    Result := Failure(ErrorInvalidArgument);
  end;
  DereferenceObject(ObjectBody);
end;

end.
