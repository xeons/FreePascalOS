{
  AHCI requests: the driver object "ahci" and its disk devices.

  Every disk gets a device object without a name; the block device layer
  (Io.BlockDevice) sends it read and write requests for whole blocks.

  Once the controller's interrupt is connected, requests are handled
  asynchronously. The read or write routine starts the request's first
  command - or queues the request if the port is busy - and returns
  StatusPending. When a command finishes the port interrupts; the
  interrupt handler only notes the port's interrupt status and queues
  the port's deferred call, which copies the data, starts the next piece
  of a large request (the bounce buffer holds 64 KiB) or completes it,
  and then starts the next waiting request.

  Before that (while disks are identified), or if the controller has no
  MSI, commands are polled and requests complete before the routine
  returns.
}
unit Drivers.AhciRequests;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.Arch.TrapFrame,
  Io.Manager,
  Drivers.AhciPort;

{ Creates the driver object; called once, before the first disk. }
procedure CreateAhciDriver;
{ Creates Port's device object (Port^.Device). False if memory is short. }
function CreateAhciDevice(Port: PAhciPort): Boolean;
{ Switches Port to interrupt driven requests; its interrupts must be on. }
procedure UseInterruptsForPort(Port: PAhciPort);
{ The controller's interrupt handler; Context is the PAhciController. }
procedure HandleAhciInterrupt(Frame: PTrapFrame; Context: Pointer);

implementation

uses
  Runtime.Atomic,
  Runtime.Memory,
  Abi.SystemCalls,
  Kernel.PriorityLevel,
  Kernel.SpinLock,
  Kernel.Mutex,
  Kernel.DeferredCalls;

const
  PortInterruptErrors = PortInterruptInterfaceFatal or PortInterruptHostBusData or
    PortInterruptHostBusFatal or PortInterruptTaskFileError;

var
  AhciDriver: PDriverObject;

function PortOf(Device: PDeviceObject): PAhciPort;
begin
  Result := PAhciPort(Device^.Extension);
end;

function AtaCommandFor(Request: PIoRequest): Byte;
begin
  if Request^.Operation = IoFunctionWrite then
    Result := AtaCommandWriteDmaExtended
  else
    Result := AtaCommandReadDmaExtended;
end;

{ The next piece of Request starting CurrentDone bytes in: how many
  bytes, at which block. }
function PieceLength(Port: PAhciPort; Request: PIoRequest; Done: QWord): QWord;
begin
  Result := Request^.Length - Done;
  if Result > MaximumBytesPerCommand then
    Result := MaximumBytesPerCommand - MaximumBytesPerCommand mod Port^.BlockSize;
end;

function RequestIsValid(Port: PAhciPort; var Request: TIoRequest): Boolean;
begin
  Result := (Request.Length > 0) and (Request.Length mod Port^.BlockSize = 0) and
    (Request.Offset mod Port^.BlockSize = 0) and
    (Request.Offset div Port^.BlockSize < Port^.BlockCount) and
    (Request.Length div Port^.BlockSize <= Port^.BlockCount - Request.Offset div Port^.BlockSize);
end;

{ --- Polled requests ------------------------------------------------------ }

function TransferPolled(Port: PAhciPort; var Request: TIoRequest): LongInt;
var
  Done: QWord;
  Piece: QWord;
  IsWrite: Boolean;
begin
  IsWrite := Request.Operation = IoFunctionWrite;
  Result := ErrorNone;
  Done := 0;
  AcquireMutex(Port^.PollingLock);
  while Done < Request.Length do
  begin
    Piece := PieceLength(Port, @Request, Done);
    if IsWrite then
      CopyToBounceBuffer(Port, PByte(Request.Buffer) + Done, Piece);
    if not ExecuteCommand(Port, AtaCommandFor(@Request), (Request.Offset + Done) div Port^.BlockSize,
      Word(Piece div Port^.BlockSize), Piece, IsWrite) then
    begin
      Result := ErrorIo;
      Break;
    end;
    if not IsWrite then
      CopyFromBounceBuffer(Port, PByte(Request.Buffer) + Done, Piece);
    Done := Done + Piece;
  end;
  ReleaseMutex(Port^.PollingLock);
  Request.Information := Int64(Done);
end;

{ --- Interrupt driven requests -------------------------------------------- }

{ Starts the command for the next piece of Port^.Current. If it cannot
  be started, the deferred call is asked to fail the request. The caller
  holds StateLock. }
procedure StartPieceLocked(Port: PAhciPort);
var
  Request: PIoRequest;
  IsWrite: Boolean;
begin
  Request := Port^.Current;
  IsWrite := Request^.Operation = IoFunctionWrite;
  Port^.CurrentPiece := PieceLength(Port, Request, Port^.CurrentDone);
  if IsWrite then
    CopyToBounceBuffer(Port, PByte(Request^.Buffer) + Port^.CurrentDone, Port^.CurrentPiece);
  if not IssueCommand(Port, AtaCommandFor(Request),
    (Request^.Offset + Port^.CurrentDone) div Port^.BlockSize,
    Word(Port^.CurrentPiece div Port^.BlockSize), Port^.CurrentPiece, IsWrite) then
  begin
    Port^.StartFailed := True;
    QueueDeferredCall(Port^.FinishCommand);
  end;
end;

{ Makes Request the running one and starts it. Caller holds StateLock. }
procedure BeginRequestLocked(Port: PAhciPort; Request: PIoRequest);
begin
  Port^.Current := Request;
  Port^.CurrentDone := 0;
  Port^.StartFailed := False;
  StartPieceLocked(Port);
end;

{ Takes the noted interrupt status of Port. }
function TakeSeenStatus(Port: PAhciPort): LongWord;
begin
  Result := LongWord(AtomicExchange(Port^.SeenInterruptStatus, 0));
end;

{ Deferred call, after the port interrupted (or a start failed). }
procedure FinishPortCommand(Context: Pointer);
var
  Port: PAhciPort;
  Request: PIoRequest;
  Seen: LongWord;
  Status: LongInt;
  PreviousLevel: TPriorityLevel;
begin
  Port := PAhciPort(Context);
  Seen := TakeSeenStatus(Port);
  PreviousLevel := AcquireSpinLock(Port^.StateLock);
  Request := Port^.Current;
  if Request = nil then
  begin
    ReleaseSpinLock(Port^.StateLock, PreviousLevel);
    Exit;
  end;

  if Port^.StartFailed or ((Seen and PortInterruptErrors) <> 0) then
    Status := ErrorIo
  else if (ReadRegister(Port^.Registers, PortCommandIssue) and 1) <> 0 then
  begin
    { Not finished yet (a stray interrupt). }
    ReleaseSpinLock(Port^.StateLock, PreviousLevel);
    Exit;
  end
  else if not CommandSucceeded(Port) then
    Status := ErrorIo
  else
  begin
    if Request^.Operation = IoFunctionRead then
      CopyFromBounceBuffer(Port, PByte(Request^.Buffer) + Port^.CurrentDone, Port^.CurrentPiece);
    Port^.CurrentDone := Port^.CurrentDone + Port^.CurrentPiece;
    if Port^.CurrentDone < Request^.Length then
    begin
      StartPieceLocked(Port);
      ReleaseSpinLock(Port^.StateLock, PreviousLevel);
      Exit;
    end;
    Status := ErrorNone;
  end;

  Request^.Information := Int64(Port^.CurrentDone);
  Port^.Current := TakeQueuedRequest(Port^.Waiting);
  if Port^.Current <> nil then
    BeginRequestLocked(Port, Port^.Current);
  ReleaseSpinLock(Port^.StateLock, PreviousLevel);
  { Outside the lock: whoever waits for the request may send the next
    one at once. }
  CompleteRequest(Request^, Status);
end;

function TransferWithInterrupts(Port: PAhciPort; var Request: TIoRequest): LongInt;
var
  PreviousLevel: TPriorityLevel;
begin
  Result := StatusPending;
  PreviousLevel := AcquireSpinLock(Port^.StateLock);
  if Port^.Current = nil then
    BeginRequestLocked(Port, @Request)
  else if not QueueRequest(Port^.Waiting, Request) then
    Result := ErrorInterrupted;
  ReleaseSpinLock(Port^.StateLock, PreviousLevel);
end;

procedure HandleAhciInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Controller: PAhciController;
  Pending: LongWord;
  PortNumber: LongWord;
  Port: PAhciPort;
  PortStatus: LongWord;
  Seen: PtrUInt;
begin
  Controller := PAhciController(Context);
  Pending := ReadRegister(Controller^.Registers, RegisterInterruptStatus);
  for PortNumber := 0 to MaximumPorts - 1 do
  begin
    if (Pending and (LongWord(1) shl PortNumber)) = 0 then
      Continue;
    Port := Controller^.Ports[PortNumber];
    if Port = nil then
      Continue;
    PortStatus := ReadRegister(Port^.Registers, PortInterruptStatus);
    WriteRegister(Port^.Registers, PortInterruptStatus, PortStatus);
    repeat
      Seen := AtomicLoad(Port^.SeenInterruptStatus);
    until AtomicCompareExchange(Port^.SeenInterruptStatus, Seen or PortStatus, Seen) = Seen;
    QueueDeferredCall(Port^.FinishCommand);
  end;
  { Port status first: a port whose status is still set would raise the
    controller's bit again. }
  WriteRegister(Controller^.Registers, RegisterInterruptStatus, Pending);
end;

{ --- The driver ------------------------------------------------------------ }

function TransferAhciDevice(Device: PDeviceObject; var Request: TIoRequest): LongInt;
var
  Port: PAhciPort;
begin
  Port := PortOf(Device);
  if not RequestIsValid(Port, Request) then
    Exit(ErrorInvalidArgument);
  if Port^.InterruptDriven then
    Result := TransferWithInterrupts(Port, Request)
  else
    Result := TransferPolled(Port, Request);
end;

procedure CreateAhciDriver;
var
  Dispatch: TDispatchTable;
begin
  if AhciDriver <> nil then
    Exit;
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @TransferAhciDevice;
  Dispatch[IoFunctionWrite] := @TransferAhciDevice;
  AhciDriver := CreateDriver('ahci', Dispatch);
end;

function CreateAhciDevice(Port: PAhciPort): Boolean;
const
  NobodyMayOpen = 0;
begin
  InitializeMutex(Port^.PollingLock);
  InitializeSpinLock(Port^.StateLock);
  InitializeRequestQueue(Port^.Waiting);
  InitializeDeferredCall(Port^.FinishCommand, @FinishPortCommand, Port);
  Port^.Device := CreateDevice(AhciDriver, nil, DeviceKindBlock, NobodyMayOpen, 0);
  if Port^.Device = nil then
    Exit(False);
  Port^.Device^.Extension := Port;
  Result := True;
end;

procedure UseInterruptsForPort(Port: PAhciPort);
begin
  { Wait for a polled request that is still running. }
  AcquireMutex(Port^.PollingLock);
  Port^.InterruptDriven := True;
  ReleaseMutex(Port^.PollingLock);
end;

end.
