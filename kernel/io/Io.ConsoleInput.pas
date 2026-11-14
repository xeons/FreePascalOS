{
  Where the console's input comes from.

  The console opens each input device (the keyboard, the serial port)
  and always keeps one read request outstanding on it. When a read
  completes, its bytes go to the console (DeliverConsoleInput, which
  also notices Ctrl-C and Ctrl-Z) and the next read is sent. Completion
  routines run at DispatchLevel and must not call back into the driver
  directly, which could nest without bound while input keeps arriving,
  so the next read is sent from a deferred call.

  The input devices are exclusive, so while the console holds them open
  no program can read them as well.
}
unit Io.ConsoleInput;

{$mode objfpc}
{$pointermath on}

interface

{ Opens the device called Name and starts reading it for the console.
  Returns False if there is no such device or it cannot be opened. }
function AttachConsoleInput(Name: PChar): Boolean;

implementation

uses
  Runtime.Memory,
  Abi.SystemCalls,
  Memory.KernelHeap,
  Kernel.DeferredCalls,
  Io.Manager,
  Io.DeviceFiles,
  Io.Console,
  Debug.Output;

const
  ReadChunkSize = 64;

type
  PInputSource = ^TInputSource;
  TInputSource = record
    OpenFile: PDeviceFile;
    Request: TIoRequest;
    Buffer: array[0..ReadChunkSize - 1] of Byte;
    SendNextRead: TDeferredCall;
  end;

procedure InputArrived(Request: PIoRequest); forward;

procedure SendRead(Context: Pointer);
var
  Source: PInputSource;
begin
  Source := PInputSource(Context);
  FillMemory(@Source^.Request, SizeOf(Source^.Request), 0);
  Source^.Request.Operation := IoFunctionRead;
  Source^.Request.OpenFile := Source^.OpenFile;
  Source^.Request.Buffer := @Source^.Buffer[0];
  Source^.Request.Length := ReadChunkSize;
  Source^.Request.CompletionRoutine := @InputArrived;
  Source^.Request.CompletionContext := Source;
  CallDriver(Source^.OpenFile^.Device, Source^.Request);
end;

procedure ReportReadFailure(Source: PInputSource; Status: LongInt);
begin
  DebugBeginMessage;
  DebugWriteTag('console');
  DebugWrite('Stopped reading ');
  DebugWrite(@Source^.OpenFile^.Device^.Name[0]);
  DebugWrite(': error ');
  DebugWriteDecimal(Status);
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure InputArrived(Request: PIoRequest);
var
  Source: PInputSource;
  Index: Int64;
begin
  Source := PInputSource(Request^.CompletionContext);
  if Request^.Status <> ErrorNone then
  begin
    ReportReadFailure(Source, Request^.Status);
    Exit;
  end;
  for Index := 0 to Request^.Information - 1 do
    DeliverConsoleInput(Char(Source^.Buffer[Index]));
  QueueDeferredCall(Source^.SendNextRead);
end;

function AttachConsoleInput(Name: PChar): Boolean;
var
  Device: PDeviceObject;
  Source: PInputSource;
begin
  Result := False;
  Device := FindDevice(Name);
  if Device = nil then
    Exit;
  Source := PInputSource(AllocateZeroedKernelMemory(SizeOf(TInputSource)));
  if Source = nil then
    Exit;
  if OpenDevice(Device, OpenRead, Source^.OpenFile) <> ErrorNone then
  begin
    FreeKernelMemory(Source);
    Exit;
  end;
  InitializeDeferredCall(Source^.SendNextRead, @SendRead, Source);
  SendRead(Source);
  Result := True;
end;

end.
