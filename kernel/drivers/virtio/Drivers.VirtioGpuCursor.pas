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
  A virtio GPU scanout's cursor: drawn by the host over the picture,
  from a 64 x 64 resource of its own.

  The resource is backed by the display's cursor image page, which the
  program maps and writes the image into; a new image is copied to the
  host (on the control queue) and then given to the cursor with its
  hotspot (update cursor, on the cursor queue). Moving sends only the
  place (move cursor); hiding is an update naming no resource.

  The log says when the cursor is shown, hidden or given a new image,
  and where it came to rest after moving: a timer looks a quarter of a
  second after a move and writes the place if it changed since the last
  line, so a moving pointer writes a few lines, not one a move.
}
unit Drivers.VirtioGpuCursor;

{$mode objfpc}

interface

uses
  Drivers.DisplayDevice,
  Drivers.VirtioGpuResources;

{ Makes the scanout's cursor resource on CursorImageMemory; False if
  the device refused it. Called with the batch empty. }
function SetUpGpuCursor(Scanout: PGpuScanout): Boolean;
{ The adapter's UpdateCursor (Context is the scanout). }
function UpdateGpuCursor(Adapter: PDisplayAdapter; const Cursor: TDisplayCursor; ImageChanged: Boolean): Boolean;
{ After waking: the resource made again and the cursor as it was. }
procedure RestoreGpuCursor(Scanout: PGpuScanout);

implementation

uses
  Runtime.Memory,
  Io.Dma,
  Kernel.Mutex,
  Kernel.Timers,
  Kernel.DeferredCalls,
  Debug.Output,
  Drivers.VirtioGpuProtocol,
  Drivers.VirtioGpuQueues;

const
  CursorSize = 64;
  CursorImageBytes = CursorSize * CursorSize * 4;
  RestLogMilliseconds = 250;
  MaximumLoggedScanouts = 16;

type
  TRestLog = record
    Scanout: PGpuScanout;
    Timer: TTimer;
    Call: TDeferredCall;
  end;

var
  RestLogs: array[0..MaximumLoggedScanouts - 1] of TRestLog;
  RestLogCount: LongInt;

procedure WriteCursorLine(Scanout: PGpuScanout; What: PChar);
begin
  DebugBeginMessage;
  DebugWriteTag('virtio-gpu');
  DebugWrite('scanout ');
  DebugWriteDecimal(Scanout^.Index);
  DebugWrite(' cursor ');
  DebugWrite(What);
  DebugWrite(' at ');
  DebugWriteSignedDecimal(Scanout^.Cursor.X);
  DebugWrite(',');
  DebugWriteSignedDecimal(Scanout^.Cursor.Y);
  DebugWriteLine('');
  DebugEndMessage;
  Scanout^.LoggedX := Scanout^.Cursor.X;
  Scanout^.LoggedY := Scanout^.Cursor.Y;
end;

procedure LogRestingPlace(Context: Pointer);
var
  Scanout: PGpuScanout;
begin
  Scanout := PGpuScanout(Context);
  if Scanout^.CursorShown and ((Scanout^.Cursor.X <> Scanout^.LoggedX) or (Scanout^.Cursor.Y <> Scanout^.LoggedY)) then
    WriteCursorLine(Scanout, 'moved');
end;

function RestLogOf(Scanout: PGpuScanout): LongInt;
var
  Index: LongInt;
begin
  for Index := 0 to RestLogCount - 1 do
    if RestLogs[Index].Scanout = Scanout then
      Exit(Index);
  Result := -1;
end;

procedure LogAfterRest(Scanout: PGpuScanout);
var
  Index: LongInt;
begin
  Index := RestLogOf(Scanout);
  if Index >= 0 then
    SetTimer(RestLogs[Index].Timer, RestLogMilliseconds, RestLogs[Index].Call);
end;

procedure AddRestLog(Scanout: PGpuScanout);
begin
  if RestLogCount = MaximumLoggedScanouts then
    Exit;
  RestLogs[RestLogCount].Scanout := Scanout;
  InitializeTimer(RestLogs[RestLogCount].Timer);
  InitializeDeferredCall(RestLogs[RestLogCount].Call, @LogRestingPlace, Scanout);
  Inc(RestLogCount);
end;

function SetUpGpuCursor(Scanout: PGpuScanout): Boolean;
var
  Device: PGpuDevice;
begin
  Device := Scanout^.Device;
  Scanout^.CursorResourceId := NewGpuResourceId(Device);
  Result := BeginCreateResource(Device, Scanout^.CursorResourceId, GpuFormatBlueGreenRedAlpha, CursorSize,
      CursorSize) and
    BeginAttachBacking(Device, Scanout^.CursorResourceId, Scanout^.CursorImageMemory.DeviceAddress,
      CursorImageBytes) and
    RunGpuCommands(Device);
  if Result then
    AddRestLog(Scanout);
end;

function SendCursor(Scanout: PGpuScanout; CommandType: LongWord; ResourceId: LongWord): Boolean;
var
  Command: TGpuUpdateCursor;
begin
  ZeroMemory(@Command, SizeOf(Command));
  Command.Header.CommandType := CommandType;
  Command.Position.ScanoutId := Scanout^.Index;
  Command.Position.X := LongWord(Scanout^.Cursor.X);
  Command.Position.Y := LongWord(Scanout^.Cursor.Y);
  Command.ResourceId := ResourceId;
  Command.HotspotX := Scanout^.Cursor.HotspotX;
  Command.HotspotY := Scanout^.Cursor.HotspotY;
  Result := SendGpuCursorCommand(Scanout^.Device, Command);
end;

{ The image copied to the host, then the cursor shown with it. }
function ShowImage(Scanout: PGpuScanout): Boolean;
var
  Device: PGpuDevice;
begin
  Device := Scanout^.Device;
  { What was drawn into the image (through the caches) reaches memory
    before the device copies it. }
  PrepareDmaToDevice(Device^.Virtio.Dma, Scanout^.CursorImageMemory.Address, CursorImageBytes);
  Result := BeginTransferToHost(Device, Scanout^.CursorResourceId, CursorSize, 0, 0, CursorSize, CursorSize) and
    RunGpuCommands(Device) and SendCursor(Scanout, GpuCommandUpdateCursor, Scanout^.CursorResourceId);
end;

function TellDevice(Scanout: PGpuScanout; ImageChanged: Boolean): Boolean;
begin
  if not Scanout^.Cursor.Visible then
  begin
    Result := not Scanout^.CursorShown or SendCursor(Scanout, GpuCommandUpdateCursor, 0);
    if Scanout^.CursorShown then
      WriteCursorLine(Scanout, 'hidden');
    Scanout^.CursorShown := False;
    Exit;
  end;
  if ImageChanged or not Scanout^.CursorShown then
  begin
    Result := ShowImage(Scanout);
    if not Scanout^.CursorShown then
      WriteCursorLine(Scanout, 'shown')
    else
      WriteCursorLine(Scanout, 'given an image');
    Scanout^.CursorShown := True;
    Exit;
  end;
  Result := SendCursor(Scanout, GpuCommandMoveCursor, Scanout^.CursorResourceId);
  LogAfterRest(Scanout);
end;

function UpdateGpuCursor(Adapter: PDisplayAdapter; const Cursor: TDisplayCursor; ImageChanged: Boolean): Boolean;
var
  Scanout: PGpuScanout;
begin
  Scanout := PGpuScanout(Adapter^.Context);
  AcquireMutex(Scanout^.Device^.Lock);
  Scanout^.Cursor := Cursor;
  { A new image while hidden is only copied when it shows. }
  if ImageChanged and not Cursor.Visible then
    Result := True
  else
    Result := TellDevice(Scanout, ImageChanged);
  ReleaseMutex(Scanout^.Device^.Lock);
end;

procedure RestoreGpuCursor(Scanout: PGpuScanout);
var
  WasShown: Boolean;
begin
  if Scanout^.CursorResourceId = 0 then
    Exit;
  if not BeginCreateResource(Scanout^.Device, Scanout^.CursorResourceId, GpuFormatBlueGreenRedAlpha, CursorSize,
       CursorSize) or
     not BeginAttachBacking(Scanout^.Device, Scanout^.CursorResourceId, Scanout^.CursorImageMemory.DeviceAddress,
       CursorSize * CursorSize * 4) or
     not RunGpuCommands(Scanout^.Device) then
    Exit;
  WasShown := Scanout^.CursorShown;
  Scanout^.CursorShown := False;
  if WasShown then
    TellDevice(Scanout, True);
end;

end.
